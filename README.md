# frostlake-zig

A dependency-free Zig driver for [Frostlake](https://frostlake.dev), speaking the engine's
HTTP protocol against a running `DatabaseHttpServer`. No JVM, no C library — Zig's own
standard library and nothing else.

Requires **Zig 0.16.0** or newer. The driver uses the `std.Io` interface that release
introduced, so it does not build on 0.15 or earlier.

## Engine version

Requires a Frostlake engine **0.2.0 or newer**. Ask a running server which one it is with
`SELECT CURRENT_VERSION()` — every release answers it, so the check works against any engine.

The driver versions independently of the engine: it speaks the HTTP protocol, not the jar, so
this is a floor rather than a lockstep pin. One behaviour depends on the engine version —
column nullability (`Column.nullable`) reads `.unknown` from servers that predate the field.

## Using it

Add it to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/Frostlake-DB/frostlake-zig
```

and wire the module into your build:

```zig
const frostlake = b.dependency("frostlake", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("frostlake", frostlake.module("frostlake"));
```

```zig
const std = @import("std");
const frostlake = @import("frostlake");

pub fn main(init: std.process.Init) !void {
    // The DSN's scope is applied with USE, so its database has to exist first.
    var created = try frostlake.queryOnce(
        init.gpa,
        init.io,
        "frostlake://localhost:18082",
        "CREATE DATABASE IF NOT EXISTS MY_DB",
        &.{},
    );
    created.deinit();

    var conn = try frostlake.Connection.open(
        init.gpa,
        init.io,
        "frostlake://localhost:18082/MY_DB?schema=PUBLIC",
    );
    defer conn.close();

    _ = try conn.exec("CREATE OR REPLACE TABLE PEOPLE (ID INTEGER, NAME VARCHAR)", &.{});
    _ = try conn.exec(
        "INSERT INTO PEOPLE VALUES (?, ?), (?, ?)",
        &.{ .of(1), .of("Ada"), .of(2), .of("Grace") },
    );

    var rows = try conn.query("SELECT ID, NAME FROM PEOPLE ORDER BY ID", &.{});
    defer rows.deinit();

    var it = rows.first().iterator();
    while (it.next()) |row| {
        std.debug.print("{d} {s}\n", .{
            try (try row.get("ID")).asInt(),
            try (try row.get("NAME")).asText(),
        });
    }
}
```

A worked example lives in [examples/demo.zig](examples/demo.zig):

```sh
zig build example -- frostlake://localhost:18082
```

### The `Io` parameter

Zig 0.16 passes an I/O implementation explicitly rather than reaching for a global, and this
driver does the same: `Connection.open` takes the `std.Io` you hand it and every socket
operation below runs on it. In a normal program that is `init.io`; in a test it is
`std.testing.io`. Nothing in the driver creates one for you, so what "blocking" means stays
your decision rather than the library's.

### DSN

```
frostlake://host:port[/DATABASE][?param=value&…]
```

| Parameter | Meaning | Default |
| --- | --- | --- |
| `schema` | schema to `USE` on every new session | — |
| `role` | role to `USE` on every new session | — |
| `warehouse` | warehouse to `USE` on every new session | — |
| `database` | an alternative to naming it in the path | — |
| `timeout` | how long to spend reaching the server: `5m`, `30s`, `1500ms`, `0` to disable | `5m` |
| `tz` | fixed UTC offset the engine's zoneless timestamps belong to: `UTC`, `+02:00`, `-0500` | `UTC` |
| `tls` | `true` to speak HTTPS — an `https://` DSN does the same | `false` |

The role, warehouse, database and schema are applied as `USE` statements on the session before
its first statement. An unknown parameter is an error rather than a silent no-op, and so is a
username or password — the engine's HTTP API has no authentication to hand them to.

## Semantics

- **Parameters** are inlined client-side (the protocol has no server-side binding), with the
  same rules as Frostlake's JDBC driver: strings escape backslashes and quotes, `Value.bytes`
  binds as a hex `BINARY` literal, a `Timestamp` as a `TIMESTAMP_NTZ` or `TIMESTAMP_TZ` literal
  depending on whether it carries an offset. A `?` inside a string literal, quoted identifier,
  `$$…$$` body or comment is never a placeholder. Whenever arguments are supplied the count
  has to match the placeholder count exactly; with none at all the `?` marks pass through to
  the server, which is where a Snowflake Scripting cursor binds them (`OPEN c USING (...)`).
  A negative number is rendered in parentheses, so `3-?` bound `-5` stays an expression
  rather than opening a `--` comment.
- **Values** are a tagged union. `Value.of(x)` infers the variant from `x`'s Zig type; the
  cases a type cannot distinguish are named instead — `Value.bytes` for `BINARY` (because
  `[]const u8` is Zig's string type too), `Value.decimalText` for digits to keep exact,
  `Value.jsonText` for a VARIANT, `Value.rawSql` to inline SQL verbatim. A union literal such
  as `.{ .integer = 1 }` always works too.
- **Named parameters**: a statement may use positional `?` or named `:name` placeholders — one
  style per statement, mixing them is an error. Named arguments bind by name, so their order
  does not matter, and one that names no placeholder is an error rather than a quiet no-op. A
  `::` cast, a `:=` assignment and a `:1` positional reference are never parameters — and
  neither is Snowflake's VARIANT path access: a colon glued to the end of an expression
  (`v:field`, `PARSE_JSON('…'):k`, `"V":k`) reads a field, so a bind marker must follow an
  operator, comma or keyword boundary (`WHERE x = :a`). Passed to `query` with **no arguments
  at all**, colon references pass through to the server untouched — that is what Snowflake
  Scripting variables look like (`EXECUTE IMMEDIATE :v`, `IFF(:flag, …)`).
- **Types**: `DATE`, `TIME` and every `TIMESTAMP` variant read as `Date`/`Time`/`Timestamp`;
  `BINARY` as bytes; integral `NUMBER` columns as `i64`; `BOOLEAN` as `bool`;
  VARIANT/OBJECT/ARRAY as their JSON text.
- **Exact numbers stay exact.** A `NUMBER` with a scale — `NUMBER(12,2)`, what money lives in —
  reads back as its digits, not as an `f64`. Reading `135500.50` into a float gives `135500.5`,
  and `0.1` into a float gives something that is not `0.1`; both are the wrong value, not a
  formatting detail. `FLOAT`/`DOUBLE`/`REAL` are binary floats and read as `f64`, because that
  is what those columns actually hold. An integer too wide for `i64` — `NUMBER(38,0)` holds
  them — arrives as its exact digits too. Every one of these still answers `asFloat()` for a
  caller who wants a number. Going the other way, a bound `f64` is written with an explicit
  `::FLOAT`, because a bare numeral is fixed-point: the account types `1.5` as `NUMBER(2,1)` and a
  whole `2.0` as `NUMBER(1,0)`, the integer `2`'s own type, and an exponent does not change that.
  The cast is what makes a bound double arrive as the `FLOAT` Snowflake's own driver produces.
- **Column metadata** reports the engine's type name, nullability, and precision and scale for
  numeric columns. Nullability is three-valued: a server predating the field reads `.unknown`,
  which is worth telling apart from "not nullable". A text or binary column also reports
  `length`, its declared width — characters for `VARCHAR`, bytes for `BINARY`, and `16777216`
  for an unbounded one, the most it could hold. Every other type has none and reads `null`,
  which is also what a server predating that field reads as; `0` is never invented for it.
- **Several statements in one request**: `A; B` answers with one result set each, once the
  session has asked for a pack — `ALTER SESSION SET MULTI_STATEMENT_COUNT = 0` for any
  number, or `= n` for exactly n. A request holds one statement until it does, and a pack
  the caller did not ask for is refused with `Actual statement count N did not match the
  desired statement count D.` `Response.set(i)` walks them, and `rowsAffected` adds up the
  DML counts.

  `queryWith` and `executeWith` say it for one request instead, through
  `ExecuteOptions.multi_statement_count`:

  ```zig
  var response = try conn.queryWith("SELECT 1; SELECT 2", &.{}, .{ .multi_statement_count = 2 });
  defer response.deinit();
  ```

  The count outranks the session's `MULTI_STATEMENT_COUNT` for that request and changes no
  session state, so nothing has to be saved and put back; `0` accepts any number. Left out —
  as `query` and `execute` leave it — the request carries no such field at all and the
  session's value decides, exactly as before.
- **Errors** are a Zig error set plus a diagnostic record. `Error.EngineRefused` means the
  engine reported the statement as failed; `Error.TransportFailed` means the request never
  became an answer; `Error.NotFrostlake` means something answered but not an engine;
  `Error.SessionLost` means the statement did not run because the engine no longer holds the
  session it depended on (see [Session lifetime](#session-lifetime)). The detail lives on the
  connection:

  ```zig
  conn.query("SELECT * FROM missing", &.{}) catch |err| {
      if (err == frostlake.Error.EngineRefused) {
          std.log.err("engine refused: {s}", .{conn.lastError()});
      }
  };
  ```

  **`conn.lastStatement()` holds the rendered SQL.** Because binding is client-side, that means
  every parameter inlined — a bound password or card number appears in it verbatim.
  `lastError()` carries none of it, so log that freely and treat `lastStatement()` as sensitive.
- **Transactions**: `begin`/`commit`/`rollback` ride the session's autocommit flag plus
  `BEGIN`/`COMMIT`/`ROLLBACK` statements, matching the JDBC transport. The engine offers read
  committed and nothing else, so there is no isolation level to choose. A `commit` that fails
  attempts a rollback and then retires the connection rather than leaving one whose state the
  driver had to guess at.
- **A broken connection is retired, never retried.** When the transport fails — the host
  refuses, the socket dies, the answer is not a Frostlake response — the connection is marked
  unusable and every later call on it fails fast. The statement is *not* re-run: after a
  transport failure its fate is unknown, and re-running it would duplicate an `INSERT`.
- **Sessions**: one HTTP session per `Connection`. A statement that moves the session's scope —
  `USE`, the `SET` family, `ALTER SESSION`, and `CREATE`/`DROP` of a `DATABASE` or `SCHEMA` —
  is therefore scoped to that one connection. Every statement in a request is examined, so a
  `USE` riding behind a leading `SELECT` counts too. `conn.reset()` puts the session back on
  the DSN's scope for a connection being reused across unrelated work; with no scope in the DSN
  there is nothing to restore, so it retires the connection instead.

  Two routes still move the scope without the driver seeing it — `EXECUTE IMMEDIATE` of a
  `USE`, and a procedure that switches scope when `CALL`ed — so prefer naming the scope in the
  DSN when it matters.

### Session lifetime

The engine keeps a session until it is released or has sat idle for 30 minutes, and a restart
loses every one. From 0.1.0 the engine says so: each answer carries `newSession`, and a request
can ask it to refuse a session it no longer holds rather than quietly start a fresh one under
the same id. The driver learns which kind of engine it talks to from the first answer that names
a session; `conn.session_id` is that session's id.

- **What is sent.** Once the engine has answered with `newSession`, every request naming the
  session carries `"requireSession":true`. An engine before 0.1.0 is sent neither that field nor
  the release below.
- **After a lost session.** The engine refuses the request (HTTP 404) and nothing ran. The
  driver drops the session, then:
  - if a transaction was open on it — `begin`, or a `BEGIN` / `START TRANSACTION` statement —
    the statement fails with `Error.SessionLost`: the transaction is gone and the statement did
    not run. A transaction `begin` opened stays dead until it is ended: every statement is
    refused with the same error without being sent, `begin` answers
    `Error.InvalidTransactionState`, `commit` fails with `Error.SessionLost` (nothing was
    committed), and `rollback` succeeds without a round trip, since the engine discarded the
    transaction with the session;
  - else, if a statement on the session set up context a fresh session would not have — `USE`,
    `SET`/`UNSET`, `ALTER SESSION`, a temporary object, `CREATE`/`DROP` of a `DATABASE` or
    `SCHEMA` — the statement fails with `Error.SessionLost` and is not re-run, since a fresh
    session would run it somewhere else;
  - otherwise the DSN's scope (`USE ROLE`/`WAREHOUSE`/`DATABASE`/`SCHEMA`) goes onto a fresh
    session and the statement is sent once more. A second refusal fails with
    `Error.SessionLost`.

  Every statement of a request is examined, so a `USE` riding behind a leading `SELECT` counts
  too, and `conn.reset()` putting the DSN's scope back counts as a fresh start. After the error
  the connection stays usable: its next statement starts a fresh session on the DSN's scope.
  `lastError()` says what went with the session, and `lastStatement()` names the statement that
  did not run.

  ```zig
  _ = conn.exec("INSERT INTO people VALUES (4, 'Edsger')", &.{}) catch |err| {
      if (err == frostlake.Error.SessionLost) {
          // redo the unit of work
      }
  };
  ```

  Against an engine before 0.1.0 none of this can happen: it re-creates a lost session under
  the same id at the server's default scope and says nothing, and the idle re-scope below is the
  only guard.
- **Close.** `conn.close()` sends `DELETE /api/sessions/{id}`, which releases the session and
  rolls back a transaction it left open. It is a courtesy: the request races a timer set to the
  shorter of the DSN's `timeout` and five seconds, connecting included, and whatever it meets —
  a 404, a 405, a closed socket, no answer — `close` still succeeds. A connection that never ran
  a statement, one closed a second time, and one talking to an engine before 0.1.0 send nothing.
  The race needs a unit of concurrency from the `Io`; one with none to spare sends the release
  unbounded.

## Known limitations

- **Against an engine before 0.1.0, server sessions are not released on close.** Those engines
  have no endpoint for ending a session, so a closed connection's session lingers until the
  engine's own 30-minute idle sweep reclaims it. Connection churn therefore accrues server-side
  sessions — enough of them will take the server down, so prefer holding a connection over
  opening one per query.
- **Against an engine before 0.1.0, a session idle past that sweep silently resumes at the
  server's default scope**, because such an engine re-creates an expired session under the same
  id and nothing in its answer says so. The driver covers this by re-establishing the DSN's scope
  on a connection idle for more than five minutes, but anything else the session held — session
  variables, an `ALTER SESSION` setting — is gone.
- **`timeout` is not enforced on Zig 0.16.0.** The driver hands the DSN's `timeout` to
  `std.http.Client.connectTcpOptions`, whose `timeout` field the 0.16.0 standard library
  declares but never reads (and whose Windows connect path has no timed variant yet), so an
  unreachable host waits for the operating system's own connect timeout and a statement that
  runs forever on the server is still waited for. This is a limit of the standard library
  rather than a choice, and it is spelled out here rather than left for you to discover. The
  release `close` sends is the exception: it races a timer (see
  [Session lifetime](#session-lifetime)).
- **`tz` is a fixed offset, not a zone.** Zig ships no IANA zone database, so `Europe/Warsaw`
  could only be honoured by guessing one of its two offsets. A zone name is refused with a
  message saying so rather than silently resolved to one that is wrong for half the year.
- **Timestamps lose sub-millisecond precision in transit.** The engine holds full nanoseconds,
  but the HTTP layer serialises milliseconds, so a `Timestamp` round trip is millisecond-precise
  however fine the value bound.
- **The connection is not threadsafe.** One `Connection` is one session; share one across
  threads and their statements interleave on it. Give each thread its own.
- **An array holding a VARIANT `undefined` cannot be read.** Engine 0.0.7 renders it as the
  bare token `undefined`, which is not JSON, so the answer to `FILTER(ARRAY_CONSTRUCT(1, NULL,
  2), …)` and its kind is a body no strict parser accepts. The driver reports that specifically
  rather than as a generic protocol mismatch, but it cannot read the value; the fix belongs on
  the server.
- **On engines before 0.1.0 an empty statement is refused by the endpoint, not the parser.** Their
  `POST /api/execute` rejects a blank `sql` itself with `SQL is required`, so the engine's own
  `Empty SQL statement.` message never reaches a client over HTTP. From 0.1.0 a blank statement
  runs and fails with that message.

## Tests

The unit tests need nothing installed — no engine, no JVM, no network:

```sh
zig build test
```

They cover the parts the driver decides on its own: DSN parsing, which characters are bind
markers, what each value renders as, how a cell is typed, and — over a mock transport — how a
connection keeps its session's scope, retires itself, runs a transaction, and handles a lost
session; closing is also checked against a loopback server that answers its release badly or not
at all.

The integration tests talk to a running engine and skip themselves when `FROSTLAKE_URL` names
none, so they are never falsely green:

```sh
FROSTLAKE_URL=frostlake://localhost:18082 zig build test-integration
```

`zig build test-all` runs both.

With `FL_CORPUS` naming the frostlake repo's testkit directory, the integration run also replays
the engine's testkit corpus — its language-neutral JSON suites — through this driver against the
same engine; without it that test is skipped:

```sh
FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit \
FROSTLAKE_URL=frostlake://localhost:18082 zig build test test-integration
```

`zig build test-suites` replays the corpus alone. A relative `FL_CORPUS` resolves against the
directory `zig build` runs in, so an absolute path is safest.

Expect `CONNECTION_REFUSED` traces on stderr during the integration run. They come from
`std.Io`'s happy-eyeballs connect: `localhost` resolves to both `::1` and `127.0.0.1`, the
engine binds one of them, and the standard library prints the failed half before succeeding on
the other. The tests pass regardless.

## License

Apache-2.0 — see [LICENSE](LICENSE).
