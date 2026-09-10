//! A dependency-free Zig driver for [Frostlake](https://frostlake.dev), speaking the engine's
//! HTTP protocol against a running `DatabaseHttpServer`. No JVM, no C library — Zig's own
//! standard library and nothing else.
//!
//! ```zig
//! const frostlake = @import("frostlake");
//!
//! var conn = try frostlake.Connection.open(allocator, io, "frostlake://localhost:18082/MY_DB?schema=PUBLIC");
//! defer conn.close();
//!
//! var rows = try conn.query("SELECT NAME FROM PEOPLE WHERE ID = ?", &.{frostlake.Value.of(1)});
//! defer rows.deinit();
//!
//! const name = try (try rows.scalar()).asText();
//! ```
//!
//! Statement parameters are inlined client-side — the protocol has no server-side binding —
//! with the same rules as Frostlake's JDBC driver. Both positional `?` and named `:name`
//! placeholders work, one style per statement.

const std = @import("std");

pub const dsn = @import("dsn.zig");
pub const sql = @import("sql.zig");
pub const wire = @import("wire.zig");
pub const http = @import("http.zig");
pub const value = @import("value.zig");
pub const decode = @import("decode.zig");

// --- the public surface ----------------------------------------------------

const connection_mod = @import("connection.zig");
pub const Connection = connection_mod.Connection;
pub const scope_refresh_after_ms = connection_mod.scope_refresh_after_ms;

const diag_mod = @import("diag.zig");
pub const Error = diag_mod.Error;
pub const Diagnostics = diag_mod.Diagnostics;

const value_mod = @import("value.zig");
pub const Value = value_mod.Value;
pub const Date = value_mod.Date;
pub const Time = value_mod.Time;
pub const Timestamp = value_mod.Timestamp;

const bind_mod = @import("bind.zig");
pub const NamedValue = bind_mod.NamedValue;
pub const substitute = bind_mod.substitute;
pub const substituteNamed = bind_mod.substituteNamed;

const decode_mod = @import("decode.zig");
pub const Cell = decode_mod.Cell;
pub const Column = decode_mod.Column;
pub const ColumnKind = decode_mod.ColumnKind;
pub const Nullability = decode_mod.Nullability;

const result_mod = @import("result.zig");
pub const Response = result_mod.Response;
pub const ResultSet = result_mod.ResultSet;
pub const Row = result_mod.Row;
pub const RowIterator = result_mod.RowIterator;

pub const Config = dsn.Config;
pub const parseDsn = dsn.parse;

const transport_mod = @import("transport.zig");
pub const Transport = transport_mod.Transport;
pub const RawReply = transport_mod.RawReply;

/// The engine release this driver was written against.
///
/// The driver versions independently of the engine — it speaks the HTTP protocol, not the jar
/// — so this is a floor rather than a lockstep pin. Ask a running server which one it is with
/// `SELECT CURRENT_VERSION()`.
pub const minimum_engine_version = "0.0.7";

/// Shorthand for the common case: open, run one statement, hand back the answer.
///
/// The caller owns the response and must `deinit` it; the connection is closed either way.
pub fn queryOnce(
    allocator: std.mem.Allocator,
    io: std.Io,
    dsn_text: []const u8,
    statement: []const u8,
    args: []const Value,
) Error!Response {
    var conn = try Connection.open(allocator, io, dsn_text);
    defer conn.close();
    return conn.query(statement, args);
}

test {
    // Pull in every module's tests, including the ones that live beside the code they cover.
    std.testing.refAllDecls(@This());
    _ = @import("diag.zig");
    _ = @import("dsn.zig");
    _ = @import("sql.zig");
    _ = @import("value.zig");
    _ = @import("bind.zig");
    _ = @import("decode.zig");
    _ = @import("result.zig");
    _ = @import("wire.zig");
    _ = @import("connection.zig");
}
