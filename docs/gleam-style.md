# Gleam for Loom — style, idiom, and a brief language tour

*This guide distills conventions observed across the official `gleam-lang`
repositories (stdlib, otp, erlang, json, http, gleeunit, the language tour,
and the official [conventions, patterns, and anti-patterns
document](https://gleam.run/documentation/conventions-patterns-and-anti-patterns/))
into the house style for Loom. Gleam
is a new language for most contributors, so Part I is a compact feature tour;
Parts II–III are the style and idiom rules; Part IV is Loom-specific policy
layered on top (see `docs/loom-implementation-spec.md` §0.2 for the normative
version).*

---

## Part I — A brief tour of the language

Gleam is a small, statically typed, immutable, expression-based language that
compiles to Erlang (our target) and JavaScript. The fastest way to build the
right mental model is by what it deliberately **does not have**:

- **No loops.** Iteration is recursion, almost always via `gleam/list`
  functions (`map`, `filter`, `fold`, …).
- **No `if`/`else`.** All flow control is `case` pattern matching, with
  compiler-checked exhaustiveness.
- **No early return.** Everything is an expression; a function's value is its
  last expression.
- **No null.** `Nil` is a unit type, not a member of other types. Absence is
  modeled with `Option(a)`.
- **No exceptions.** Fallible functions return `Result(a, e)` and the
  compiler forces callers to handle both cases.
- **No mutation.** Rebinding with `let` shadows; it never mutates. Records,
  lists, and dicts are persistent data structures.
- **No overloading, no macros, no type classes, no OOP, no reflection.**
  First-class functions and pattern matching are the whole toolkit. (The
  no-reflection property is load-bearing for Loom's code-mode security model
  — see `docs/loom-design.md` §6.2.)

### Bindings, blocks, and expressions

```gleam
let x = "Original"
let x = "New"          // rebinding shadows; nothing was mutated
let _ignored = 1000    // leading underscore silences unused warnings

let celsius = { fahrenheit - 32 } * 5 / 9   // blocks group; last expr is the value
```

Type annotations on `let` are legal but unidiomatic — annotate functions, not
bindings.

### Numbers, strings, bools

Operators are not overloaded: `Int` uses `+ - * / %`, `Float` uses
`+. -. *. /.` and `>.`-style comparisons. `<>` concatenates strings. Use
underscores in long literals: `1_000_000`. On the Erlang target integers are
arbitrary precision; division by zero is defined as zero (stdlib offers
`Result`-returning alternatives). `&&`/`||` short-circuit.

### Lists and tuples

`List(a)` is an immutable singly-linked list: prepending (`[x, ..rest]`) is
cheap; indexing is not — if you need random access, a list is the wrong
structure. Tuples `#(1, 2.2, "three")` are for quick ad-hoc grouping; reach
for a named record once a tuple crosses a function boundary or grows past two
or three elements.

### Custom types and records

```gleam
pub type SchoolPerson {
  Teacher(name: String, subject: String)
  Student(name: String)
}

let teacher = Teacher(name: "Ms Doe", subject: "ICT")
let renamed = Teacher(..teacher, name: "Ms Ray")   // record update: a new value
```

A single-variant custom type whose variant shares the type's name is Gleam's
struct. Field access via `record.name` works across variants only when the
field has the same name, position, and type in every variant; otherwise
pattern-match first. Type parameters are lowercase names:
`pub type Option(inner) { Some(inner) None }`.

### Pattern matching

`case` is the only conditional, and its exhaustiveness checking is the
language's headline refactoring tool:

```gleam
case lists, limit {
  [], _ -> []
  [first, ..] , l if first > l -> [first]     // guards: no function calls allowed
  [_, ..rest], l -> search(rest, l)
}
```

Patterns compose: multiple subjects (`case x, y`), alternatives
(`2 | 4 | 6 -> ...`), aliases (`[_, ..] as pair`), string prefixes
(`"Hello, " <> name -> ...`), list shapes (`[_, _, ..]`), and bit arrays
(`<<len:size(16), rest:bits>>`).

### Recursion and tail calls

Loops are written as recursion with an accumulator; the tail-recursive worker
is a private function suffixed `_loop`, and the accumulator never leaks into
the public signature:

```gleam
pub fn factorial(x: Int) -> Int {
  factorial_loop(x, 1)
}

fn factorial_loop(x: Int, accumulator: Int) -> Int {
  case x {
    0 | 1 -> accumulator
    _ -> factorial_loop(x - 1, accumulator * x)
  }
}
```

### Result, Option, Nil

`Result(a, e)` is the error channel; `Option(a)` is a data-modeling type.
The official policy (from the stdlib's own docs): **all fallible functions
return `Result`** — `Nil` as the error when there is nothing to say — and
`Option` is only for optional values in arguments and data structures.

```gleam
pub type PurchaseError {
  NotEnoughMoney(required: Int)
  NotLuckyEnough
}

fn buy_pastry(money: Int) -> Result(Int, PurchaseError) {
  case money >= 5 {
    True -> Ok(money - 5)
    False -> Error(NotEnoughMoney(required: 5))
  }
}
```

### `use` expressions

`use` is sugar for passing the rest of the block as a final-argument
callback. It is how Gleam recovers flat, readable error propagation without
exceptions or early returns:

```gleam
pub fn log_in() -> Result(String, Nil) {
  use username <- result.try(get_username())
  use password <- result.try(get_password())
  use greeting <- result.map(authenticate(username, password))
  greeting <> ", " <> username
}
```

Everything below a `use` line becomes `fn(username) { ... }` passed to
`result.try`. The same mechanism powers `bool.guard` (early-exit),
`decode.field` (decoders), and resource-scoping helpers. Overuse hurts
clarity: keep the right-hand side a simple call, and prefer a plain function
call when `use` buys no indentation.

### Labelled arguments

Labels make call sites read as prose, cost nothing at runtime, and may be
reordered or omitted:

```gleam
pub fn fold(over list: List(a), from initial: acc, with fun: fn(acc, a) -> acc) -> acc

list.fold(over: items, from: 0, with: int.add)
```

The shorthand `Cat(name:, lives:)` punning collapses `name: name` — used
heavily in both construction and destructuring (`let Request(headers:, ..)`).

### Opaque types

`pub opaque type` exports the type but not its constructors, so invariants
can be enforced by smart constructors — the module boundary becomes a proof
boundary:

```gleam
pub opaque type PositiveInt {
  PositiveInt(inner: Int)
}

pub fn new(i: Int) -> PositiveInt {
  case i >= 0 {
    True -> PositiveInt(i)
    False -> PositiveInt(0)
  }
}
```

### The crash ladder

Four escalating crash mechanisms, all supporting `as "message"`, all
discouraged outside their niche:

| Construct | Meaning | Where it's acceptable |
|---|---|---|
| `todo` | unfinished code (compiler warns) | during development only |
| `panic` | "this is unreachable" | almost never; prefer types that make the state impossible |
| `let assert Ok(x) = ...` | partial pattern, crash on mismatch | tests; documented invariants |
| `assert expr` | boolean check, crash on `False` | test code |

### Externals and targets

`@external(erlang, "module", "function")` binds a Gleam signature to foreign
code; the annotation is trusted unchecked, so FFI is the one place where the
type system takes your word for it. External types
(`pub type Pid` with no constructors) name foreign values without exposing
structure. A function can carry an external for one target and a Gleam body
as the fallback for the other. Details and house rules in Part III.

---

## Part II — Code style

### Formatting

`gleam format` is canonical and has no configuration. All code is formatted;
CI runs `gleam format --check`. Never hand-align anything; never argue with
the formatter. Build with `--warnings-as-errors` in CI; no warnings in
committed code.

### Naming

The compiler enforces `snake_case` for values/functions/modules and
`PascalCase` for types and constructors. On top of that, the official
conventions:

- **Write names in full.** `capacity`, not `cap`; `process_data(session)`,
  not `proc_dat(ss)`. The ecosystem uses full words even for long names
  (`absolute_value`, `exclusive_or`).
- **Acronyms are single words**: `Json`, `parse_http` — never `JSON`.
- **Module names are singular** (`loom/register`, not `loom/registers`), one
  concept per module, path segments included.
- **No design-pattern or category-theory names.** `monadic_bind`,
  `app/utilities`, `Monoid` — all officially called out as anti-patterns.
  Name things for the domain.

The stdlib's verb vocabulary is consistent enough to treat as a contract —
reuse it rather than inventing synonyms:

| Name shape | Meaning | Examples |
|---|---|---|
| `map` | transform the inner value(s) | `list.map`, `result.map` |
| `try` / `try_*` | same, but the callback is fallible and short-circuits | `result.try`, `list.try_map`, `list.try_fold` |
| `fold` | accumulate; callback is `fn(acc, a) -> acc`, accumulator first | `list.fold`, `list.index_fold` |
| `each` | side effects, returns `Nil` | `list.each` |
| `filter_map` | keep the `Ok`s | `list.filter_map` |
| `is_*` | predicate | `is_empty`, `is_ok` |
| `to_*` / `from_*` | conversion | `to_string`, `from_list` |
| `x_to_y` | conversion when both ends need naming | `method_to_string` |
| `parse_*` | fallible from-string | `parse_method` |
| `lazy_*` | thunk instead of eager value | `lazy_unwrap`, `lazy_guard` |
| `new` | empty/default constructor | `dict.new`, `request.new` |
| `*_loop` | private tail-recursive worker | `map_loop`, `parse_body_loop` |
| `do_*` | private per-target or arg-order-adapting impl | `do_insert`, `do_parse` |
| `*_forever` | infinite-timeout variant | `receive_forever`, `call_forever` |

Drop redundant type prefixes when the module carries the type's name:
`identifier.to_string`, never `identifier.identifier_to_string`. Getters
have no `get_` prefix unless paired with a `set_` (`get_header`/`set_header`).

### Module organization

- **Do not prematurely split modules.** Large modules are not a problem; the
  official conventions doc explicitly warns that fragmenting into
  `client`/`config`/`error`/`types` modules is an anti-pattern "especially
  common with AI-generated code." Split by business domain
  (`loom/storage`, `loom/lane`), never by kind (`loom/types`,
  `loom/helpers`).
- All modules live under the package's namespace directory
  (`src/loom_core.gleam` + `src/loom_core/...`); never place modules in
  another package's namespace.
- Code that must be `pub` for testing but is not API goes in
  `internal` modules (the default `internal_modules` glob covers
  `$PACKAGE/internal[/*]`), or is marked `@internal`.
- Three source directories with strict roles: `src` (may import only
  dependencies and `src`), `test`, and `dev` (both may import anything).
- Tool configuration lives in `gleam.toml` under `[tools.*]`, not in
  standalone config files.

### Imports

Functions and constants are used **qualified** (`list.reverse`, not
`import gleam/list.{reverse}`). Types are commonly imported unqualified with
the `type` keyword, along with ubiquitous constructors:

```gleam
import gleam/erlang/process.{type Pid, type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor.{type Supervisor} as supervisor
```

Module aliasing (`as supervisor`) is fine when it improves call sites.

### Type annotations

Annotate **all module functions** — arguments and return type, private
functions included (the stdlib annotates its `_loop` workers too). Do not
annotate `let` bindings.

### Doc comments

`////` for module docs at the top of the file; `///` on every public
function, type, and even individual record fields and variants. Function
docs use an `## Examples` section (plural, even for one), each example in
its own fenced block, calling the function module-qualified, written as a
runnable `assert`:

```gleam
/// Returns the first element of a list, if there is one.
///
/// ## Examples
///
/// ```gleam
/// assert list.first([]) == Error(Nil)
/// ```
///
/// ```gleam
/// assert list.first([0]) == Ok(0)
/// ```
///
pub fn first(list: List(a)) -> Result(a, Nil)
```

For side-effecting or nondeterministic examples, use the `// -> result`
comment convention instead of `assert`. Docs also state complexity and
per-target behavior where relevant ("runs in linear time", "constant time on
Erlang, linear on JavaScript"), and every function that can panic documents
it under a `# Panics` heading. Module docs may be long-form tutorials —
`gleam/otp/actor` and `gleam/dynamic/decode` both carry ~150+ line worked
examples, and the otp repo compiles its module-doc example as a real test.

### Plain comments

Comment liberally — the *why*, constraints the code can't show, algorithm
explanations inside `case` arms, RFC citations. `//` comments go on the line
before the item, never trailing.

### Deprecation

`@deprecated("Use x instead")` with a message that names the replacement;
deprecate for a release cycle, then remove.

---

## Part III — Idiomatic Gleam

### Error handling

- **`Result` for everything fallible; `Option` never signals failure.**
  `Result(a, Nil)` is the default when the caller needs no explanation
  (`list.first`, `dict.get`, `int.parse` all return it). Introduce an error
  ADT only when callers genuinely branch on the cause.
- **Design descriptive errors.** Variants named for the domain failure, each
  carrying context: `NoteCouldNotBeRead(path: String, reason: FileError)`.
  Wrapping a dependency's raw error as your entire error type is an
  anti-pattern.
- **Chain with `use` + `result.try`/`result.map`**, `bool.guard` for early
  exits (`use <- bool.guard(when: input == "", return: Error(Nil))`). Nested
  `case` on `Result`s is a smell; `case` is for ADT dispatch.
- **Never check-then-assert** (`result.is_ok` followed by
  `let assert Ok(..)`) — pattern match once.
- **Avoid catch-all `_ ->` patterns.** Exhaustiveness checking is how the
  compiler finds every site affected by a new variant; a catch-all disables
  it. Match variants explicitly unless the type is genuinely open-ended.
- **Libraries must not panic.** `panic`/`let assert` in library code is
  reserved for documented invariant violations where crashing the process is
  the design (OTP supervision absorbs it) — and then always with an
  `as "message"` explaining the invariant:

```gleam
let assert Ok(pid) = named(name) as "Sending to unregistered name"
```

### Type design

- **Make invalid states impossible.** Prefer
  `LoggedIn(id: Int, email: String) | Guest` over
  `User(id: Option(Int), email: Option(String))`. Encode invariants in
  constructors, not in runtime checks.
- **Replace booleans with two-variant custom types** when the meaning isn't
  obvious at the call site: `role: Role` (`Student | Teacher`) over
  `is_student: Bool`.
- **Opaque types guard invariants**: anything with a validity condition
  (`Subject`, `Set`, `Decoder`) is `pub opaque type` with smart
  constructors. External types (`pub type Pid` — no constructors at all)
  name foreign values.
- **Small private enums beat boolean parameters** internally too:
  `type Direction { Leading Trailing }`.
- **Dicts are second-class.** No literal syntax, no pattern matching, no
  ordering guarantees; custom types with named fields are the default for
  structured data.
- Type aliases add no safety and are used rarely — mostly to shorten
  recurring shapes (`pub type Header = #(String, String)`, with invariants
  documented and enforced by functions) or re-export
  (`pub type Dynamic = dynamic.Dynamic`).
- Descriptive type variables where the parameter is domain-relevant:
  `Request(body)`, `fn set_body(req: Request(old_body), body: new_body) ->
  Request(new_body)`; single letters (`a`, `e`, `k`, `v`, `acc`) elsewhere.

### Pipelines and function values

APIs put the subject first so `|>` works; one step per line for chains of
three or more. The capture shorthand `f(x, _)` pipes into a non-first
position; use it sparingly. Pass named functions directly when arity fits
(`list.map(names, string.uppercase)`), otherwise a literal `fn(x) { ... }`.
Point-free composition is un-Gleam — the stdlib removed its `compose`/`tap`
helpers.

```gleam
string
|> string_tree.from_string
|> string_tree.reverse
|> string_tree.to_string
```

### The builder pattern

The house pattern for configurable construction, used identically by
`actor`, `static_supervisor`, and HTTP requests: an (often opaque) record,
`new` with sensible defaults, pipeable setters using record-update syntax
and label punning, and a terminal verb:

```gleam
pub fn start_supervisor() -> actor.StartResult(Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(database_pool.supervised())
  |> supervisor.add(http_server.supervised())
  |> supervisor.start
}
```

Setters are two-liners: compute the new field into a `let` named after the
field, then `Request(..request, headers:)`.

### Core libraries and the sans-io pattern

Use the maintained core packages — `gleam_stdlib`, `gleam_erlang`,
`gleam_otp`, `gleam_json`, `gleam_http`, `gleam_time` — rather than
replicating what they provide; they are the ecosystem's shared foundation.
`gleam_http` also models the official **sans-io pattern** for API surfaces:
a package of pure types plus request-builder and response-parser functions,
with the actual I/O supplied by the caller. Loom's effect plane is this
pattern writ large — pure planning in `loom_machine`, I/O only at the
broker — so prefer sans-io shapes for any protocol code.

### Decoders and encoders

JSON/dynamic decoding uses `gleam/dynamic/decode` with `use`-chained fields
ending in `decode.success` + punned construction (older
`dynamic.field` pipelines are obsolete):

```gleam
let cat_decoder = {
  use name <- decode.field("name", decode.string)
  use lives <- decode.field("lives", decode.int)
  decode.success(Cat(name:, lives:))
}
```

Encoders are plain `t -> Json` functions composed with `json.object`
tuple-lists and `json.array(items, of: encoder)`; `Option` maps to null via
`json.nullable(from: value, of: encoder)`.

### Processes, actors, supervision

Loom is OTP-shaped, so the `gleam_otp`/`gleam_erlang` idioms are our bread
and butter:

- **Message types: one variant per message, labelled fields, replies carry a
  `Subject`** conventionally named `reply_with:`/`reply_to:`:

```gleam
pub type Message(element) {
  Shutdown
  Push(push: element)
  Pop(reply_with: Subject(Result(element, Nil)))
}
```

- **Wrap the message API in functions.** Callers get `stack.push(subject, x)`
  and `stack.pop(subject, timeout)`, not raw message constructors. `call`
  takes the constructor partially applied:
  `process.call(subject, waiting: 100, sending: Pop)`.
- **Actors via the builder**: `actor.new(state) |> actor.on_message(handle)
  |> actor.start`; handlers are `fn(state, msg) -> actor.Next(state, msg)`
  returning `actor.continue(state)` / `actor.stop()`. Selectors merge
  differently-typed subjects (`new_selector() |> select_map(subject, Wrap)`).
- **Every startable thing exposes `start` and `supervised()`** — the latter
  returns a `ChildSpecification` for embedding in a supervision tree, and is
  the one you should normally use. Supervisors compose the same way
  (`supervisor.new(strategy) |> supervisor.add(child.supervised())`).
- **Failure philosophy is split deliberately**: `receive` returns `Result`
  (timeout is expected); `call` **panics** on timeout or callee death — a
  crashed caller under supervision beats a process in an invalid state.
  Timeouts are plain `Int` milliseconds with a labelled argument; "forever"
  is a separate function, not a magic value.

### FFI

FFI is the guarded escape hatch — both in official guidance ("most projects
won't use any at all") and in Loom's security model:

- **Design the Gleam API first**; never mirror the foreign API's shape.
  Define precise external types (`pub type ZipHandle`), **never `Dynamic`**,
  for foreign values.
- Erlang shims live in one flat `<package>_ffi.erl` module per package;
  prefer direct `@external` to stock OTP modules (`lists`, `maps`) when
  types line up. Externals still carry full Gleam signatures and labels.
- Erlang-side shims convert to Gleam conventions at the boundary: catch
  exceptions and return `{ok, X} | {error, nil}`; normalize raw terms into
  the shapes of Gleam variants.
- When an Erlang function returns a meaningless or leaky value, wrap it with
  the `DoNotLeak` idiom — the external returns a private empty type and a
  public wrapper discards it and returns `Nil`.
- Single-variant private types stand in for Erlang atoms so no atom is built
  at runtime: `type KillFlag { Kill }`.
- A `do_` wrapper adapts argument order when the foreign function isn't
  subject-first.

### Testing

- gleeunit: `test/<package>_test.gleam` has `pub fn main() {
  gleeunit.main() }`; every public function ending in `_test` anywhere under
  `test/` runs as a test. The test tree mirrors `src`.
- **Assert with the `assert` keyword** — `assert some_function() == "Hi!"` —
  not the deprecated `gleeunit/should` module. `let assert` destructures
  expected shapes (`let assert Error(json.UnexpectedByte(byte)) = result`);
  `panic as "..."` marks branches a test must not reach.
- **One small scenario per test, named for it**: `first_ok_test`,
  `from_list_duplicate_key_test`. Many micro-tests beat few mega-tests.
- Shared assertion helpers are plain local functions
  (`fn should_encode(data, expected)`); fixtures are local closures.

---

## Part IV — Loom-specific policy

These rules from the implementation spec (§0.2) are normative here and
tighten the ecosystem defaults:

1. **Toolchain**: Gleam ≥ 1.6, Erlang/OTP ≥ 27. `gleam format` enforced; no
   warnings.
2. **Total decoders**: every durability or wire boundary decodes with a
   `Decoder(t)` returning `Result(t, CorruptionReport)`. Partial decoding is
   a bug class, not a style choice — parse fully or report corruption.
3. **No `panic`/`let assert` outside tests**, except documented invariant
   violations that must fault the process (mirroring "failed admitted commit
   faults the harness"). Always with an `as "message"`.
4. **FFI confinement**: `@external` only in `*/internal/ffi_*.gleam`
   modules; every external carries a comment naming the OTP function used
   and why no pure alternative exists. CI greps enforce this.
5. **Purity layering**: `loom_core` and `loom_machine` are pure — no I/O
   imports at all. Effects live behind the broker; the state machine is
   `State × Inputs -> Action`.
6. **Time and identity are injected**: timestamps come from a `Clock`
   capability, ids from an injected UUIDv7 generator — never
   `erlang:system_time` or random bytes reached for directly.
7. **Documentation**: every public function documented; every ADT
   constructor's invariants stated in its doc comment.
