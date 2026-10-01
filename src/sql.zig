//! Lexical analysis of SQL text.
//!
//! Everything in this file reads a statement as *text* rather than parsing it: where the
//! string literals are, where the bind markers are, where one statement ends and the next
//! begins. Client-side binding and session-scope tracking both depend on the same question —
//! "is this character code, or is it inside something quoted?" — so both read the one scanner
//! here and cannot disagree about the answer.
//!
//! Nothing here allocates. The scanners are iterators over borrowed slices, so a caller that
//! only wants to count bind markers pays nothing for the ones it does not keep.

const std = @import("std");

/// A byte that may appear in an unquoted identifier. `$` is legal in Frostlake identifiers,
/// which is why `A$$B` is a name rather than the start of a dollar-quoted body.
pub fn isWordByte(c: u8) bool {
    return c == '_' or c == '$' or std.ascii.isAlphanumeric(c);
}

/// Index just past the single-quoted literal starting at `i`.
///
/// Both doubled quotes and backslash escapes stay inside the literal — backslash always
/// escapes in Frostlake's string dialect, so `'a\'b'` is one literal and not two.
pub fn skipString(sql: []const u8, i: usize) usize {
    var j = i + 1;
    while (j < sql.len) {
        switch (sql[j]) {
            '\\' => j += 2,
            '\'' => {
                if (j + 1 < sql.len and sql[j + 1] == '\'') {
                    j += 2;
                } else {
                    return j + 1;
                }
            },
            else => j += 1,
        }
    }
    return sql.len;
}

/// Index just past a `quote`-delimited run starting at `i`, where the delimiter is doubled to
/// escape itself. Quoted identifiers (`"a""b"`) are written this way.
pub fn skipQuoted(sql: []const u8, i: usize, quote: u8) usize {
    var j = i + 1;
    while (j < sql.len) {
        if (sql[j] == quote) {
            if (j + 1 < sql.len and sql[j + 1] == quote) {
                j += 2;
                continue;
            }
            return j + 1;
        }
        j += 1;
    }
    return sql.len;
}

/// Whether the `$` at `i` opens a `$$…$$` body rather than sitting inside an identifier.
/// A real delimiter is never preceded by an identifier byte.
pub fn opensDollarQuote(sql: []const u8, i: usize) bool {
    if (i + 1 >= sql.len or sql[i + 1] != '$') return false;
    return i == 0 or !isWordByte(sql[i - 1]);
}

/// Index just past a `$$…$$` body starting at `i`. Function and procedure bodies are written
/// this way and their contents are not SQL — a `?` inside one is body text, never a bind marker.
pub fn skipDollarQuoted(sql: []const u8, i: usize) usize {
    if (std.mem.indexOf(u8, sql[i + 2 ..], "$$")) |j| return i + 2 + j + 2;
    return sql.len;
}

/// Index just past the rest of the line starting at `i`, or the end of input.
pub fn skipLine(sql: []const u8, i: usize) usize {
    if (std.mem.indexOfScalar(u8, sql[i..], '\n')) |j| return i + j + 1;
    return sql.len;
}

/// Index just past a `/* … */` comment starting at `i`. An unterminated comment swallows the
/// rest of the input, which is what the server does with it too.
pub fn skipBlockComment(sql: []const u8, i: usize) usize {
    if (std.mem.indexOf(u8, sql[i + 2 ..], "*/")) |j| return i + 2 + j + 2;
    return sql.len;
}

/// Advance past whatever non-code construct starts at `i`, or return null if `i` is code.
///
/// This is the single place that knows the set of things a bind marker cannot hide inside.
/// Every scanner below defers to it, so adding a construct here teaches all of them at once.
fn skipNonCode(sql: []const u8, i: usize) ?usize {
    return switch (sql[i]) {
        '\'' => skipString(sql, i),
        '"' => skipQuoted(sql, i, '"'),
        '$' => if (opensDollarQuote(sql, i)) skipDollarQuoted(sql, i) else null,
        '-' => if (i + 1 < sql.len and sql[i + 1] == '-') skipLine(sql, i) else null,
        '/' => if (i + 1 < sql.len and sql[i + 1] == '/')
            skipLine(sql, i)
        else if (i + 1 < sql.len and sql[i + 1] == '*')
            skipBlockComment(sql, i)
        else
            null,
        else => null,
    };
}

/// One bind site in a statement.
pub const Placeholder = struct {
    /// Byte offset of the marker's first character.
    start: usize,
    /// Byte offset just past the marker.
    end: usize,
    /// The name of a `:name` marker as written, or empty for a positional `?`.
    /// Names compare case-insensitively; `Placeholder.matches` is what does that.
    name: []const u8 = "",

    pub fn isPositional(self: Placeholder) bool {
        return self.name.len == 0;
    }

    /// Whether this marker names `other`, folding case the way an unquoted identifier does.
    pub fn matches(self: Placeholder, other: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, other);
    }
};

/// Iterates the bind sites of a statement, skipping string literals, quoted identifiers,
/// dollar-quoted bodies and comments.
///
/// Counting arguments and substituting them both run this one scan, so they cannot disagree
/// about what counts as a placeholder.
pub const PlaceholderIterator = struct {
    sql: []const u8,
    i: usize = 0,

    pub fn init(sql: []const u8) PlaceholderIterator {
        return .{ .sql = sql };
    }

    pub fn next(self: *PlaceholderIterator) ?Placeholder {
        while (self.i < self.sql.len) {
            const i = self.i;
            if (skipNonCode(self.sql, i)) |past| {
                self.i = past;
                continue;
            }
            switch (self.sql[i]) {
                '?' => {
                    self.i = i + 1;
                    return .{ .start = i, .end = i + 1 };
                },
                ':' => {
                    // `::` is a cast and `:=` an assignment; neither introduces a parameter.
                    if (i + 1 < self.sql.len and (self.sql[i + 1] == ':' or self.sql[i + 1] == '=')) {
                        self.i = i + 2;
                        continue;
                    }
                    // A colon glued to the END of an expression is Snowflake's VARIANT path
                    // access (`v:field`, `PARSE_JSON('…'):k`, `{'a':1}:a`, `"V":k`), not a bind
                    // marker — a marker follows an operator, comma or keyword boundary instead.
                    //
                    // A positional `?` ends an expression too: it is replaced by the value it
                    // binds, and a VARIANT one renders as `PARSE_JSON('…')`, which takes a path.
                    // Without it here, `SELECT ?:a` read `:a` as a named placeholder and the
                    // statement was refused for mixing two placeholder styles the caller never
                    // mixed.
                    if (i > 0) {
                        const prev = self.sql[i - 1];
                        if (isWordByte(prev) or prev == ')' or prev == ']' or
                            prev == '}' or prev == '"' or prev == '\'' or prev == '?')
                        {
                            self.i = i + 1;
                            continue;
                        }
                    }
                    var j = i + 1;
                    while (j < self.sql.len and isWordByte(self.sql[j])) j += 1;
                    // `:1` is a positional reference to a server-side bind, not a name.
                    if (j > i + 1 and !std.ascii.isDigit(self.sql[i + 1])) {
                        self.i = j;
                        return .{ .start = i, .end = j, .name = self.sql[i + 1 .. j] };
                    }
                    self.i = if (j > i + 1) j else i + 1;
                },
                else => self.i = i + 1,
            }
        }
        return null;
    }
};

/// How many bind sites of each style a statement carries.
pub const PlaceholderCounts = struct {
    positional: usize = 0,
    /// Every `:name` occurrence, counting repeats.
    named: usize = 0,
    /// Distinct `:name` values, folding case. `:a … :A` is one parameter.
    distinct_named: usize = 0,

    pub fn isMixed(self: PlaceholderCounts) bool {
        return self.positional > 0 and self.named > 0;
    }
};

/// Count the bind sites of `sql` without keeping them.
pub fn countPlaceholders(sql: []const u8) PlaceholderCounts {
    var counts = PlaceholderCounts{};
    // Distinct names are counted against the names already seen. A statement's parameter list
    // is small enough that a linear rescan beats allocating a set for it.
    var it = PlaceholderIterator.init(sql);
    while (it.next()) |p| {
        if (p.isPositional()) {
            counts.positional += 1;
            continue;
        }
        counts.named += 1;
        var seen = false;
        var back = PlaceholderIterator.init(sql);
        while (back.next()) |q| {
            if (q.start >= p.start) break;
            if (!q.isPositional() and q.matches(p.name)) {
                seen = true;
                break;
            }
        }
        if (!seen) counts.distinct_named += 1;
    }
    return counts;
}

/// Splits a request on its top-level semicolons, leaving alone any that sit inside a string
/// literal, a quoted identifier, a dollar-quoted body or a comment.
///
/// A procedural block is split along with everything else. That only makes the scope check
/// below more willing to flag a statement, which is the safe direction to be wrong in.
pub const StatementIterator = struct {
    sql: []const u8,
    start: usize = 0,
    done: bool = false,

    pub fn init(sql: []const u8) StatementIterator {
        return .{ .sql = sql };
    }

    pub fn next(self: *StatementIterator) ?[]const u8 {
        if (self.done) return null;
        var i = self.start;
        while (i < self.sql.len) {
            if (skipNonCode(self.sql, i)) |past| {
                i = past;
                continue;
            }
            if (self.sql[i] == ';') {
                const statement = self.sql[self.start..i];
                self.start = i + 1;
                return statement;
            }
            i += 1;
        }
        self.done = true;
        return self.sql[self.start..];
    }
};

/// Iterates the leading words of a statement, upper-cased into `buffer`, skipping whitespace
/// and comments and stopping at the first thing that is not a word.
///
/// Words are folded into a caller-owned buffer so the iterator allocates nothing; a word
/// longer than the buffer stops the iteration, which is fine for its one use — the keywords
/// it looks for are all short.
pub const LeadingWordIterator = struct {
    sql: []const u8,
    i: usize = 0,
    buffer: []u8,

    pub fn init(sql: []const u8, buffer: []u8) LeadingWordIterator {
        return .{ .sql = sql, .buffer = buffer };
    }

    pub fn next(self: *LeadingWordIterator) ?[]const u8 {
        while (self.i < self.sql.len) {
            const c = self.sql[self.i];
            if (std.ascii.isWhitespace(c)) {
                self.i += 1;
                continue;
            }
            if (c == '-' and self.i + 1 < self.sql.len and self.sql[self.i + 1] == '-') {
                self.i = skipLine(self.sql, self.i);
                continue;
            }
            if (c == '/' and self.i + 1 < self.sql.len and self.sql[self.i + 1] == '/') {
                self.i = skipLine(self.sql, self.i);
                continue;
            }
            if (c == '/' and self.i + 1 < self.sql.len and self.sql[self.i + 1] == '*') {
                const past = skipBlockComment(self.sql, self.i);
                // An unterminated comment leaves no words behind it.
                if (past >= self.sql.len) return null;
                self.i = past;
                continue;
            }
            if (!isWordByte(c)) return null;
            const start = self.i;
            while (self.i < self.sql.len and isWordByte(self.sql[self.i])) self.i += 1;
            const word = self.sql[start..self.i];
            if (word.len > self.buffer.len) return null;
            return std.ascii.upperString(self.buffer[0..word.len], word);
        }
        return null;
    }
};

/// The modifiers that may sit between CREATE/DROP/ALTER and the object being named.
const object_modifiers = [_][]const u8{
    "OR",     "REPLACE", "TRANSIENT", "TEMPORARY", "TEMP",   "VOLATILE",
    "LOCAL",  "GLOBAL",  "SECURE",    "IF",        "NOT",    "EXISTS",
    "PUBLIC", "PRIVATE", "ICEBERG",   "DYNAMIC",   "HYBRID", "EVENT",
};

fn isObjectModifier(word: []const u8) bool {
    for (object_modifiers) |modifier| {
        if (std.mem.eql(u8, word, modifier)) return true;
    }
    return false;
}

/// Whether a single statement can move the session off the scope the DSN established.
///
/// Only `USE`, the `SET` family, `ALTER SESSION`, and `CREATE`/`DROP` of a `DATABASE` or
/// `SCHEMA` move the session. `CREATE TABLE` and its kind leave the scope exactly where it
/// was, and counting them would retire a connection for every DDL statement a caller ran.
pub fn statementChangesScope(statement: []const u8) bool {
    var buffer: [32]u8 = undefined;
    var words = LeadingWordIterator.init(statement, &buffer);

    const first = words.next() orelse return false;
    if (std.mem.eql(u8, first, "USE") or
        std.mem.eql(u8, first, "SET") or
        std.mem.eql(u8, first, "UNSET")) return true;

    const wants_session = std.mem.eql(u8, first, "ALTER");
    const wants_scope = std.mem.eql(u8, first, "CREATE") or std.mem.eql(u8, first, "DROP");
    if (!wants_session and !wants_scope) return false;

    // Step over the modifiers between the verb and the object it names.
    while (words.next()) |word| {
        if (isObjectModifier(word)) continue;
        if (wants_session) return std.mem.eql(u8, word, "SESSION");
        return std.mem.eql(u8, word, "DATABASE") or std.mem.eql(u8, word, "SCHEMA");
    }
    return false;
}

/// The modifiers `touchesSession` steps over: the scope check's own, and the rarer ones that
/// may also sit before an object's kind.
fn isSessionModifier(word: []const u8) bool {
    return isObjectModifier(word) or
        std.mem.eql(u8, word, "RECURSIVE") or
        std.mem.eql(u8, word, "MATERIALIZED") or
        std.mem.eql(u8, word, "EXTERNAL");
}

/// Whether a single statement leaves context behind that a fresh session on the DSN's scope
/// would not have: a moved scope (`USE`, `CREATE` or `DROP` of a `DATABASE` or `SCHEMA`), a
/// session variable or setting (`SET`, `UNSET`, `ALTER SESSION`), or a temporary object.
///
/// A lost session that held any of it is reported rather than replaced. This is wider than
/// `statementChangesScope`, which decides only whether the scope has to be put back: a
/// temporary table leaves the scope alone, but a statement re-run without it reads something
/// else.
pub fn touchesSession(statement: []const u8) bool {
    var buffer: [64]u8 = undefined;
    var words = LeadingWordIterator.init(statement, &buffer);

    const first = words.next() orelse return false;
    if (std.mem.eql(u8, first, "USE") or
        std.mem.eql(u8, first, "SET") or
        std.mem.eql(u8, first, "UNSET")) return true;

    const alter = std.mem.eql(u8, first, "ALTER");
    const create = std.mem.eql(u8, first, "CREATE");
    if (!alter and !create and !std.mem.eql(u8, first, "DROP")) return false;

    // Step over the modifiers between the verb and the object it names, noting a temporary one.
    var temporary = false;
    while (words.next()) |word| {
        if (isSessionModifier(word)) {
            if (std.mem.eql(u8, word, "TEMPORARY") or
                std.mem.eql(u8, word, "TEMP") or
                std.mem.eql(u8, word, "VOLATILE")) temporary = true;
            continue;
        }
        if (alter) return std.mem.eql(u8, word, "SESSION");
        if (std.mem.eql(u8, word, "DATABASE") or std.mem.eql(u8, word, "SCHEMA")) return true;
        return create and temporary;
    }
    return create and temporary;
}

/// What a statement does to the session's transaction.
pub const TransactionEffect = enum { begins, ends, none };

/// Read a single statement's effect on the session's transaction.
///
/// `BEGIN` on its own, or with `TRANSACTION`, `WORK` or `NAME`, opens one, as does
/// `START TRANSACTION`; `BEGIN` followed by a statement opens a scripting block instead.
/// `COMMIT` and `ROLLBACK` end one.
pub fn transactionEffect(statement: []const u8) TransactionEffect {
    var buffer: [64]u8 = undefined;
    var words = LeadingWordIterator.init(statement, &buffer);

    const first = words.next() orelse return .none;
    if (std.mem.eql(u8, first, "COMMIT") or std.mem.eql(u8, first, "ROLLBACK")) return .ends;
    if (std.mem.eql(u8, first, "START")) {
        const second = words.next() orelse return .none;
        return if (std.mem.eql(u8, second, "TRANSACTION")) .begins else .none;
    }
    if (!std.mem.eql(u8, first, "BEGIN")) return .none;
    const second = words.next() orelse return .begins;
    if (std.mem.eql(u8, second, "TRANSACTION") or
        std.mem.eql(u8, second, "WORK") or
        std.mem.eql(u8, second, "NAME")) return .begins;
    return .none;
}

/// Whether a request — which may hold several statements — can move the session's scope.
///
/// Every statement is examined rather than only the first: a `USE` riding behind a leading
/// `SELECT` moves the scope just as surely as one standing alone.
pub fn changesSessionScope(sql: []const u8) bool {
    var it = StatementIterator.init(sql);
    while (it.next()) |statement| {
        if (statementChangesScope(statement)) return true;
    }
    return false;
}

/// Whether `name` survives unquoted: upper-case letters, digits, underscore and `$`, never
/// leading with a digit or `$`.
pub fn isPlainUpperIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        switch (c) {
            'A'...'Z', '_' => {},
            '0'...'9', '$' => if (i == 0) return false,
            else => return false,
        }
    }
    return true;
}

/// Write `name` as an identifier, quoting it unless it is already a plain upper-case name.
///
/// Frostlake folds an unquoted identifier to upper case, so a name that is already upper-case
/// needs no quoting. Embedded quotes are doubled, which is what stops a name arriving from a
/// DSN from breaking out of the quoting and into the statement.
pub fn writeQuotedIdent(writer: anytype, name: []const u8) !void {
    if (isPlainUpperIdent(name)) {
        try writer.writeAll(name);
        return;
    }
    try writer.writeAll("\"");
    for (name) |c| {
        if (c == '"') try writer.writeAll("\"");
        try writer.writeByte(c);
    }
    try writer.writeAll("\"");
}
