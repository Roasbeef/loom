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
//// There are four allowlists, not one, and a submission is judged against
//// exactly one of them (`Seam`, `for_seam`). Three of them admit source
//// that runs today; the fourth is declared for a tier that does not
//// exist yet, so that it is frozen before a loader can invent it:
////
//// - the **workspace** seam — `cap/{fs, proc, net, git, lsp, report, task,
////   actor, kv}` — a program that orchestrates *effects*;
//// - the **orchestration** seam — child operations, reporting, background
////   input and explicitly authorized peers — a program orchestrating agents;
//// - the **extension** seam — the workspace seam plus `ext`, `ext/hook`,
////   `ext/memory` and HTTP data helpers — an
////   installed extension's tool, compiled once and run per call;
//// - the **resident** seam — `ext`, `ext/hook` and the extension seam's
////   standard library, with every module that reaches the broker
////   removed — the seam a harness-resident hook body would be judged
////   against if one were ever loaded (`resident`).
////
//// Workspace and orchestration submissions can compose effects with child
//// operations. An extension remains an effect-only workspace program with a
//// different entry point, so its allowlist does not gain child custody.
//// The property that holds it is a superset claim rather than an
//// intersection (`extension_cap_modules`), and it is asserted for the
//// same reason the intersection is: so the relationship between the seams
//// is checked rather than assumed.
////
//// Both program modes use the same union of effect and agent capabilities.
//// The operator can still install a workspace-only host, which uses
//// `workspace_effects` and does not advertise unserviceable child operations.
//// The extension and resident policies remain separate because their
//// execution contexts do not own the same child lifecycle.
////
//// Nothing else about the mechanism changes: this module was already an
//// opaque, per-submission allowlist, so two seams are a *configuration*
//// of machinery that exists rather than a second mechanism to get right.
//// An import outside the installed host's allowlist is still refused as
//// `ImportNotAllowed`, with the rejected module named for in-band repair.

import gleam/list
import gleam/set.{type Set}
import gleam/string

/// Which seam a submission is judged against. Four variants and no
/// fifth: the set of seams is closed here rather than left to whoever
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

  /// The resident seam: the seam a harness-resident hook body would be
  /// judged against if one were ever loaded. No loader exists, and the
  /// seam is deliberately declared before one does — see `resident`.
  ResidentSeam
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
    ResidentSeam -> resident()
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

/// The default workspace-mode allowlist: all program capabilities and a
/// curated subset of the standard library whose public API is effect-free.
///
/// Both installed program modes admit this same full set. An explicitly
/// effect-only host uses `workspace_effects`.
///
/// # The capability prelude (`cap/*`)
///
/// These are the typed capability modules whose implementations are RPC stubs
/// to the ToolBroker carrying the execution's token (design §6.2). They *are*
/// the effect surface a program is allowed to reach; every effect a submitted
/// program can have flows through one of them, token- and policy-checked at the
/// broker. The precise set is owned by the prelude package; this default uses
/// the union of effect and child-operation modules. Narrower installed hosts
/// pass an explicit policy.
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
///
/// JSON and dynamic decoders are included because typed capability results
/// still carry unstructured file contents and command output. Parsing those
/// strings grants no authority: the caller receives data, not access to the
/// runtime, and the pinned compiler seed already supplies `gleam_json`.
pub fn default() -> VetPolicy {
  new(list.append(program_cap_modules(), default_stdlib_modules()))
}

/// The effect-only policy for a host installed without Agency custody.
///
/// ## Examples
///
/// ```gleam
/// assert !policy.contains(policy.workspace_effects(), "cap/strand")
/// ```
///
pub fn workspace_effects() -> VetPolicy {
  new(list.append(default_cap_modules(), default_stdlib_modules()))
}

/// The orchestration mode uses the same full capability set as the default.
///
/// ## Examples
///
/// ```gleam
/// assert policy.contains(policy.orchestration(), "cap/strand")
/// ```
///
/// ```gleam
/// assert policy.contains(policy.orchestration(), "cap/proc")
/// ```
///
pub fn orchestration() -> VetPolicy {
  default()
}

/// The extension seam's allowlist: the workspace effect subset plus
/// the `ext` prelude, and the workspace seam's standard-library subset
/// plus the modules an extension needs for HTTP data.
///
/// A superset of the workspace seam, on purpose. An extension tool *is* a
/// workspace program — it reads files, runs processes, and (under
/// Decision 2 of the extension ruling) makes brokered HTTP requests — so
/// carving it a fourth, narrower capability set would buy nothing and
/// would have to be kept in step by hand. What it additionally needs is
/// the vocabulary its tools and hooks are typed against (`ext`,
/// `ext/hook`), and the one capability that is an extension's alone:
/// `ext/memory`, the durable cells under the reserved prefix the
/// extension owns. A code-mode program has no such subtree — its name
/// is the second segment of the key and it does not have one — so this
/// is a capability that could not be on the workspace seam rather than
/// one held back from it.
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

/// The resident seam's allowlist: the extension seam with every
/// capability module removed. `ext`, `ext/hook`, and the same
/// standard-library subset the jailed seam admits — nothing that opens
/// a channel to the broker, `ext/memory` included, and nothing else.
///
/// # Why an allowlist exists for a tier that does not
///
/// Design §7's hard rule is that the trusted computing base is not
/// runtime-extensible. Every extension body in the tree today runs in a
/// jail, so nothing crosses into the harness VM and the rule holds by
/// construction. Tier H — a hook body hot-loaded into the harness itself
/// — is the one design the rule was written against, and it is
/// deliberately unbuilt (#32): the survey behind the extension note found
/// no real extension that needs in-VM residency, and what the vocabulary
/// is missing is not a tier.
///
/// So this list is the freeze rather than a feature. A loader written
/// later starts from a seam that already exists and that a test already
/// pins, instead of inventing an allowlist at the moment somebody most
/// wants to be permissive. Nothing selects `ResidentSeam` today, and
/// that is the intended state.
///
/// # Why no capability at all
///
/// A jailed body reaches the broker through `cap/*` because the jail is
/// what makes that safe: the token is scoped to one execution, the
/// broker judges every call, and a kernel stands behind both. A resident
/// body has none of that — it runs in the harness VM, where a capability
/// stub is no longer a request to somebody else but a direct call inside
/// the process that holds the durability plane. A resident hook is
/// therefore a *pure transform over the payload it is handed*: it may
/// decode an event, build an answer, and return it, and it may reach
/// nothing. Everything else stays in the jail, where it already works.
///
/// `ext/memory` is the sharpest case of that, which is why it is out
/// rather than in: its cells are rows in the very store the harness VM
/// owns, so a resident body holding it would be writing the durability
/// plane from inside the process that serves it, with no broker between
/// them to judge the call. An extension that wants to remember has the
/// jail, where the write is a brokered request like any other.
///
/// Pure is not the same as bounded, and a loader has to supply the
/// second: this seam bounds the names a body may write, never the time
/// or the memory it may spend, so a `json.parse` over a hostile payload
/// or a runaway recursion inside the harness VM has no jail, no rlimit
/// and no deadline behind it. Whoever builds the loader owes the call a
/// bound of its own.
///
/// Written as the extension seam filtered rather than as a literal list,
/// so "no capability" is a fact about the code and not a promise two
/// lists have to keep. Widen the extension seam and this one does not
/// widen with it.
///
/// ## Examples
///
/// ```gleam
/// assert policy.contains(policy.resident(), "ext/hook")
/// ```
///
/// ```gleam
/// assert !policy.contains(policy.resident(), "cap/fs")
/// ```
///
pub fn resident() -> VetPolicy {
  new(list.append(resident_prelude_modules(), extension_stdlib_modules()))
}

/// The prelude modules on the resident seam: the extension seam's
/// prelude list with every module that reaches the broker filtered out,
/// which is `ext` and `ext/hook`.
///
/// The filter is a prefix match *and* a membership test, because the
/// `cap/` prefix stopped being the whole answer when `ext/memory`
/// arrived. A capability is a module that opens a channel to the broker,
/// and `ext/memory` opens one under a name that says which vocabulary it
/// belongs to rather than which door it is. Matching on the prefix alone
/// would have handed a resident body the durable store — the one thing
/// on this seam that writes to the plane the harness VM holds — so
/// `extension_authority_modules` names the exceptions and this filter
/// asks about authority rather than about spelling.
///
/// Public for the freeze test, which pins this list against the module
/// names the trusted computing base's packages actually ship and needs to
/// name the prelude half apart from the standard-library half it shares
/// with the jailed seam.
///
/// ## Examples
///
/// ```gleam
/// assert policy.resident_prelude_modules() == ["ext", "ext/hook"]
/// ```
///
pub fn resident_prelude_modules() -> List(String) {
  list.filter(extension_cap_modules(), fn(name) {
    !string.starts_with(name, "cap/")
    && !list.contains(extension_authority_modules(), name)
  })
}

/// The extension seam's capability modules that do not wear the `cap/`
/// prefix: `ext/memory`, and nothing else today.
///
/// A list rather than a naming convention because the convention is the
/// thing that failed. `ext/memory` sits in the `ext` vocabulary an
/// author writes against, so it is spelled like `ext/hook`, which carries
/// no authority at all; underneath it is a `cap/internal/channel` client
/// like every `cap/*` module. Whoever adds the next one has to add it
/// here too, and `resident_prelude_modules` is what makes forgetting
/// visible: a capability missing from this list would silently become
/// admissible inside the harness VM.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.extension_authority_modules(), "ext/memory")
/// ```
///
pub fn extension_authority_modules() -> List(String) {
  ["ext/memory"]
}

/// The capability-prelude modules in the default allowlist. The union of the
/// sets named in design §6.2 (`fs proc net git lsp task actor report`) and
/// spec WP-J (`fs proc git lsp report task actor kv`), widened since by
/// `cap/schedule`, `cap/job` and `cap/search`, and narrowed by one: `cap/lsp`.
///
/// Both lists name `lsp`, and it is left off here on purpose. Its router
/// answers only over a language server the session actually runs, and
/// ADR-013 §6 configures those per workspace with no built-in default, so
/// most sessions have none. A static entry would render the module's
/// whole type surface into the `code_mode` description of every session,
/// the cached prefix every request pays for, to advertise imports that
/// could only be refused. It is admitted the way `cap/notes` and the MCP
/// façades are, per host and only with its door present
/// (`client/codemode.seam_allowlist`), and it waits on
/// `harness_only_cap_modules` until then.
///
/// `cap/search` is here on the same argument that puts `cap/fs` here and
/// on one more of its own: it is read-only navigation and search over the
/// workspace, so it grants strictly less than `cap/fs` already grants, and
/// a program that imports it instead of `cap/fs` has said in its imports
/// that it cannot write.
///
/// `cap/strand` is absent from this effect subset. Installed program modes
/// append it through `program_cap_modules`; extensions do not.
///
/// Public so the effect-only installed host and extension policy share one
/// named subset, while tests compare it with the full program surface.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.default_cap_modules(), "cap/fs")
/// ```
///
pub fn default_cap_modules() -> List(String) {
  [
    "cap/fs", "cap/proc", "cap/net", "cap/git", "cap/report", "cap/execution",
    "cap/peer", "cap/task", "cap/actor", "cap/kv", "cap/schedule", "cap/job",
    "cap/search",
  ]
}

/// The child-operation modules and shared collaboration modules.
///
/// Both program modes admit this list together with `default_cap_modules`.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.orchestration_cap_modules(), "cap/strand")
/// ```
///
pub fn orchestration_cap_modules() -> List(String) {
  ["cap/strand", "cap/report", "cap/execution", "cap/peer", "cap/workflow"]
}

/// All capabilities admitted by either installed code-mode program mode.
///
/// The shared entries already occur in `default_cap_modules`, so only child
/// custody modules need appending. The explicit effect-only host and extension
/// policy keep using `default_cap_modules`.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.program_cap_modules(), "cap/strand")
/// ```
///
pub fn program_cap_modules() -> List(String) {
  list.append(default_cap_modules(), ["cap/strand", "cap/workflow"])
}

/// The capability-prelude and prelude-package modules on the extension
/// seam: every workspace effect capability, plus `ext`, `ext/hook` and
/// `ext/memory`.
///
/// Written as `default_cap_modules()` widened rather than as a list of
/// its own, so the superset relation is a fact about the code and not a
/// promise two literals have to keep. Add an effect capability to the base
/// subset and the extension seam gets it; child custody remains excluded.
///
/// `ext` and `ext/hook` are not `cap/*` modules and carry no authority:
/// they are the vocabulary an extension's tools and hooks are typed
/// against (`packages/ext`), vendored into the build beside the prelude.
/// `ext/hook` arrived with phase 3 and is the same kind of thing as
/// `ext` — types, a name-to-event mapping, and the JSON marshalling of
/// the hook payloads — so it is admitted on the same argument.
///
/// `ext/memory` is spelled like those two and is not one of them: it is
/// a broker client, and the one capability an extension has that a
/// workspace program could not, because the key its cells live under is
/// composed from the name an operator installed this extension under.
/// It is appended through `extension_authority_modules` so the seams
/// that must not have it can ask about authority rather than about the
/// `cap/` prefix it does not wear.
///
/// There is no capability here for "which call am I serving?", and the
/// absence is the point. Phase 1 had one — `cap/ext.call`, a pull the
/// node made once at boot — and phase 3 deleted it: a satellite that
/// lives for the session is *told* what to answer over a `hook_call`
/// (`protocol-change/012`), so the question no longer has a caller.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.extension_cap_modules(), "ext")
/// ```
///
pub fn extension_cap_modules() -> List(String) {
  list.append(default_cap_modules(), ["ext", "ext/hook"])
  |> list.append(extension_authority_modules())
}

/// The standard-library modules on the extension seam: the shared pure
/// subset plus `gleam/bit_array` and `gleam/uri` for brokered HTTP data.
///
/// JSON parsing and dynamic decoding are shared with code-mode programs.
/// Extensions additionally need to read binary HTTP responses and build
/// request URLs. These two helpers expose data transformations, not I/O,
/// processes, or an FFI-declaring surface to their caller.
///
/// ## Examples
///
/// ```gleam
/// assert list.contains(policy.extension_stdlib_modules(), "gleam/json")
/// ```
///
pub fn extension_stdlib_modules() -> List(String) {
  list.append(default_stdlib_modules(), ["gleam/bit_array", "gleam/uri"])
}

// Protocol 048 admits effect and child modules on both default program modes.
// Input remains bound to the execution, and peer delivery still requires an
// operator-owned directional grant with separate idle-wake permission. An
// explicitly effect-only host, extensions, and resident hooks stay narrower.
//
// The extension seam still widens only the effect subset. `cap/schedule`
// reaches an installed extension's tool exactly as `cap/fs` does, while
// child custody stays with code-mode program executions.
//
// `cap/job` rides the same superset and is ruled the same way, with one
// division the allowlist cannot express. An extension's tool call may
// start a background job: it runs under the model's own operation, the
// strand's model reads it in its own transcript and can kill it, and an
// abort of that operation reaches it — the posture above, exactly. An
// extension's *hook* may not. A hook fires on the harness's timeline
// under the one session-long operation `client/serve.hook_coordinates`
// mints and attributes to the root strand for reads; no operator ever
// sees that operation as a running step, so no operator can abort it,
// and a `context` or pre-tool hook that started a job on every event
// would spend the model's own ceiling of live jobs on work it never
// asked for and cannot find. Vetting cannot make that call, because the
// two paths import the same module in the same package: the division is
// made where the difference exists, in the workspace bridge
// `client/extension/dispatch.bridge` builds, which serves a hook-origin
// invocation `workspace.no_jobs()` and a tool-origin one the real door.
// `docs/architecture/extensions.md` states it beside the other
// invariants, and `dispatch_test` pins both polarities.

/// Prelude modules outside every static seam. Host-installed modules are
/// added only when their corresponding runtime door is present.
///
/// cap/notes is installed by client/codemode for workspace and orchestration
/// programs with a blackboard door. Extensions and resident hooks never gain
/// it. Its static absence prevents advertising a door an unconfigured host
/// cannot answer.
///
/// `cap/lsp` is the same kind of wait as `cap/notes`: `client/codemode`
/// admits it for workspace and orchestration programs on a host whose
/// session runs a language server, together with the `lsp.*` router arm
/// and serviced capabilities, and never for extensions or resident hooks.
/// `default_cap_modules` says why it is not static.
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
/// assert policy.harness_only_cap_modules()
///   == ["cap/notes", "cap/lsp", "cap/mcp", "cap/runtime"]
/// ```
///
pub fn harness_only_cap_modules() -> List(String) {
  ["cap/notes", "cap/lsp", "cap/mcp", "cap/runtime"]
}

/// The standard-library modules in the default allowlist. Every one has a pure,
/// effect-free public API (see `default`); none exposes I/O, processes, atom
/// creation, or an FFI-declaring surface to its caller.
///
/// **Both program modes append this list**, so a `cap/*` name added here would
/// also reach the explicit effect-only host without appearing in its named
/// capability subset. A test asserts this list holds no capability module.
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
    "gleam/set", "gleam/order", "gleam/pair", "gleam/function", "gleam/json",
    "gleam/dynamic", "gleam/dynamic/decode",
  ]
}
