//// The vetting policy: the set of module names a submitted code-mode program
//// is permitted to import.
////
//// # Why this module is security-critical
////
//// Loom's code-mode security rests on a single principle (design §6.2): a
//// Gleam program's *maximal capability set* is the transitive closure of its
//// imports plus its own `@external` declarations. Pure Gleam cannot perform
//// I/O — every effect enters through an import that ultimately declares
//// `@external`. So if the linter forbids `@external` in submitted source and
//// confines imports to a curated allowlist, the program can reach nothing but
//// what that allowlist exposes. This module owns the allowlist and, more
//// importantly, the *comparison rule* that decides whether an import names an
//// allowlisted module. That comparison is where the adversary lives.
////
//// # The comparison rule: ASCII grammar gate, then byte-identical membership
////
//// An import name is accepted only if it (a) is a legal ASCII Gleam module
//// name and (b) is byte-identical to an allowlist entry. We deliberately do
//// **not** rely on Unicode normalization to defend against lookalikes.
//// Normalization (NFC/NFD) folds *canonically equivalent* sequences together,
//// but a Cyrillic `с` (U+0441) and a Latin `c` (U+0063) are distinct
//// characters, not normalization variants — no amount of normalization makes
//// them equal, and any normalization pass that *did* would be a vulnerability.
//// Instead we exploit a fact about the domain: legal Gleam module names are
//// built from ASCII identifier segments (`[a-z][a-z0-9_]*`) joined by `/`.
//// Every allowlist entry is such a name. Therefore any import name containing
//// a non-ASCII byte — a homoglyph, a fullwidth character, a zero-width joiner,
//// an NFD-decomposed sequence — is *definitionally* not a legal reference to
//// an allowlisted module, and is rejected by the grammar gate before the
//// membership test ever runs. The membership test itself is Gleam string
//// equality, which is byte equality; a name that differs by even one byte is
//// not a member. This is airtight and needs no Unicode tables.
////
//// # The default allowlist
////
//// The default (`default`) is the pinned capability prelude plus a curated,
//// provably-pure subset of the standard library. The exact `cap/*` module
//// names are owned by the prelude, so callers should prefer `new` with the
//// names the prelude actually ships; the default is the documented starting
//// point and the value the corpus tests exercise. See `default` for the
//// per-module justification.

import gleam/list
import gleam/set.{type Set}
import gleam/string

/// The allowlist of importable module names. Opaque so that the only way to
/// obtain one is through a constructor that fixes the membership set, and so
/// that the byte-identical comparison in `contains` is the sole membership
/// path — a caller cannot reach in and compare names some looser way.
pub opaque type VetPolicy {
  VetPolicy(allowed_imports: Set(String))
}

/// Build a policy from an explicit list of allowed module names. This is the
/// constructor the caller uses to inject the exact `cap/*` names the pinned
/// prelude ships, rather than trusting the built-in default.
///
/// The names are stored verbatim; no normalization is applied, because
/// membership is decided by byte-identical comparison (see the module doc).
///
/// ## Examples
///
/// ```gleam
/// let policy = policy.new(["cap/fs", "gleam/list"])
/// assert policy.contains(policy, "cap/fs")
/// ```
///
pub fn new(allowed_imports: List(String)) -> VetPolicy {
  VetPolicy(set.from_list(allowed_imports))
}

/// Add a module name to a policy's allowlist. A pipeable builder step for
/// composing a policy on top of `default` or `new`.
///
/// ## Examples
///
/// ```gleam
/// let policy = policy.default() |> policy.allow("cap/db")
/// assert policy.contains(policy, "cap/db")
/// ```
///
pub fn allow(policy: VetPolicy, module: String) -> VetPolicy {
  VetPolicy(set.insert(policy.allowed_imports, module))
}

/// The allowed module names, for auditing and error messages. Order is
/// unspecified (it is a set).
pub fn allowed_imports(policy: VetPolicy) -> List(String) {
  set.to_list(policy.allowed_imports)
}

/// Whether `module` is an allowlisted import under `policy`.
///
/// This is byte-identical membership: `module` is compared for exact string
/// equality (which on the Erlang target is byte equality) against the stored
/// names. It performs no grammar check itself — callers apply
/// `is_legal_module_name` first so that a non-ASCII lookalike is reported with
/// a precise reason. On its own, `contains` still rejects lookalikes, since a
/// homoglyph is never byte-equal to an ASCII allowlist entry.
///
/// ## Examples
///
/// ```gleam
/// let policy = policy.new(["cap/fs"])
/// assert policy.contains(policy, "cap/fs")
/// assert !policy.contains(policy, "cap/proc")
/// ```
///
pub fn contains(policy: VetPolicy, module: String) -> Bool {
  set.contains(policy.allowed_imports, module)
}

/// Whether `name` is a syntactically legal ASCII Gleam module name: one or
/// more segments joined by `/`, each segment a lowercase ASCII identifier
/// (`[a-z][a-z0-9_]*`).
///
/// This is the grammar gate described in the module doc, and it is the primary
/// defense against unicode-lookalike imports. Any character outside the ASCII
/// identifier alphabet — a Cyrillic or Greek homoglyph, a fullwidth Latin
/// letter, a zero-width joiner, a combining mark from an NFD decomposition, an
/// uppercase letter, a dot, a dash, whitespace — makes the name illegal and so
/// rejects it before any allowlist comparison. Fails closed: an empty name or
/// an empty segment (from a leading, trailing, or doubled `/`) is illegal.
///
/// ## Examples
///
/// ```gleam
/// assert policy.is_legal_module_name("cap/fs")
/// assert policy.is_legal_module_name("gleam/string_tree")
/// ```
///
/// ```gleam
/// // A Cyrillic 'с' (U+0441) in place of ASCII 'c'.
/// assert !policy.is_legal_module_name("сap/fs")
/// ```
///
pub fn is_legal_module_name(name: String) -> Bool {
  case string.split(name, "/") {
    [] -> False
    segments -> list.all(segments, is_legal_segment)
  }
}

/// Whether one `/`-delimited segment is a legal lowercase ASCII identifier.
/// A segment must be non-empty, start with `a`–`z`, and continue with
/// `a`–`z`, `0`–`9`, or `_`.
fn is_legal_segment(segment: String) -> Bool {
  case string.to_utf_codepoints(segment) {
    [] -> False
    [first, ..rest] ->
      is_lower_alpha(string.utf_codepoint_to_int(first))
      && list.all(rest, fn(cp) {
        is_ident_continue(string.utf_codepoint_to_int(cp))
      })
  }
}

/// Whether `code` is an ASCII lowercase letter (`a`–`z`, U+0061–U+007A).
fn is_lower_alpha(code: Int) -> Bool {
  code >= 0x61 && code <= 0x7a
}

/// Whether `code` may continue an identifier: a lowercase ASCII letter, an
/// ASCII digit (`0`–`9`), or an underscore.
fn is_ident_continue(code: Int) -> Bool {
  is_lower_alpha(code) || { code >= 0x30 && code <= 0x39 } || code == 0x5f
}

/// The default allowlist: the pinned capability prelude plus a curated subset
/// of the standard library whose public API is provably effect-free.
///
/// # The capability prelude (`cap/*`)
///
/// These are the typed capability modules whose implementations are RPC stubs
/// to the ToolBroker carrying the execution's token (design §6.2). They *are*
/// the effect surface a program is allowed to reach; every effect a submitted
/// program can have flows through one of them, token- and policy-checked at the
/// broker. The precise set is owned by the prelude package; this default tracks
/// the union named in design §6.2 and spec WP-J. Callers that know the exact
/// shipped set should pass it to `new`.
///
/// # The standard-library subset
///
/// Only modules whose *public API* is pure data transformation are included.
/// Such a module may use `@external` internally, but that FFI is compiled into
/// the pinned prelude, not re-exported: importing `gleam/string` grants the
/// caller string manipulation, not the ability to declare foreign functions.
/// Excluded, deliberately:
///
/// - `gleam/io` — its API writes to stdout, an effect that must instead flow
///   through `cap/report` where it is captured and audited.
/// - `gleam/erlang` and everything beneath it (`.../process`, `.../atom`,
///   `.../os`) — these expose processes, atom creation, and OS access as
///   effects; concurrency for submitted programs is `cap/task`/`cap/actor`.
/// - `gleam/otp/*` — supervision and actors reaching the real VM; out of reach
///   by the same reasoning.
/// - `gleam/dynamic` and `gleam/dynamic/decode` — pure in principle, but a
///   decoding surface a submitted program should not need (cap modules return
///   typed values). Left out until the prelude's API is shown to require it;
///   add via `allow` or `new` if so.
pub fn default() -> VetPolicy {
  new(list.append(default_cap_modules(), default_stdlib_modules()))
}

/// The capability-prelude modules in the default allowlist. The union of the
/// sets named in design §6.2 (`fs proc net git lsp task actor report`) and
/// spec WP-J (`fs proc git lsp report task actor kv`).
fn default_cap_modules() -> List(String) {
  [
    "cap/fs", "cap/proc", "cap/net", "cap/git", "cap/lsp", "cap/report",
    "cap/task", "cap/actor", "cap/kv",
  ]
}

/// The standard-library modules in the default allowlist. Every one has a pure,
/// effect-free public API (see `default`); none exposes I/O, processes, atom
/// creation, or an FFI-declaring surface to its caller.
fn default_stdlib_modules() -> List(String) {
  [
    "gleam/list", "gleam/string", "gleam/string_tree", "gleam/int",
    "gleam/float", "gleam/bool", "gleam/result", "gleam/option", "gleam/dict",
    "gleam/set", "gleam/order", "gleam/pair", "gleam/function",
  ]
}
