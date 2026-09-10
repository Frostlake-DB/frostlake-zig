//! Tests that talk to a real engine.
//!
//! Every one skips itself when `FROSTLAKE_URL` names no server, so a checkout with no engine
//! running still reports green rather than red — and never silently passes, because a skip is
//! reported as a skip.
//!
//! ```sh
//! FROSTLAKE_URL=frostlake://localhost:18082 zig build test-integration
//! ```

const std = @import("std");
const testing = std.testing;
const frostlake = @import("frostlake");

const Value = frostlake.Value;
const Date = frostlake.Date;
const Time = frostlake.Time;
const Timestamp = frostlake.Timestamp;

/// The DSN to test against, or null when none was named.
///
/// Caller owns the returned memory.
fn serverUrl(allocator: std.mem.Allocator) !?[]u8 {
    return testing.environ.getAlloc(allocator, "FROSTLAKE_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => err,
    };
}

/// Open a connection to a scratch database, or skip the test.
///
/// Each test gets its own database so nothing it creates can collide with another test's
/// tables — the reason these tests can run against a server that is not otherwise empty.
fn connect(database: []const u8) !frostlake.Connection {
    const base = (try serverUrl(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(base);

    // Create the database over a scopeless connection first: a DSN naming a database that does
    // not exist yet would fail on its own USE.
    {
        var setup = try frostlake.Connection.open(testing.allocator, testing.io, base);
        defer setup.close();
        const create = try std.fmt.allocPrint(testing.allocator, "CREATE OR REPLACE DATABASE {s}", .{database});
        defer testing.allocator.free(create);
        var created = try setup.query(create, &.{});
        created.deinit();
    }

    const dsn = try std.fmt.allocPrint(testing.allocator, "{s}/{s}?schema=PUBLIC", .{ base, database });
    defer testing.allocator.free(dsn);
    return frostlake.Connection.open(testing.allocator, testing.io, dsn);
}

/// `connect` needs the CREATE statement to outlive the call that sends it; this frees it.
fn createScratch(conn: *frostlake.Connection, sql: []const u8) !void {
    var response = try conn.query(sql, &.{});
    response.deinit();
}

test "integration: ping reaches a real engine" {
    const base = (try serverUrl(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(base);

    var conn = try frostlake.Connection.open(testing.allocator, testing.io, base);
    defer conn.close();
    try conn.ping();
}

test "integration: ping refuses something that is not an engine" {
    const base = (try serverUrl(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(base);

    // A port nothing is listening on: the failure must be reported, not swallowed.
    var conn = try frostlake.Connection.open(testing.allocator, testing.io, "frostlake://localhost:1?timeout=2s");
    defer conn.close();
    try testing.expectError(frostlake.Error.TransportFailed, conn.ping());
    try testing.expect(conn.lastError().len > 0);
}

test "integration: CURRENT_VERSION answers" {
    const base = (try serverUrl(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(base);

    var conn = try frostlake.Connection.open(testing.allocator, testing.io, base);
    defer conn.close();

    var response = try conn.query("SELECT CURRENT_VERSION()", &.{});
    defer response.deinit();
    const version = try (try response.scalar()).asText();
    try testing.expect(version.len > 0);
}

test "integration: a table round trips through DDL, DML and SELECT" {
    var conn = try connect("ZIG_RT_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE PEOPLE (ID INTEGER, NAME VARCHAR)");

    const inserted = try conn.exec(
        "INSERT INTO PEOPLE VALUES (?, ?), (?, ?)",
        &.{ Value.of(1), Value.of("Ada"), Value.of(2), Value.of("Grace") },
    );
    try testing.expectEqual(@as(i64, 2), inserted);

    var rows = try conn.query("SELECT ID, NAME FROM PEOPLE ORDER BY ID", &.{});
    defer rows.deinit();

    const set = rows.first();
    try testing.expectEqual(@as(usize, 2), set.rowCount());
    try testing.expectEqual(@as(i64, 1), try (try set.at(0, 0)).asInt());
    try testing.expectEqualStrings("Ada", try (try set.at(0, 1)).asText());
    try testing.expectEqualStrings("Grace", try (try set.atName(1, "NAME")).asText());

    // ...and the row iterator sees the same thing.
    var it = set.iterator();
    var seen: usize = 0;
    while (it.next()) |row| : (seen += 1) {
        _ = try (try row.get("ID")).asInt();
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "integration: update and delete counts" {
    var conn = try connect("ZIG_DML_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (ID INTEGER, V VARCHAR)");
    _ = try conn.exec("INSERT INTO T VALUES (1,'a'), (2,'b'), (3,'c')", &.{});

    try testing.expectEqual(@as(i64, 1), try conn.exec("UPDATE T SET V = 'x' WHERE ID = ?", &.{Value.of(2)}));
    try testing.expectEqual(@as(i64, 1), try conn.exec("DELETE FROM T WHERE ID = ?", &.{Value.of(3)}));

    var rows = try conn.query("SELECT COUNT(*) FROM T", &.{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 2), try (try rows.scalar()).asInt());
}

test "integration: every bound type survives the round trip" {
    var conn = try connect("ZIG_TYPES_DB");
    defer conn.close();

    try createScratch(&conn,
        \\CREATE TABLE T (
        \\  B BOOLEAN, I INTEGER, F FLOAT, S VARCHAR,
        \\  BIG NUMBER(38,0), D DATE, TS TIMESTAMP_NTZ, BIN BINARY
        \\)
    );

    _ = try conn.exec("INSERT INTO T VALUES (?, ?, ?, ?, ?, ?, ?, ?)", &.{
        Value.of(true),
        Value.of(@as(i64, -42)),
        Value.of(@as(f64, 1.5)),
        // A string carrying both of the characters that need escaping.
        Value.of("it's a \\ backslash"),
        Value.decimalText("123456789012345678901234567890"),
        Value.of(Date{ .year = 2026, .month = 8, .day = 24 }),
        Value.of(Timestamp{
            .date = .{ .year = 2026, .month = 8, .day = 24 },
            .time = .{ .hour = 13, .minute = 30, .second = 5, .nanosecond = 250_000_000 },
        }),
        Value.bytes(&.{ 0x00, 0xAB, 0xFF }),
    });

    var rows = try conn.query("SELECT B, I, F, S, BIG, D, TS, BIN FROM T", &.{});
    defer rows.deinit();
    const set = rows.first();

    try testing.expectEqual(true, try (try set.at(0, 0)).asBool());
    try testing.expectEqual(@as(i64, -42), try (try set.at(0, 1)).asInt());
    try testing.expectEqual(@as(f64, 1.5), try (try set.at(0, 2)).asFloat());
    try testing.expectEqualStrings("it's a \\ backslash", try (try set.at(0, 3)).asText());

    // The exact digits survive: an f64 would have rounded this away.
    try testing.expectEqualStrings("123456789012345678901234567890", try (try set.at(0, 4)).asText());

    const date = try (try set.at(0, 5)).asDate();
    try testing.expectEqual(@as(i32, 2026), date.year);
    try testing.expectEqual(@as(u8, 8), date.month);
    try testing.expectEqual(@as(u8, 24), date.day);

    const ts = try (try set.at(0, 6)).asTimestamp();
    try testing.expectEqual(@as(u8, 13), ts.time.hour);
    try testing.expectEqual(@as(u8, 30), ts.time.minute);
    try testing.expectEqual(@as(u8, 5), ts.time.second);
    // The HTTP layer serialises milliseconds, so this is as fine as a round trip gets.
    try testing.expectEqual(@as(u32, 250_000_000), ts.time.nanosecond);

    try testing.expectEqualSlices(u8, &.{ 0x00, 0xAB, 0xFF }, try (try set.at(0, 7)).asBytes());
}

test "integration: NULL binds and reads back as NULL" {
    var conn = try connect("ZIG_NULL_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (A INTEGER, B VARCHAR)");
    _ = try conn.exec("INSERT INTO T VALUES (?, ?)", &.{ Value.nul(), Value.of("x") });

    var rows = try conn.query("SELECT A, B FROM T", &.{});
    defer rows.deinit();
    try testing.expect((try rows.first().at(0, 0)).isNull());
    try testing.expect(!(try rows.first().at(0, 1)).isNull());
}

test "integration: named parameters bind by name" {
    var conn = try connect("ZIG_NAMED_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (ID INTEGER, V VARCHAR)");
    _ = try conn.exec("INSERT INTO T VALUES (1,'a'), (2,'b')", &.{});

    var rows = try conn.queryNamed("SELECT V FROM T WHERE ID = :id", &.{
        .{ .name = "id", .value = Value.of(2) },
    });
    defer rows.deinit();
    try testing.expectEqualStrings("b", try (try rows.scalar()).asText());
}

test "integration: a VARIANT round trips as JSON text" {
    var conn = try connect("ZIG_VARIANT_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (V VARIANT)");
    _ = try conn.exec("INSERT INTO T SELECT ?", &.{Value.jsonText("{\"a\":1,\"b\":[2,3]}")});

    var rows = try conn.query("SELECT V:a FROM T", &.{});
    defer rows.deinit();
    const cell = try rows.scalar();
    // The path extraction answers with the element, however the engine chooses to type it.
    try testing.expect(!cell.isNull());
}

test "integration: several statements answer with one result set each" {
    var conn = try connect("ZIG_MULTI_DB");
    defer conn.close();

    var response = try conn.query("SELECT 1; SELECT 2", &.{});
    defer response.deinit();

    try testing.expectEqual(@as(usize, 2), response.setCount());
    try testing.expectEqual(@as(i64, 1), try (try (try response.set(0)).scalar()).asInt());
    try testing.expectEqual(@as(i64, 2), try (try (try response.set(1)).scalar()).asInt());
}

test "integration: a transaction commits" {
    var conn = try connect("ZIG_TXC_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (ID INTEGER)");

    try conn.begin();
    _ = try conn.exec("INSERT INTO T VALUES (1)", &.{});
    try conn.commit();

    var rows = try conn.query("SELECT COUNT(*) FROM T", &.{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), try (try rows.scalar()).asInt());
}

test "integration: a transaction rolls back" {
    var conn = try connect("ZIG_TXR_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (ID INTEGER)");
    _ = try conn.exec("INSERT INTO T VALUES (1)", &.{});

    try conn.begin();
    _ = try conn.exec("INSERT INTO T VALUES (2)", &.{});
    try conn.rollback();

    var rows = try conn.query("SELECT COUNT(*) FROM T", &.{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), try (try rows.scalar()).asInt());
}

test "integration: a refused statement carries the engine's message" {
    var conn = try connect("ZIG_ERR_DB");
    defer conn.close();

    try testing.expectError(
        frostlake.Error.EngineRefused,
        conn.query("SELECT * FROM NO_SUCH_TABLE", &.{}),
    );
    try testing.expect(conn.lastError().len > 0);
    try testing.expectEqualStrings("SELECT * FROM NO_SUCH_TABLE", conn.lastStatement());

    // ...and the connection is still usable afterwards: a bad statement is not a bad socket.
    try testing.expect(conn.isValid());
    var rows = try conn.query("SELECT 1", &.{});
    rows.deinit();
}

test "integration: column metadata reports type, nullability and scale" {
    var conn = try connect("ZIG_META_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE T (A NUMBER(10,2) NOT NULL, B VARCHAR)");
    _ = try conn.exec("INSERT INTO T VALUES (1.25, 'x')", &.{});

    var rows = try conn.query("SELECT A, B FROM T", &.{});
    defer rows.deinit();
    const set = rows.first();

    const a = try set.column(0);
    try testing.expectEqual(frostlake.Nullability.not_null, a.nullable);
    try testing.expectEqual(@as(i32, 2), frostlake.decode.declaredScale(a));
    try testing.expect(frostlake.decode.hasPrecisionScale(a));
    try testing.expectEqual(frostlake.ColumnKind.decimal, a.kind());

    const b = try set.column(1);
    try testing.expectEqual(frostlake.Nullability.nullable, b.nullable);
    try testing.expectEqual(frostlake.ColumnKind.text, b.kind());
}

test "integration: the DSN's scope reaches the session" {
    var conn = try connect("ZIG_SCOPE_DB");
    defer conn.close();

    var rows = try conn.query("SELECT CURRENT_DATABASE(), CURRENT_SCHEMA()", &.{});
    defer rows.deinit();
    const set = rows.first();
    try testing.expectEqualStrings("ZIG_SCOPE_DB", try (try set.at(0, 0)).asText());
    try testing.expectEqualStrings("PUBLIC", try (try set.at(0, 1)).asText());
}

test "integration: a USE moves the session and reset puts it back" {
    var conn = try connect("ZIG_USE_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE SCHEMA OTHER");

    var moved = try conn.query("USE SCHEMA OTHER", &.{});
    moved.deinit();
    try testing.expect(conn.session_dirty);

    var check = try conn.query("SELECT CURRENT_SCHEMA()", &.{});
    try testing.expectEqualStrings("OTHER", try (try check.scalar()).asText());
    check.deinit();

    try conn.reset();

    var restored = try conn.query("SELECT CURRENT_SCHEMA()", &.{});
    defer restored.deinit();
    try testing.expectEqualStrings("PUBLIC", try (try restored.scalar()).asText());
}

test "integration: a ? inside a literal is not a bind marker" {
    var conn = try connect("ZIG_LIT_DB");
    defer conn.close();

    var rows = try conn.query("SELECT '?', ?", &.{Value.of(7)});
    defer rows.deinit();
    const set = rows.first();
    try testing.expectEqualStrings("?", try (try set.at(0, 0)).asText());
    try testing.expectEqual(@as(i64, 7), try (try set.at(0, 1)).asInt());
}

test "integration: an argument count mismatch never reaches the server" {
    var conn = try connect("ZIG_ARGS_DB");
    defer conn.close();

    try testing.expectError(
        frostlake.Error.BindMismatch,
        conn.query("SELECT ?, ?", &.{Value.of(1)}),
    );
    // The connection is untouched by a binding mistake.
    try testing.expect(conn.isValid());
}
