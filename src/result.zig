//! Result sets, and what a request answers with.
//!
//! One request can hold several statements, and the engine answers with one result set each.
//! A `Response` owns them all, along with the storage their cells point into: releasing the
//! response releases every string and every decoded byte slice that came with it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const decode = @import("decode.zig");
const Cell = decode.Cell;
const Column = decode.Column;
const diag_mod = @import("diag.zig");
const Error = diag_mod.Error;

/// A single statement's answer: its columns, and its rows in wire order.
pub const ResultSet = struct {
    columns: []const Column = &.{},
    /// Row-major cells. Every row has `columns.len` entries.
    rows: []const []const Cell = &.{},
    /// The row count the engine reported, which is what a caller should trust over
    /// `rows.len` — they agree today, and a server that ever paged would make them differ.
    row_count: usize = 0,

    pub fn columnCount(self: ResultSet) usize {
        return self.columns.len;
    }

    pub fn rowCount(self: ResultSet) usize {
        return self.rows.len;
    }

    pub fn columnName(self: ResultSet, index: usize) Error![]const u8 {
        if (index >= self.columns.len) return Error.NotFound;
        return self.columns[index].name;
    }

    /// Index of the column named `name`, folding case the way an unquoted identifier does.
    pub fn columnIndex(self: ResultSet, name: []const u8) ?usize {
        for (self.columns, 0..) |candidate, i| {
            if (std.ascii.eqlIgnoreCase(candidate.name, name)) return i;
        }
        return null;
    }

    pub fn column(self: ResultSet, index: usize) Error!Column {
        if (index >= self.columns.len) return Error.NotFound;
        return self.columns[index];
    }

    pub fn at(self: ResultSet, row_index: usize, col: usize) Error!Cell {
        if (row_index >= self.rows.len) return Error.NotFound;
        const cells = self.rows[row_index];
        if (col >= cells.len) return Error.NotFound;
        return cells[col];
    }

    pub fn atName(self: ResultSet, row_index: usize, name: []const u8) Error!Cell {
        const index = self.columnIndex(name) orelse return Error.NotFound;
        return self.at(row_index, index);
    }

    /// The first cell of the first row — what a `SELECT COUNT(*)` is usually after.
    pub fn scalar(self: ResultSet) Error!Cell {
        return self.at(0, 0);
    }

    pub fn row(self: ResultSet, index: usize) Error!Row {
        if (index >= self.rows.len) return Error.NotFound;
        return .{ .set = self, .index = index };
    }

    pub fn iterator(self: ResultSet) RowIterator {
        return .{ .set = self };
    }
};

/// One row, carrying its result set so cells can be read by column name.
pub const Row = struct {
    set: ResultSet,
    index: usize,

    pub fn at(self: Row, col: usize) Error!Cell {
        return self.set.at(self.index, col);
    }

    pub fn get(self: Row, name: []const u8) Error!Cell {
        return self.set.atName(self.index, name);
    }

    pub fn len(self: Row) usize {
        return self.set.rows[self.index].len;
    }
};

pub const RowIterator = struct {
    set: ResultSet,
    index: usize = 0,

    pub fn next(self: *RowIterator) ?Row {
        if (self.index >= self.set.rows.len) return null;
        defer self.index += 1;
        return .{ .set = self.set, .index = self.index };
    }
};

/// Everything one request answered with.
///
/// The arena behind it owns every slice reachable from here, so cells stay valid exactly as
/// long as the response does and are all released together.
pub const Response = struct {
    arena: std.heap.ArenaAllocator,
    sets: []const ResultSet = &.{},
    /// The session the engine ran this in. Borrowed from the arena.
    session_id: []const u8 = "",
    /// How long the engine reported spending on it.
    execution_time_ms: u64 = 0,

    pub fn deinit(self: *Response) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn setCount(self: *const Response) usize {
        return self.sets.len;
    }

    /// The first result set, or an empty one.
    ///
    /// A request that produced none — a DDL statement, say — reads as empty rather than
    /// failing, so a caller that always asks for `first()` does not have to branch first.
    pub fn first(self: *const Response) ResultSet {
        if (self.sets.len == 0) return .{};
        return self.sets[0];
    }

    pub fn set(self: *const Response, index: usize) Error!ResultSet {
        if (index >= self.sets.len) return Error.NotFound;
        return self.sets[index];
    }

    /// The first cell of the first row of the first result set.
    pub fn scalar(self: *const Response) Error!Cell {
        if (self.sets.len == 0) return Error.NotFound;
        return self.sets[0].scalar();
    }

    /// How many rows the request's DML statements touched.
    ///
    /// Frostlake reports a DML count as a one-cell result set titled `number of rows
    /// inserted` / `updated` / `deleted`, so the count is read back out of that grid. A
    /// request holding several statements answers with one such set each, and they add up.
    pub fn rowsAffected(self: *const Response) i64 {
        var total: i64 = 0;
        for (self.sets) |result_set| {
            total += affectedIn(result_set) orelse continue;
        }
        return total;
    }
};

/// The DML count a single result set reports, if it is one of those grids.
///
/// The shape is "one row, and every column named `number of …`", the only rule that covers
/// all of them: an `UPDATE` answers with two columns — `number of rows updated` alongside
/// `number of multi-joined rows updated` — so a rule that insisted on a single column read
/// every update as having touched nothing.
///
/// Every `number of rows …` counter counts — a MERGE answers inserted, updated and deleted
/// side by side, and reading only the first cell under-reported it. The `number of
/// multi-joined rows updated` column is a diagnostic sub-count of rows already counted as
/// updated, so it is the one left out.
fn affectedIn(result_set: ResultSet) ?i64 {
    if (result_set.columns.len == 0) return null;
    if (result_set.rows.len != 1 or result_set.rows[0].len == 0) return null;
    for (result_set.columns) |candidate| {
        if (!std.ascii.startsWithIgnoreCase(candidate.name, "number of ")) return null;
    }
    var total: i64 = 0;
    for (result_set.columns, 0..) |candidate, i| {
        if (i >= result_set.rows[0].len) break;
        if (!std.ascii.startsWithIgnoreCase(candidate.name, "number of rows")) continue;
        total += result_set.rows[0][i].asInt() catch continue;
    }
    return total;
}
