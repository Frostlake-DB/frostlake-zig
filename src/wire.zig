//! The JSON on the wire.
//!
//! `POST /api/execute` takes `{"sql":…,"sessionId":…,"autoCommit":…}` and answers with
//! `{"success":…,"sessionId":…,"errorMessage":…,"resultSets":[…],"executionTimeMs":…}`.
//!
//! The response is read with `std.json`'s token scanner rather than its dynamic tree, for one
//! reason: the scanner hands back a number's text exactly as it appeared. A `NUMBER(38,0)` and
//! a `NUMBER(20,10)` both hold values `f64` cannot name, and a decoder that parses first and
//! asks questions later has already rounded them away.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const decode = @import("decode.zig");
const Cell = decode.Cell;
const Column = decode.Column;
const Nullability = decode.Nullability;
const result_mod = @import("result.zig");
const Response = result_mod.Response;
const ResultSet = result_mod.ResultSet;
const diag_mod = @import("diag.zig");
const Diagnostics = diag_mod.Diagnostics;
const Error = diag_mod.Error;

pub const Request = struct {
    sql: []const u8,
    session_id: []const u8 = "",
    auto_commit: bool = true,
};

/// Render a request body.
pub fn encodeRequest(allocator: Allocator, request: Request) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    writer.writeAll("{\"sql\":") catch return error.OutOfMemory;
    writeJsonString(writer, request.sql) catch return error.OutOfMemory;
    if (request.session_id.len > 0) {
        writer.writeAll(",\"sessionId\":") catch return error.OutOfMemory;
        writeJsonString(writer, request.session_id) catch return error.OutOfMemory;
    }
    writer.writeAll(if (request.auto_commit) ",\"autoCommit\":true}" else ",\"autoCommit\":false}") catch
        return error.OutOfMemory;

    return out.toOwnedSlice();
}

/// Write `text` as a JSON string, escaping what JSON forbids raw.
///
/// Every control character is escaped, not just the familiar ones: a compilation error's
/// message can carry any byte, and one that slips through unescaped produces a body no client
/// can parse.
pub fn writeJsonString(writer: *Writer, text: []const u8) Writer.Error!void {
    try writer.writeByte('"');
    for (text) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// A decoded answer. `response` owns the arena every slice here points into.
pub const Decoded = struct {
    response: Response,
    success: bool = false,
    /// Borrowed from the response's arena.
    session_id: []const u8 = "",
    error_message: []const u8 = "",
};

/// Whether a body that failed to parse did so because it carries a bare `undefined`.
///
/// Engine 0.0.7 renders a VARIANT `undefined` — what `FILTER`/`TRANSFORM` leave behind where an
/// array element was SQL NULL — as the bare token `undefined`, which is not JSON and which no
/// strict parser will accept. Telling that apart from a wrong port matters: one is a server
/// bug on a specific query, the other is a misconfigured address, and "not a Frostlake
/// response" fits both.
///
/// The scan skips string contents, so the word appearing inside a VARCHAR value does not
/// trigger it.
pub fn carriesBareUndefined(body: []const u8) bool {
    var i: usize = 0;
    while (i < body.len) {
        switch (body[i]) {
            '"' => {
                // Step over a string literal, honouring backslash escapes.
                i += 1;
                while (i < body.len) : (i += 1) {
                    if (body[i] == '\\') {
                        i += 1;
                    } else if (body[i] == '"') break;
                }
                i += 1;
            },
            'u' => {
                if (std.mem.startsWith(u8, body[i..], "undefined")) return true;
                i += 1;
            },
            else => i += 1,
        }
    }
    return false;
}

/// Whether a body looks like the health endpoint's answer.
///
/// A 200 on its own only says something is listening — anything can serve that. The `status`
/// field is what says the far side is a Frostlake engine.
pub fn looksLikeHealth(body: []const u8) bool {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return false;
    return std.mem.indexOf(u8, trimmed, "\"status\"") != null;
}

/// A cell exactly as it arrived, before its column has had a say in what it means.
///
/// Rows are read before the decoder knows which column each belongs to — nothing promises
/// `columns` arrives before `rows` — so cells are held in their wire form until the whole
/// result set is in hand.
const RawCell = union(enum) {
    null_value,
    boolean: bool,
    /// The number's text, exactly as written.
    number: []const u8,
    string: []const u8,
    /// A nested object or array, re-serialised.
    structured: []const u8,
};

/// Decode a response body.
pub fn decodeResponse(allocator: Allocator, body: []const u8, diag: ?*Diagnostics) Error!Decoded {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const gpa = arena.allocator();

    // The body is copied into the arena once, so every borrowed slice the scanner hands back
    // points at memory the response owns and outlives the reply buffer.
    const input = try gpa.dupe(u8, body);

    var scanner = std.json.Scanner.initCompleteInput(gpa, input);
    defer scanner.deinit();

    // The arena is moved into the response at the very END of this function, never here.
    // `gpa` refers to the local `arena`, so copying it now would freeze its bookkeeping at
    // this moment and leak everything allocated afterwards.
    var decoded = Decoded{ .response = .{ .arena = undefined } };
    var sets: std.ArrayList(ResultSet) = .empty;
    // A top-level `{"error": …}` is how the endpoint rejects a request rather than running it.
    var endpoint_error: []const u8 = "";
    var saw_success_field = false;

    if (!try expect(&scanner, .object_begin)) return notFrostlake(diag);

    while (true) {
        const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
        const key = switch (token) {
            .object_end => break,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return notFrostlake(diag),
        };

        if (std.mem.eql(u8, key, "success")) {
            decoded.success = (try readBool(&scanner, gpa)) orelse return notFrostlake(diag);
            saw_success_field = true;
        } else if (std.mem.eql(u8, key, "sessionId")) {
            decoded.session_id = (try readOptionalString(&scanner, gpa)) orelse "";
        } else if (std.mem.eql(u8, key, "errorMessage")) {
            decoded.error_message = (try readOptionalString(&scanner, gpa)) orelse "";
        } else if (std.mem.eql(u8, key, "error")) {
            endpoint_error = (try readOptionalString(&scanner, gpa)) orelse "";
        } else if (std.mem.eql(u8, key, "executionTimeMs")) {
            const text = (try readNumberText(&scanner, gpa)) orelse "";
            decoded.response.execution_time_ms = std.fmt.parseInt(u64, text, 10) catch 0;
        } else if (std.mem.eql(u8, key, "resultSets")) {
            try readResultSets(&scanner, gpa, &sets, diag);
        } else {
            // A field this driver does not know about. Skipping it rather than failing is what
            // lets a newer engine add one without breaking every client at once.
            skipValue(&scanner, gpa) catch return notFrostlake(diag);
        }
    }

    // Neither `success` nor `error` means this was not a Frostlake answer, whatever else the
    // body held. A proxy's JSON error page would otherwise read as a successful statement
    // that returned no rows.
    if (!saw_success_field and endpoint_error.len == 0) return notFrostlake(diag);

    if (endpoint_error.len > 0 and decoded.error_message.len == 0) {
        decoded.error_message = try std.fmt.allocPrint(gpa, "frostlake: {s}", .{endpoint_error});
    }

    decoded.response.sets = try sets.toOwnedSlice(gpa);
    decoded.response.session_id = decoded.session_id;
    // Nothing else allocates from `gpa` past this point, so the arena's bookkeeping is
    // complete and can travel with the response.
    decoded.response.arena = arena;
    return decoded;
}

fn notFrostlake(diag: ?*Diagnostics) Error {
    _ = diag;
    // The caller knows the endpoint and the status and reports both; here there is only the
    // fact that the body did not parse as one of ours.
    return Error.NotFrostlake;
}

fn readResultSets(
    scanner: *std.json.Scanner,
    gpa: Allocator,
    sets: *std.ArrayList(ResultSet),
    diag: ?*Diagnostics,
) Error!void {
    const first = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
    switch (first) {
        .null => return,
        .array_begin => {},
        else => return notFrostlake(diag),
    }
    while (true) {
        const token = scanner.peekNextTokenType() catch return notFrostlake(diag);
        if (token == .array_end) {
            _ = scanner.next() catch return notFrostlake(diag);
            return;
        }
        const set = try readResultSet(scanner, gpa, diag);
        try sets.append(gpa, set);
    }
}

fn readResultSet(scanner: *std.json.Scanner, gpa: Allocator, diag: ?*Diagnostics) Error!ResultSet {
    if (!try expect(scanner, .object_begin)) return notFrostlake(diag);

    var columns: std.ArrayList(Column) = .empty;
    var raw_rows: std.ArrayList([]const RawCell) = .empty;
    var row_count: usize = 0;

    while (true) {
        const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
        const key = switch (token) {
            .object_end => break,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return notFrostlake(diag),
        };
        if (std.mem.eql(u8, key, "columns")) {
            try readColumns(scanner, gpa, &columns, diag);
        } else if (std.mem.eql(u8, key, "rows")) {
            try readRows(scanner, gpa, &raw_rows, diag);
        } else if (std.mem.eql(u8, key, "rowCount")) {
            const text = (try readNumberText(scanner, gpa)) orelse "";
            row_count = std.fmt.parseInt(usize, text, 10) catch 0;
        } else {
            skipValue(scanner, gpa) catch return notFrostlake(diag);
        }
    }

    // Now that the columns are known, every cell can be given its type.
    const column_slice = try columns.toOwnedSlice(gpa);
    const rows = try gpa.alloc([]const Cell, raw_rows.items.len);
    for (raw_rows.items, 0..) |raw_row, r| {
        const cells = try gpa.alloc(Cell, raw_row.len);
        for (raw_row, 0..) |raw, c| {
            const column: Column = if (c < column_slice.len)
                column_slice[c]
            else
                // A cell with no column to explain it. Reading it as text keeps the value
                // rather than dropping the row.
                .{ .name = "", .data_type = "VARCHAR" };
            cells[c] = try decodeCell(gpa, raw, column);
        }
        rows[r] = cells;
    }

    return .{
        .columns = column_slice,
        .rows = rows,
        .row_count = if (row_count > 0) row_count else rows.len,
    };
}

fn decodeCell(gpa: Allocator, raw: RawCell, column: Column) Allocator.Error!Cell {
    return switch (raw) {
        .null_value => .null_value,
        .boolean => |v| .{ .boolean = v },
        .number => |text| decode.decodeNumber(text, column),
        .string => |text| try decode.decodeString(gpa, text, column),
        // A nested object or array is a structured cell whatever the column says.
        .structured => |text| .{ .variant = text },
    };
}

fn readColumns(
    scanner: *std.json.Scanner,
    gpa: Allocator,
    columns: *std.ArrayList(Column),
    diag: ?*Diagnostics,
) Error!void {
    const first = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
    switch (first) {
        .null => return,
        .array_begin => {},
        else => return notFrostlake(diag),
    }
    while (true) {
        const next_type = scanner.peekNextTokenType() catch return notFrostlake(diag);
        if (next_type == .array_end) {
            _ = scanner.next() catch return notFrostlake(diag);
            return;
        }
        if (!try expect(scanner, .object_begin)) return notFrostlake(diag);

        var column = Column{ .name = "", .data_type = "" };
        while (true) {
            const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
            const key = switch (token) {
                .object_end => break,
                .string => |s| s,
                .allocated_string => |s| s,
                else => return notFrostlake(diag),
            };
            if (std.mem.eql(u8, key, "name")) {
                column.name = (try readOptionalString(scanner, gpa)) orelse "";
            } else if (std.mem.eql(u8, key, "dataType")) {
                column.data_type = (try readOptionalString(scanner, gpa)) orelse "";
            } else if (std.mem.eql(u8, key, "precision")) {
                const text = (try readNumberText(scanner, gpa)) orelse "";
                column.precision = std.fmt.parseInt(i32, text, 10) catch 0;
            } else if (std.mem.eql(u8, key, "scale")) {
                const text = (try readNumberText(scanner, gpa)) orelse "";
                column.scale = std.fmt.parseInt(i32, text, 10) catch 0;
            } else if (std.mem.eql(u8, key, "nullable")) {
                // The field means "known to accept NULL" and is always sent by an engine that
                // has it; absent or null therefore means exactly one thing — a server
                // predating the field — which is worth telling apart from "not nullable".
                const value = try readBool(scanner, gpa);
                column.nullable = if (value) |v|
                    (if (v) Nullability.nullable else Nullability.not_null)
                else
                    Nullability.unknown;
            } else {
                skipValue(scanner, gpa) catch return notFrostlake(diag);
            }
        }
        try columns.append(gpa, column);
    }
}

fn readRows(
    scanner: *std.json.Scanner,
    gpa: Allocator,
    rows: *std.ArrayList([]const RawCell),
    diag: ?*Diagnostics,
) Error!void {
    const first = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
    switch (first) {
        .null => return,
        .array_begin => {},
        else => return notFrostlake(diag),
    }
    while (true) {
        const next_type = scanner.peekNextTokenType() catch return notFrostlake(diag);
        if (next_type == .array_end) {
            _ = scanner.next() catch return notFrostlake(diag);
            return;
        }
        if (!try expect(scanner, .array_begin)) return notFrostlake(diag);

        var cells: std.ArrayList(RawCell) = .empty;
        while (true) {
            const cell_type = scanner.peekNextTokenType() catch return notFrostlake(diag);
            if (cell_type == .array_end) {
                _ = scanner.next() catch return notFrostlake(diag);
                break;
            }
            try cells.append(gpa, try readCell(scanner, gpa, diag));
        }
        try rows.append(gpa, try cells.toOwnedSlice(gpa));
    }
}

fn readCell(scanner: *std.json.Scanner, gpa: Allocator, diag: ?*Diagnostics) Error!RawCell {
    const next_type = scanner.peekNextTokenType() catch return notFrostlake(diag);
    switch (next_type) {
        .object_begin, .array_begin => {
            const text = try captureValue(scanner, gpa, diag);
            return .{ .structured = text };
        },
        else => {},
    }
    const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
    return switch (token) {
        .null => .null_value,
        .true => .{ .boolean = true },
        .false => .{ .boolean = false },
        .number => |text| .{ .number = text },
        .allocated_number => |text| .{ .number = text },
        .string => |text| .{ .string = text },
        .allocated_string => |text| .{ .string = text },
        else => notFrostlake(diag),
    };
}

/// Re-serialise a nested object or array back to JSON text.
///
/// The engine sends a VARIANT as its text, so this is not the usual path — but a structured
/// cell that arrived as real JSON should still reach the caller as JSON rather than as a hole.
fn captureValue(scanner: *std.json.Scanner, gpa: Allocator, diag: ?*Diagnostics) Error![]const u8 {
    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try writeValue(scanner, gpa, &out.writer, diag);
    return out.toOwnedSlice();
}

fn writeValue(scanner: *std.json.Scanner, gpa: Allocator, writer: *Writer, diag: ?*Diagnostics) Error!void {
    const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
    switch (token) {
        .null => writer.writeAll("null") catch return error.OutOfMemory,
        .true => writer.writeAll("true") catch return error.OutOfMemory,
        .false => writer.writeAll("false") catch return error.OutOfMemory,
        .number, .allocated_number => |text| writer.writeAll(text) catch return error.OutOfMemory,
        .string, .allocated_string => |text| writeJsonString(writer, text) catch return error.OutOfMemory,
        .array_begin => {
            writer.writeByte('[') catch return error.OutOfMemory;
            var first = true;
            while (true) {
                const next_type = scanner.peekNextTokenType() catch return notFrostlake(diag);
                if (next_type == .array_end) {
                    _ = scanner.next() catch return notFrostlake(diag);
                    break;
                }
                if (!first) writer.writeByte(',') catch return error.OutOfMemory;
                first = false;
                try writeValue(scanner, gpa, writer, diag);
            }
            writer.writeByte(']') catch return error.OutOfMemory;
        },
        .object_begin => {
            writer.writeByte('{') catch return error.OutOfMemory;
            var first = true;
            while (true) {
                const key_token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return notFrostlake(diag);
                const key = switch (key_token) {
                    .object_end => break,
                    .string => |s| s,
                    .allocated_string => |s| s,
                    else => return notFrostlake(diag),
                };
                if (!first) writer.writeByte(',') catch return error.OutOfMemory;
                first = false;
                writeJsonString(writer, key) catch return error.OutOfMemory;
                writer.writeByte(':') catch return error.OutOfMemory;
                try writeValue(scanner, gpa, writer, diag);
            }
            writer.writeByte('}') catch return error.OutOfMemory;
        },
        else => return notFrostlake(diag),
    }
}

// --- small scanner helpers -------------------------------------------------

fn expect(scanner: *std.json.Scanner, comptime want: std.json.TokenType) Error!bool {
    const token = scanner.next() catch return false;
    return switch (want) {
        .object_begin => token == .object_begin,
        .array_begin => token == .array_begin,
        else => @compileError("unhandled token type"),
    };
}

/// Read a string, or null. Anything else is a shape this decoder does not expect.
fn readOptionalString(scanner: *std.json.Scanner, gpa: Allocator) Error!?[]const u8 {
    const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return Error.NotFrostlake;
    return switch (token) {
        .null => null,
        .string => |s| s,
        .allocated_string => |s| s,
        else => Error.NotFrostlake,
    };
}

fn readBool(scanner: *std.json.Scanner, gpa: Allocator) Error!?bool {
    const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return Error.NotFrostlake;
    return switch (token) {
        .null => null,
        .true => true,
        .false => false,
        else => Error.NotFrostlake,
    };
}

fn readNumberText(scanner: *std.json.Scanner, gpa: Allocator) Error!?[]const u8 {
    const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return Error.NotFrostlake;
    return switch (token) {
        .null => null,
        .number => |text| text,
        .allocated_number => |text| text,
        else => Error.NotFrostlake,
    };
}

fn skipValue(scanner: *std.json.Scanner, gpa: Allocator) !void {
    _ = gpa;
    try scanner.skipValue();
}
