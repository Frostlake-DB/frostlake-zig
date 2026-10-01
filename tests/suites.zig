//! Runs the engine-owned, language-neutral JSON test suites through THIS driver.
//!
//! The definitions live in the frostlake repo
//! (`engine/src/test/resources/testkit/suites/*.json`, spec in `SCHEMA.md` next to them);
//! every statement travels this driver -> HTTP -> `DatabaseHttpServer`. The engine owns the
//! definitions and this file is only the Zig runner, so suites added on the engine side are
//! picked up here with no driver change.
//!
//! ```sh
//! FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
//! FROSTLAKE_URL=frostlake://localhost:18082 zig build test-suites
//! ```
//!
//! `FL_CORPUS` names the testkit directory whose `suites/*.json` run: without it the test
//! skips, and a directory holding no suites fails it. `zig build test-integration` runs it
//! too. With no engine named the whole thing skips, so a checkout without one is never falsely
//! green.
//!
//! Semantics (mirroring SCHEMA.md and the other drivers' runners):
//!   - backend name for a suite's skip clause: `zig`; `http` entries are honoured too, since
//!     this driver rides the HTTP transport and the same engine.
//!   - per-test isolation: `CREATE OR REPLACE DATABASE test_db` -> `USE` ->
//!     `CREATE OR REPLACE SCHEMA test_schema` -> `USE`, then the steps on ONE connection,
//!     which is what keeps `USE`, variables and transactions on a single session.
//!   - capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT. No ERROR_CODE — the HTTP protocol
//!     carries a message only, so an expected error's `code`/`sqlState` is counted as a
//!     missing API rather than as a failure.

const std = @import("std");
const testing = std.testing;
const frostlake = @import("frostlake");

const backend_name = "zig";

const Status = enum { pass, fail, skip };

const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
    missing_api: usize = 0,
    /// The first few failures, for a report that says what went wrong rather than how much.
    first_failures: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        for (self.first_failures.items) |line| allocator.free(line);
        self.first_failures.deinit(allocator);
    }
};

const max_reported_failures = 20;

test "testkit: the engine's JSON suites run through this driver" {
    // The corpus is checked before the engine: without FL_CORPUS it is left out, and a
    // directory holding no suites is a caller pointing at the wrong place.
    if (!try testing.environ.containsUnempty(testing.allocator, "FL_CORPUS")) {
        std.debug.print("\ntestkit: set FL_CORPUS to frostlake's engine/src/test/resources/testkit to replay the testkit corpus\n", .{});
        return error.SkipZigTest;
    }
    const corpus = try testing.environ.getAlloc(testing.allocator, "FL_CORPUS");
    defer testing.allocator.free(corpus);
    const suites_dir = try std.fs.path.join(testing.allocator, &.{ corpus, "suites" });
    defer testing.allocator.free(suites_dir);

    var dir = std.Io.Dir.cwd().openDir(testing.io, suites_dir, .{ .iterate = true }) catch |err| {
        noSuites(corpus);
        return err;
    };
    defer dir.close(testing.io);

    // Suite files run in NAME order, the order every other runner walks: account-level
    // objects (a warehouse, a stage) outlive the per-test database reset, so a bare
    // `CREATE WAREHOUSE wh` only passes when its suite runs before the ones creating the same
    // warehouse with IF NOT EXISTS. A directory iteration hands files back in no order.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| testing.allocator.free(n);
        names.deinit(testing.allocator);
    }
    var it = dir.iterate();
    while (try it.next(testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(testing.allocator, try testing.allocator.dupe(u8, entry.name));
    }
    if (names.items.len == 0) {
        noSuites(corpus);
        return error.NoSuites;
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    const base = testing.environ.getAlloc(testing.allocator, "FROSTLAKE_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer testing.allocator.free(base);

    var summary = Summary{};
    defer summary.deinit(testing.allocator);

    // One connection carries every test.
    //
    // A connection per test would be tidier, but only an engine that answers `newSession`
    // lets a closed connection release its session. An older one keeps it until the server's
    // own idle sweep reclaims it, and across a few thousand tests that is a few thousand live
    // sessions, which is enough to take the server down. One shared session replays the same
    // way against both. Each test re-creates its database and re-issues its USEs, so a shared
    // session starts each one from the same place a fresh one would.
    var session = Session{ .base = base };
    defer session.close();

    for (names.items) |name| {
        runSuiteFile(testing.allocator, dir, name, &session, &summary) catch |err| switch (err) {
            // One dead engine used to fail every remaining case on "cannot reach",
            // thousands of times over; the run stops with the reason instead.
            error.EngineUnreachable => {
                std.debug.print("\nABORTED: the engine stopped answering during {s}; the remaining suites were not run\n", .{name});
                summary.failed += 1;
                break;
            },
            else => return err,
        };
    }

    std.debug.print(
        "\ntestkit [{s}]: {d} passed, {d} failed, {d} skipped, {d} check(s) needing an API the HTTP transport lacks\n",
        .{ backend_name, summary.passed, summary.failed, summary.skipped, summary.missing_api },
    );
    for (summary.first_failures.items) |line| std.debug.print("  {s}\n", .{line});

    try testing.expectEqual(@as(usize, 0), summary.failed);
}

/// FL_CORPUS points at no `suites/*.json`: the run fails, and says which value it was given.
fn noSuites(corpus: []const u8) void {
    std.debug.print("\ntestkit: FL_CORPUS={s}: no suites/*.json there; point it at frostlake's engine/src/test/resources/testkit\n", .{corpus});
}

/// The one connection every test runs on, re-opened only if it becomes unusable.
///
/// A statement can leave the connection in a state the driver will not vouch for — a body that
/// was not a Frostlake response, a commit whose fate is unknown. Rather than fail every
/// remaining test, the next `borrow` notices and opens a fresh one.
const Session = struct {
    base: []const u8,
    conn: ?frostlake.Connection = null,

    fn borrow(self: *Session, allocator: std.mem.Allocator) !*frostlake.Connection {
        if (self.conn) |*existing| {
            if (existing.isValid()) return existing;
            existing.close();
            self.conn = null;
        }
        self.conn = try frostlake.Connection.open(allocator, testing.io, self.base);
        return &self.conn.?;
    }

    fn close(self: *Session) void {
        if (self.conn) |*existing| existing.close();
        self.conn = null;
    }
};

fn runSuiteFile(
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    name: []const u8,
    session: *Session,
    summary: *Summary,
) !void {
    const text = try dir.readFileAlloc(testing.io, name, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch {
        try note(allocator, summary, "{s}: not valid JSON", .{name});
        summary.failed += 1;
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const tests = root.object.get("tests") orelse return;
    if (tests != .array) return;

    for (tests.array.items) |case| {
        if (case != .object) continue;
        try runCase(allocator, name, case.object, session, summary);
    }
}

fn runCase(
    allocator: std.mem.Allocator,
    suite_name: []const u8,
    case: std.json.ObjectMap,
    session: *Session,
    summary: *Summary,
) !void {
    const case_name = stringField(case, "name") orelse "(unnamed)";

    if (case.get("skip")) |skip| {
        if (skip == .object and namesThisBackend(skip.object)) {
            summary.skipped += 1;
            return;
        }
    }

    const steps = case.get("steps") orelse return;
    if (steps != .array) return;

    // Per-test isolation: a fresh database and schema, on the one connection the steps run on,
    // so session state carries across steps exactly as the format requires.
    const conn = session.borrow(allocator) catch {
        try note(allocator, summary, "{s} / {s}: cannot open a connection", .{ suite_name, case_name });
        summary.failed += 1;
        return;
    };

    // A previous test may have left a transaction open; the reset has to run outside one.
    if (conn.in_transaction) conn.rollback() catch {};

    const reset = [_][]const u8{
        // A session runs one statement per request until it asks for more, so a case whose step
        // sends several would be refused on the count rather than answered; 0 means any number.
        "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0",
        "CREATE OR REPLACE DATABASE test_db",
        "USE DATABASE test_db",
        "CREATE OR REPLACE SCHEMA test_schema",
        "USE SCHEMA test_schema",
    };
    for (reset) |statement| {
        var response = conn.execute(statement) catch |err| {
            try note(allocator, summary, "{s} / {s}: reset failed at `{s}`: {s}", .{
                suite_name, case_name, statement, conn.lastError(),
            });
            summary.failed += 1;
            // The transport, not the engine's answer: the engine is gone.
            if (err == error.TransportFailed or err == error.ConnectionUnusable) return error.EngineUnreachable;
            return;
        };
        response.deinit();
    }

    for (steps.array.items, 0..) |step, index| {
        if (step != .object) continue;
        const sql = stringField(step.object, "sql") orelse continue;
        const status = try runStep(allocator, conn, step.object, sql, summary, suite_name, case_name, index + 1);
        switch (status) {
            // The first failed check stops the test, as the format requires.
            .fail => {
                summary.failed += 1;
                return;
            },
            .skip, .pass => {},
        }
    }
    summary.passed += 1;
}

fn runStep(
    allocator: std.mem.Allocator,
    conn: *frostlake.Connection,
    step: std.json.ObjectMap,
    sql: []const u8,
    summary: *Summary,
    suite_name: []const u8,
    case_name: []const u8,
    step_number: usize,
) !Status {
    const expect = blk: {
        const value = step.get("expect") orelse break :blk null;
        if (value != .object) break :blk null;
        break :blk value.object;
    };

    // An expected error: the statement must fail, and the message must match if one is named.
    if (expect) |e| {
        if (e.get("error")) |expected_error| {
            if (conn.execute(sql)) |*ok| {
                var mutable = ok.*;
                mutable.deinit();
                try note(allocator, summary, "{s} / {s} step {d}: expected an error, the statement succeeded: {s}", .{
                    suite_name, case_name, step_number, sql,
                });
                return .fail;
            } else |err| {
                // Only the engine's own refusal is a statement failure; a transport
                // failure satisfies no expectation — a dead engine must not pass an
                // `error` step.
                if (err != error.EngineRefused) {
                    try note(allocator, summary, "{s} / {s} step {d}: transport failure, not a refusal: {s}", .{
                        suite_name, case_name, step_number, conn.lastError(),
                    });
                    return .fail;
                }
                if (expected_error == .object) {
                    // `code` and `sqlState` need an API the HTTP transport does not have. The
                    // expectations already sit in the files, so the day it exists they light
                    // up without a test changing.
                    if (expected_error.object.get("code") != null) summary.missing_api += 1;
                    if (expected_error.object.get("sqlState") != null) summary.missing_api += 1;

                    if (stringField(expected_error.object, "messageContains")) |fragment| {
                        if (!containsIgnoreCase(conn.lastError(), fragment)) {
                            try note(allocator, summary, "{s} / {s} step {d}: message `{s}` does not contain `{s}`", .{
                                suite_name, case_name, step_number, conn.lastError(), fragment,
                            });
                            return .fail;
                        }
                    }
                }
                return .pass;
            }
        }
    }

    var response = conn.execute(sql) catch {
        try note(allocator, summary, "{s} / {s} step {d}: {s} -- {s}", .{
            suite_name, case_name, step_number, sql, conn.lastError(),
        });
        return .fail;
    };
    defer response.deinit();

    const e = expect orelse return .pass;
    const set = response.first();

    if (e.get("updateCount")) |wanted| {
        const want = asInteger(wanted) orelse 0;
        const got = response.rowsAffected();
        if (want != got) {
            try note(allocator, summary, "{s} / {s} step {d}: updateCount expected {d}, got {d}", .{
                suite_name, case_name, step_number, want, got,
            });
            return .fail;
        }
    }

    if (e.get("rowCount")) |wanted| {
        const want: usize = @intCast(asInteger(wanted) orelse 0);
        if (want != set.rowCount()) {
            try note(allocator, summary, "{s} / {s} step {d}: rowCount expected {d}, got {d}", .{
                suite_name, case_name, step_number, want, set.rowCount(),
            });
            return .fail;
        }
    }

    if (e.get("columns")) |wanted| {
        if (wanted == .array) {
            if (wanted.array.items.len != set.columnCount()) {
                try note(allocator, summary, "{s} / {s} step {d}: expected {d} column(s), got {d}", .{
                    suite_name, case_name, step_number, wanted.array.items.len, set.columnCount(),
                });
                return .fail;
            }
            for (wanted.array.items, 0..) |column, i| {
                const want = if (column == .string) column.string else continue;
                const got = try set.columnName(i);
                if (!std.ascii.eqlIgnoreCase(want, got)) {
                    try note(allocator, summary, "{s} / {s} step {d}: column {d} expected `{s}`, got `{s}`", .{
                        suite_name, case_name, step_number, i, want, got,
                    });
                    return .fail;
                }
            }
        }
    }

    if (e.get("value")) |wanted| {
        const cell = set.scalar() catch {
            try note(allocator, summary, "{s} / {s} step {d}: expected a value, the grid is empty", .{
                suite_name, case_name, step_number,
            });
            return .fail;
        };
        var scratch: std.Io.Writer.Allocating = .init(allocator);
        defer scratch.deinit();
        var want_buffer: [64]u8 = undefined;
        const want = jsonScalarText(wanted, &want_buffer);
        const got = try columnText(set, 0, cell, &scratch);
        if (!valuesMatch(want, got)) {
            try note(allocator, summary, "{s} / {s} step {d}: value expected `{s}`, got `{s}`", .{
                suite_name, case_name, step_number, want, got,
            });
            return .fail;
        }
    }

    if (e.get("rows")) |wanted| {
        if (wanted == .array) {
            const ordered = if (e.get("ordered")) |o| (o == .bool and o.bool) else false;
            if (!try rowsMatch(allocator, set, wanted.array.items, ordered)) {
                try note(allocator, summary, "{s} / {s} step {d}: the grid does not match ({d} expected row(s), {d} returned)", .{
                    suite_name, case_name, step_number, wanted.array.items.len, set.rowCount(),
                });
                return .fail;
            }
        }
    }

    return .pass;
}

// --- comparison -------------------------------------------------------------

/// Whether the suite's skip clause names this backend.
///
/// `http` counts as well as `zig`: this driver rides the HTTP transport and the same engine,
/// so anything that transport cannot express is out of reach here too.
fn namesThisBackend(skip: std.json.ObjectMap) bool {
    const backends = skip.get("backends") orelse return false;
    if (backends != .array) return false;
    for (backends.array.items) |entry| {
        if (entry != .string) continue;
        if (std.ascii.eqlIgnoreCase(entry.string, backend_name)) return true;
        if (std.ascii.eqlIgnoreCase(entry.string, "http")) return true;
    }
    return false;
}

/// Compare two cells the way SCHEMA.md says to: null and empty are NULL, booleans fold case,
/// anything numeric compares as a number rounded to ten significant digits, everything else is
/// an exact trimmed string.
fn valuesMatch(want: []const u8, got: []const u8) bool {
    const a = std.mem.trim(u8, want, " \t\r\n");
    const b = std.mem.trim(u8, got, " \t\r\n");

    const a_null = a.len == 0 or std.ascii.eqlIgnoreCase(a, "null");
    const b_null = b.len == 0 or std.ascii.eqlIgnoreCase(b, "null");
    if (a_null or b_null) return a_null and b_null;

    if (asBool(a)) |x| {
        if (asBool(b)) |y| return x == y;
    }

    if (std.fmt.parseFloat(f64, a)) |x| {
        if (std.fmt.parseFloat(f64, b)) |y| {
            // NaN never equals itself, so a numeric comparison alone would call two NaNs
            // different. A column that answers NaN and a test that expects NaN agree.
            if (std.math.isNan(x) or std.math.isNan(y)) return std.math.isNan(x) and std.math.isNan(y);
            return roundToSignificant(x, 10) == roundToSignificant(y, 10);
        } else |_| return false;
    } else |_| {}

    return std.mem.eql(u8, a, b);
}

fn asBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false")) return false;
    return null;
}

/// Round to `digits` significant digits, so `2` and `2.000000` compare equal and floating
/// noise in the last places does not decide a test.
fn roundToSignificant(value: f64, digits: i32) f64 {
    if (value == 0 or !std.math.isFinite(value)) return value;
    const magnitude = @floor(@log10(@abs(value)));
    const factor = std.math.pow(f64, 10, @as(f64, @floatFromInt(digits)) - 1 - magnitude);
    return @round(value * factor) / factor;
}

/// Full-grid comparison. Unordered by default, so a result with no ORDER BY is matched by
/// pairing each expected row with an unclaimed returned row.
fn rowsMatch(
    allocator: std.mem.Allocator,
    set: frostlake.ResultSet,
    expected: []const std.json.Value,
    ordered: bool,
) !bool {
    if (expected.len != set.rowCount()) return false;

    const claimed = try allocator.alloc(bool, set.rowCount());
    defer allocator.free(claimed);
    @memset(claimed, false);

    var scratch: std.Io.Writer.Allocating = .init(allocator);
    defer scratch.deinit();

    for (expected, 0..) |expected_row, i| {
        if (expected_row != .array) return false;
        if (ordered) {
            if (!try rowMatches(set, i, expected_row.array.items, &scratch)) return false;
            continue;
        }
        var found = false;
        for (0..set.rowCount()) |candidate| {
            if (claimed[candidate]) continue;
            if (try rowMatches(set, candidate, expected_row.array.items, &scratch)) {
                claimed[candidate] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn rowMatches(
    set: frostlake.ResultSet,
    row: usize,
    expected: []const std.json.Value,
    scratch: *std.Io.Writer.Allocating,
) !bool {
    if (expected.len != set.columnCount()) return false;
    for (expected, 0..) |want_value, col| {
        var want_buffer: [64]u8 = undefined;
        const want = jsonScalarText(want_value, &want_buffer);
        const cell = set.at(row, col) catch return false;
        const got = try columnText(set, col, cell, scratch);
        if (!valuesMatch(want, got)) return false;
    }
    return true;
}

/// A JSON scalar as the text the comparison works on. `buffer` backs the numeric cases.
fn jsonScalarText(value: std.json.Value, buffer: []u8) []const u8 {
    return switch (value) {
        .null => "",
        .bool => |v| if (v) "true" else "false",
        .string => |v| v,
        .number_string => |v| v,
        .integer => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch "",
        .float => |v| std.fmt.bufPrint(buffer, "{d}", .{v}) catch "",
        // A structured expectation compares as nothing; the format does not define one.
        .array, .object => "",
    };
}

/// A cell as the text the comparison works on, decoded once when its column carries
/// semi-structured values.
fn columnText(
    set: frostlake.ResultSet,
    col: usize,
    cell: frostlake.Cell,
    scratch: *std.Io.Writer.Allocating,
) ![]const u8 {
    const text = try cellText(cell, scratch);
    const column = set.column(col) catch return text;
    if (!semiStructured(column.data_type)) return text;
    return semiStructuredValue(text, scratch);
}

/// Whether a column carries semi-structured values, read from the type the engine declared.
fn semiStructured(data_type: []const u8) bool {
    for ([_][]const u8{ "VARIANT", "OBJECT", "ARRAY" }) |name| {
        if (std.ascii.eqlIgnoreCase(data_type, name)) return true;
    }
    return false;
}

/// The value a semi-structured cell carries, as the suites record it.
///
/// A VARIANT, OBJECT or ARRAY cell reaches a client as its JSON TEXT — a string's own quotes
/// included — which is what the account's own drivers do. The suites record the VALUE (`a`, not
/// `"a"`), so such a cell is decoded once: a JSON string becomes its content, which for a whole
/// object or array is the object's own text, and anything else — a number, a boolean, text that
/// is not JSON at all — is left exactly as it came. Only a semi-structured COLUMN is decoded, so
/// a VARCHAR whose content merely looks quoted keeps its quotes.
fn semiStructuredValue(text: []const u8, scratch: *std.Io.Writer.Allocating) ![]const u8 {
    const allocator = scratch.allocator;
    // `alloc_always`, so the decoded string owns its bytes rather than aliasing `text` — which
    // may itself point into the scratch this then rewrites.
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        text,
        .{ .allocate = .alloc_always },
    ) catch return text;
    defer parsed.deinit();
    if (parsed.value != .string) return text;
    scratch.clearRetainingCapacity();
    try scratch.writer.writeAll(parsed.value.string);
    return scratch.written();
}

/// A cell as the text the comparison works on.
///
/// `scratch` grows to fit, and is cleared on entry. A fixed buffer was wrong here: a BINARY
/// prints two characters per byte, so a hundred-byte value needs two hundred, and a buffer
/// that overflowed silently produced an empty string that then failed to compare — a driver
/// bug reported where there was none.
fn cellText(cell: frostlake.Cell, scratch: *std.Io.Writer.Allocating) ![]const u8 {
    scratch.clearRetainingCapacity();
    const w = &scratch.writer;
    switch (cell) {
        .null_value => return "",
        .boolean => |v| return if (v) "true" else "false",
        .string, .decimal, .variant => |v| return v,
        .integer => |v| try w.print("{d}", .{v}),
        .float => |v| try w.print("{d}", .{v}),
        // A BINARY compares as the uppercase hex the engine sent.
        .binary => |v| for (v) |byte| try w.print("{X:0>2}", .{byte}),
        .date => |v| try v.format(w),
        .time => |v| try v.format(w),
        .timestamp => |v| try v.format(w),
    }
    return scratch.written();
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn asInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        .number_string, .string => |v| std.fmt.parseInt(i64, v, 10) catch null,
        else => null,
    };
}

/// Record a failure line, keeping only the first handful so a broad regression reports what
/// broke rather than scrolling past it.
fn note(
    allocator: std.mem.Allocator,
    summary: *Summary,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    if (summary.first_failures.items.len >= max_reported_failures) return;
    const line = try std.fmt.allocPrint(allocator, fmt, args);
    try summary.first_failures.append(allocator, line);
}
