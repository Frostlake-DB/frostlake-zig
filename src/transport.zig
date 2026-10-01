//! The seam between the connection and the network.
//!
//! `Connection` talks to this interface rather than to `std.http.Client` directly. That keeps
//! the interesting logic — session scope, the pending `USE` queue, retiring a connection whose
//! state can no longer be vouched for — testable without a server to talk to, which is the
//! part of a driver that is otherwise only ever exercised by integration tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const diag_mod = @import("diag.zig");
const Diagnostics = diag_mod.Diagnostics;
const Error = diag_mod.Error;

/// A response as it came off the wire, before anyone has decided whether it is JSON.
pub const RawReply = struct {
    status: u16,
    /// Owned by the allocator passed to the call that produced it.
    body: []u8,

    pub fn deinit(self: *RawReply, allocator: Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

/// A transport that can carry a request to a Frostlake server and bring back the answer.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// POST `body` to `path` (a path such as `/api/execute`, not a full URL).
        post: *const fn (
            ptr: *anyopaque,
            allocator: Allocator,
            path: []const u8,
            body: []const u8,
            diag: ?*Diagnostics,
        ) Error!RawReply,

        /// GET `path`.
        get: *const fn (
            ptr: *anyopaque,
            allocator: Allocator,
            path: []const u8,
            diag: ?*Diagnostics,
        ) Error!RawReply,

        /// The endpoint prefix, for error messages that need to name what was called.
        baseUrl: *const fn (ptr: *anyopaque) []const u8,

        deinit: *const fn (ptr: *anyopaque) void,

        /// DELETE `path`, giving up once `timeout_ms` has passed, connecting included. Null in
        /// a transport that sends none, which leaves an engine session to the engine's own idle
        /// sweep when its connection closes.
        delete: ?*const fn (
            ptr: *anyopaque,
            allocator: Allocator,
            path: []const u8,
            timeout_ms: u64,
        ) Error!RawReply = null,
    };

    pub fn post(
        self: Transport,
        allocator: Allocator,
        path: []const u8,
        body: []const u8,
        diag: ?*Diagnostics,
    ) Error!RawReply {
        return self.vtable.post(self.ptr, allocator, path, body, diag);
    }

    pub fn get(self: Transport, allocator: Allocator, path: []const u8, diag: ?*Diagnostics) Error!RawReply {
        return self.vtable.get(self.ptr, allocator, path, diag);
    }

    pub fn baseUrl(self: Transport) []const u8 {
        return self.vtable.baseUrl(self.ptr);
    }

    /// Whether this transport can send a DELETE at all.
    pub fn canDelete(self: Transport) bool {
        return self.vtable.delete != null;
    }

    /// DELETE `path`, bounded by `timeout_ms` in all.
    pub fn delete(self: Transport, allocator: Allocator, path: []const u8, timeout_ms: u64) Error!RawReply {
        const send = self.vtable.delete orelse return Error.TransportFailed;
        return send(self.ptr, allocator, path, timeout_ms);
    }

    pub fn deinit(self: Transport) void {
        self.vtable.deinit(self.ptr);
    }
};
