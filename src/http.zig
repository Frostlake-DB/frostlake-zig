//! The HTTP transport, over `std.http.Client`.
//!
//! Nothing about the protocol lives here — this only carries bytes to an endpoint and brings
//! bytes back, so everything above it can be exercised without a socket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const transport_mod = @import("transport.zig");
const Transport = transport_mod.Transport;
const RawReply = transport_mod.RawReply;
const diag_mod = @import("diag.zig");
const Diagnostics = diag_mod.Diagnostics;
const Error = diag_mod.Error;
const fail = diag_mod.fail;

/// How much of a response body is accepted. A result set can be large, but not unbounded — an
/// answer past this is a runaway rather than a query.
pub const max_response_bytes: usize = 256 * 1024 * 1024;

/// Where the request is going, worked out from the base URL once rather than per request.
const Endpoint = struct {
    host: Io.net.HostName,
    port: u16,
    protocol: std.http.Client.Protocol,
};

pub const Client = struct {
    allocator: Allocator,
    io: Io,
    /// `http://host:port`, owned.
    base_url: []const u8,
    endpoint: Endpoint,
    /// Bounds establishing the connection. See the note in `send`.
    connect_timeout: Io.Timeout,
    http: std.http.Client,

    const vtable = Transport.VTable{
        .post = postThunk,
        .get = getThunk,
        .baseUrl = baseUrlThunk,
        .deinit = deinitThunk,
        .delete = deleteThunk,
    };

    /// Build a client for `base_url`.
    ///
    /// The caller takes ownership through the `Transport` this hands back; releasing that
    /// releases this.
    pub fn create(
        allocator: Allocator,
        io: Io,
        base_url: []const u8,
        timeout_ms: u64,
        diag: ?*Diagnostics,
    ) Error!*Client {
        const endpoint = try parseEndpoint(allocator, base_url, diag);

        const self = try allocator.create(Client);
        errdefer allocator.destroy(self);

        const owned_url = try allocator.dupe(u8, base_url);
        errdefer allocator.free(owned_url);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .base_url = owned_url,
            // The host name borrows the owned URL rather than the caller's slice, so it stays
            // valid for as long as the client does.
            .endpoint = .{
                .host = .{ .bytes = owned_url[endpoint.host_start..endpoint.host_end] },
                .port = endpoint.port,
                .protocol = endpoint.protocol,
            },
            .connect_timeout = if (timeout_ms == 0)
                .none
            else
                .{
                    .duration = .{
                        .raw = .{ .nanoseconds = @intCast(timeout_ms * std.time.ns_per_ms) },
                        // Measured on the monotonic clock: a clock correction partway through a
                        // connect should not turn into a spurious timeout.
                        .clock = .awake,
                    },
                },
            .http = .{ .allocator = allocator, .io = io },
        };
        return self;
    }

    pub fn transport(self: *Client) Transport {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn postThunk(
        ptr: *anyopaque,
        allocator: Allocator,
        path: []const u8,
        body: []const u8,
        diag: ?*Diagnostics,
    ) Error!RawReply {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.send(allocator, .POST, path, body, diag);
    }

    fn getThunk(ptr: *anyopaque, allocator: Allocator, path: []const u8, diag: ?*Diagnostics) Error!RawReply {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.send(allocator, .GET, path, null, diag);
    }

    fn baseUrlThunk(ptr: *anyopaque) []const u8 {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.base_url;
    }

    fn deleteThunk(ptr: *anyopaque, allocator: Allocator, path: []const u8, timeout_ms: u64) Error!RawReply {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.deleteWithin(allocator, path, timeout_ms);
    }

    /// How a bounded request ends: answered, or overtaken by its timer.
    const Race = union(enum) {
        answered: Error!RawReply,
        expired: Io.Cancelable!void,
    };

    /// DELETE `path`, bounded as a whole by `timeout_ms`.
    ///
    /// `send` bounds nothing but connecting, and Zig 0.16's threaded I/O cannot bound even
    /// that, so the request runs as a task of its own raced against a timer, and whichever
    /// loses is cancelled. An `Io` with no unit of concurrency to spare sends it unbounded.
    fn deleteWithin(self: *Client, allocator: Allocator, path: []const u8, timeout_ms: u64) Error!RawReply {
        var slots: [2]Race = undefined;
        var race: Io.Select(Race) = .init(self.io, &slots);
        race.concurrent(.answered, send, .{ self, allocator, .DELETE, path, null, null }) catch
            return self.send(allocator, .DELETE, path, null, null);
        const budget: Io.Duration = .fromMilliseconds(@intCast(@min(timeout_ms, std.math.maxInt(i64))));
        // Without a timer the request is simply waited for.
        race.concurrent(.expired, Io.sleep, .{ self.io, budget, .awake }) catch {};

        var outcome: Error!RawReply = Error.TransportFailed;
        if (race.await()) |first| switch (first) {
            .answered => |reply| outcome = reply,
            .expired => {},
        } else |_| {}
        // Whatever is still running is cancelled; an answer that arrived regardless is freed.
        while (race.cancel()) |late| switch (late) {
            .answered => |reply| if (reply) |owned| {
                var discarded = owned;
                discarded.deinit(allocator);
            } else |_| {},
            .expired => {},
        };
        return outcome;
    }

    fn deinitThunk(ptr: *anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        self.http.deinit();
        self.allocator.free(self.base_url);
        self.allocator.destroy(self);
    }

    /// Send one request and read the whole answer.
    ///
    /// The request is driven rather than handed to `std.http.Client.fetch` for one reason: the
    /// DSN's `timeout` has to reach something. `fetch` exposes no deadline at all, and the
    /// only one the client offers is on establishing the connection — so that is where it is
    /// applied, and the connection is acquired here to apply it.
    ///
    /// A statement that runs forever on the server is therefore still waited for. That is a
    /// real limit rather than an oversight: the standard library has no whole-request deadline
    /// to ask for.
    fn send(
        self: *Client,
        allocator: Allocator,
        method: std.http.Method,
        path: []const u8,
        payload: ?[]const u8,
        diag: ?*Diagnostics,
    ) Error!RawReply {
        const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path });
        defer allocator.free(url);

        const uri = std.Uri.parse(url) catch {
            return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} is not a usable URL", .{url});
        };

        const connection = self.http.connectTcpOptions(.{
            .host = self.endpoint.host,
            .port = self.endpoint.port,
            .protocol = self.endpoint.protocol,
            .timeout = self.connect_timeout,
        }) catch |err| {
            return fail(diag, allocator, Error.TransportFailed, "frostlake: cannot reach {s}: {s}", .{ self.base_url, @errorName(err) });
        };

        var request = self.http.request(method, uri, .{
            .connection = connection,
            .redirect_behavior = .unhandled,
            .headers = .{
                .content_type = if (payload != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
        }) catch |err| {
            return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
        };
        defer request.deinit();

        if (payload) |bytes| {
            request.transfer_encoding = .{ .content_length = bytes.len };
            var body_writer = request.sendBodyUnflushed(&.{}) catch |err| {
                return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
            };
            body_writer.writer.writeAll(bytes) catch |err| {
                return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
            };
            body_writer.end() catch |err| {
                return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
            };
            request.connection.?.flush() catch |err| {
                return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
            };
        } else {
            request.sendBodiless() catch |err| {
                return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
            };
        }

        var response = request.receiveHead(&.{}) catch |err| {
            return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: {s}", .{ @tagName(method), url, @errorName(err) });
        };

        var body: Writer.Allocating = .init(allocator);
        defer body.deinit();

        var transfer_buffer: [4096]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        var decompress_buffer: []u8 = &.{};
        defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);
        switch (response.head.content_encoding) {
            .identity => {},
            .zstd => decompress_buffer = try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => decompress_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} answered with an unsupported content encoding", .{url}),
        }

        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&body.writer) catch {
            return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} {s}: the answer ended early", .{ @tagName(method), url });
        };

        if (body.written().len > max_response_bytes) {
            return fail(diag, allocator, Error.TransportFailed, "frostlake: {s} answered with more than {d} bytes", .{ url, max_response_bytes });
        }

        return .{
            .status = @intFromEnum(response.head.status),
            .body = try allocator.dupe(u8, body.written()),
        };
    }
};

/// Where the host name sits inside a base URL, plus the port and protocol it implies.
///
/// Offsets rather than a slice: the client keeps its own copy of the URL, and the host name
/// has to point into that copy rather than into the caller's.
const EndpointParts = struct {
    host_start: usize,
    host_end: usize,
    port: u16,
    protocol: std.http.Client.Protocol,
};

fn parseEndpoint(allocator: Allocator, base_url: []const u8, diag: ?*Diagnostics) Error!EndpointParts {
    const separator = std.mem.indexOf(u8, base_url, "://") orelse
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: \"{s}\" is not a usable base URL", .{base_url});

    const protocol: std.http.Client.Protocol = if (std.ascii.eqlIgnoreCase(base_url[0..separator], "https"))
        .tls
    else
        .plain;

    const authority_start = separator + 3;
    var host_start = authority_start;
    var host_end = base_url.len;
    var port: u16 = if (protocol == .tls) 443 else 80;

    // A bracketed IPv6 literal keeps its colons inside the brackets, so the port is looked for
    // after them rather than at the first colon.
    if (host_start < base_url.len and base_url[host_start] == '[') {
        const close = std.mem.indexOfScalarPos(u8, base_url, host_start, ']') orelse
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: \"{s}\" has an unterminated IPv6 host", .{base_url});
        host_start += 1;
        host_end = close;
        if (close + 1 < base_url.len and base_url[close + 1] == ':') {
            port = std.fmt.parseInt(u16, base_url[close + 2 ..], 10) catch
                return fail(diag, allocator, Error.InvalidDsn, "frostlake: \"{s}\" has an unreadable port", .{base_url});
        }
    } else if (std.mem.indexOfScalarPos(u8, base_url, authority_start, ':')) |colon| {
        host_end = colon;
        port = std.fmt.parseInt(u16, base_url[colon + 1 ..], 10) catch
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: \"{s}\" has an unreadable port", .{base_url});
    }

    if (host_end <= host_start) {
        return fail(diag, allocator, Error.InvalidDsn, "frostlake: \"{s}\" names no host", .{base_url});
    }
    // HostName.validate admits letters, digits, '-' and '.' only, and refused every IPv6
    // literal — the very thing the brackets above exist for. A numeric address is looked up
    // by std as an address, not a name, so it skips the name check.
    const host_text = base_url[host_start..host_end];
    const numeric = (Io.net.IpAddress.parse(host_text, 0) catch null) != null;
    if (!numeric) {
        Io.net.HostName.validate(host_text) catch
            return fail(diag, allocator, Error.InvalidDsn, "frostlake: \"{s}\" is not a usable host name", .{host_text});
    }

    return .{ .host_start = host_start, .host_end = host_end, .port = port, .protocol = protocol };
}
