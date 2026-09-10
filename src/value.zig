//! The values a caller binds, and how each is rendered as a SQL literal.
//!
//! The protocol has no server-side binding, so a bound argument becomes text in the statement
//! before it is sent — exactly what Frostlake's JDBC driver does. Everything about that
//! rendering lives here, which is also why it is worth being precise: a value that renders
//! wrong is not a type error, it is a different value silently stored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag_mod = @import("diag.zig");
const Error = diag_mod.Error;

/// A calendar date with no zone and no time.
pub const Date = struct {
    year: i32,
    month: u8,
    day: u8,

    pub fn format(self: Date, writer: anytype) !void {
        // A negative or four-plus-digit year is left to the formatter rather than padded
        // blindly; padding a year of -5 to "00-5" would be worse than printing it long.
        if (self.year >= 0 and self.year <= 9999) {
            try writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(self.year)), self.month, self.day });
        } else {
            try writer.print("{d}-{d:0>2}-{d:0>2}", .{ self.year, self.month, self.day });
        }
    }
};

/// A wall-clock time of day. `nanosecond` holds sub-second precision; the engine's HTTP layer
/// serialises milliseconds, so a round trip through it keeps three digits of the nine.
pub const Time = struct {
    hour: u8,
    minute: u8,
    second: u8 = 0,
    nanosecond: u32 = 0,

    pub fn format(self: Time, writer: anytype) !void {
        try writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ self.hour, self.minute, self.second });
        try writeFraction(writer, self.nanosecond);
    }
};

/// A date and a time, optionally carrying a fixed offset from UTC in minutes.
///
/// With `offset_minutes` null this is a `TIMESTAMP_NTZ` — a wall clock belonging to whichever
/// zone the reader decides. With an offset it is a `TIMESTAMP_TZ`, an instant.
pub const Timestamp = struct {
    date: Date,
    time: Time = .{ .hour = 0, .minute = 0 },
    offset_minutes: ?i16 = null,

    pub fn format(self: Timestamp, writer: anytype) !void {
        try self.date.format(writer);
        try writer.writeAll(" ");
        try self.time.format(writer);
        if (self.offset_minutes) |offset| try writeOffset(writer, offset);
    }
};

/// Write a fractional-second suffix, trimmed of trailing zeroes and omitted entirely when the
/// value is whole. `.500000000` prints as `.5`, which parses back the same and reads better.
fn writeFraction(writer: anytype, nanosecond: u32) !void {
    if (nanosecond == 0) return;
    var buffer: [9]u8 = undefined;
    _ = std.fmt.printInt(&buffer, nanosecond, 10, .lower, .{ .width = 9, .fill = '0' });
    var end: usize = 9;
    while (end > 1 and buffer[end - 1] == '0') end -= 1;
    try writer.writeAll(".");
    try writer.writeAll(buffer[0..end]);
}

/// Write a `±HH:MM` offset.
fn writeOffset(writer: anytype, offset_minutes: i16) !void {
    const sign: u8 = if (offset_minutes < 0) '-' else '+';
    const magnitude: u16 = @intCast(@abs(offset_minutes));
    try writer.print("{c}{d:0>2}:{d:0>2}", .{ sign, magnitude / 60, magnitude % 60 });
}

/// A value being bound into a statement.
///
/// The constructors below read better at a call site than the union syntax does, and the
/// awkward ones — binary against string, exact decimal against float — are named rather than
/// left to look identical.
pub const Value = union(enum) {
    null_value,
    boolean: bool,
    integer: i64,
    float: f64,
    /// Text. Rendered as a quoted literal with escaping.
    string: []const u8,
    /// Bytes. Rendered as `X'…'`, not as text.
    binary: []const u8,
    /// Digits to emit verbatim as a numeric literal, for values wider than f64 can name
    /// exactly — `NUMBER(38,0)` holds them and a float64 would round them.
    decimal: []const u8,
    /// JSON text, rendered as `PARSE_JSON('…')` so it lands in a VARIANT rather than a string.
    variant: []const u8,
    /// SQL to inline exactly as written. Never escaped — see `raw`.
    raw_sql: []const u8,
    date: Date,
    time: Time,
    timestamp: Timestamp,

    pub fn isNull(self: Value) bool {
        return self == .null_value;
    }

    // Constructors.
    //
    // A union literal — `.{ .integer = 1 }` — is always available and is the most direct way
    // to write a value. These exist for the cases where it reads badly: inferring the variant
    // from a Zig type, and naming the ones a literal cannot tell apart (bytes are not a
    // string, exact digits are not a float).

    /// A SQL NULL.
    pub fn nul() Value {
        return .null_value;
    }

    /// Infer the variant from `v`'s Zig type.
    ///
    /// Booleans, integers, floats, strings, the temporal types and an existing `Value` all
    /// map to the obvious variant, and an optional binds its payload or NULL. Bytes are
    /// deliberately absent: `[]const u8` is Zig's string type too, so a `[]u8` that meant
    /// BINARY would silently become a VARCHAR. Use `bytes` for those.
    pub fn of(v: anytype) Value {
        const T = @TypeOf(v);
        const info = @typeInfo(T);
        return switch (info) {
            .null => .null_value,
            .bool => .{ .boolean = v },
            .comptime_int => .{ .integer = @intCast(v) },
            .int => |int_info| blk: {
                if (int_info.bits > 64) {
                    @compileError("frostlake: an integer wider than 64 bits cannot be bound with Value.of; render it as text with Value.decimalText");
                }
                // A u64 past i64's range would trap in @intCast; say what to do instead.
                break :blk .{ .integer = std.math.cast(i64, v) orelse
                    @panic("frostlake: a u64 above 9223372036854775807 cannot be bound with Value.of; render it as text with Value.decimalText") };
            },
            .float, .comptime_float => .{ .float = @floatCast(v) },
            .optional => if (v) |inner| of(inner) else .null_value,
            else => blk: {
                if (T == Value) break :blk v;
                if (T == Date) break :blk .{ .date = v };
                if (T == Time) break :blk .{ .time = v };
                if (T == Timestamp) break :blk .{ .timestamp = v };
                if (comptime isStringLike(T)) break :blk .{ .string = v };
                @compileError("frostlake: no SQL literal form for " ++ @typeName(T));
            },
        };
    }

    /// Bind bytes as a `BINARY` literal rather than as text.
    pub fn bytes(v: []const u8) Value {
        return .{ .binary = v };
    }

    /// Bind digits exactly, for a NUMBER too wide for `i64` or too precise for `f64`.
    pub fn decimalText(digits: []const u8) Value {
        return .{ .decimal = digits };
    }

    /// Bind JSON text as a VARIANT.
    pub fn jsonText(v: []const u8) Value {
        return .{ .variant = v };
    }

    /// Inline SQL verbatim — `CURRENT_TIMESTAMP()`, a column name, a subquery.
    ///
    /// Nothing is escaped, so this is the one constructor that will build an injectable
    /// statement out of untrusted text. It exists because binding cannot express a function
    /// call and the alternative is string-concatenating the whole statement, which is worse.
    pub fn rawSql(v: []const u8) Value {
        return .{ .raw_sql = v };
    }

    /// Render as the SQL literal that will carry this value to the engine.
    pub fn render(self: Value, writer: anytype) !void {
        switch (self) {
            .null_value => try writer.writeAll("NULL"),
            .boolean => |v| try writer.writeAll(if (v) "TRUE" else "FALSE"),
            // A negative numeral goes in parentheses: spliced straight after a minus it
            // would otherwise open a -- comment, so `SELECT 3-?` bound -5 became
            // `SELECT 3--5`, which the engine reads as `SELECT 3`.
            .integer => |v| if (v < 0) try writer.print("({d})", .{v}) else try writer.print("{d}", .{v}),
            .float => |v| try renderFloat(writer, v),
            .string => |v| try renderString(writer, v),
            .binary => |v| {
                try writer.writeAll("X'");
                for (v) |byte| try writer.print("{X:0>2}", .{byte});
                try writer.writeAll("'");
            },
            .decimal => |v| try writer.writeAll(v),
            .variant => |v| {
                try writer.writeAll("PARSE_JSON(");
                try renderString(writer, v);
                try writer.writeAll(")");
            },
            .raw_sql => |v| try writer.writeAll(v),
            .date => |v| {
                try writer.writeAll("'");
                try v.format(writer);
                try writer.writeAll("'::DATE");
            },
            .time => |v| {
                try writer.writeAll("'");
                try v.format(writer);
                try writer.writeAll("'::TIME");
            },
            .timestamp => |v| {
                try writer.writeAll("'");
                try v.format(writer);
                try writer.writeAll("'");
                // The cast is what decides which of the two timestamp types the literal
                // lands in, so it follows the offset rather than being chosen by the column.
                try writer.writeAll(if (v.offset_minutes == null) "::TIMESTAMP_NTZ" else "::TIMESTAMP_TZ");
            },
        }
    }
};

/// Whether `T` is one of the shapes Zig uses for a string literal or slice.
fn isStringLike(comptime T: type) bool {
    const info = @typeInfo(T);
    return switch (info) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// Mirror the engine's canonical literal encoder: backslashes doubled — backslash always
/// escapes in Frostlake's string dialect — and quotes doubled.
pub fn renderString(writer: anytype, text: []const u8) !void {
    try writer.writeAll("'");
    for (text) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '\'' => try writer.writeAll("''"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeAll("'");
}

/// Render a float so the parser reads back the value that was bound.
///
/// The special values need spelling out: written bare, `nan` and `inf` reach the parser as
/// identifiers and the statement fails on a name it cannot resolve. A whole number gets a
/// `.0` so the literal keeps its floating type rather than binding as an integer.
fn renderFloat(writer: anytype, v: f64) !void {
    if (std.math.isNan(v)) {
        try writer.writeAll("'NaN'::FLOAT");
        return;
    }
    // The engine's own spellings; the shorter 'Inf' is refused.
    if (std.math.isPositiveInf(v)) {
        try writer.writeAll("'Infinity'::FLOAT");
        return;
    }
    if (std.math.isNegativeInf(v)) {
        try writer.writeAll("'-Infinity'::FLOAT");
        return;
    }
    // A negative numeral goes in parentheses: spliced straight after a minus it would
    // otherwise open a -- comment (`SELECT 3-?` bound -5 became `SELECT 3--5`).
    const negative = v < 0;
    if (negative) try writer.writeByte('(');
    var buffer: [64]u8 = undefined;
    if (std.fmt.bufPrint(&buffer, "{d}", .{v})) |rendered| {
        try writer.writeAll(rendered);
        // `{d}` prints 2.0 as "2"; without a fractional part the literal would bind as an
        // integer, so a bound 2.0 and a bound 2 would become the same value with different
        // types.
        if (std.mem.indexOfAny(u8, rendered, ".eEnN") == null) try writer.writeAll(".0");
    } else |_| {
        try writer.print("{d}", .{v});
    }
    if (negative) try writer.writeByte(')');
}

/// Render `value` into a freshly allocated string. Used by tests and by callers that want to
/// see a literal without building a statement around it.
pub fn renderAlloc(allocator: Allocator, value: Value) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    value.render(&out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}
