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
/// An engine that predates `newSession` reclaims idle sessions and then re-creates one under the
/// very same id at the server's default scope — which a client cannot tell apart from its own
/// session surviving. An idle connection to one therefore has its scope re-established rather
/// than assumed. Comfortably under the engine's 30-minute default.
pub const scope_refresh_after_ms: i64 = 5 * std.time.ms_per_min;

const scope_refresh_after_ns: i96 = @as(i96, scope_refresh_after_ms) * std.time.ns_per_ms;

/// How long closing may spend releasing the engine session; a shorter DSN timeout bounds it
/// further.
pub const close_budget_ms: u64 = 5 * std.time.ms_per_s;

// What the `SessionLost` failures say went with the session.
const lost_transaction = "frostlake: the engine no longer holds this connection's session (it expired, was released, or the server restarted), so its open transaction is gone; the statement did not run";
const lost_context = "frostlake: the engine no longer holds this connection's session (it expired, was released, or the server restarted), and the context set up on it (USE, SET, ALTER SESSION or a temporary object) went with it, so the statement was not re-run; the next statement starts a fresh session on the connection's scope";
const lost_fresh = "frostlake: the engine refused a session it had just started; the statement did not run";
const lost_tx_statement = "frostlake: the transaction went with the connection's session, which the engine no longer holds; the statement did not run, and the transaction can only be rolled back";
const lost_commit = "frostlake: the transaction went with the connection's session, which the engine no longer holds, so nothing was committed";

/// What one request to `/api/execute` came to.
const Outcome = union(enum) {
    /// The engine answered. The caller owns the response.
    answered: Response,
    /// The engine refused the session it was required to resume, as one it no longer holds:
    /// nothing ran.
    session_gone,
};

/// What a caller may say about one request, over and above its SQL.
///
/// Every field has a default, so `.{}` is the request the driver has always sent.
pub const ExecuteOptions = struct {
    /// How many statements this request carries.
    ///
    /// A session runs one statement per request until its `MULTI_STATEMENT_COUNT` says otherwise,
    /// and refuses a request carrying more. This says it for one request instead: it outranks the
    /// session's setting for that request and leaves the session itself untouched, so there is
    /// nothing to put back afterwards and two connections cannot disturb each other's packing.
    /// `0` accepts any number; null leaves the session's value in charge, as before.
    multi_statement_count: ?u32 = null,
};

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

    /// Whether the engine reports `newSession`, which arrived together with `requireSession`
    /// and `DELETE /api/sessions/{id}`. Null until the first answer that names a session.
    tracks_sessions: ?bool = null,
    /// Set once a statement left context on the session that a fresh one on the DSN's scope
    /// would not have — `USE`, `SET`/`UNSET`, `ALTER SESSION`, a temporary object, `CREATE`/`DROP`
    /// of a `DATABASE` or `SCHEMA` — so a lost session is reported rather than replaced. Putting
    /// the DSN's scope back clears it.
    holds_context: bool = false,
    /// Set when the session was lost under a transaction `begin` opened: statements are refused
    /// until `commit` or `rollback` ends it.
    transaction_lost: bool = false,
    /// Set when the engine ran a request in a fresh session in place of this one, so the DSN's
    /// scope goes back on before the next statement.
    rescope: bool = false,
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

    /// Close the connection, releasing the engine session with `DELETE /api/sessions/{id}`,
    /// which also rolls back a transaction it left open.
    ///
    /// Releasing is a courtesy: it is bounded by the shorter of the DSN's timeout and
    /// `close_budget_ms`, and whatever it meets, closing still succeeds — the engine reclaims an
    /// idle session by itself. An engine that predates `newSession` has no such endpoint and is
    /// sent nothing; its session lingers until the engine's own idle sweep.
    pub fn close(self: *Connection) void {
        // Idempotent: a second close must not free the transport and config again, nor send
        // anything.
        if (self.closed) return;
        self.closed = true;
        self.release();
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
        return self.queryWith(statement, args, .{});
    }

    /// `query`, with the options that apply to this one request.
    pub fn queryWith(
        self: *Connection,
        statement: []const u8,
        args: []const Value,
        options: ExecuteOptions,
    ) Error!Response {
        const rendered = try bind.substitute(self.allocator, statement, args, &self.diagnostics);
        defer self.allocator.free(rendered);
        return self.executeWith(rendered, options);
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
        return self.executeWith(statement, .{});
    }

    /// `execute`, with the options that apply to this one request.
    pub fn executeWith(self: *Connection, statement: []const u8, options: ExecuteOptions) Error!Response {
        try self.ensureUsable();
        if (self.transaction_lost) return self.lost(statement, lost_tx_statement);

        // An idle connection to an engine that predates `newSession` may be holding a session
        // the engine has already reclaimed and re-created at the default scope. Put the DSN's
        // scope back rather than assume it.
        if (self.sessionMayHaveLapsed()) self.restoreScope() catch {};

        try self.applyScope(statement);

        var response = switch (try self.post(statement, options)) {
            .answered => |answered| answered,
            .session_gone => try self.recover(statement, options),
        };
        errdefer response.deinit();

        self.last_activity = std.Io.Timestamp.now(self.io, .awake);
        if (sql_mod.changesSessionScope(statement)) self.session_dirty = true;
        self.track(statement);
        return response;
    }

    /// Run the DSN's queued `USE` statements ahead of `statement`, the caller's.
    ///
    /// Each USE leaves the queue only once it has succeeded. A DSN naming a database that does
    /// not exist has to keep failing; the alternative is later statements quietly running in
    /// the default scope.
    ///
    /// A session found gone while its scope goes back on is replaced by a fresh one, which takes
    /// the whole scope from its first statement: nothing ran, and the scope is exactly what a
    /// fresh session needs. Only a transaction open on the lost session stands in the way, and
    /// is reported.
    fn applyScope(self: *Connection, statement: []const u8) Error!void {
        var restarted = false;
        while (true) {
            if (self.rescope) {
                self.rescope = false;
                try self.requeueScope();
            }
            if (self.pending_use.len == 0) return;
            const use = self.pending_use.items[0];
            // Each USE is one statement of its own, so the caller's count is none of its business.
            switch (try self.post(use, .{})) {
                .session_gone => {
                    // Putting the scope back resets the session's context anyway.
                    self.holds_context = false;
                    try self.refuseLost(statement);
                    if (restarted) return self.lost(statement, lost_fresh);
                    restarted = true;
                },
                .answered => |answered| {
                    var reply = answered;
                    reply.deinit();
                    // A fresh session took over part-way through: the whole scope goes on again.
                    if (self.rescope) continue;
                    // Shift the queue down. At most four entries, so the copy costs nothing.
                    self.allocator.free(use);
                    var i: usize = 1;
                    while (i < self.pending_use.len) : (i += 1) {
                        self.pending_use.items[i - 1] = self.pending_use.items[i];
                    }
                    self.pending_use.len -= 1;
                },
            }
        }
    }

    /// Answer the engine's refusal of a session it no longer holds — it expired, was released,
    /// or the server restarted — and nothing ran.
    ///
    /// With a transaction or context gone with the session, re-running would put the statement
    /// somewhere its author did not intend, so that is reported; otherwise a fresh session on the
    /// DSN's scope takes over and the statement is sent once more.
    fn recover(self: *Connection, statement: []const u8, options: ExecuteOptions) Error!Response {
        try self.refuseLost(statement);
        try self.applyScope(statement);
        return switch (try self.post(statement, options)) {
            .answered => |answered| answered,
            .session_gone => {
                try self.dropSession();
                return self.lost(statement, lost_fresh);
            },
        };
    }

    /// Drop a session the engine no longer holds, and report the loss when it held a transaction
    /// or context `statement` may depend on.
    fn refuseLost(self: *Connection, statement: []const u8) Error!void {
        const had_transaction = self.in_transaction;
        const had_context = self.holds_context;
        try self.dropSession();
        if (had_transaction) {
            // A transaction `begin` opened stays refused until `commit` or `rollback` ends it: a
            // statement run now would land in a fresh session, outside anything either decides.
            self.transaction_lost = !self.auto_commit;
            return self.lost(statement, lost_transaction);
        }
        if (had_context) return self.lost(statement, lost_context);
    }

    /// Record a `SessionLost` failure for `statement`, which did not run.
    fn lost(self: *Connection, statement: []const u8, comptime message: []const u8) Error {
        self.diagnostics.setStatement(self.allocator, statement);
        self.diagnostics.status = 0;
        return fail(&self.diagnostics, self.allocator, Error.SessionLost, message, .{});
    }

    /// Forget the session, with everything tracked about it, and queue the DSN's scope for the
    /// fresh session the next statement starts.
    fn dropSession(self: *Connection) Error!void {
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = "";
        self.session_dirty = false;
        self.holds_context = false;
        self.in_transaction = false;
        self.rescope = false;
        try self.requeueScope();
    }

    fn requeueScope(self: *Connection) Error!void {
        const fresh = try self.config.useStatements();
        self.pending_use.deinit();
        self.pending_use = fresh;
    }

    /// Learn from an answer that names a session. Whether it carries `newSession` settles what
    /// the engine offers. A fresh session started in place of the one that was sent — which only
    /// happens while `requireSession` is not sent — means whatever the old one held is gone, and
    /// the DSN's scope goes back on before the next statement.
    fn absorb(self: *Connection, new_session: ?bool, sent_id: bool) void {
        const started = new_session orelse {
            if (self.tracks_sessions == null) self.tracks_sessions = false;
            return;
        };
        self.tracks_sessions = true;
        if (!started or !sent_id) return;
        self.rescope = true;
        self.session_dirty = false;
        self.holds_context = false;
        self.in_transaction = false;
    }

    /// Update what the session holds from the text of a request that succeeded. Every statement
    /// in it counts: a `USE` riding behind a leading `SELECT` moves the session just the same.
    fn track(self: *Connection, statement: []const u8) void {
        var it = sql_mod.StatementIterator.init(statement);
        while (it.next()) |piece| {
            if (sql_mod.touchesSession(piece)) self.holds_context = true;
            switch (sql_mod.transactionEffect(piece)) {
                .begins => self.in_transaction = true,
                .ends => self.in_transaction = false,
                .none => {},
            }
        }
    }

    /// Release the engine session, when there is one and the engine is known to release it.
    fn release(self: *Connection) void {
        if (self.session_id.len == 0 or self.tracks_sessions != true) return;
        if (!self.transport.canDelete()) return;
        var path: std.Io.Writer.Allocating = .init(self.allocator);
        defer path.deinit();
        path.writer.writeAll("/api/sessions/") catch return;
        writePathSegment(&path.writer, self.session_id) catch return;
        const budget = if (self.config.timeout_ms == 0) close_budget_ms else @min(self.config.timeout_ms, close_budget_ms);
        var reply = self.transport.delete(self.allocator, path.written(), budget) catch return;
        reply.deinit(self.allocator);
    }

    /// Send one statement and read the answer, without any recovery.
    fn post(self: *Connection, statement: []const u8, options: ExecuteOptions) Error!Outcome {
        const sent_id = self.session_id.len > 0;
        // Resume this session or refuse: without it the engine starts a fresh session under the
        // same id when the old one has gone, and the statement runs in the wrong context. Only an
        // engine known to offer it is asked, since an older one may refuse a field it does not
        // know.
        const require_session = sent_id and self.tracks_sessions == true;
        const body = try wire.encodeRequest(self.allocator, .{
            .sql = statement,
            .session_id = self.session_id,
            .require_session = require_session,
            .auto_commit = self.auto_commit,
            .multi_statement_count = options.multi_statement_count,
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

        if (reply.status == 404 and require_session and !parsed.success and parsed.session_id.len == 0) {
            parsed.response.deinit();
            return .session_gone;
        }

        if (parsed.session_id.len > 0) {
            try self.rememberSession(parsed.session_id);
            self.absorb(parsed.new_session, sent_id);
        }

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
        return .{ .answered = parsed.response };
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
        // An engine that reports `newSession` never leaves the driver guessing: it refuses a
        // session it no longer holds, and the driver recovers from that refusal.
        if (self.tracks_sessions == true) return false;
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
        self.holds_context = false;
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
        if (self.in_transaction or self.transaction_lost) {
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
        // With the DSN's scope back, what the session held is no longer what its statements
        // count on, as on a fresh session.
        self.holds_context = false;
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
        // A transaction that went with a lost session stays open to this API until `rollback`
        // or `commit` ends it.
        if (self.in_transaction or self.transaction_lost) {
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

    /// Commit the transaction `begin` opened.
    ///
    /// One that went with a lost session cannot be: that is `Error.SessionLost`, and nothing is
    /// sent — a COMMIT in a fresh session would report a success that never happened.
    pub fn commit(self: *Connection) Error!void {
        if (self.transaction_lost) {
            self.transaction_lost = false;
            self.auto_commit = true;
            return self.lost("COMMIT", lost_commit);
        }
        if (!self.in_transaction) {
            return fail(&self.diagnostics, self.allocator, Error.InvalidTransactionState, "frostlake: commit was called with no transaction open", .{});
        }
        var response = self.execute("COMMIT") catch |err| {
            self.in_transaction = false;
            self.auto_commit = true;
            // The COMMIT found the session gone and did not run: the engine discarded the
            // transaction with the session, so nothing is left open and the connection is fine.
            if (err == Error.SessionLost) {
                self.transaction_lost = false;
                return err;
            }
            // The COMMIT may never have reached the engine, which would then still be holding
            // the transaction open with no one left to end it. Try to end it, and retire the
            // connection either way rather than keeping one whose state was guessed at. The
            // rollback's own failure must not replace the diagnosis of the commit's.
            const saved = self.allocator.dupe(u8, self.lastError()) catch null;
            defer if (saved) |text| self.allocator.free(text);
            if (!self.bad) self.discard("ROLLBACK");
            if (saved) |text| self.diagnostics.report(self.allocator, "{s}", .{text});
            self.bad = true;
            return err;
        };
        response.deinit();
        self.in_transaction = false;
        self.auto_commit = true;
    }

    /// Roll back the transaction `begin` opened. One that went with a lost session is already
    /// gone, so that succeeds without a round trip.
    pub fn rollback(self: *Connection) Error!void {
        if (self.transaction_lost) {
            self.transaction_lost = false;
            self.auto_commit = true;
            return;
        }
        if (!self.in_transaction) {
            return fail(&self.diagnostics, self.allocator, Error.InvalidTransactionState, "frostlake: rollback was called with no transaction open", .{});
        }
        var response = self.execute("ROLLBACK") catch |err| {
            self.in_transaction = false;
            self.auto_commit = true;
            // Found gone on the way: the transaction went with the session, which is all a
            // rollback asks for.
            if (err == Error.SessionLost) {
                self.transaction_lost = false;
                return;
            }
            self.bad = true;
            return err;
        };
        response.deinit();
        self.in_transaction = false;
        self.auto_commit = true;
    }
};

/// Write `text` as a single URL path segment: every byte but the unreserved ones is escaped.
fn writePathSegment(writer: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(c),
            else => try writer.print("%{X:0>2}", .{c}),
        }
    }
}

test "a session id travels as one path segment" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writePathSegment(&out.writer, "0f3c-9a_b.c~d");
    try writePathSegment(&out.writer, "a/b c?");
    try std.testing.expectEqualStrings("0f3c-9a_b.c~da%2Fb%20c%3F", out.written());
}
