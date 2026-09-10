//! Tests that need nothing installed — no engine, no JVM, no network.
//!
//! Everything the driver decides on its own is checked here: how a DSN is read, which
//! characters are bind markers, what a value renders as, how a cell is typed, and how a
//! connection keeps its session's scope. The last of those runs over a mock transport, so the
//! parts of a driver that are usually only reachable from an integration test are covered
//! without a server.

const std = @import("std");
const testing = std.testing;
const frostlake = @import("frostlake");

const Value = frostlake.Value;
const Cell = frostlake.Cell;
const Column = frostlake.Column;
const Date = frostlake.Date;
const Time = frostlake.Time;
const Timestamp = frostlake.Timestamp;

// ---------------------------------------------------------------------------
// DSN
// ---------------------------------------------------------------------------

test "dsn: minimal" {
    var config = try frostlake.parseDsn(testing.allocator, "frostlake://localhost:18082", null);
    defer config.deinit();

    try testing.expectEqualStrings("http://localhost:18082", config.base_url);
    try testing.expectEqualStrings("", config.database);
    try testing.expectEqual(frostlake.dsn.default_timeout_ms, config.timeout_ms);
    try testing.expectEqual(@as(i16, 0), config.tz_offset_minutes);
    try testing.expect(!config.hasScope());
}

test "dsn: full scope and parameters" {
    var config = try frostlake.parseDsn(
        testing.allocator,
        "frostlake://db.example:18082/MY_DB?schema=PUBLIC&role=ANALYST&warehouse=WH&timeout=30s&tz=%2B02:00",
        null,
    );
    defer config.deinit();

    try testing.expectEqualStrings("http://db.example:18082", config.base_url);
    try testing.expectEqualStrings("MY_DB", config.database);
    try testing.expectEqualStrings("PUBLIC", config.schema);
    try testing.expectEqualStrings("ANALYST", config.role);
    try testing.expectEqualStrings("WH", config.warehouse);
    try testing.expectEqual(@as(u64, 30_000), config.timeout_ms);
    try testing.expectEqual(@as(i16, 120), config.tz_offset_minutes);
    try testing.expect(config.hasScope());
}

test "dsn: https via scheme and via tls parameter" {
    var by_scheme = try frostlake.parseDsn(testing.allocator, "https://host:443", null);
    defer by_scheme.deinit();
    try testing.expectEqualStrings("https://host:443", by_scheme.base_url);

    var by_param = try frostlake.parseDsn(testing.allocator, "frostlake://host:18082?tls=true", null);
    defer by_param.deinit();
    try testing.expectEqualStrings("https://host:18082", by_param.base_url);
}

test "dsn: USE statements come out in dependency order and are quoted when they must be" {
    var config = try frostlake.parseDsn(
        testing.allocator,
        "frostlake://h:1/my%20db?schema=PUBLIC&role=R&warehouse=W",
        null,
    );
    defer config.deinit();

    var use = try config.useStatements();
    defer use.deinit();

    const items = use.slice();
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("USE ROLE R", items[0]);
    try testing.expectEqualStrings("USE WAREHOUSE W", items[1]);
    // Lower case and a space, so it has to be quoted to survive identifier folding.
    try testing.expectEqualStrings("USE DATABASE \"my db\"", items[2]);
    try testing.expectEqualStrings("USE SCHEMA PUBLIC", items[3]);
}

test "dsn: a quote in an identifier cannot break out of the quoting" {
    var config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1/a%22b", null);
    defer config.deinit();

    var use = try config.useStatements();
    defer use.deinit();
    try testing.expectEqualStrings("USE DATABASE \"a\"\"b\"", use.slice()[0]);
}

test "dsn: rejections carry a message" {
    var diag = frostlake.Diagnostics{};
    defer diag.deinit();

    const cases = [_][]const u8{
        "localhost:18082", // no scheme
        "mysql://localhost:3306", // wrong scheme
        "frostlake://", // no host
        "frostlake://user:pass@host:1", // credentials the API cannot accept
        "frostlake://h:1?nope=1", // unknown parameter
        "frostlake://h:1?timeout=soon", // unreadable duration
        "frostlake://h:1?tz=Europe/Warsaw", // an IANA zone this driver cannot resolve
        "frostlake://h:1?tls=perhaps", // unreadable boolean
    };
    for (cases) |dsn| {
        try testing.expectError(
            frostlake.Error.InvalidDsn,
            frostlake.parseDsn(testing.allocator, dsn, &diag),
        );
        try testing.expect(diag.message.len > 0);
    }
}

test "dsn: durations in every accepted spelling" {
    const cases = [_]struct { text: []const u8, ms: u64 }{
        .{ .text = "0", .ms = 0 },
        .{ .text = "1500ms", .ms = 1500 },
        .{ .text = "30", .ms = 30_000 },
        .{ .text = "30s", .ms = 30_000 },
        .{ .text = "5m", .ms = 300_000 },
        .{ .text = "2m30s", .ms = 150_000 },
        .{ .text = "1h", .ms = 3_600_000 },
    };
    for (cases) |case| {
        const dsn = try std.fmt.allocPrint(testing.allocator, "frostlake://h:1?timeout={s}", .{case.text});
        defer testing.allocator.free(dsn);
        var config = try frostlake.parseDsn(testing.allocator, dsn, null);
        defer config.deinit();
        try testing.expectEqual(case.ms, config.timeout_ms);
    }
}

test "dsn: fixed UTC offsets in every accepted spelling" {
    const cases = [_]struct { text: []const u8, minutes: i16 }{
        .{ .text = "UTC", .minutes = 0 },
        .{ .text = "Z", .minutes = 0 },
        .{ .text = "%2B02:00", .minutes = 120 },
        .{ .text = "-0500", .minutes = -300 },
        .{ .text = "%2B05:30", .minutes = 330 },
        .{ .text = "-08", .minutes = -480 },
    };
    for (cases) |case| {
        const dsn = try std.fmt.allocPrint(testing.allocator, "frostlake://h:1?tz={s}", .{case.text});
        defer testing.allocator.free(dsn);
        var config = try frostlake.parseDsn(testing.allocator, dsn, null);
        defer config.deinit();
        try testing.expectEqual(case.minutes, config.tz_offset_minutes);
    }
}

// ---------------------------------------------------------------------------
// Placeholder scanning
// ---------------------------------------------------------------------------

fn countMarkers(sql: []const u8) frostlake.sql.PlaceholderCounts {
    return frostlake.sql.countPlaceholders(sql);
}

test "scan: positional markers" {
    try testing.expectEqual(@as(usize, 2), countMarkers("SELECT * FROM t WHERE a = ? AND b = ?").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT 1").positional);
}

test "scan: a ? inside a literal, an identifier, a body or a comment is not a marker" {
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT '?'").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT \"we?rd\" FROM t").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT 1 -- what? \n").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT 1 // what?\n").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT /* ? */ 1").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("CREATE PROCEDURE p() AS $$ x = '?' $$").positional);
    // An escaped quote keeps the literal open, so the ? stays inside it.
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT 'a\\'? b'").positional);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT 'a''? b'").positional);
    // ...and one after the literal closes is a real marker.
    try testing.expectEqual(@as(usize, 1), countMarkers("SELECT '?' , ?").positional);
}

test "scan: named markers, and the colons that are not markers" {
    try testing.expectEqual(@as(usize, 2), countMarkers("SELECT * FROM t WHERE a = :a AND b = :b").distinct_named);
    // The same name twice is one parameter but two sites.
    const repeated = countMarkers("SELECT :x, :x");
    try testing.expectEqual(@as(usize, 2), repeated.named);
    try testing.expectEqual(@as(usize, 1), repeated.distinct_named);
    // Case folds, the way an unquoted identifier does.
    try testing.expectEqual(@as(usize, 1), countMarkers("SELECT :x, :X").distinct_named);

    // A cast, an assignment and a positional reference are never parameters.
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT '1'::INT").named);
    try testing.expectEqual(@as(usize, 0), countMarkers("LET x := 1").named);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT :1").named);

    // Neither is VARIANT path access, in any of its spellings.
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT v:field FROM t").named);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT PARSE_JSON('{}'):k").named);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT \"V\":k FROM t").named);
    try testing.expectEqual(@as(usize, 0), countMarkers("SELECT a[0]:k FROM t").named);

    // A marker after an operator, comma or keyword boundary is real.
    try testing.expectEqual(@as(usize, 1), countMarkers("SELECT * FROM t WHERE x = :a").distinct_named);
    try testing.expectEqual(@as(usize, 2), countMarkers("SELECT :a, :b").distinct_named);
}

test "scan: mixing the two styles is detectable" {
    try testing.expect(countMarkers("SELECT ? , :a").isMixed());
    try testing.expect(!countMarkers("SELECT ?, ?").isMixed());
    try testing.expect(!countMarkers("SELECT :a, :b").isMixed());
}

// ---------------------------------------------------------------------------
// Statement splitting and session scope
// ---------------------------------------------------------------------------

fn splitCount(sql: []const u8) usize {
    var it = frostlake.sql.StatementIterator.init(sql);
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}

test "split: semicolons inside quoted things do not split" {
    try testing.expectEqual(@as(usize, 2), splitCount("SELECT 1; SELECT 2"));
    try testing.expectEqual(@as(usize, 1), splitCount("SELECT ';'"));
    try testing.expectEqual(@as(usize, 1), splitCount("SELECT \"a;b\" FROM t"));
    try testing.expectEqual(@as(usize, 1), splitCount("SELECT 1 -- ;\n"));
    try testing.expectEqual(@as(usize, 1), splitCount("CREATE PROCEDURE p() AS $$ a; b $$"));
}

test "scope: only the statements that move a session are flagged" {
    const moves = [_][]const u8{
        "USE DATABASE X",
        "use schema public",
        "SET x = 1",
        "UNSET x",
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        "CREATE DATABASE D",
        "CREATE OR REPLACE DATABASE D",
        "DROP SCHEMA IF EXISTS S",
        "CREATE TRANSIENT SCHEMA S",
        // A scope change riding behind a leading SELECT still counts.
        "SELECT 1; USE SCHEMA S",
        // ...and so does one behind a comment.
        "/* lead */ USE SCHEMA S",
    };
    for (moves) |sql| {
        try testing.expect(frostlake.sql.changesSessionScope(sql));
    }

    const stays = [_][]const u8{
        "SELECT 1",
        "CREATE TABLE T (A INT)",
        "CREATE OR REPLACE TABLE T (A INT)",
        "DROP TABLE T",
        "ALTER TABLE T ADD COLUMN B INT",
        "INSERT INTO T VALUES (1)",
        "-- USE DATABASE X\nSELECT 1",
        "SELECT 'USE DATABASE X'",
    };
    for (stays) |sql| {
        try testing.expect(!frostlake.sql.changesSessionScope(sql));
    }
}

// ---------------------------------------------------------------------------
// Literal rendering
// ---------------------------------------------------------------------------

fn expectRenders(value: Value, want: []const u8) !void {
    const rendered = try frostlake.value.renderAlloc(testing.allocator, value);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(want, rendered);
}

test "render: scalars" {
    try expectRenders(Value.nul(), "NULL");
    try expectRenders(Value.of(true), "TRUE");
    try expectRenders(Value.of(false), "FALSE");
    try expectRenders(Value.of(@as(i64, 42)), "42");
    // A negative in parentheses: bare after a minus it would open a -- comment.
    try expectRenders(Value.of(@as(i64, -7)), "(-7)");
    try expectRenders(Value.of(@as(f64, -1.5)), "(-1.5)");
}

test "render: strings escape backslashes and quotes" {
    try expectRenders(Value.of("plain"), "'plain'");
    try expectRenders(Value.of("it's"), "'it''s'");
    try expectRenders(Value.of("back\\slash"), "'back\\\\slash'");
    try expectRenders(Value.of("both'\\"), "'both''\\\\'");
    try expectRenders(Value.of(""), "''");
}

test "render: floats keep their type and spell the special values" {
    try expectRenders(Value.of(@as(f64, 1.5)), "1.5");
    // A whole float keeps a fractional part; without one it would bind as an integer.
    try expectRenders(Value.of(@as(f64, 2.0)), "2.0");
    try expectRenders(Value.of(@as(f64, std.math.nan(f64))), "'NaN'::FLOAT");
    try expectRenders(Value.of(@as(f64, std.math.inf(f64))), "'Infinity'::FLOAT");
    try expectRenders(Value.of(@as(f64, -std.math.inf(f64))), "'-Infinity'::FLOAT");
}

test "render: binary, exact decimals, variants and raw SQL" {
    try expectRenders(Value.bytes(&.{ 0x00, 0xAB, 0xFF }), "X'00ABFF'");
    try expectRenders(Value.bytes(&.{}), "X''");
    try expectRenders(Value.decimalText("123456789012345678901234567890"), "123456789012345678901234567890");
    try expectRenders(Value.jsonText("{\"a\":1}"), "PARSE_JSON('{\"a\":1}')");
    try expectRenders(Value.rawSql("CURRENT_TIMESTAMP()"), "CURRENT_TIMESTAMP()");
}

test "render: temporals" {
    try expectRenders(Value.of(Date{ .year = 2026, .month = 8, .day = 24 }), "'2026-08-24'::DATE");
    try expectRenders(Value.of(Time{ .hour = 9, .minute = 5, .second = 3 }), "'09:05:03'::TIME");
    try expectRenders(
        Value.of(Time{ .hour = 9, .minute = 5, .second = 3, .nanosecond = 500_000_000 }),
        "'09:05:03.5'::TIME",
    );
    try expectRenders(
        Value.of(Timestamp{
            .date = .{ .year = 2026, .month = 8, .day = 24 },
            .time = .{ .hour = 13, .minute = 30, .second = 0 },
        }),
        "'2026-08-24 13:30:00'::TIMESTAMP_NTZ",
    );
    // An offset makes it a TIMESTAMP_TZ, an instant rather than a wall clock.
    try expectRenders(
        Value.of(Timestamp{
            .date = .{ .year = 2026, .month = 8, .day = 24 },
            .time = .{ .hour = 13, .minute = 30, .second = 0 },
            .offset_minutes = 120,
        }),
        "'2026-08-24 13:30:00+02:00'::TIMESTAMP_TZ",
    );
    try expectRenders(
        Value.of(Timestamp{
            .date = .{ .year = 2026, .month = 1, .day = 2 },
            .time = .{ .hour = 3, .minute = 4, .second = 5 },
            .offset_minutes = -330,
        }),
        "'2026-01-02 03:04:05-05:30'::TIMESTAMP_TZ",
    );
}

test "render: Value.of infers from the Zig type" {
    try expectRenders(Value.of(1), "1");
    try expectRenders(Value.of(1.25), "1.25");
    try expectRenders(Value.of("x"), "'x'");
    try expectRenders(Value.of(true), "TRUE");
    // An optional binds its payload, or NULL.
    const present: ?i64 = 5;
    const absent: ?i64 = null;
    try expectRenders(Value.of(present), "5");
    try expectRenders(Value.of(absent), "NULL");
}

// ---------------------------------------------------------------------------
// Binding
// ---------------------------------------------------------------------------

fn expectBound(sql: []const u8, args: []const Value, want: []const u8) !void {
    const rendered = try frostlake.substitute(testing.allocator, sql, args, null);
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings(want, rendered);
}

test "bind: positional arguments are inlined in order" {
    try expectBound(
        "INSERT INTO T VALUES (?, ?)",
        &.{ Value.of(1), Value.of("Ada") },
        "INSERT INTO T VALUES (1, 'Ada')",
    );
    try expectBound("SELECT 1", &.{}, "SELECT 1");
}

test "bind: a marker inside a literal is left alone" {
    try expectBound(
        "SELECT '?' , ?",
        &.{Value.of(7)},
        "SELECT '?' , 7",
    );
}

test "bind: the argument count has to match" {
    var diag = frostlake.Diagnostics{};
    defer diag.deinit();

    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substitute(testing.allocator, "SELECT ?, ?", &.{Value.of(1)}, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message, "2 placeholder") != null);

    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substitute(testing.allocator, "SELECT ?", &.{ Value.of(1), Value.of(2) }, &diag),
    );
}

test "bind: named arguments bind by name, in any order, repeated if need be" {
    const rendered = try frostlake.substituteNamed(
        testing.allocator,
        "SELECT * FROM T WHERE B = :b AND A = :a AND B2 = :b",
        &.{
            .{ .name = "a", .value = Value.of(1) },
            .{ .name = "b", .value = Value.of("x") },
        },
        null,
    );
    defer testing.allocator.free(rendered);
    try testing.expectEqualStrings("SELECT * FROM T WHERE B = 'x' AND A = 1 AND B2 = 'x'", rendered);
}

test "bind: named mismatches are refused" {
    var diag = frostlake.Diagnostics{};
    defer diag.deinit();

    // A marker with no argument.
    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substituteNamed(testing.allocator, "SELECT :a, :b", &.{
            .{ .name = "a", .value = Value.of(1) },
        }, &diag),
    );

    // An argument that names no marker — a misspelling that would otherwise bind nothing.
    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substituteNamed(testing.allocator, "SELECT :a", &.{
            .{ .name = "a", .value = Value.of(1) },
            .{ .name = "typo", .value = Value.of(2) },
        }, &diag),
    );
    try testing.expect(std.mem.indexOf(u8, diag.message, "typo") != null);
}

test "bind: the two styles cannot be mixed" {
    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substitute(testing.allocator, "SELECT ?, :a", &.{Value.of(1)}, null),
    );
    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substituteNamed(testing.allocator, "SELECT ?, :a", &.{
            .{ .name = "a", .value = Value.of(1) },
        }, null),
    );
}

test "bind: with no arguments, colon references pass through to the server" {
    // Snowflake Scripting variables are the server's, not the driver's. With no arguments
    // supplied there are no client binds, so the statement must arrive verbatim.
    try expectBound("EXECUTE IMMEDIATE :stmt", &.{}, "EXECUTE IMMEDIATE :stmt");
    try expectBound("SELECT IFF(:flag, 1, 2)", &.{}, "SELECT IFF(:flag, 1, 2)");
}

test "bind: positional arguments against a named statement are refused" {
    try testing.expectError(
        frostlake.Error.BindMismatch,
        frostlake.substitute(testing.allocator, "SELECT :a", &.{Value.of(1)}, null),
    );
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

fn column(data_type: []const u8, scale: i32) Column {
    return .{ .name = "C", .data_type = data_type, .scale = scale };
}

test "decode: column kinds" {
    const k = frostlake.decode.classify;
    try testing.expectEqual(frostlake.ColumnKind.date, k(column("DATE", 0)));
    try testing.expectEqual(frostlake.ColumnKind.time, k(column("TIME", 0)));
    try testing.expectEqual(frostlake.ColumnKind.timestamp_naive, k(column("TIMESTAMP_NTZ", 0)));
    try testing.expectEqual(frostlake.ColumnKind.timestamp_zoned, k(column("TIMESTAMP_TZ", 0)));
    try testing.expectEqual(frostlake.ColumnKind.timestamp_zoned, k(column("TIMESTAMP_LTZ", 0)));
    try testing.expectEqual(frostlake.ColumnKind.binary, k(column("BINARY", 0)));
    try testing.expectEqual(frostlake.ColumnKind.variant, k(column("VARIANT", 0)));
    try testing.expectEqual(frostlake.ColumnKind.boolean, k(column("BOOLEAN", 0)));
    try testing.expectEqual(frostlake.ColumnKind.integral, k(column("INTEGER", 0)));
    // Scale is what separates a whole NUMBER from a fractional one.
    try testing.expectEqual(frostlake.ColumnKind.integral, k(column("NUMBER", 0)));
    try testing.expectEqual(frostlake.ColumnKind.decimal, k(column("NUMBER", 2)));
    try testing.expectEqual(frostlake.ColumnKind.floating, k(column("FLOAT", 0)));
    try testing.expectEqual(frostlake.ColumnKind.text, k(column("VARCHAR(16777216)", 0)));
    // An inline (p,s) spelling is honoured when the wire fields are absent.
    try testing.expectEqual(frostlake.ColumnKind.decimal, k(column("NUMBER(10,2)", 0)));
    try testing.expectEqual(frostlake.ColumnKind.integral, k(column("NUMBER(38,0)", 0)));
}

test "decode: numbers keep their exact digits when they must" {
    // Fits an i64 on an integral column.
    const small = frostlake.decode.decodeNumber("42", column("NUMBER", 0));
    try testing.expectEqual(@as(i64, 42), try small.asInt());

    // Wider than i64 — NUMBER(38,0) holds these, and an f64 would round them.
    const wide = frostlake.decode.decodeNumber("123456789012345678901234567890", column("NUMBER", 0));
    try testing.expectEqualStrings("123456789012345678901234567890", try wide.asText());

    // A fixed-point column keeps its digits: NUMBER(12,2) promises exactness, and reading
    // 135500.50 as an f64 gives back 135500.5 — a different value than the column holds.
    const money = frostlake.decode.decodeNumber("135500.50", column("NUMBER", 2));
    try testing.expectEqualStrings("135500.50", try money.asText());
    // ...and it still reads as a number for callers that want one.
    try testing.expectEqual(@as(f64, 135500.5), try money.asFloat());

    // A true FLOAT column is a binary float and reads as one.
    const approximate = frostlake.decode.decodeNumber("3.5", column("FLOAT", 0));
    try testing.expectEqual(@as(f64, 3.5), try approximate.asFloat());
}

test "decode: strings against their column type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try frostlake.decode.decodeString(gpa, "hello", column("VARCHAR", 0));
    try testing.expectEqualStrings("hello", try text.asText());

    const bytes = try frostlake.decode.decodeString(gpa, "00ABFF", column("BINARY", 0));
    try testing.expectEqualSlices(u8, &.{ 0x00, 0xAB, 0xFF }, try bytes.asBytes());

    // Not hex after all: the value is handed back as text rather than lost.
    const not_hex = try frostlake.decode.decodeString(gpa, "zz", column("BINARY", 0));
    try testing.expectEqualStrings("zz", try not_hex.asText());

    const variant = try frostlake.decode.decodeString(gpa, "{\"a\":1}", column("VARIANT", 0));
    try testing.expectEqualStrings("{\"a\":1}", try variant.asText());
}

test "decode: temporal text in the shapes the engine sends" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const date = try frostlake.decode.decodeString(gpa, "2026-08-24", column("DATE", 0));
    const d = try date.asDate();
    try testing.expectEqual(@as(i32, 2026), d.year);
    try testing.expectEqual(@as(u8, 8), d.month);
    try testing.expectEqual(@as(u8, 24), d.day);

    const time = try frostlake.decode.decodeString(gpa, "13:30:05", column("TIME", 0));
    const t = try time.asTime();
    try testing.expectEqual(@as(u8, 13), t.hour);
    try testing.expectEqual(@as(u8, 30), t.minute);
    try testing.expectEqual(@as(u8, 5), t.second);

    // The engine's own TIMESTAMP shape: milliseconds, space-separated.
    const naive = try frostlake.decode.decodeString(gpa, "2026-08-24 13:30:05.250", column("TIMESTAMP_NTZ", 0));
    const ts = try naive.asTimestamp();
    try testing.expectEqual(@as(u32, 250_000_000), ts.time.nanosecond);
    try testing.expect(ts.offset_minutes == null);

    // ...and its TIMESTAMP_TZ shape: a trailing +0000 style offset.
    const zoned = try frostlake.decode.decodeString(gpa, "2026-08-24 13:30:05.000 +0200", column("TIMESTAMP_TZ", 0));
    const zts = try zoned.asTimestamp();
    try testing.expectEqual(@as(i16, 120), zts.offset_minutes.?);

    // A `T` separator and a `Z` offset parse too, for a server that spells them that way.
    const iso = try frostlake.decode.decodeString(gpa, "2026-08-24T13:30:05Z", column("TIMESTAMP_TZ", 0));
    try testing.expectEqual(@as(i16, 0), (try iso.asTimestamp()).offset_minutes.?);
}

test "decode: a cell read as the wrong type says so" {
    const cell = Cell{ .string = "not a number" };
    try testing.expectError(frostlake.Error.TypeMismatch, cell.asInt());
    try testing.expectError(frostlake.Error.TypeMismatch, cell.asBytes());
    try testing.expectError(frostlake.Error.TypeMismatch, cell.asDate());

    // A fractional float is not silently truncated to an integer.
    const fractional = Cell{ .float = 1.5 };
    try testing.expectError(frostlake.Error.TypeMismatch, fractional.asInt());
    // ...but a whole one reads fine.
    const whole = Cell{ .float = 2.0 };
    try testing.expectEqual(@as(i64, 2), try whole.asInt());
}

// ---------------------------------------------------------------------------
// The wire format
// ---------------------------------------------------------------------------

test "wire: a request body escapes what JSON forbids raw" {
    const body = try frostlake.wire.encodeRequest(testing.allocator, .{
        .sql = "SELECT '\n\t\"\\'",
        .session_id = "s-1",
        .auto_commit = false,
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"sql\":\"SELECT '\\n\\t\\\"\\\\'\",\"sessionId\":\"s-1\",\"autoCommit\":false}",
        body,
    );
}

test "wire: a request with no session omits the field" {
    const body = try frostlake.wire.encodeRequest(testing.allocator, .{ .sql = "SELECT 1" });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"sql\":\"SELECT 1\",\"autoCommit\":true}", body);
}

test "wire: a control character is escaped rather than emitted raw" {
    const body = try frostlake.wire.encodeRequest(testing.allocator, .{ .sql = "a\x01b" });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\\u0001") != null);
}

test "wire: a successful response decodes into typed cells" {
    const payload =
        \\{"success":true,"sessionId":"abc","resultSets":[{"columns":[
        \\{"name":"ID","dataType":"NUMBER","precision":38,"scale":0,"nullable":false},
        \\{"name":"NAME","dataType":"VARCHAR","nullable":true}],
        \\"rows":[[1,"Ada"],[2,null]],"rowCount":2}],"executionTimeMs":7}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();

    try testing.expect(decoded.success);
    try testing.expectEqualStrings("abc", decoded.session_id);
    try testing.expectEqual(@as(u64, 7), decoded.response.execution_time_ms);

    const set = decoded.response.first();
    try testing.expectEqual(@as(usize, 2), set.columnCount());
    try testing.expectEqual(@as(usize, 2), set.rowCount());
    try testing.expectEqualStrings("ID", try set.columnName(0));
    try testing.expectEqual(frostlake.Nullability.not_null, (try set.column(0)).nullable);
    try testing.expectEqual(frostlake.Nullability.nullable, (try set.column(1)).nullable);

    try testing.expectEqual(@as(i64, 1), try (try set.at(0, 0)).asInt());
    try testing.expectEqualStrings("Ada", try (try set.at(0, 1)).asText());
    try testing.expect((try set.at(1, 1)).isNull());

    // ...and by name, folding case.
    try testing.expectEqualStrings("Ada", try (try set.atName(0, "name")).asText());
}

test "wire: a column with no nullable field reads as unknown" {
    const payload =
        \\{"success":true,"resultSets":[{"columns":[{"name":"A","dataType":"VARCHAR"}],"rows":[["x"]]}]}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();
    try testing.expectEqual(frostlake.Nullability.unknown, (try decoded.response.first().column(0)).nullable);
}

test "wire: a failed statement carries the engine's message" {
    const payload =
        \\{"success":false,"sessionId":"abc","errorMessage":"Table 'T' does not exist","resultSets":[]}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();
    try testing.expect(!decoded.success);
    try testing.expectEqualStrings("Table 'T' does not exist", decoded.error_message);
}

test "wire: the endpoint's own rejection is reported too" {
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, "{\"error\":\"SQL is required\"}", null);
    defer decoded.response.deinit();
    try testing.expect(!decoded.success);
    try testing.expectEqualStrings("frostlake: SQL is required", decoded.error_message);
}

test "wire: a body that is not a Frostlake response is refused" {
    const bodies = [_][]const u8{
        "<html>502 Bad Gateway</html>",
        "",
        "null",
        "[1,2,3]",
        // Valid JSON, but from something that is not the engine — no success, no error.
        "{\"message\":\"hello from nginx\"}",
        // Truncated.
        "{\"success\":true,\"resultSets\":[{\"columns\":[",
    };
    for (bodies) |body| {
        try testing.expectError(
            frostlake.Error.NotFrostlake,
            frostlake.wire.decodeResponse(testing.allocator, body, null),
        );
    }
}

test "wire: a bare `undefined` in the body is recognised" {
    // Engine 0.0.7 renders a VARIANT `undefined` as a bare token, which is not JSON. Telling
    // that apart from a wrong port is the difference between a server bug on one statement and
    // a misconfigured address.
    try testing.expect(frostlake.wire.carriesBareUndefined(
        "{\"success\":true,\"resultSets\":[{\"rows\":[[[undefined,undefined]]]}]}",
    ));
    try testing.expect(frostlake.wire.carriesBareUndefined("[1,undefined,2]"));

    // The word inside a string value is just text and must not trigger it.
    try testing.expect(!frostlake.wire.carriesBareUndefined("{\"a\":\"undefined\"}"));
    try testing.expect(!frostlake.wire.carriesBareUndefined("{\"a\":\"say \\\"undefined\\\" here\"}"));
    try testing.expect(!frostlake.wire.carriesBareUndefined("{\"success\":true,\"resultSets\":[]}"));
}

test "wire: several result sets, and the DML counts add up" {
    const payload =
        \\{"success":true,"resultSets":[
        \\{"columns":[{"name":"number of rows inserted","dataType":"NUMBER","scale":0}],"rows":[[2]],"rowCount":1},
        \\{"columns":[{"name":"number of rows updated","dataType":"NUMBER","scale":0}],"rows":[[3]],"rowCount":1}]}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();

    try testing.expectEqual(@as(usize, 2), decoded.response.setCount());
    try testing.expectEqual(@as(i64, 5), decoded.response.rowsAffected());
}

test "wire: a SELECT grid is not mistaken for a DML count" {
    const payload =
        \\{"success":true,"resultSets":[{"columns":[{"name":"N","dataType":"NUMBER","scale":0}],"rows":[[9]],"rowCount":1}]}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();
    try testing.expectEqual(@as(i64, 0), decoded.response.rowsAffected());
}

test "wire: an unknown field is skipped rather than fatal" {
    const payload =
        \\{"success":true,"somethingNew":{"a":[1,2]},"resultSets":[],"sessionId":"s"}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();
    try testing.expect(decoded.success);
    try testing.expectEqualStrings("s", decoded.session_id);
}

test "wire: rows survive columns arriving after them" {
    // Nothing in the protocol promises field order, so the decoder must not depend on it.
    const payload =
        \\{"success":true,"resultSets":[{"rows":[["2026-08-24"]],
        \\"columns":[{"name":"D","dataType":"DATE"}],"rowCount":1}]}
    ;
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, payload, null);
    defer decoded.response.deinit();
    const d = try (try decoded.response.first().at(0, 0)).asDate();
    try testing.expectEqual(@as(i32, 2026), d.year);
}

test "wire: an empty result set list reads as empty rather than failing" {
    var decoded = try frostlake.wire.decodeResponse(testing.allocator, "{\"success\":true,\"resultSets\":[]}", null);
    defer decoded.response.deinit();
    const set = decoded.response.first();
    try testing.expectEqual(@as(usize, 0), set.columnCount());
    try testing.expectError(frostlake.Error.NotFound, set.scalar());
}

// ---------------------------------------------------------------------------
// Session behaviour, over a mock transport
// ---------------------------------------------------------------------------

/// A transport that answers from a script and records what it was asked.
const MockTransport = struct {
    allocator: std.mem.Allocator,
    /// Statements seen, in order. Owned.
    seen: std.ArrayList([]u8) = .empty,
    /// Bodies to answer with, in order; the last one repeats once exhausted.
    replies: []const []const u8,
    reply_index: usize = 0,
    status: u16 = 200,

    const vtable = frostlake.Transport.VTable{
        .post = post,
        .get = get,
        .baseUrl = baseUrl,
        .deinit = deinitFn,
    };

    fn create(allocator: std.mem.Allocator, replies: []const []const u8) !*MockTransport {
        const self = try allocator.create(MockTransport);
        self.* = .{ .allocator = allocator, .replies = replies };
        return self;
    }

    fn transport(self: *MockTransport) frostlake.Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn post(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
        body: []const u8,
        diag: ?*frostlake.Diagnostics,
    ) frostlake.Error!frostlake.RawReply {
        _ = path;
        _ = diag;
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        try self.seen.append(self.allocator, try self.allocator.dupe(u8, extractSql(body)));
        const reply = self.replies[@min(self.reply_index, self.replies.len - 1)];
        self.reply_index += 1;
        return .{ .status = self.status, .body = try allocator.dupe(u8, reply) };
    }

    fn get(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        path: []const u8,
        diag: ?*frostlake.Diagnostics,
    ) frostlake.Error!frostlake.RawReply {
        _ = ptr;
        _ = path;
        _ = diag;
        return .{ .status = 200, .body = try allocator.dupe(u8, "{\"status\":\"UP\"}") };
    }

    fn baseUrl(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "http://mock";
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *MockTransport = @ptrCast(@alignCast(ptr));
        for (self.seen.items) |statement| self.allocator.free(statement);
        self.seen.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Pull the `sql` field back out of a request body, so a test can assert on what was sent
    /// without re-implementing the encoder.
    fn extractSql(body: []const u8) []const u8 {
        const key = "{\"sql\":\"";
        if (!std.mem.startsWith(u8, body, key)) return body;
        var i = key.len;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\') {
                i += 1;
                continue;
            }
            if (body[i] == '"') return body[key.len..i];
        }
        return body;
    }
};

const ok_reply = "{\"success\":true,\"sessionId\":\"s-1\",\"resultSets\":[]}";

test "session: the DSN's scope is applied before the first statement" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1/DB?schema=S", null);
    const mock = try MockTransport.create(testing.allocator, &.{ok_reply});
    var conn = try frostlake.Connection.openWithTransport(
        testing.allocator,
        testing.io,
        config,
        mock.transport(),
    );
    defer conn.close();

    var response = try conn.query("SELECT 1", &.{});
    response.deinit();

    // USE DATABASE, USE SCHEMA, then the statement itself.
    try testing.expectEqual(@as(usize, 3), mock.seen.items.len);
    try testing.expectEqualStrings("USE DATABASE DB", mock.seen.items[0]);
    try testing.expectEqualStrings("USE SCHEMA S", mock.seen.items[1]);
    try testing.expectEqualStrings("SELECT 1", mock.seen.items[2]);

    // ...and only once: a second statement rides the session already established.
    var second = try conn.query("SELECT 2", &.{});
    second.deinit();
    try testing.expectEqual(@as(usize, 4), mock.seen.items.len);
}

test "session: a scope-moving statement marks the session dirty and reset puts it back" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1/DB?schema=S", null);
    const mock = try MockTransport.create(testing.allocator, &.{ok_reply});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    var first = try conn.query("USE SCHEMA OTHER", &.{});
    first.deinit();
    try testing.expect(conn.session_dirty);

    try conn.reset();
    try testing.expect(!conn.session_dirty);

    var second = try conn.query("SELECT 1", &.{});
    second.deinit();

    // The scope is re-applied before the next statement rather than assumed.
    const seen = mock.seen.items;
    try testing.expectEqualStrings("USE DATABASE DB", seen[seen.len - 3]);
    try testing.expectEqualStrings("USE SCHEMA S", seen[seen.len - 2]);
    try testing.expectEqualStrings("SELECT 1", seen[seen.len - 1]);
}

test "session: with no scope in the DSN, reset retires the connection" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1", null);
    const mock = try MockTransport.create(testing.allocator, &.{ok_reply});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    var response = try conn.query("USE SCHEMA OTHER", &.{});
    response.deinit();

    // There is no DSN scope to restore, so the next caller must not inherit this one.
    try testing.expectError(frostlake.Error.ConnectionUnusable, conn.reset());
    try testing.expect(!conn.isValid());
}

test "session: a failing USE keeps failing rather than running in the default scope" {
    const refused = "{\"success\":false,\"errorMessage\":\"Database 'NOPE' does not exist\",\"resultSets\":[]}";
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1/NOPE", null);
    const mock = try MockTransport.create(testing.allocator, &.{refused});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    try testing.expectError(frostlake.Error.EngineRefused, conn.query("SELECT 1", &.{}));
    try testing.expect(std.mem.indexOf(u8, conn.lastError(), "does not exist") != null);

    // The second attempt must not skip the USE and quietly run in the server's default scope.
    try testing.expectError(frostlake.Error.EngineRefused, conn.query("SELECT 1", &.{}));
    try testing.expectEqual(@as(usize, 2), mock.seen.items.len);
    try testing.expectEqualStrings("USE DATABASE NOPE", mock.seen.items[1]);
}

test "session: a refused statement records the SQL that was sent" {
    const refused = "{\"success\":false,\"errorMessage\":\"boom\",\"resultSets\":[]}";
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1", null);
    const mock = try MockTransport.create(testing.allocator, &.{refused});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    try testing.expectError(frostlake.Error.EngineRefused, conn.query("SELECT ?", &.{Value.of("secret")}));
    try testing.expectEqualStrings("boom", conn.lastError());
    // The rendered SQL carries the bound value, which is exactly why it is kept apart from
    // the message rather than folded into it.
    try testing.expectEqualStrings("SELECT 'secret'", conn.lastStatement());
}

test "session: an unrecognised body retires the connection" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1", null);
    const mock = try MockTransport.create(testing.allocator, &.{"<html>502</html>"});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    try testing.expectError(frostlake.Error.NotFrostlake, conn.query("SELECT 1", &.{}));
    try testing.expect(!conn.isValid());
    // A connection whose far side cannot be identified is not handed on.
    try testing.expectError(frostlake.Error.ConnectionUnusable, conn.query("SELECT 1", &.{}));
}

test "session: transactions ride the autocommit flag" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1", null);
    const mock = try MockTransport.create(testing.allocator, &.{ok_reply});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    try testing.expect(conn.auto_commit);
    try conn.begin();
    try testing.expect(!conn.auto_commit);
    try testing.expect(conn.in_transaction);

    _ = try conn.exec("INSERT INTO T VALUES (1)", &.{});
    try conn.commit();
    try testing.expect(conn.auto_commit);
    try testing.expect(!conn.in_transaction);

    const seen = mock.seen.items;
    try testing.expectEqualStrings("BEGIN", seen[0]);
    try testing.expectEqualStrings("INSERT INTO T VALUES (1)", seen[1]);
    try testing.expectEqualStrings("COMMIT", seen[2]);
}

test "session: transaction calls in the wrong order are refused" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1", null);
    const mock = try MockTransport.create(testing.allocator, &.{ok_reply});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    defer conn.close();

    try testing.expectError(frostlake.Error.InvalidTransactionState, conn.commit());
    try testing.expectError(frostlake.Error.InvalidTransactionState, conn.rollback());

    try conn.begin();
    try testing.expectError(frostlake.Error.InvalidTransactionState, conn.begin());
    try conn.rollback();
}

test "session: a closed connection refuses further work" {
    const config = try frostlake.parseDsn(testing.allocator, "frostlake://h:1", null);
    const mock = try MockTransport.create(testing.allocator, &.{ok_reply});
    var conn = try frostlake.Connection.openWithTransport(testing.allocator, testing.io, config, mock.transport());
    conn.close();

    try testing.expect(!conn.isValid());
}
