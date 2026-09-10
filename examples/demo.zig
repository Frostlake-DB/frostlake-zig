//! A worked example against a running engine.
//!
//! ```sh
//! zig build example -- frostlake://localhost:18082
//! ```
//!
//! With no argument it uses `FROSTLAKE_URL`, and falls back to `frostlake://localhost:18082`.

const std = @import("std");
const frostlake = @import("frostlake");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next(); // the program's own name

    const dsn = if (args.next()) |arg|
        try gpa.dupe(u8, arg)
    else if (init.environ_map.get("FROSTLAKE_URL")) |from_env|
        try gpa.dupe(u8, from_env)
    else
        try gpa.dupe(u8, "frostlake://localhost:18082");
    defer gpa.free(dsn);

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &stdout.interface;

    var conn = frostlake.Connection.open(gpa, io, dsn) catch |err| {
        try w.print("cannot open {s}: {s}\n", .{ dsn, @errorName(err) });
        try w.flush();
        return 1;
    };
    defer conn.close();

    conn.ping() catch |err| {
        try w.print("no engine at {s}: {s}\n  {s}\n", .{ dsn, @errorName(err), conn.lastError() });
        try w.flush();
        return 1;
    };
    try w.print("connected to {s}\n", .{dsn});

    // Which engine is on the other end. Every release answers this one.
    {
        var response = try conn.query("SELECT CURRENT_VERSION()", &.{});
        defer response.deinit();
        try w.print("engine version: {s}\n\n", .{try (try response.scalar()).asText()});
    }

    try run(&conn, w);
    try w.flush();
    return 0;
}

fn run(conn: *frostlake.Connection, w: *std.Io.Writer) !void {
    const Value = frostlake.Value;

    try exec(conn, w, "CREATE OR REPLACE DATABASE ZIG_DEMO");
    try exec(conn, w, "USE DATABASE ZIG_DEMO");
    try exec(conn, w, "USE SCHEMA PUBLIC");
    try exec(conn, w,
        \\CREATE OR REPLACE TABLE PEOPLE (
        \\  ID INTEGER, NAME VARCHAR, HIRED DATE, SALARY NUMBER(12,2)
        \\)
    );

    // Positional binding. Values are inlined client-side, escaping and all.
    const inserted = try conn.exec(
        "INSERT INTO PEOPLE VALUES (?, ?, ?, ?), (?, ?, ?, ?)",
        &.{
            Value.of(1),
            Value.of("Ada Lovelace"),
            Value.of(frostlake.Date{ .year = 1843, .month = 7, .day = 10 }),
            Value.decimalText("120000.00"),
            Value.of(2),
            // An apostrophe that a naive driver would let break out of the literal.
            Value.of("Grace O'Hopper"),
            Value.of(frostlake.Date{ .year = 1944, .month = 5, .day = 1 }),
            Value.decimalText("135500.50"),
        },
    );
    try w.print("inserted {d} row(s)\n\n", .{inserted});

    // Named binding. Order does not matter and a name may repeat.
    var rows = try conn.queryNamed(
        "SELECT ID, NAME, HIRED, SALARY FROM PEOPLE WHERE SALARY > :floor ORDER BY ID",
        &.{.{ .name = "floor", .value = Value.decimalText("100000") }},
    );
    defer rows.deinit();

    const set = rows.first();

    // Column metadata comes back with the grid.
    const width = 18;
    for (set.columns) |c| try pad(w, c.name, width);
    try w.writeAll("\n");
    for (set.columns) |_| try w.splatByteAll('-', width);
    try w.writeAll("\n");

    var cell_buffer: [64]u8 = undefined;
    var it = set.iterator();
    while (it.next()) |row| {
        var col: usize = 0;
        while (col < set.columnCount()) : (col += 1) {
            try pad(w, try cellText(try row.at(col), &cell_buffer), width);
        }
        try w.writeAll("\n");
    }

    // A transaction, rolled back so the demo leaves nothing behind.
    try conn.begin();
    _ = try conn.exec("DELETE FROM PEOPLE", &.{});
    try conn.rollback();

    var after = try conn.query("SELECT COUNT(*) FROM PEOPLE", &.{});
    defer after.deinit();
    try w.print("\nafter the rolled-back delete: {d} row(s)\n", .{try (try after.scalar()).asInt()});

    // A statement the engine refuses. The message is the engine's own.
    if (conn.query("SELECT * FROM NO_SUCH_TABLE", &.{})) |*ok| {
        var mutable = ok.*;
        mutable.deinit();
    } else |_| {
        try w.print("as expected: {s}\n", .{conn.lastError()});
    }
}

fn exec(conn: *frostlake.Connection, w: *std.Io.Writer, sql: []const u8) !void {
    var response = conn.query(sql, &.{}) catch |err| {
        try w.print("failed: {s}\n  {s}\n", .{ sql, conn.lastError() });
        return err;
    };
    response.deinit();
}

/// Write `text` followed by enough spaces to fill `width`.
fn pad(w: *std.Io.Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    if (text.len < width) try w.splatByteAll(' ', width - text.len);
}

/// A cell as printable text. `buffer` backs the cases that have to be formatted.
///
/// Note what `.decimal` does NOT do: it prints the digits the engine sent. A `NUMBER(12,2)`
/// holding `135500.50` prints as `135500.50`, where reading it into an `f64` first would have
/// printed `135500.5`.
fn cellText(cell: frostlake.Cell, buffer: []u8) ![]const u8 {
    return switch (cell) {
        .null_value => "NULL",
        .boolean => |v| if (v) "true" else "false",
        .integer => |v| try std.fmt.bufPrint(buffer, "{d}", .{v}),
        .float => |v| try std.fmt.bufPrint(buffer, "{d}", .{v}),
        .string, .decimal, .variant => |v| v,
        .binary => |v| blk: {
            var writer: std.Io.Writer = .fixed(buffer);
            for (v) |byte| try writer.print("{X:0>2}", .{byte});
            break :blk writer.buffered();
        },
        .date => |v| blk: {
            var writer: std.Io.Writer = .fixed(buffer);
            try v.format(&writer);
            break :blk writer.buffered();
        },
        .time => |v| blk: {
            var writer: std.Io.Writer = .fixed(buffer);
            try v.format(&writer);
            break :blk writer.buffered();
        },
        .timestamp => |v| blk: {
            var writer: std.Io.Writer = .fixed(buffer);
            try v.format(&writer);
            break :blk writer.buffered();
        },
    };
}
