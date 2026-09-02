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
////
//// # Three seams over one mechanism
////
//// There are three allowlists, not one, and a submission is judged against
//// exactly one of them (`Seam`, `for_seam`):
////
//// - the **workspace** seam — `cap/{fs, proc, net, git, lsp, report, task,
////   actor, kv}` — a program that orchestrates *effects*;
//// - the **orchestration** seam — `cap/strand` and `cap/report`, and
////   nothing else — a program that orchestrates *agents*;
//// - the **extension** seam — the workspace seam plus `ext`, `cap/ext`
////   and the decoding half of the standard library — an installed
////   extension's tool, compiled once and run per call.
////
//// The first two are disjoint by construction and the third is
//// deliberately *not*: an extension is a workspace program with a
//// different entry point, so its allowlist is the workspace seam's
//// widened rather than a fourth set of capabilities that travel together.
//// The property that holds it is a superset claim rather than an
//// intersection (`extension_cap_modules`), and it is asserted for the
//// same reason the intersection is: so the relationship between the seams
//// is checked rather than assumed.
////
//// The separation is a rule about which capabilities travel together. An
//// orchestrator that could also write files, run a process, or reach the
//// network is a materially worse thing to hand a model than one that
//// cannot: a compromised orchestration program can spawn and message
//// within the lineage its own strand roots, and can touch neither the
//// disk, the network, nor a process. That property holds only while the
//// two sets stay disjoint in the capability dimension, which is why
//// `orchestration_cap_modules` and `default_cap_modules` share no entry
//// but `cap/report`, and a test pins the *intersection* rather than a
//// snapshot of either side. Both lists are public for that test's sake:
//// the seams also share `default_stdlib_modules`, so a capability added
//// to that shared list would widen both seams at once, and the property
//// that catches it has to be able to name the capability lists apart
//// from the allowlists they end up in.
////
//// Nothing else about the mechanism changes: this module was already an
//// opaque, per-submission allowlist, so two seams are a *configuration*
//// of machinery that exists rather than a second mechanism to get right.
//// Both directions of the confinement are the same one rule — an import
//// outside the allowlist the submission is judged against is rejected —
//// so an orchestration program reaching for `cap/fs` and a workspace
//// program reaching for `cap/strand` are refused by the same code, and
//// both refusals are the structured `ImportNotAllowed` rejection the
//// model reads and repairs in band.

import gleam/list
import gleam/set.{type Set}
import gleam/string

/// Which seam a submission is judged against. Three variants and no
/// fourth: the set of seams is closed here rather than left to whoever
/// builds a policy, so "which capabilities travel together" is a
/// decision this module owns and a caller selects from.
pub type Seam {
  /// The workspace seam: a program that orchestrates effects.
  WorkspaceSeam

  /// The orchestration seam: a program that orchestrates agents.
  OrchestrationSeam

  /// The extension seam: an installed extension's own source, judged at
  /// install and again at every load.
  ExtensionSeam
}

/// The allowlist a seam judges a submission against.
///
/// ## Examples
///
/// ```gleam
/// let allowed = policy.for_seam(policy.OrchestrationSeam)
/// assert !policy.contains(allowed, "cap/fs")
/// ```
///
/// ```gleam
/// let allowed = policy.for_seam(policy.WorkspaceSeam)
/// assert !policy.contains(allowed, "cap/strand")
/// ```
///
pub fn for_seam(seam: Seam) -> VetPolicy {
  case seam {
    WorkspaceSeam -> default()
    OrchestrationSeam -> orchestration()
    ExtensionSeam -> extension()
  }
}

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

/// Whether `name` names a module on the explicit denylist: `gleam/erlang` and
/// everything beneath it, and `gleam/otp` and everything beneath it.
///
/// This is redundant defense (CH-F1). These modules are already excluded by
/// omission from the allowlist, so `contains` alone rejects them; the denylist
/// exists so the rejection carries a *specific* reason — these modules expose
/// raw processes, atoms, OS access, and supervision reaching the real VM, and a
/// submitted program's concurrency is `cap/task`/`cap/actor` instead — and so a
/// future policy that mistakenly `allow`ed one still cannot let it through. The
/// vetting layer consults this before the allowlist for exactly that reason. It
/// does not close the transitive-dependency build-graph path (that is J3c
/// Builder work); it is a source-level import guard.
///
/// ## Examples
///
/// ```gleam
/// assert policy.is_denied("gleam/erlang/process")
/// assert policy.is_denied("gleam/otp/actor")
/// assert !policy.is_denied("gleam/list")
/// ```
///
pub fn is_denied(name: String) -> Bool {
  name == "gleam/erlang"
  || string.starts_with(name, "gleam/erlang/")
  || name == "gleam/otp"
  || string.starts_with(name, "gleam/otp/")
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

/// The default allowlist — the **workspace** seam: the pinned capability
/// prelude plus a curated subset of the standard library whose public API
/// is provably effect-free.
///
/// This is one of the two seams (`Seam`, `for_seam`); `orchestration` is
/// the other, and the two share no capability module but `cap/report`.
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

/// The orchestration seam's allowlist: `cap/strand`, `cap/report`, and the
/// same pure standard-library subset the workspace seam gets.
///
/// `cap/strand` is the whole of what an orchestration program may reach
/// out to, and `cap/report` is how it says what it found — a program that
/// could not build an outcome could not report a fan-out's answer at all.
/// Nothing else is here, and the omissions are the point rather than an
/// oversight: no `cap/fs`, no `cap/proc`, no `cap/net`, no `cap/git`, so a
/// compromised orchestrator reaches no disk, no process, and no socket.
/// `cap/task` and `cap/actor` are absent too, and they are the omission a
/// reader is most likely to think a mistake: an orchestration program does
/// not need local concurrency, because `strand.spawn` returns at admission
/// and `strand.wait` joins a whole list against one deadline — the fan-out
/// happens on the strands, not in the satellite.
///
/// ## Examples
///
/// ```gleam
/// assert policy.contains(policy.orchestration(), "cap/strand")
/// ```
///
/// ```gleam
/// assert !policy.contains(policy.orchestration(), "cap/proc")
/// ```
///
pub fn orchestration() -> VetPolicy {
  new(list.append(orchestration_cap_modules(), default_stdlib_modules()))
}

/// The extension seam's allowlist: the workspace seam's capabilities plus
/// the `ext` prelude, and the workspace seam's standard-library subset
/// plus the modules an extension needs to speak JSON.
///
/// A superset of the workspace seam, on purpose. An extension tool *is* a
/// workspace program — it reads files, runs processes, and (under
/// Decision 2 of the extension ruling) makes brokered HTTP requests — so
/// carving it a fourth, narrower capability set would buy nothing and
/// would have to be kept in step by hand. What it additionally needs is
/// the vocabulary its entry point is typed against (`ext`), the client
/// that fetches the call (`cap/ext`), and enough of the standard library
/// to decode arguments and encode a reply.
///
/// ## Examples
///
/// ```gleam
/// assert policy.contains(policy.extension(), "ext")
/// ```
///
/// ```gleam
/// assert !policy.contains(policy.extension(), "cap/strand")
/// ```
///
pub fn extension() -> VetPolicy {
  new(list.append(extension_cap_modules(), extension_stdlib_modules()))
}

/// The capability-prelude modules in the default allowlist. The union of the
/// sets named in design §6.2 (`fs proc net git lsp task actor report`) and
/// spec WP-J (`fs proc git lsp report task actor kv`).
///
/// `cap/strand` is deliberately not here. A workspace program that imports
/// it is rejected by exactly the same rule that rejects an orchestration
/// program importing `cap/fs`, which is what makes the confinement one
/// rule read in two directions rather than two rules that could drift.
///
/// Public because the confinement's real property is about *this* list and
/// its orchestration counterpart, not about either seam's whole allowlist:
/// the two seams also share `default_stdlib_modules`, so a test that could
/// only see `default()` and `orchestration()` could not tell a capability
/// added to both apart from a stdlib module added to both. See
/// `orchestration_cap_modules`.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.default_cap_modules(), "cap/fs")
/// ```
///
pub fn default_cap_modules() -> List(String) {
  [
    "cap/fs", "cap/proc", "cap/net", "cap/git", "cap/lsp", "cap/report",
    "cap/task", "cap/actor", "cap/kv", "cap/schedule",
  ]
}

/// The capability-prelude modules on the orchestration seam. Shares
/// exactly one entry with `default_cap_modules` — `cap/report`, which
/// carries no authority of its own — and no other.
///
/// That intersection *is* the confinement, so it is asserted as an
/// intersection rather than as a snapshot of one side of it. A snapshot
/// catches a capability moved from one seam to the other and misses a
/// capability added to both, which is the likelier mistake: the shared
/// door is `default_stdlib_modules`, which both seams append, and a new
/// module looks like it belongs there.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.orchestration_cap_modules(), "cap/strand")
/// ```
///
pub fn orchestration_cap_modules() -> List(String) {
  ["cap/strand", "cap/report"]
}

/// The capability-prelude and prelude-package modules on the extension
/// seam: every workspace capability, plus `cap/ext` and `ext`.
///
/// Written as `default_cap_modules()` widened rather than as a list of
/// its own, so the superset relation is a fact about the code and not a
/// promise two literals have to keep. Add a capability to the workspace
/// seam and the extension seam gets it; that is the intended coupling,
/// because an extension tool is a workspace program with a different
/// entry point.
///
/// `ext` is not a `cap/*` module and carries no authority: it is the
/// vocabulary an extension's tools are typed against (`packages/ext`),
/// vendored into the build beside the prelude. `cap/ext` is the one
/// capability only an extension makes — "which call am I serving?" — and
/// it is on this seam and no other for the same reason `cap/strand` is on
/// exactly one.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.extension_cap_modules(), "cap/ext")
/// ```
///
pub fn extension_cap_modules() -> List(String) {
  list.append(default_cap_modules(), ["cap/ext", "ext"])
}

/// The standard-library modules on the extension seam: the shared pure
/// subset, plus the five an extension needs and a code-mode program does
/// not.
///
/// `gleam/dynamic` and `gleam/dynamic/decode` are here because an
/// extension tool's arguments arrive as a `Dynamic` — the manifest's JSON
/// schema is the only thing that knows their shape, so the decode has to
/// happen in the extension. `gleam/json` is how a reply is built and how
/// those arguments are parsed; `gleam/bit_array` and `gleam/uri` are what
/// a tool needs to read a brokered HTTP response and build the URL it
/// asked for. All five are pure: none exposes I/O, processes, or an
/// FFI-declaring surface to its caller, which is the same bar
/// `default_stdlib_modules` is held to.
///
/// This list is *not* shared with the other two seams, which is the point
/// of it being a separate function: widening it widens exactly one seam.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.extension_stdlib_modules(), "gleam/json")
/// ```
///
pub fn extension_stdlib_modules() -> List(String) {
  list.append(default_stdlib_modules(), [
    "gleam/dynamic", "gleam/dynamic/decode", "gleam/bit_array", "gleam/uri",
    "gleam/json",
  ])
}

// `cap/schedule` is on the workspace seam and not this one, which is a
// choice rather than an oversight. A heartbeat reads as orchestration —
// it is about what happens later rather than about the files in front of
// you — and putting it on both seams was considered and dropped, because
// the intersection above *is* the confinement property and widening it
// from one module to two costs a real guarantee to buy a convenience
// nobody has asked for yet. An orchestration program that wants a
// heartbeat can have the strand it is running on schedule one.

/// The capability-prelude modules on **no** seam, deliberately.
///
/// `cap/runtime` is the boot runtime: the satellite's generated entry
/// module calls it, and a submitted program has no business naming it. So
/// it is unreachable from either allowlist — which, on its own, is
/// indistinguishable from an oversight. A capability written, vendored
/// into the build seed and never allowlisted fails exactly the same way:
/// the `code_mode` description omits it, vetting rejects any program that
/// imports it, and nothing anywhere says the module exists but cannot be
/// reached (issue #95).
///
/// `cap/mcp` is here for a different reason, and it is a standing one
/// rather than a wait. It is the types-only shared vocabulary for the
/// generated `cap/mcp/<server>` façades (issue #106) — it carries no
/// authority, since the invoke lives in `cap/internal/mcp` and is
/// reachable only through a façade — and the façades themselves are
/// **generated per host from that host's configured servers**, so no
/// static list can name them. A host with servers configured therefore
/// extends the workspace seam's allowlist *at boot*, with `cap/mcp` and
/// each generated module name, and a host with none allows neither
/// (`client/codemode.seam_allowlist`). Keeping `cap/mcp` off every
/// static seam is what makes that per-host: allowlisting it here would
/// advertise the vocabulary on every host, including the ones where no
/// module using it exists to import.
///
/// Writing the exclusion down is most of the value — it turns "not in the
/// allowlist" from an absence into a decision someone made — and
/// `scripts/gen-prelude.sh --check` is what makes it load-bearing: every
/// module in `packages/cap` must appear on a seam's list or on this one,
/// so a new module forces the question rather than disappearing.
///
/// ## Examples
///
/// ```gleam
/// assert policy.harness_only_cap_modules() == ["cap/mcp", "cap/runtime"]
/// ```
///
pub fn harness_only_cap_modules() -> List(String) {
  ["cap/mcp", "cap/runtime"]
}

/// The standard-library modules in the default allowlist. Every one has a pure,
/// effect-free public API (see `default`); none exposes I/O, processes, atom
/// creation, or an FFI-declaring surface to its caller.
///
/// **Both seams append this list**, so a `cap/*` name added here would land
/// on the orchestration seam and the workspace seam at once, widening the
/// orchestration surface past `cap/strand` + `cap/report` with no
/// intersection test able to see it. That is the one door the disjointness
/// property does not close by itself, so a test asserts this list holds no
/// capability module at all.
///
/// ## Examples
///
/// ```gleam
/// assert !list.contains(policy.default_stdlib_modules(), "cap/fs")
/// ```
///
pub fn default_stdlib_modules() -> List(String) {
  [
    "gleam/list", "gleam/string", "gleam/string_tree", "gleam/int",
    "gleam/float", "gleam/bool", "gleam/result", "gleam/option", "gleam/dict",
    "gleam/set", "gleam/order", "gleam/pair", "gleam/function",
  ]
}
