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

/// Whether this engine refuses a statement pack the caller never asked for.
///
/// Only an engine carrying the statement-count gate refuses one; an older engine runs any pack it
/// is handed. This driver supports both, so a test that rests on the refusal asks first and skips
/// itself where there is no refusal to observe.
fn refusesUnaskedPack(conn: *frostlake.Connection) !bool {
    var accepted = conn.query("SELECT 1; SELECT 2", &.{}) catch |err| {
        if (err == frostlake.Error.EngineRefused) return true;
        return err;
    };
    accepted.deinit();
    return false;
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

    // A request holds one statement unless the session asks for more, so ask first.
    // Zero means any number, which keeps the single statements around it working too.
    var allow = try conn.query("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0", &.{});
    allow.deinit();

    var response = try conn.query("SELECT 1; SELECT 2", &.{});
    defer response.deinit();

    try testing.expectEqual(@as(usize, 2), response.setCount());
    try testing.expectEqual(@as(i64, 1), try (try (try response.set(0)).scalar()).asInt());
    try testing.expectEqual(@as(i64, 2), try (try (try response.set(1)).scalar()).asInt());
}

test "integration: a request may declare its own statement count" {
    var conn = try connect("ZIG_MULTI_CALL_DB");
    defer conn.close();

    // The session is still at one statement a request, so the pack is refused on its count alone —
    // on an engine that counts at all.
    const gated = try refusesUnaskedPack(&conn);

    // The same pack, saying how many statements it holds. No ALTER SESSION anywhere.
    var response = try conn.queryWith("SELECT 1; SELECT 2", &.{}, .{ .multi_statement_count = 2 });
    defer response.deinit();
    try testing.expectEqual(@as(usize, 2), response.setCount());
    try testing.expectEqual(@as(i64, 1), try (try (try response.set(0)).scalar()).asInt());
    try testing.expectEqual(@as(i64, 2), try (try (try response.set(1)).scalar()).asInt());

    // Zero accepts any number.
    var three = try conn.queryWith("SELECT 1; SELECT 2; SELECT 3", &.{}, .{ .multi_statement_count = 0 });
    defer three.deinit();
    try testing.expectEqual(@as(usize, 3), three.setCount());

    // The count belonged to those requests: the session was never moved, so the next pack — asked
    // for by nobody — is refused again.
    //
    // Only an engine carrying the statement-count gate refuses one at all, and this driver
    // supports older engines than that. Against one of those the refusal never comes, so this ends
    // in a SKIP rather than a pass: a green tick would claim an engine had been checked for a
    // refusal it does not make.
    if (!gated) return error.SkipZigTest;
    try testing.expectError(frostlake.Error.EngineRefused, conn.query("SELECT 1; SELECT 2", &.{}));
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

test "integration: a VARIANT path reads straight off a positional marker" {
    var conn = try connect("ZIG_PATH_DB");
    defer conn.close();

    // The marker ends an expression, so the colon after it is a path and not a second
    // placeholder. This used to be refused before anything was sent, for mixing two placeholder
    // styles the caller never mixed.
    var rows = try conn.query("SELECT ?:a AS V", &.{Value.jsonText("{\"a\":[1,2]}")});
    defer rows.deinit();
    try testing.expectEqualStrings("[1,2]", try (try rows.first().scalar()).asText());

    // The spellings that already worked still answer the same thing.
    var wrapped = try conn.query("SELECT (?):a AS V", &.{Value.jsonText("{\"a\":[1,2]}")});
    defer wrapped.deinit();
    try testing.expectEqualStrings("[1,2]", try (try wrapped.first().scalar()).asText());
}

test "integration: a bound f64 arrives as a FLOAT, not as fixed-point" {
    var conn = try connect("ZIG_FLOAT_DB");
    defer conn.close();

    // A bare numeral is fixed-point: the account types 1.5 as NUMBER(2,1) and a whole 2.0 as
    // NUMBER(1,0), which is the integer 2's own type. Snowflake's own driver binds a double so
    // that the account answers FLOAT, and this driver's cast is what reproduces that.
    var rows = try conn.query("SELECT ? AS W, ? AS F, ? AS N", &.{
        frostlake.Value.of(@as(f64, 2.0)),
        frostlake.Value.of(@as(f64, 1.5)),
        frostlake.Value.of(@as(f64, -1.5)),
    });
    defer rows.deinit();
    const set = rows.first();

    try testing.expectEqual(frostlake.ColumnKind.floating, (try set.column(0)).kind());
    try testing.expectEqual(frostlake.ColumnKind.floating, (try set.column(1)).kind());
    try testing.expectEqual(frostlake.ColumnKind.floating, (try set.column(2)).kind());

    // And a negative still survives being spliced straight after a minus, where a bare numeral
    // would open a -- comment.
    var diff = try conn.query("SELECT 3-? AS V", &.{frostlake.Value.of(@as(f64, -1.5))});
    defer diff.deinit();
    const got = diff.first();
    try testing.expectEqual(frostlake.ColumnKind.floating, (try got.column(0)).kind());
}

test "integration: a text or binary column reports its declared width" {
    var conn = try connect("ZIG_WIDTH_DB");
    defer conn.close();

    try createScratch(&conn, "CREATE TABLE W (V9 VARCHAR(9), B5 BINARY(5), N NUMBER(10,2), VU VARCHAR)");

    var rows = try conn.query("SELECT V9, B5, N, VU FROM W", &.{});
    defer rows.deinit();
    const set = rows.first();

    // An engine from before the wire carried a column length sends none, and this driver supports
    // those: with nothing to report, every column here reports nothing and there is no width to
    // check. SKIPPED rather than passed — a green tick would claim an engine had been checked for
    // something it never sends.
    if ((try set.column(0)).length == null) return error.SkipZigTest;

    // Characters for text, bytes for binary.
    try testing.expectEqual(@as(?i32, 9), (try set.column(0)).length);
    try testing.expectEqual(@as(?i32, 5), (try set.column(1)).length);
    // A number has a precision and a scale and no width at all.
    try testing.expectEqual(@as(?i32, null), (try set.column(2)).length);
    // An unbounded column reports the most it could hold.
    try testing.expectEqual(@as(?i32, 16777216), (try set.column(3)).length);
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

// A session lost behind its connection's back — as the engine's idle reaper or a restart would
// lose it — and what the driver does next.

/// One raw request to the server named by FROSTLAKE_URL, made past every connection: the
/// status it answered with, and its body. Caller owns the body.
fn rawRequest(method: []const u8, path: []const u8) !struct { status: u16, body: []u8 } {
    const base = (try serverUrl(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(base);
    var config = try frostlake.parseDsn(testing.allocator, base, null);
    defer config.deinit();
    // base_url is http://host:port.
    const authority = config.base_url[std.mem.indexOf(u8, config.base_url, "://").? + 3 ..];
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':').?;
    const port = try std.fmt.parseInt(u16, authority[colon + 1 ..], 10);
    const address = try std.Io.net.IpAddress.parse(authority[0..colon], port);

    const stream = try address.connect(testing.io, .{ .mode = .stream });
    defer stream.close(testing.io);
    var write_buffer: [512]u8 = undefined;
    var writer = stream.writer(testing.io, &write_buffer);
    try writer.interface.print(
        "{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n",
        .{ method, path, authority },
    );
    try writer.interface.flush();

    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(testing.io, &read_buffer);
    var answer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer answer.deinit();
    _ = try reader.interface.streamRemaining(&answer.writer);
    const text = answer.written();
    const status_start = std.mem.indexOfScalar(u8, text, ' ').? + 1;
    const status = try std.fmt.parseInt(u16, text[status_start .. status_start + 3], 10);
    const body_start = (std.mem.indexOf(u8, text, "\r\n\r\n") orelse text.len - 4) + 4;
    return .{ .status = status, .body = try testing.allocator.dupe(u8, text[body_start..]) };
}

/// End `session_id` behind its connection's back.
fn releaseOutOfBand(session_id: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "/api/sessions/{s}", .{session_id});
    defer testing.allocator.free(path);
    const reply = try rawRequest("DELETE", path);
    defer testing.allocator.free(reply.body);
    try testing.expectEqual(@as(u16, 200), reply.status);
}

fn activeSessions() !i64 {
    const reply = try rawRequest("GET", "/api/sessions");
    defer testing.allocator.free(reply.body);
    const key = "\"activeSessions\":";
    const at = (std.mem.indexOf(u8, reply.body, key) orelse return error.TestUnexpectedResult) + key.len;
    var end = at;
    while (end < reply.body.len and std.ascii.isDigit(reply.body[end])) end += 1;
    return std.fmt.parseInt(i64, reply.body[at..end], 10);
}

/// The connection's database and schema, as `DATABASE.SCHEMA`. Caller owns the text.
fn currentScope(conn: *frostlake.Connection) ![]u8 {
    var rows = try conn.query("SELECT CURRENT_DATABASE() || '.' || CURRENT_SCHEMA()", &.{});
    defer rows.deinit();
    return testing.allocator.dupe(u8, try (try rows.scalar()).asText());
}

fn expectScope(conn: *frostlake.Connection, want: []const u8) !void {
    const scope = try currentScope(conn);
    defer testing.allocator.free(scope);
    try testing.expectEqualStrings(want, scope);
}

test "integration: a released session comes back on the DSN's scope" {
    var conn = try connect("ZIG_LOST_SCOPE_DB");
    defer conn.close();
    try expectScope(&conn, "ZIG_LOST_SCOPE_DB.PUBLIC");

    const released_id = try testing.allocator.dupe(u8, conn.session_id);
    defer testing.allocator.free(released_id);
    try releaseOutOfBand(released_id);

    try expectScope(&conn, "ZIG_LOST_SCOPE_DB.PUBLIC");
    try testing.expect(!std.mem.eql(u8, released_id, conn.session_id));
}

test "integration: a released session under a transaction is reported" {
    var conn = try connect("ZIG_LOST_TX_DB");
    defer conn.close();
    try createScratch(&conn, "CREATE TABLE lost_t (a INTEGER)");

    try conn.begin();
    _ = try conn.exec("INSERT INTO lost_t VALUES (1)", &.{});
    try releaseOutOfBand(conn.session_id);

    try testing.expectError(frostlake.Error.SessionLost, conn.exec("INSERT INTO lost_t VALUES (2)", &.{}));
    try testing.expectError(frostlake.Error.SessionLost, conn.commit());

    // The connection stays usable, on the DSN's scope, and nothing of the transaction survived.
    try expectScope(&conn, "ZIG_LOST_TX_DB.PUBLIC");
    var count = try conn.query("SELECT COUNT(*) FROM lost_t", &.{});
    defer count.deinit();
    try testing.expectEqual(@as(i64, 0), try (try count.scalar()).asInt());
}

test "integration: closing releases the engine session" {
    const base = (try serverUrl(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(base);
    var conn = try frostlake.Connection.open(testing.allocator, testing.io, base);
    var ran = try conn.query("SELECT 1", &.{});
    ran.deinit();

    const before = try activeSessions();
    conn.close();
    try testing.expectEqual(before - 1, try activeSessions());
}
