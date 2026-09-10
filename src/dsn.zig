//! DSN parsing.
//!
//! ```
//! frostlake://host:port[/DATABASE][?param=value&…]
//! ```
//!
//! An unknown parameter is an error rather than a silent no-op, and so is a username or
//! password — the engine's HTTP API has no authentication to hand them to, so accepting
//! credentials would mean quietly discarding them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag_mod = @import("diag.zig");
const Diagnostics = diag_mod.Diagnostics;
const Error = diag_mod.Error;
const fail = diag_mod.fail;
const sql = @import("sql.zig");

/// A single request's time budget. Queries can legitimately run for minutes, so the default is
/// generous rather than snappy; `timeout=0` in the DSN removes it entirely.
pub const default_timeout_ms: u64 = 5 * std.time.ms_per_min;

/// The most `USE` statements a DSN can imply: role, warehouse, database, schema.
pub const max_use_statements = 4;

/// The `USE` statements a DSN's scope needs on a fresh session, in dependency order.
///
/// Rebuilt on demand rather than held once, so a connection that has moved off the DSN's scope
/// can be put back on it.
pub const UseStatements = struct {
    allocator: Allocator,
    items: [max_use_statements][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const UseStatements) []const []const u8 {
        return self.items[0..self.len];
    }

    pub fn deinit(self: *UseStatements) void {
        for (self.items[0..self.len]) |statement| self.allocator.free(statement);
        self.len = 0;
    }

    fn push(self: *UseStatements, comptime keyword: []const u8, name: []const u8) Allocator.Error!void {
        if (name.len == 0) return;
        var buffer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer buffer.deinit();
        buffer.writer.writeAll("USE " ++ keyword ++ " ") catch return error.OutOfMemory;
        sql.writeQuotedIdent(&buffer.writer, name) catch return error.OutOfMemory;
        self.items[self.len] = try buffer.toOwnedSlice();
        self.len += 1;
    }
};

pub const Scheme = enum {
    http,
    https,

    pub fn text(self: Scheme) []const u8 {
        return switch (self) {
            .http => "http",
            .https => "https",
        };
    }
};

/// A parsed DSN. Owns every string it holds; `deinit` releases them.
pub const Config = struct {
    allocator: Allocator,

    /// `http://host:port` or `https://host:port` — the prefix every endpoint hangs off.
    base_url: []const u8,
    scheme: Scheme,

    database: []const u8 = "",
    schema: []const u8 = "",
    role: []const u8 = "",
    warehouse: []const u8 = "",

    /// Per-request budget in milliseconds; 0 disables it.
    timeout_ms: u64 = default_timeout_ms,

    /// Minutes east of UTC that the engine's zoneless values belong to.
    ///
    /// `DATE`, `TIME` and `TIMESTAMP_NTZ` are wall clocks with no zone of their own, so
    /// something has to say which zone that clock names. This is a FIXED offset rather than an
    /// IANA zone: Zig's standard library ships no zone database, and a made-up mapping from
    /// `Europe/Warsaw` to one offset would be wrong for half the year without saying so.
    tz_offset_minutes: i16 = 0,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.base_url);
        if (self.database.len > 0) self.allocator.free(self.database);
        if (self.schema.len > 0) self.allocator.free(self.schema);
        if (self.role.len > 0) self.allocator.free(self.role);
        if (self.warehouse.len > 0) self.allocator.free(self.warehouse);
        self.* = undefined;
    }

    /// Render the DSN's scope as the `USE` statements a fresh session needs.
    pub fn useStatements(self: *const Config) !UseStatements {
        var out = UseStatements{ .allocator = self.allocator };
        errdefer out.deinit();
        try out.push("ROLE", self.role);
        try out.push("WAREHOUSE", self.warehouse);
        try out.push("DATABASE", self.database);
        try out.push("SCHEMA", self.schema);
        return out;
    }

    /// Whether the DSN named any scope at all.
    pub fn hasScope(self: *const Config) bool {
        return self.database.len > 0 or self.schema.len > 0 or
            self.role.len > 0 or self.warehouse.len > 0;
    }
};

/// Parse a DSN.
pub fn parse(allocator: Allocator, dsn: []const u8, diag: ?*Diagnostics) Error!Config {
    var rest = dsn;

    const separator = std.mem.indexOf(u8, rest, "://") orelse
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: DSN \"{s}\" must start with frostlake://, http:// or https://", .{dsn});

    const scheme_text = rest[0..separator];
    rest = rest[separator + 3 ..];

    var scheme: Scheme = .http;
    if (std.ascii.eqlIgnoreCase(scheme_text, "frostlake") or std.ascii.eqlIgnoreCase(scheme_text, "http")) {
        scheme = .http;
    } else if (std.ascii.eqlIgnoreCase(scheme_text, "https")) {
        scheme = .https;
    } else {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: DSN scheme \"{s}\" is not one of frostlake, http or https", .{scheme_text});
    }

    // Split off the query, then the path, leaving the authority.
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    // A fragment is not part of a DSN, but trimming one beats reading it as a database name.
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| rest = rest[0..i];

    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
        path = rest[i + 1 ..];
        rest = rest[0..i];
    }

    const authority = rest;
    // The engine's HTTP API has no authentication, so credentials would be silently
    // discarded. Saying so beats pretending they were used.
    if (std.mem.indexOfScalar(u8, authority, '@') != null) {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: the DSN carries a username or password, which the engine's HTTP API does not accept", .{});
    }
    if (authority.len == 0) {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: DSN \"{s}\" is missing host[:port]", .{dsn});
    }

    var config = Config{
        .allocator = allocator,
        .base_url = "",
        .scheme = scheme,
    };
    // Every owned field is released together if any later step fails.
    errdefer {
        if (config.base_url.len > 0) allocator.free(config.base_url);
        if (config.database.len > 0) allocator.free(config.database);
        if (config.schema.len > 0) allocator.free(config.schema);
        if (config.role.len > 0) allocator.free(config.role);
        if (config.warehouse.len > 0) allocator.free(config.warehouse);
    }

    if (path.len > 0) {
        // Only the first path segment is a database name; a trailing slash is not part of it.
        var database = path;
        if (std.mem.indexOfScalar(u8, database, '/')) |i| database = database[0..i];
        if (database.len > 0) config.database = try decodeComponent(allocator, database);
    }

    var scheme_from_query: ?Scheme = null;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const raw_key = pair[0..equals];
        const raw_value = if (equals < pair.len) pair[equals + 1 ..] else "";

        const key = try decodeComponent(allocator, raw_key);
        defer allocator.free(key);
        const value = try decodeComponent(allocator, raw_value);
        // Ownership of `value` moves into config for the string parameters; the ones that
        // parse it into a number free it themselves.
        var value_kept = false;
        defer if (!value_kept) allocator.free(value);

        if (std.ascii.eqlIgnoreCase(key, "schema")) {
            if (config.schema.len > 0) allocator.free(config.schema);
            config.schema = value;
            value_kept = true;
        } else if (std.ascii.eqlIgnoreCase(key, "role")) {
            if (config.role.len > 0) allocator.free(config.role);
            config.role = value;
            value_kept = true;
        } else if (std.ascii.eqlIgnoreCase(key, "warehouse")) {
            if (config.warehouse.len > 0) allocator.free(config.warehouse);
            config.warehouse = value;
            value_kept = true;
        } else if (std.ascii.eqlIgnoreCase(key, "database") or std.ascii.eqlIgnoreCase(key, "db")) {
            if (config.database.len > 0) allocator.free(config.database);
            config.database = value;
            value_kept = true;
        } else if (std.ascii.eqlIgnoreCase(key, "timeout")) {
            config.timeout_ms = try parseDuration(allocator, value, diag);
        } else if (std.ascii.eqlIgnoreCase(key, "tz")) {
            config.tz_offset_minutes = try parseOffset(allocator, value, diag);
        } else if (std.ascii.eqlIgnoreCase(key, "tls")) {
            scheme_from_query = if (try parseBool(allocator, value, diag)) .https else .http;
        } else {
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: unknown DSN parameter \"{s}\"", .{key});
        }
    }

    // An explicit tls= wins over the scheme, so `http://…?tls=true` is HTTPS rather than a
    // contradiction resolved silently in the other direction.
    if (scheme_from_query) |s| config.scheme = s;
    config.base_url = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ config.scheme.text(), authority });
    return config;
}

/// Percent-decode one query or path component, treating `+` as a space the way form encoding
/// does. An invalid escape is left as written rather than rejected: a `%` is legal in an
/// identifier, and refusing the DSN over one would be worse than passing it through.
fn decodeComponent(allocator: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);

    var i: usize = 0;
    while (i < text.len) {
        switch (text[i]) {
            '+' => {
                try out.append(allocator, ' ');
                i += 1;
            },
            '%' => {
                if (i + 2 < text.len) {
                    const hi = std.fmt.charToDigit(text[i + 1], 16) catch {
                        try out.append(allocator, text[i]);
                        i += 1;
                        continue;
                    };
                    const lo = std.fmt.charToDigit(text[i + 2], 16) catch {
                        try out.append(allocator, text[i]);
                        i += 1;
                        continue;
                    };
                    try out.append(allocator, hi * 16 + lo);
                    i += 3;
                } else {
                    try out.append(allocator, text[i]);
                    i += 1;
                }
            },
            else => {
                try out.append(allocator, text[i]);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Read a duration written the way Go writes one — `5m`, `1500ms`, `2m30s`, `0` — into
/// milliseconds. Bare digits are seconds, matching what a reader expects from `timeout=30`.
fn parseDuration(allocator: Allocator, text: []const u8, diag: ?*Diagnostics) Error!u64 {
    if (text.len == 0) {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: timeout is empty; write it as a duration such as 5m, 30s or 1500ms", .{});
    }
    var total: u64 = 0;
    var i: usize = 0;
    var saw_component = false;
    while (i < text.len) {
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) {
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: timeout \"{s}\" is not a duration; write it as 5m, 30s or 1500ms", .{text});
        }
        const magnitude = std.fmt.parseInt(u64, text[start..i], 10) catch {
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: timeout \"{s}\" is too large", .{text});
        };
        const unit_start = i;
        while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
        const unit = text[unit_start..i];

        const factor: u64 = if (unit.len == 0)
            std.time.ms_per_s
        else if (std.mem.eql(u8, unit, "ms"))
            1
        else if (std.mem.eql(u8, unit, "s"))
            std.time.ms_per_s
        else if (std.mem.eql(u8, unit, "m"))
            std.time.ms_per_min
        else if (std.mem.eql(u8, unit, "h"))
            std.time.ms_per_hour
        else
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: timeout unit \"{s}\" is not one of ms, s, m or h", .{unit});

        total += magnitude * factor;
        saw_component = true;
    }
    if (!saw_component) {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: timeout \"{s}\" is not a duration", .{text});
    }
    return total;
}

/// Read a fixed UTC offset — `UTC`, `Z`, `+02:00`, `-0500`, `+05:30`, `-08` — into minutes
/// east of UTC.
///
/// An IANA zone name is refused rather than approximated. Zig ships no zone database, so
/// `Europe/Warsaw` could only be mapped by guessing one of its two offsets, and a driver that
/// guesses is worse than one that says it cannot.
fn parseOffset(allocator: Allocator, text: []const u8, diag: ?*Diagnostics) Error!i16 {
    if (std.ascii.eqlIgnoreCase(text, "utc") or
        std.ascii.eqlIgnoreCase(text, "z") or
        std.mem.eql(u8, text, "+00:00") or
        std.mem.eql(u8, text, "-00:00")) return 0;

    // A '+' in a query value was decoded as a space, so the README's own spelling
    // (?tz=+02:00) arrived here as " 02:00"; a leading space means plus.
    const offset_text = if (text.len > 0 and text[0] == ' ') text[1..] else text;
    const leading_space = text.len > 0 and text[0] == ' ';
    if (offset_text.len == 0 or (!leading_space and offset_text[0] != '+' and offset_text[0] != '-')) {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: tz \"{s}\" is not a fixed UTC offset; write it as UTC, +02:00 or -0500 (this driver has no IANA zone database, so a zone name cannot be resolved)", .{text});
    }
    const sign: i16 = if (!leading_space and offset_text[0] == '-') -1 else 1;
    var digits = if (leading_space) offset_text else offset_text[1..];

    var hours: i16 = 0;
    var minutes: i16 = 0;
    if (std.mem.indexOfScalar(u8, digits, ':')) |i| {
        hours = parseOffsetField(digits[0..i]) orelse
            return failOffset(allocator, text, diag);
        minutes = parseOffsetField(digits[i + 1 ..]) orelse
            return failOffset(allocator, text, diag);
    } else if (digits.len == 4) {
        hours = parseOffsetField(digits[0..2]) orelse return failOffset(allocator, text, diag);
        minutes = parseOffsetField(digits[2..4]) orelse return failOffset(allocator, text, diag);
    } else if (digits.len == 1 or digits.len == 2) {
        hours = parseOffsetField(digits) orelse return failOffset(allocator, text, diag);
    } else {
        return failOffset(allocator, text, diag);
    }

    if (hours > 18 or minutes > 59) return failOffset(allocator, text, diag);
    return sign * (hours * 60 + minutes);
}

fn parseOffsetField(text: []const u8) ?i16 {
    if (text.len == 0 or text.len > 2) return null;
    return std.fmt.parseInt(i16, text, 10) catch null;
}

fn failOffset(allocator: Allocator, text: []const u8, diag: ?*Diagnostics) Error {
    return fail(diag, allocator, Error.InvalidDsn, "frostlake: tz \"{s}\" is not a fixed UTC offset; write it as UTC, +02:00 or -0500", .{text});
}

fn parseBool(allocator: Allocator, text: []const u8, diag: ?*Diagnostics) Error!bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1") or
        std.ascii.eqlIgnoreCase(text, "yes") or std.ascii.eqlIgnoreCase(text, "on")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0") or
        std.ascii.eqlIgnoreCase(text, "no") or std.ascii.eqlIgnoreCase(text, "off")) return false;
    return fail(diag, allocator, Error.InvalidDsn, "frostlake: tls \"{s}\" is not a boolean", .{text});
}
