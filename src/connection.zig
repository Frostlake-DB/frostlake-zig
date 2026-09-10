//! A connection, and the session behind it.
//!
//! One `Connection` is one engine session. The session is what holds the current database and
//! schema, session variables, and an open transaction, so nearly everything subtle in this
//! file is about keeping the driver's idea of that session and the engine's in agreement.

const std = @import("std");
const Allocator = std.mem.Allocator;

const dsn_mod = @import("dsn.zig");
const Config = dsn_mod.Config;
const UseStatements = dsn_mod.UseStatements;
const sql_mod = @import("sql.zig");
const bind = @import("bind.zig");
const NamedValue = bind.NamedValue;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const result_mod = @import("result.zig");
const Response = result_mod.Response;
const wire = @import("wire.zig");
const transport_mod = @import("transport.zig");
const Transport = transport_mod.Transport;
const http = @import("http.zig");
const diag_mod = @import("diag.zig");
const Diagnostics = diag_mod.Diagnostics;
const Error = diag_mod.Error;
const fail = diag_mod.fail;

/// How long a connection may sit idle before the driver stops trusting that its engine session
/// still exists.
///
/// The engine reclaims idle sessions and then re-creates one under the very same id at the
/// server's default scope — which a client cannot tell apart from its own session surviving.
/// An idle connection therefore has its scope re-established rather than assumed. Comfortably
/// under the engine's 30-minute default.
pub const scope_refresh_after_ms: i64 = 5 * std.time.ms_per_min;

const scope_refresh_after_ns: i96 = @as(i96, scope_refresh_after_ms) * std.time.ns_per_ms;

pub const Connection = struct {
    allocator: Allocator,
    /// The I/O implementation everything below this connection runs on. Zig 0.16 passes one
    /// explicitly rather than reaching for a global, so the caller decides what "blocking"
    /// means here.
    io: std.Io,
    config: Config,
    transport: Transport,

    /// The engine's id for this session. Empty until the first answer names one.
    session_id: []const u8 = "",
    auto_commit: bool = true,
    in_transaction: bool = false,

    /// `USE` statements that must run before the next user statement.
    pending_use: UseStatements,
    /// Set once a statement has moved the session off the DSN's scope.
    session_dirty: bool = false,
    /// When the connection last spoke to the engine, on the monotonic clock. Null until its
    /// first statement. Monotonic rather than wall-clock: this measures how long a connection
    /// has been idle, which an NTP correction should not be able to change.
    last_activity: ?std.Io.Timestamp = null,

    /// Set when the connection is in a state the driver cannot vouch for. It is never used
    /// again — a session whose transaction ended in a way the driver had to guess at is worse
    /// than no session.
    bad: bool = false,
    closed: bool = false,

    /// Detail behind the last failure. Owned by the connection.
    diagnostics: Diagnostics = .{},

    /// Open a connection from a DSN.
    ///
    /// Nothing is sent — the engine creates a session on the first statement, and there is no
    /// handshake to perform. Call `ping` to prove something is actually listening.
    pub fn open(allocator: Allocator, io: std.Io, dsn: []const u8) Error!Connection {
        var diag = Diagnostics{};
        errdefer diag.deinit();
        var config = dsn_mod.parse(allocator, dsn, &diag) catch |err| {
            // The DSN failed to parse, so there is no connection to hang the detail on. Log it
            // where it will not be lost, then hand back the bare error.
            std.log.scoped(.frostlake).err("{s}", .{diag.message});
            diag.deinit();
            return err;
        };
        errdefer config.deinit();

        const client = http.Client.create(allocator, io, config.base_url, config.timeout_ms, &diag) catch |err| {
            std.log.scoped(.frostlake).err("{s}", .{diag.message});
            diag.deinit();
            return err;
        };
        errdefer client.transport().deinit();
        diag.deinit();

        return openWithTransport(allocator, io, config, client.transport());
    }

    /// Open a connection over a transport that has already been built.
    ///
    /// Takes ownership of both `config` and `transport`; `close` releases them.
    pub fn openWithTransport(
        allocator: Allocator,
        io: std.Io,
        config: Config,
        transport: Transport,
    ) Error!Connection {
        var pending = try config.useStatements();
        errdefer pending.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .transport = transport,
            .pending_use = pending,
        };
    }

    pub fn close(self: *Connection) void {
        // Idempotent: a second close must not free the transport and config again.
        if (self.closed) return;
        // The HTTP API has no endpoint for ending a session, so there is nothing to send: the
        // server-side session lingers until the engine's own idle sweep reclaims it.
        self.closed = true;
        self.pending_use.deinit();
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = "";
        self.diagnostics.deinit();
        self.transport.deinit();
        self.config.deinit();
    }

    /// The message behind the last failure, or an empty string if nothing has failed.
    pub fn lastError(self: *const Connection) []const u8 {
        return self.diagnostics.message;
    }

    /// The SQL behind the last statement failure, exactly as it was sent.
    ///
    /// Because binding is client-side that means every parameter inlined, so treat this as
    /// sensitive: a bound password appears in it verbatim. `lastError` carries none of it.
    pub fn lastStatement(self: *const Connection) []const u8 {
        return self.diagnostics.statement;
    }

    /// Whether the connection can still be used.
    pub fn isValid(self: *const Connection) bool {
        return !self.closed and !self.bad;
    }

    /// Ask the server's health endpoint whether it is there.
    ///
    /// A 200 on its own only says something is listening — anything can serve that. The health
    /// payload is what says it is a Frostlake engine, so a wrong address is reported as such
    /// rather than passing for a healthy server.
    pub fn ping(self: *Connection) Error!void {
        try self.ensureUsable();
        var reply = try self.transport.get(self.allocator, "/api/health", &self.diagnostics);
        defer reply.deinit(self.allocator);

        if (reply.status != 200) {
            self.bad = true;
            return fail(&self.diagnostics, self.allocator, Error.NotFrostlake, "frostlake: {s}/api/health answered HTTP {d}", .{ self.transport.baseUrl(), reply.status });
        }
        if (!wire.looksLikeHealth(reply.body)) {
            self.bad = true;
            self.diagnostics.setBody(self.allocator, reply.body);
            return fail(&self.diagnostics, self.allocator, Error.NotFrostlake, "frostlake: {s}/api/health answered HTTP {d} with a body that is not a Frostlake health response", .{ self.transport.baseUrl(), reply.status });
        }
    }

    /// Run a statement with positional `?` arguments.
    ///
    /// The caller owns the returned response and must `deinit` it.
    pub fn query(self: *Connection, statement: []const u8, args: []const Value) Error!Response {
        const rendered = try bind.substitute(self.allocator, statement, args, &self.diagnostics);
        defer self.allocator.free(rendered);
        return self.execute(rendered);
    }

    /// Run a statement with named `:name` arguments.
    pub fn queryNamed(self: *Connection, statement: []const u8, args: []const NamedValue) Error!Response {
        const rendered = try bind.substituteNamed(self.allocator, statement, args, &self.diagnostics);
        defer self.allocator.free(rendered);
        return self.execute(rendered);
    }

    /// Run a statement and answer with how many rows it touched, discarding any grid.
    pub fn exec(self: *Connection, statement: []const u8, args: []const Value) Error!i64 {
        var response = try self.query(statement, args);
        defer response.deinit();
        return response.rowsAffected();
    }

    /// Run already-rendered SQL. Nothing is bound — whatever is here is what the engine sees.
    pub fn execute(self: *Connection, statement: []const u8) Error!Response {
        try self.ensureUsable();

        // An idle connection may be holding a session the engine has already reclaimed and
        // re-created at the default scope. Put the DSN's scope back rather than assume it.
        if (self.sessionMayHaveLapsed()) self.restoreScope() catch {};

        // Each USE leaves the queue only once it has succeeded. A DSN naming a database that
        // does not exist has to keep failing; the alternative is later statements quietly
        // running in the default scope.
        while (self.pending_use.len > 0) {
            const use = self.pending_use.items[0];
            var reply = try self.roundTrip(use);
            reply.deinit();
            // Shift the queue down. At most four entries, so the copy costs nothing.
            self.allocator.free(use);
            var i: usize = 1;
            while (i < self.pending_use.len) : (i += 1) {
                self.pending_use.items[i - 1] = self.pending_use.items[i];
            }
            self.pending_use.len -= 1;
        }

        var response = try self.roundTrip(statement);
        errdefer response.deinit();

        self.last_activity = std.Io.Timestamp.now(self.io, .awake);
        if (sql_mod.changesSessionScope(statement)) self.session_dirty = true;
        return response;
    }

    /// Send one statement and read the answer.
    fn roundTrip(self: *Connection, statement: []const u8) Error!Response {
        const body = try wire.encodeRequest(self.allocator, .{
            .sql = statement,
            .session_id = self.session_id,
            .auto_commit = self.auto_commit,
        });
        defer self.allocator.free(body);

        var reply = self.transport.post(self.allocator, "/api/execute", body, &self.diagnostics) catch |err| {
            // The request never became an answer. The socket may have broken after the request
            // was written, so the statement's fate is unknown — the connection is retired
            // rather than reused, and deliberately NOT retried: re-running it would duplicate
            // an INSERT.
            self.bad = true;
            return err;
        };
        defer reply.deinit(self.allocator);

        var parsed = wire.decodeResponse(self.allocator, reply.body, &self.diagnostics) catch |err| {
            // A proxy error page, the wrong port, a crashed server. The far side cannot be
            // identified, so the connection is not kept.
            self.bad = true;
            if (err == Error.NotFrostlake) {
                self.diagnostics.setBody(self.allocator, reply.body);
                self.diagnostics.status = reply.status;
                self.diagnostics.setStatement(self.allocator, statement);
                if (wire.carriesBareUndefined(reply.body)) {
                    return fail(&self.diagnostics, self.allocator, Error.NotFrostlake, "frostlake: the engine's answer is not valid JSON — it renders a VARIANT `undefined` as a bare token, which no JSON parser accepts. This is a server-side defect on this statement, not a bad address", .{});
                }
                return fail(&self.diagnostics, self.allocator, Error.NotFrostlake, "frostlake: {s}/api/execute answered HTTP {d} with a body that is not a Frostlake response", .{ self.transport.baseUrl(), reply.status });
            }
            return err;
        };
        errdefer parsed.response.deinit();

        if (parsed.session_id.len > 0) try self.rememberSession(parsed.session_id);

        if (!parsed.success) {
            self.diagnostics.setStatement(self.allocator, statement);
            self.diagnostics.status = reply.status;
            // A response can report failure carrying no message at all — an empty statement is
            // refused with a differently shaped body — and an error that prints as nothing
            // tells a caller less than the status code would.
            // The message points into the response's arena, so it has to be copied into the
            // diagnostics before the errdefer above releases it. `report` allocates, so it
            // does copy.
            if (parsed.error_message.len > 0) {
                self.diagnostics.report(self.allocator, "{s}", .{parsed.error_message});
            } else {
                self.diagnostics.report(self.allocator, "frostlake: statement failed with HTTP {d} and no error message", .{reply.status});
            }
            return Error.EngineRefused;
        }
        return parsed.response;
    }

    /// Run a statement for its effect only, ignoring both its answer and its failure.
    ///
    /// Used where the driver is already handling one failure and is trying to leave the server
    /// tidy — there is nothing useful to do if the tidying itself fails.
    fn discard(self: *Connection, statement: []const u8) void {
        var response = self.execute(statement) catch return;
        response.deinit();
    }

    fn rememberSession(self: *Connection, session_id: []const u8) Allocator.Error!void {
        if (std.mem.eql(u8, self.session_id, session_id)) return;
        const copy = try self.allocator.dupe(u8, session_id);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = copy;
    }

    fn ensureUsable(self: *Connection) Error!void {
        if (self.closed) {
            return fail(&self.diagnostics, self.allocator, Error.ConnectionClosed, "frostlake: the connection is closed", .{});
        }
        if (self.bad) {
            return fail(&self.diagnostics, self.allocator, Error.ConnectionUnusable, "frostlake: the connection is in a state the driver cannot vouch for and will not be used again", .{});
        }
    }

    fn sessionMayHaveLapsed(self: *const Connection) bool {
        const last = self.last_activity orelse return false;
        // An open transaction is proof the session is alive; re-establishing scope under one
        // would also be the wrong thing to do mid-transaction.
        if (self.in_transaction) return false;
        const now = std.Io.Timestamp.now(self.io, .awake);
        return last.durationTo(now).nanoseconds > scope_refresh_after_ns;
    }

    /// Queue the DSN's scope to be re-applied before the next statement.
    fn restoreScope(self: *Connection) Error!void {
        if (self.pending_use.len > 0) return;
        var refreshed = try self.config.useStatements();
        if (refreshed.len == 0) {
            refreshed.deinit();
            return;
        }
        self.pending_use.deinit();
        self.pending_use = refreshed;
        self.session_dirty = false;
    }

    /// Put the session back on the DSN's scope, for a caller reusing one connection across
    /// unrelated pieces of work.
    ///
    /// A statement that moved the session — `USE`, the `SET` family, `ALTER SESSION`, and
    /// `CREATE`/`DROP` of a `DATABASE` or `SCHEMA` — would otherwise leak into whatever runs
    /// next. With no scope in the DSN there is nothing to restore, and the connection is
    /// retired instead so the next one starts from the server's default.
    pub fn reset(self: *Connection) Error!void {
        try self.ensureUsable();
        if (self.in_transaction) {
            self.rollback() catch {};
        }
        self.auto_commit = true;
        if (!self.session_dirty) return;
        if (!self.config.hasScope()) {
            self.bad = true;
            return fail(&self.diagnostics, self.allocator, Error.ConnectionUnusable, "frostlake: the session's scope moved and the DSN names none to restore, so the connection is retired", .{});
        }
        const refreshed = try self.config.useStatements();
        self.pending_use.deinit();
        self.pending_use = refreshed;
        self.session_dirty = false;
    }

    // -----------------------------------------------------------------------
    // Transactions
    //
    // These ride the session's autoCommit flag plus BEGIN/COMMIT/ROLLBACK statements, matching
    // the JDBC transport. The engine offers read committed and nothing else, so there is no
    // isolation level to choose.
    // -----------------------------------------------------------------------

    pub fn begin(self: *Connection) Error!void {
        try self.ensureUsable();
        if (self.in_transaction) {
            return fail(&self.diagnostics, self.allocator, Error.InvalidTransactionState, "frostlake: a transaction is already open on this connection", .{});
        }
        self.auto_commit = false;
        var response = self.execute("BEGIN") catch |err| {
            self.auto_commit = true;
            return err;
        };
        response.deinit();
        self.in_transaction = true;
    }

    pub fn commit(self: *Connection) Error!void {
        if (!self.in_transaction) {
            return fail(&self.diagnostics, self.allocator, Error.InvalidTransactionState, "frostlake: commit was called with no transaction open", .{});
        }
        self.in_transaction = false;
        var response = self.execute("COMMIT") catch |err| {
            // The COMMIT may never have reached the engine, which would then still be holding
            // the transaction open with no one left to end it. Try to end it, and retire the
            // connection either way rather than keeping one whose state was guessed at. The
            // rollback's own failure must not replace the diagnosis of the commit's.
            self.auto_commit = true;
            const saved = self.allocator.dupe(u8, self.lastError()) catch null;
            defer if (saved) |text| self.allocator.free(text);
            if (!self.bad) self.discard("ROLLBACK");
            if (saved) |text| self.diagnostics.report(self.allocator, "{s}", .{text});
            self.bad = true;
            return err;
        };
        response.deinit();
        self.auto_commit = true;
    }

    pub fn rollback(self: *Connection) Error!void {
        if (!self.in_transaction) {
            return fail(&self.diagnostics, self.allocator, Error.InvalidTransactionState, "frostlake: rollback was called with no transaction open", .{});
        }
        self.in_transaction = false;
        var response = self.execute("ROLLBACK") catch |err| {
            self.auto_commit = true;
            self.bad = true;
            return err;
        };
        response.deinit();
        self.auto_commit = true;
    }
};
