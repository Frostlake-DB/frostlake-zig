//! Client-side parameter binding.
//!
//! The protocol carries no bind values, so arguments are inlined into the statement text
//! before it is sent — the same thing Frostlake's JDBC driver does. A statement uses either
//! positional `?` markers or named `:name` ones, never both.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const sql = @import("sql.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const diag_mod = @import("diag.zig");
const Diagnostics = diag_mod.Diagnostics;
const Error = diag_mod.Error;
const fail = diag_mod.fail;

/// An argument bound by name rather than by position.
pub const NamedValue = struct {
    name: []const u8,
    value: Value,

    pub fn init(name: []const u8, v: Value) NamedValue {
        return .{ .name = name, .value = v };
    }
};

/// Inline positional arguments into `statement`, returning the SQL to send.
///
/// The argument count has to match the marker count. A marker left without an argument is an
/// error rather than a silently bound NULL — the difference between the two is a row that
/// says something false and a call that says it went wrong.
pub fn substitute(
    allocator: Allocator,
    statement: []const u8,
    args: []const Value,
    diag: ?*Diagnostics,
) Error![]u8 {
    const counts = sql.countPlaceholders(statement);
    if (counts.isMixed()) {
        return fail(diag, allocator, Error.BindMismatch, "frostlake: a statement may use ? or :name placeholders, not both", .{});
    }
    if (counts.named > 0) {
        if (args.len == 0) {
            // With no arguments at all the colon references belong to the SERVER — they are
            // Snowflake Scripting variables (EXECUTE IMMEDIATE :v, IFF(:flag, …)) — and the
            // statement passes through verbatim. Named client binds exist only when named
            // arguments are supplied.
            return allocator.dupe(u8, statement);
        }
        return fail(diag, allocator, Error.BindMismatch, "frostlake: the statement uses :name placeholders, so its arguments must be named", .{});
    }
    // Symmetrically, with no arguments at all the ? marks are the SERVER's — a Snowflake
    // Scripting cursor placeholder bound by OPEN c USING (...) — and the statement passes
    // through verbatim. Positional client binds exist only when arguments are supplied.
    if (args.len == 0) return allocator.dupe(u8, statement);
    if (counts.positional != args.len) {
        return fail(diag, allocator, Error.BindMismatch, "frostlake: statement has {d} placeholder(s), got {d} argument(s)", .{ counts.positional, args.len });
    }
    if (counts.positional == 0) return allocator.dupe(u8, statement);

    var out: Writer.Allocating = try .initCapacity(allocator, statement.len + 16 * args.len);
    errdefer out.deinit();

    var cursor: usize = 0;
    var index: usize = 0;
    var it = sql.PlaceholderIterator.init(statement);
    while (it.next()) |marker| : (index += 1) {
        out.writer.writeAll(statement[cursor..marker.start]) catch return error.OutOfMemory;
        try renderInto(allocator, &out, args[index]);
        cursor = marker.end;
    }
    out.writer.writeAll(statement[cursor..]) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Inline named arguments into `statement`.
///
/// Order does not matter, a name may appear more than once, and an argument that names no
/// marker is an error — a misspelt name that bound nothing would otherwise run a statement
/// the caller did not write.
pub fn substituteNamed(
    allocator: Allocator,
    statement: []const u8,
    args: []const NamedValue,
    diag: ?*Diagnostics,
) Error![]u8 {
    const counts = sql.countPlaceholders(statement);
    if (counts.isMixed()) {
        return fail(diag, allocator, Error.BindMismatch, "frostlake: a statement may use ? or :name placeholders, not both", .{});
    }
    if (counts.positional > 0) {
        return fail(diag, allocator, Error.BindMismatch, "frostlake: the statement uses positional ? placeholders, so its arguments must not be named", .{});
    }
    if (counts.named == 0 and args.len > 0) {
        return fail(diag, allocator, Error.BindMismatch, "frostlake: the statement has no :name placeholders, but {d} named argument(s) were given", .{args.len});
    }
    if (counts.named == 0) return allocator.dupe(u8, statement);

    var out: Writer.Allocating = try .initCapacity(allocator, statement.len + 16 * counts.named);
    errdefer out.deinit();

    // Which arguments were actually used. A statement carries few enough parameters that a
    // stack bitmap is not worth the allocation a set would cost.
    var used = try allocator.alloc(bool, args.len);
    defer allocator.free(used);
    @memset(used, false);

    var cursor: usize = 0;
    var it = sql.PlaceholderIterator.init(statement);
    while (it.next()) |marker| {
        out.writer.writeAll(statement[cursor..marker.start]) catch return error.OutOfMemory;
        const found = findNamed(args, marker.name) orelse {
            return fail(diag, allocator, Error.BindMismatch, "frostlake: no argument bound for :{s}", .{marker.name});
        };
        used[found] = true;
        try renderInto(allocator, &out, args[found].value);
        cursor = marker.end;
    }
    out.writer.writeAll(statement[cursor..]) catch return error.OutOfMemory;

    for (args, 0..) |arg, i| {
        if (!used[i]) {
            return fail(diag, allocator, Error.BindMismatch, "frostlake: argument :{s} does not appear in the statement", .{arg.name});
        }
    }
    return out.toOwnedSlice();
}

/// Index of the argument named `name`, folding case the way an unquoted identifier does.
fn findNamed(args: []const NamedValue, name: []const u8) ?usize {
    for (args, 0..) |arg, i| {
        if (std.ascii.eqlIgnoreCase(arg.name, name)) return i;
    }
    return null;
}

/// Append a value's literal form to `out`.
///
/// `Value.render` is exhaustive over the union, so a variant added without a literal form is
/// a compile error rather than something to check for here.
fn renderInto(allocator: Allocator, out: *Writer.Allocating, v: Value) Allocator.Error!void {
    _ = allocator;
    v.render(&out.writer) catch return error.OutOfMemory;
}
