//! Error sets and the diagnostic record that carries their detail.
//!
//! A Zig error is a bare tag: `error.EngineRefused` says what went wrong but not which
//! statement, which message the engine used, or what came back instead of an answer. The
//! family's other drivers put that detail in a typed exception; here it lands in a
//! `Diagnostics` the caller lends to the call, which is the same trade `std.json` makes.
//!
//! Every entry point that can fail in an interesting way takes a `?*Diagnostics`. Passing
//! null is supported and costs nothing — the detail is simply not recorded.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Everything the driver can fail with.
pub const Error = error{
    /// The DSN could not be read: bad scheme, missing host, unparsable or unknown parameter,
    /// or credentials the engine's HTTP API has no way to accept.
    InvalidDsn,
    /// The statement and its arguments disagree: a count mismatch, both placeholder styles in
    /// one statement, a named argument against positional markers, or an argument that names
    /// no marker.
    BindMismatch,
    /// A bound value has no SQL literal form.
    UnsupportedParameter,
    /// The engine reported the statement as failed. `Diagnostics.message` holds its wording
    /// and `Diagnostics.statement` the SQL as sent.
    EngineRefused,
    /// The request never became an answer: the host refused it, the socket died, the request
    /// timed out.
    TransportFailed,
    /// Something answered, but not a Frostlake engine — a proxy error page, the wrong port, a
    /// truncated body. `Diagnostics.body` holds a bounded excerpt of what came back.
    NotFrostlake,
    /// The operation needs a connection that is still open.
    ConnectionClosed,
    /// The connection is in a state the driver cannot vouch for and will not use again.
    ConnectionUnusable,
    /// A cell was read as a type it does not hold.
    TypeMismatch,
    /// No such column, row, or result set.
    NotFound,
    /// The engine offers read committed only, and an option was asked for that it cannot honour.
    UnsupportedIsolation,
    /// A transaction call arrived in the wrong order — committing without beginning, or
    /// beginning inside a transaction that is already open.
    InvalidTransactionState,
    /// The engine no longer holds the connection's session — it expired, was released, or the
    /// server restarted — and the statement was NOT run, because it depended on something that
    /// went with the session: an open transaction, or context set up on it (`USE`, `SET`,
    /// `ALTER SESSION` or a temporary object). The connection stays usable: its next statement
    /// starts a fresh session on the DSN's scope, once `commit` or `rollback` has ended a
    /// transaction `begin` opened.
    SessionLost,
} || Allocator.Error;

/// How much of an unrecognised response body is kept for reporting. The body is not buffered
/// beyond this.
pub const max_body_excerpt = 512;

/// The detail behind a failure.
///
/// A `Diagnostics` starts empty, is filled by whichever call fails, and owns whatever it
/// holds. Reuse across calls is fine — each failure releases what the last one left.
pub const Diagnostics = struct {
    allocator: ?Allocator = null,

    /// The engine's own wording where there is one, otherwise the driver's explanation of
    /// what happened. Never empty after a failure.
    message: []const u8 = "",

    /// For a statement failure, the SQL exactly as it was sent.
    ///
    /// Because binding is client-side, that means every parameter inlined — a bound password
    /// or card number appears here verbatim. `message` carries none of it, so log that freely
    /// and treat this as sensitive.
    statement: []const u8 = "",

    /// A bounded excerpt of a response body that was not a Frostlake response.
    body: []const u8 = "",

    /// The HTTP status the answer arrived with, or 0 when the request never completed.
    /// Statement failures are reported with 200; 500 means the engine threw while handling
    /// the request.
    status: u16 = 0,

    /// Release anything the record owns and return it to its empty state.
    pub fn deinit(self: *Diagnostics) void {
        const allocator = self.allocator orelse {
            self.* = .{};
            return;
        };
        // The out-of-memory fallback is a string literal, not an allocation.
        if (self.message.len > 0 and !isStaticFallback(self.message)) allocator.free(self.message);
        if (self.statement.len > 0) allocator.free(self.statement);
        if (self.body.len > 0) allocator.free(self.body);
        self.* = .{ .allocator = allocator };
    }

    /// Record a formatted message, replacing any previous one.
    ///
    /// Reporting a failure must not itself fail, so an allocator that cannot serve the
    /// formatted text falls back to a fixed message rather than propagating: losing the
    /// wording of an error is better than losing the error.
    pub fn report(self: *Diagnostics, allocator: Allocator, comptime fmt: []const u8, args: anytype) void {
        self.clearMessage(allocator);
        self.allocator = allocator;
        self.message = std.fmt.allocPrint(allocator, fmt, args) catch
            "frostlake: out of memory while formatting the error message";
    }

    /// Record the statement a failure belongs to. Silently left unset if it cannot be copied —
    /// the message is the part a caller cannot do without.
    pub fn setStatement(self: *Diagnostics, allocator: Allocator, statement: []const u8) void {
        if (self.allocator) |a| {
            if (self.statement.len > 0) a.free(self.statement);
        }
        self.allocator = allocator;
        self.statement = allocator.dupe(u8, statement) catch "";
    }

    /// Record a bounded excerpt of an unrecognised response body.
    pub fn setBody(self: *Diagnostics, allocator: Allocator, body: []const u8) void {
        if (self.allocator) |a| {
            if (self.body.len > 0) a.free(self.body);
        }
        self.allocator = allocator;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        const excerpt = trimmed[0..@min(trimmed.len, max_body_excerpt)];
        self.body = allocator.dupe(u8, excerpt) catch "";
    }

    fn clearMessage(self: *Diagnostics, allocator: Allocator) void {
        _ = allocator;
        if (self.allocator) |a| {
            // A fallback message from a failed allocPrint is static, so only free what was
            // actually allocated. Comparing the pointer is what tells them apart.
            if (self.message.len > 0 and !isStaticFallback(self.message)) a.free(self.message);
        }
        self.message = "";
    }

    fn isStaticFallback(message: []const u8) bool {
        return message.ptr == oom_message.ptr;
    }

    const oom_message: []const u8 = "frostlake: out of memory while formatting the error message";
};

/// Record `message` on `diag` when the caller lent one, then return `err`.
///
/// The shorthand exists because nearly every failure in the driver wants to do exactly this,
/// and spelling it out at each site buried the control flow in null checks.
pub fn fail(
    diag: ?*Diagnostics,
    allocator: Allocator,
    err: Error,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    if (diag) |d| d.report(allocator, fmt, args);
    return err;
}

test "diagnostics report and release" {
    const testing = std.testing;
    var diag = Diagnostics{};
    defer diag.deinit();

    diag.report(testing.allocator, "frostlake: unknown DSN parameter \"{s}\"", .{"nope"});
    try testing.expectEqualStrings("frostlake: unknown DSN parameter \"nope\"", diag.message);

    // Reporting again releases the first message rather than leaking it.
    diag.report(testing.allocator, "second", .{});
    try testing.expectEqualStrings("second", diag.message);

    diag.setStatement(testing.allocator, "SELECT 1");
    try testing.expectEqualStrings("SELECT 1", diag.statement);

    diag.deinit();
    try testing.expectEqualStrings("", diag.message);
    try testing.expectEqualStrings("", diag.statement);
}

test "diagnostics trims and bounds a body excerpt" {
    const testing = std.testing;
    var diag = Diagnostics{};
    defer diag.deinit();

    diag.setBody(testing.allocator, "  \n<html>bad gateway</html>\n ");
    try testing.expectEqualStrings("<html>bad gateway</html>", diag.body);

    const long = "x" ** (max_body_excerpt + 64);
    diag.setBody(testing.allocator, long);
    try testing.expectEqual(max_body_excerpt, diag.body.len);
}

test "fail records the message and returns the error" {
    const testing = std.testing;
    var diag = Diagnostics{};
    defer diag.deinit();

    const err = fail(&diag, testing.allocator, Error.InvalidDsn, "bad {s}", .{"dsn"});
    try testing.expectError(Error.InvalidDsn, @as(Error!void, err));
    try testing.expectEqualStrings("bad dsn", diag.message);

    // A null diagnostics is supported and costs nothing.
    _ = fail(null, testing.allocator, Error.InvalidDsn, "ignored", .{}) catch {};
}
