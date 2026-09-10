//! Reading cells back: what a column's declared type means, and how the JSON on the wire
//! becomes a typed value.
//!
//! The wire is loosely typed — a cell arrives as JSON text, a JSON number or a JSON bool — so
//! the column's declared type is what decides how to read it. A `DATE` and a `VARCHAR` both
//! cross as strings and only the metadata tells them apart.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Date = value_mod.Date;
const Time = value_mod.Time;
const Timestamp = value_mod.Timestamp;
const Value = value_mod.Value;
const diag_mod = @import("diag.zig");
const Error = diag_mod.Error;

/// Whether a column's nullability is known. The engine always sends the field; absent means
/// only one thing — a server predating it — which is worth telling apart from "not nullable".
pub const Nullability = enum { unknown, nullable, not_null };

/// A column's declared type, reduced to how its cells should be read.
pub const ColumnKind = enum {
    text,
    integral,
    /// A `NUMBER`/`NUMERIC`/`DECIMAL` with a scale — an exact fixed-point value.
    ///
    /// Kept apart from `floating` on purpose. `NUMBER(12,2)` is what money is stored in, and
    /// its whole promise is that the digits are exact; reading one into an `f64` turns
    /// `135500.50` into `135500.5` and `0.1` into something that is not `0.1` at all.
    decimal,
    /// `FLOAT`/`DOUBLE`/`REAL` — a binary float, which is what the column actually holds.
    floating,
    boolean,
    binary,
    variant,
    date,
    time,
    /// TIMESTAMP / TIMESTAMP_NTZ / DATETIME — a wall clock with no zone of its own.
    timestamp_naive,
    /// TIMESTAMP_LTZ / TIMESTAMP_TZ — a wall clock plus an offset.
    timestamp_zoned,
};

/// A result column's metadata.
pub const Column = struct {
    name: []const u8,
    /// The engine's own spelling of the type, e.g. `NUMBER` or `VARCHAR(16777216)`.
    data_type: []const u8,
    precision: i32 = 0,
    scale: i32 = 0,
    nullable: Nullability = .unknown,

    pub fn kind(self: Column) ColumnKind {
        return classify(self);
    }
};

/// Strip any `(p,s)` suffix, so `NUMBER(38,0)` and `NUMBER` answer alike.
pub fn baseTypeName(data_type: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, data_type, " \t");
    if (std.mem.indexOfScalar(u8, trimmed, '(')) |i| {
        return std.mem.trim(u8, trimmed[0..i], " \t");
    }
    return trimmed;
}

fn eqlType(data_type: []const u8, comptime name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(data_type, name);
}

fn isAnyType(data_type: []const u8, comptime names: []const []const u8) bool {
    inline for (names) |name| {
        if (eqlType(data_type, name)) return true;
    }
    return false;
}

/// The scale a column declares.
///
/// The wire carries precision and scale as their own fields — `data_type` is the bare word
/// `NUMBER` — so those decide, with an inline `NUMBER(p,s)` spelling honoured as a fallback
/// for servers that put the pair in the type name instead.
pub fn declaredScale(column: Column) i32 {
    if (column.scale != 0) return column.scale;
    const name = column.data_type;
    const open = std.mem.indexOfScalar(u8, name, '(') orelse return column.scale;
    const close = std.mem.indexOfScalarPos(u8, name, open, ')') orelse return column.scale;
    const comma = std.mem.indexOfScalarPos(u8, name, open, ',') orelse return column.scale;
    if (comma > close) return column.scale;
    const text = std.mem.trim(u8, name[comma + 1 .. close], " \t");
    return std.fmt.parseInt(i32, text, 10) catch column.scale;
}

/// Whether precision and scale mean anything for this column. The approximate family carries
/// no pair — the engine leaves both at zero for a FLOAT, matching what Snowflake reports.
pub fn hasPrecisionScale(column: Column) bool {
    const base = baseTypeName(column.data_type);
    if (!isAnyType(base, &.{ "NUMBER", "NUMERIC", "DECIMAL", "DEC" })) return false;
    return column.precision > 0;
}

/// Reduce a declared type to how its cells should be read.
pub fn classify(column: Column) ColumnKind {
    const base = baseTypeName(column.data_type);

    if (eqlType(base, "DATE")) return .date;
    if (eqlType(base, "TIME")) return .time;
    if (isAnyType(base, &.{ "TIMESTAMP", "TIMESTAMP_NTZ", "TIMESTAMPNTZ", "DATETIME" })) return .timestamp_naive;
    if (isAnyType(base, &.{ "TIMESTAMP_LTZ", "TIMESTAMPLTZ", "TIMESTAMP_TZ", "TIMESTAMPTZ" })) return .timestamp_zoned;
    if (isAnyType(base, &.{ "BINARY", "VARBINARY" })) return .binary;
    if (isAnyType(base, &.{ "VARIANT", "OBJECT", "ARRAY", "MAP", "GEOGRAPHY", "GEOMETRY" })) return .variant;
    if (eqlType(base, "BOOLEAN") or eqlType(base, "BOOL")) return .boolean;
    if (isAnyType(base, &.{ "INT", "INTEGER", "BIGINT", "SMALLINT", "TINYINT", "BYTEINT" })) return .integral;
    if (isAnyType(base, &.{ "NUMBER", "NUMERIC", "DECIMAL", "DEC" })) {
        return if (declaredScale(column) == 0) .integral else .decimal;
    }
    if (isAnyType(base, &.{ "FLOAT", "FLOAT4", "FLOAT8", "DOUBLE", "DOUBLE PRECISION", "REAL" })) return .floating;
    return .text;
}

/// A cell read back from a result set.
///
/// Slices point into the result set's own storage and stay valid until it is released.
pub const Cell = union(enum) {
    null_value,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    binary: []const u8,
    /// Exact digits of a number too wide or too precise for `i64`/`f64` to name — a
    /// `NUMBER(38,0)` holds values a float would silently round.
    decimal: []const u8,
    /// VARIANT / OBJECT / ARRAY, as its JSON text.
    variant: []const u8,
    date: Date,
    time: Time,
    timestamp: Timestamp,

    pub fn isNull(self: Cell) bool {
        return self == .null_value;
    }

    pub fn asBool(self: Cell) Error!bool {
        return switch (self) {
            .boolean => |v| v,
            // The engine can hand a BOOLEAN back as text through an expression.
            .string => |v| parseBoolText(v) orelse Error.TypeMismatch,
            else => Error.TypeMismatch,
        };
    }

    pub fn asInt(self: Cell) Error!i64 {
        return switch (self) {
            .integer => |v| v,
            .decimal => |v| std.fmt.parseInt(i64, v, 10) catch Error.TypeMismatch,
            .string => |v| std.fmt.parseInt(i64, v, 10) catch Error.TypeMismatch,
            // A whole float reads as an integer; a fractional one is a mismatch rather than a
            // silent truncation.
            // The upper bound is strict: 9223372036854775808.0 IS 2^63, one past i64's
            // largest, and @intFromFloat trapped on it.
            .float => |v| if (v == @trunc(v) and v >= -9.2233720368547758e18 and v < 9.2233720368547758e18)
                @as(i64, @intFromFloat(v))
            else
                Error.TypeMismatch,
            else => Error.TypeMismatch,
        };
    }

    pub fn asFloat(self: Cell) Error!f64 {
        return switch (self) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            .decimal => |v| std.fmt.parseFloat(f64, v) catch Error.TypeMismatch,
            .string => |v| std.fmt.parseFloat(f64, v) catch Error.TypeMismatch,
            else => Error.TypeMismatch,
        };
    }

    /// The cell's text. Only the kinds that genuinely hold text answer — reading a number as
    /// text would otherwise depend on how the engine happened to send it.
    pub fn asText(self: Cell) Error![]const u8 {
        return switch (self) {
            .string, .variant, .decimal => |v| v,
            else => Error.TypeMismatch,
        };
    }

    pub fn asBytes(self: Cell) Error![]const u8 {
        return switch (self) {
            .binary => |v| v,
            else => Error.TypeMismatch,
        };
    }

    pub fn asDate(self: Cell) Error!Date {
        return switch (self) {
            .date => |v| v,
            .timestamp => |v| v.date,
            else => Error.TypeMismatch,
        };
    }

    pub fn asTime(self: Cell) Error!Time {
        return switch (self) {
            .time => |v| v,
            .timestamp => |v| v.time,
            else => Error.TypeMismatch,
        };
    }

    pub fn asTimestamp(self: Cell) Error!Timestamp {
        return switch (self) {
            .timestamp => |v| v,
            .date => |v| .{ .date = v },
            else => Error.TypeMismatch,
        };
    }

    /// Re-bind a cell that was just read. Slices are borrowed, so the value stays valid only
    /// as long as the result set it came from.
    pub fn toValue(self: Cell) Value {
        return switch (self) {
            .null_value => .null_value,
            .boolean => |v| .{ .boolean = v },
            .integer => |v| .{ .integer = v },
            .float => |v| .{ .float = v },
            .string => |v| .{ .string = v },
            .binary => |v| .{ .binary = v },
            .decimal => |v| .{ .decimal = v },
            .variant => |v| .{ .variant = v },
            .date => |v| .{ .date = v },
            .time => |v| .{ .time = v },
            .timestamp => |v| .{ .timestamp = v },
        };
    }
};

fn parseBoolText(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) return false;
    return null;
}

/// Decode a JSON string cell against its column's declared type.
///
/// `arena` owns whatever the decoded cell points at — a hex-decoded BINARY needs storage that
/// outlives the parse, and borrowing the JSON text would tie the result to a buffer the caller
/// does not know about.
pub fn decodeString(arena: Allocator, text: []const u8, column: Column) Allocator.Error!Cell {
    switch (classify(column)) {
        .date => return if (parseDate(text)) |d| .{ .date = d } else .{ .string = text },
        .time => return if (parseTime(text)) |t| .{ .time = t } else .{ .string = text },
        .timestamp_naive, .timestamp_zoned => {
            if (parseTimestamp(text)) |ts| return .{ .timestamp = ts };
            return .{ .string = text };
        },
        .binary => {
            if (decodeHex(arena, text)) |bytes| return .{ .binary = bytes } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Not hex after all: hand back the text rather than losing the value.
                error.InvalidHex => return .{ .string = text },
            }
        },
        .variant => return .{ .variant = text },
        // A number or a boolean the engine chose to send as text still belongs to its column.
        .integral, .decimal => return .{ .decimal = text },
        .floating => return if (std.fmt.parseFloat(f64, text)) |f| .{ .float = f } else |_| .{ .string = text },
        .boolean => return if (parseBoolText(text)) |b| .{ .boolean = b } else .{ .string = text },
        .text => return .{ .string = text },
    }
}

/// Decode a JSON number cell against its column's declared type.
///
/// `text` is the number exactly as it appeared on the wire, which is what keeps a
/// `NUMBER(38,0)` exact: parsed as an f64 it would round, so a value too wide for `i64` keeps
/// its digits instead.
pub fn decodeNumber(text: []const u8, column: Column) Cell {
    switch (classify(column)) {
        // An exact fixed-point column keeps its digits, whatever they are. Parsing first and
        // asking questions later has already lost the scale.
        .decimal => return .{ .decimal = text },
        .integral => {
            if (std.mem.indexOfAny(u8, text, ".eE") == null) {
                if (std.fmt.parseInt(i64, text, 10)) |n| return .{ .integer = n } else |_| {
                    // Wider than i64 — NUMBER(38,0) holds values f64 cannot name. Keeping the
                    // digits keeps them exact.
                    return .{ .decimal = text };
                }
            }
            // A scale-0 column that answered with a fraction anyway: keep it rather than
            // rounding it to fit the declared type.
            return .{ .decimal = text };
        },
        else => {},
    }
    if (std.fmt.parseFloat(f64, text)) |f| {
        return .{ .float = f };
    } else |_| {
        return .{ .decimal = text };
    }
}

const HexError = error{ InvalidHex, OutOfMemory };

fn decodeHex(arena: Allocator, text: []const u8) HexError![]const u8 {
    if (text.len % 2 != 0) return error.InvalidHex;
    const out = try arena.alloc(u8, text.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = std.fmt.charToDigit(text[i * 2], 16) catch return error.InvalidHex;
        const lo = std.fmt.charToDigit(text[i * 2 + 1], 16) catch return error.InvalidHex;
        out[i] = hi * 16 + lo;
    }
    return out;
}

// ---------------------------------------------------------------------------
// Temporal text
//
// The engine renders DATE as `yyyy-MM-dd`, TIME as `HH:mm:ss`, the zoneless timestamps as
// `yyyy-MM-dd HH:mm:ss.SSS` and the zoned ones as `yyyy-MM-dd HH:mm:ss.SSS Z`. The parsers
// below accept those and a little more — a `T` separator, a missing or longer fraction, a
// `+HH:MM` or `Z` offset — so a server that spells a value more precisely still reads.
// ---------------------------------------------------------------------------

/// `yyyy-MM-dd`, allowing a negative or long year.
pub fn parseDate(text: []const u8) ?Date {
    const trimmed = std.mem.trim(u8, text, " \t");
    var rest = trimmed;
    var negative = false;
    if (rest.len > 0 and rest[0] == '-') {
        negative = true;
        rest = rest[1..];
    }
    const first = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, rest, first + 1, '-') orelse return null;

    const year_magnitude = std.fmt.parseInt(i32, rest[0..first], 10) catch return null;
    const month = std.fmt.parseInt(u8, rest[first + 1 .. second], 10) catch return null;
    const day = std.fmt.parseInt(u8, rest[second + 1 ..], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    return .{
        .year = if (negative) -year_magnitude else year_magnitude,
        .month = month,
        .day = day,
    };
}

/// `HH:mm:ss[.fraction]`, with the seconds optional.
pub fn parseTime(text: []const u8) ?Time {
    const trimmed = std.mem.trim(u8, text, " \t");
    const first = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    const hour = std.fmt.parseInt(u8, trimmed[0..first], 10) catch return null;

    var rest = trimmed[first + 1 ..];
    var minute: u8 = 0;
    var second: u8 = 0;
    var nanosecond: u32 = 0;

    if (std.mem.indexOfScalar(u8, rest, ':')) |second_sep| {
        minute = std.fmt.parseInt(u8, rest[0..second_sep], 10) catch return null;
        rest = rest[second_sep + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
            second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return null;
            nanosecond = parseFraction(rest[dot + 1 ..]) orelse return null;
        } else {
            second = std.fmt.parseInt(u8, rest, 10) catch return null;
        }
    } else {
        minute = std.fmt.parseInt(u8, rest, 10) catch return null;
    }

    if (hour > 23 or minute > 59 or second > 60) return null;
    return .{ .hour = hour, .minute = minute, .second = second, .nanosecond = nanosecond };
}

/// A fraction-of-a-second suffix, scaled to nanoseconds. `.5` is 500000000ns, and more than
/// nine digits are truncated rather than rejected.
fn parseFraction(digits: []const u8) ?u32 {
    if (digits.len == 0) return null;
    var nanosecond: u32 = 0;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const digit: u32 = if (i < digits.len) blk: {
            if (!std.ascii.isDigit(digits[i])) return null;
            break :blk digits[i] - '0';
        } else 0;
        nanosecond = nanosecond * 10 + digit;
    }
    // Anything past nine digits must still be digits for the text to be a valid fraction.
    while (i < digits.len) : (i += 1) {
        if (!std.ascii.isDigit(digits[i])) return null;
    }
    return nanosecond;
}

/// `yyyy-MM-dd[ T]HH:mm:ss[.fraction][ ][±HHMM|±HH:MM|Z]`.
pub fn parseTimestamp(text: []const u8) ?Timestamp {
    var rest = std.mem.trim(u8, text, " \t");
    if (rest.len == 0) return null;

    // Split date from time at the separator, which is a space or a `T`. The year may be
    // negative, so the search for the separator starts past a leading sign.
    const search_from: usize = if (rest[0] == '-') 1 else 0;
    const separator = blk: {
        if (std.mem.indexOfScalarPos(u8, rest, search_from, ' ')) |i| break :blk i;
        if (std.mem.indexOfScalarPos(u8, rest, search_from, 'T')) |i| break :blk i;
        // A date on its own is a timestamp at midnight.
        return if (parseDate(rest)) |d| Timestamp{ .date = d } else null;
    };

    const date = parseDate(rest[0..separator]) orelse return null;
    rest = rest[separator + 1 ..];

    // Peel off the offset, which may be attached or separated by a space.
    var offset: ?i16 = null;
    if (rest.len > 0 and (rest[rest.len - 1] == 'Z' or rest[rest.len - 1] == 'z')) {
        offset = 0;
        rest = rest[0 .. rest.len - 1];
    } else if (findOffsetStart(rest)) |i| {
        offset = parseOffsetText(rest[i..]) orelse return null;
        rest = rest[0..i];
    }
    rest = std.mem.trim(u8, rest, " \t");

    const time = if (rest.len == 0) Time{ .hour = 0, .minute = 0 } else parseTime(rest) orelse return null;
    return .{ .date = date, .time = time, .offset_minutes = offset };
}

/// Where a trailing `±…` offset begins, if there is one.
///
/// The sign is searched for from the end because the time itself contains no sign, and a
/// leading `-` would belong to a negative year rather than to an offset.
fn findOffsetStart(text: []const u8) ?usize {
    var i = text.len;
    while (i > 0) {
        i -= 1;
        const c = text[i];
        if (c == '+' or c == '-') return i;
        // Walk back over the offset's own characters only; anything else means there is none.
        if (!std.ascii.isDigit(c) and c != ':') return null;
    }
    return null;
}

/// `±HHMM`, `±HH:MM` or `±HH`, in minutes east of UTC.
fn parseOffsetText(text: []const u8) ?i16 {
    if (text.len < 2) return null;
    const sign: i16 = switch (text[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    const digits = text[1..];
    var hours: i16 = 0;
    var minutes: i16 = 0;
    if (std.mem.indexOfScalar(u8, digits, ':')) |i| {
        hours = std.fmt.parseInt(i16, digits[0..i], 10) catch return null;
        minutes = std.fmt.parseInt(i16, digits[i + 1 ..], 10) catch return null;
    } else switch (digits.len) {
        4 => {
            hours = std.fmt.parseInt(i16, digits[0..2], 10) catch return null;
            minutes = std.fmt.parseInt(i16, digits[2..4], 10) catch return null;
        },
        1, 2 => hours = std.fmt.parseInt(i16, digits, 10) catch return null,
        else => return null,
    }
    if (hours > 18 or minutes > 59) return null;
    return sign * (hours * 60 + minutes);
}
