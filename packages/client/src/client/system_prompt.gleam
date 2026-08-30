//// Assembling and pinning the session's system prompt: the I/O half of
//// `prompt`.
////
//// The `prompt` package is pure by construction — it cannot read a file
//// or probe a kernel — so someone has to hand it a decoded pack and a
//// populated `Environment`. This module is that someone. It reads the
//// pack (the shipped default, or the file `LOOM_PROMPT_PACK` names),
//// gathers every environment field from a real source, renders once, and
//// pins the bytes into the reserved `prompt/` corner of the blackboard so
//// that every later boot of the same session sends exactly the string the
//// first one did.
////
//// ## Why pinning, and why the bytes must not move
////
//// The rendered string sits behind a one-hour prompt-cache breakpoint,
//// written at 2× base input and read on every turn of every strand for
//// the rest of the session. Its economics rest entirely on the head not
//// moving. Every input to `render` is fixed at session open, but the
//// *sources* of those inputs are not: the agent may edit `CLAUDE.md`, the
//// host's kernel may change under a restart, a flag may differ. So the
//// assembled string is written once and read thereafter — re-deriving it
//// on resume is what would move the bytes. The enforcement demand is the
//// one exception because it changes whether those bytes tell the truth: its
//// identity is pinned beside the prompt, and a changed or legacy identity
//// deliberately pays one new render and cache write.
////
//// ## The order the pin has to survive
////
//// `wiring.Config.system` must hold the string *before* `api.open`, and
//// `api.open` is what stands the writer up. The cell is therefore read
//// straight off the session store before the tree boots — legal, because
//// no committer exists yet — and written back through
//// `api.put_reserved_fact` once the open has returned, so the commit is
//// journaled like every other. Read before, write after; the string
//// handed to the wiring is the same value either way.
////
//// ## The three ways a boot gets its prompt
////
//// `LOOM_SYSTEM_PROMPT` (an explicit operator override, which bypasses
//// the pack entirely), the pinned cell, or a fresh render — in that
//// order. An override is pinned too, so the session's durable record is
//// what was actually sent rather than what a pack would have produced.
////
//// ## What refuses a boot and what only warns
////
//// A pack that does not decode refuses the boot, worded, naming the file
//// and the fault: a silently-empty system prompt is the failure this
//// module exists to end, and so is a silently-*ignored* pack file. A pack
//// that renders to nothing refuses for the same reason. But a pack whose
//// `problems()` is non-empty — a dropped section, a misspelled
//// placeholder — only warns and runs. `decode` deliberately accepts more
//// than `problems` approves (`prompt/pack`'s own invariant), a mutated
//// pack that drops a section is still a valid pack, and turning a
//// slightly incomplete prompt into a dead server is the worse of the two
//// failures. The line between them is sharp: renders to nothing is
//// refused, renders to something is run and every complaint is reported.

import broker/exec.{type EnforcementDemand}
import broker/policy.{type SandboxPolicy}
import core/corruption.{type CorruptionReport}
import core/json.{type JsonValue}
import core/register
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import prompt/default
import prompt/pack
import prompt/summary
import runtime/api.{type Runtime}
import session/session.{type Session}
import simplifile
import storage/storage

/// The reserved `fact.custom` key the assembled prompt and its enforcement
/// identity are pinned under. Keeping the two in one register makes their
/// behavioural relationship atomic across a failed boot.
/// `api.reserved_fact_key` covers it, so no model-reachable `put_fact` can
/// rewrite the operator's channel.
pub const system_key = "prompt/system"

/// The reserved key carrying the pinned prompt's provenance — where it
/// came from, the pack's version, and the pack's digest. Written for
/// attribution (a cache miss traced to a prompt change) and never read
/// back for behaviour.
pub const pack_key = "prompt/pack"

/// The environment variable naming a pack file to use instead of the
/// shipped default.
pub const pack_path_variable = "LOOM_PROMPT_PACK"

/// The environment variable naming a summarization pack file to use
/// instead of the shipped one. Separate from `pack_path_variable`
/// because the two packs are paid for on entirely different schedules:
/// the system prompt on every request of every strand, the
/// summarization prompts once per compaction.
pub const summary_pack_variable = "LOOM_SUMMARY_PACK"

/// The environment variable holding a literal system prompt that
/// bypasses the pack entirely.
pub const override_variable = "LOOM_SYSTEM_PROMPT"

/// The largest `CLAUDE.md` this module will read. Well above any real
/// guidance file and well below what would trouble the boot process;
/// `render` caps what actually reaches the prompt at
/// `pack.max_repository_guidance_bytes` on a line boundary and announces
/// the cut. A file above *this* bound is not a guidance file, and is
/// skipped with a warning rather than read into memory to have all but
/// 16 KiB of it thrown away.
pub const max_guidance_file_bytes = 1_048_576

// --- the environment ------------------------------------------------------

/// Everything the harness knows about this host, gathered from real
/// sources by whoever boots. Each field's source, in order: the resolved
/// `--workspace`; `ffi_os.platform`; the shell jailed commands actually
/// run under (`exec.SpawnConfig.shell_path`); the tool registry's sorted
/// names; `serve`'s `--best-effort` demand paired with the `degraded`
/// feature from a helper's hello; the composed session base policy; and
/// the root `CLAUDE.md` if there is one.
///
/// Constructor invariant, and the only one that matters: **every field is
/// fixed for the life of the session.** Nothing here may be re-read per
/// turn, and nothing numeric belongs here at all — a millisecond, a token
/// count and a cost all arrive disguised as an `Int`.
pub type Host {
  Host(
    /// The workspace root, exactly as the policy and the tools see it.
    workspace: String,
    /// `os:type/0` and the machine architecture, raw from `ffi_os`.
    platform: #(String, String),
    /// The shell jailed commands run under.
    shell: String,
    /// The registered tool names (`tool.names`, already sorted).
    tools: List(String),
    /// The enforcement posture demanded of the helper.
    demand: EnforcementDemand,
    /// Whether a helper's hello advertised `degraded`.
    degraded: Bool,
    /// The session's composed base sandbox policy.
    base_policy: SandboxPolicy,
    /// The root `CLAUDE.md`, verbatim, if it exists and is readable.
    guidance: Option(String),
  )
}

/// Builds the pack's `Environment` from a host. Every list field is
/// normalized on the way in by `pack.environment` itself, so a discovery
/// order here cannot reach the rendered bytes.
///
/// ## Examples
///
/// ```gleam
/// // pack.tools(system_prompt.environment(host)) == ["bash", "grep"]
/// ```
///
pub fn environment(host: Host) -> pack.Environment {
  pack.environment(
    workspace: host.workspace,
    platform: platform(host.platform),
    shell: host.shell,
    tools: host.tools,
    enforcement: enforcement(host.demand, host.degraded),
    network: posture(host.base_policy.network),
    protected_paths: host.base_policy.protected,
    repository_guidance: host.guidance,
  )
}

/// The platform label the prompt carries, from `ffi_os.platform`'s raw
/// pair: the OS name with the two that would puzzle a reader renamed, and
/// the architecture cut to its leading component and spelled the way the
/// world spells it.
///
/// ## Examples
///
/// ```gleam
/// assert system_prompt.platform(#("linux", "x86_64-pc-linux-gnu"))
///   == "linux/x86_64"
/// ```
///
/// ```gleam
/// assert system_prompt.platform(#("darwin", "aarch64-apple-darwin23"))
///   == "macos/arm64"
/// ```
///
pub fn platform(raw: #(String, String)) -> String {
  let #(os, architecture) = raw
  let os = case os {
    "darwin" -> "macos"
    "nt" -> "windows"
    other -> other
  }
  let architecture = case string.split_once(architecture, on: "-") {
    Ok(#(head, _rest)) -> head
    Error(Nil) -> architecture
  }
  let architecture = case architecture {
    "aarch64" -> "arm64"
    "amd64" -> "x86_64"
    other -> other
  }
  os <> "/" <> architecture
}

/// The behavioural enforcement posture, from the pair the harness can
/// actually know at session open: the demand `serve` was started with,
/// and the coarse `degraded` flag a helper advertised in its hello.
///
/// Best effort was asked for explicitly, so it reports itself whatever
/// the helper says. Both strict demands refuse a degraded helper before
/// dispatch. A healthy platform demand says that the platform's mandatory
/// boundary is enforced while its explicitly reported portability gaps may
/// remain; full enforcement claims the stronger, gap-free posture.
///
/// ## Examples
///
/// ```gleam
/// assert system_prompt.enforcement(exec.FullEnforcement, True)
///   == pack.DegradedRefusing
/// ```
///
pub fn enforcement(
  demand: EnforcementDemand,
  degraded: Bool,
) -> pack.Enforcement {
  case demand, degraded {
    exec.BestEffort, _ -> pack.BestEffort
    exec.PlatformEnforcement, True -> pack.DegradedRefusing
    exec.PlatformEnforcement, False -> pack.PlatformEnforced
    exec.FullEnforcement, True -> pack.DegradedRefusing
    exec.FullEnforcement, False -> pack.FullyEnforced
  }
}

/// The network posture, mirrored from the composed base policy. The
/// proxy address is dropped on purpose — it changes nothing an agent
/// does, and the pack has nowhere to put it.
///
/// ## Examples
///
/// ```gleam
/// assert system_prompt.posture(policy.NetworkOff) == pack.NetworkBlocked
/// ```
///
pub fn posture(network: policy.NetworkPolicy) -> pack.NetworkPosture {
  case network {
    policy.NetworkOff -> pack.NetworkBlocked
    policy.NetworkProxy(allow:, proxy: _) -> pack.NetworkProxied(allow:)
    policy.NetworkFull -> pack.NetworkOpen
  }
}

// --- loading and rendering a pack -----------------------------------------

/// Where this boot's prompt came from, for wording errors and warnings.
pub type Origin {
  /// The pack compiled into this build (`prompt/default.source`).
  Shipped
  /// A pack file named by `LOOM_PROMPT_PACK`.
  PackFile(path: String)
  /// `LOOM_SYSTEM_PROMPT`: no pack was consulted at all.
  Override
  /// The pinned cell from an earlier boot of this session.
  Pinned
}

/// One rendered prompt and what a person needs to know about it.
///
/// Constructor invariants: `text` is non-empty and whitespace-trimmed
/// (`render_pack` refuses anything else); `version` and `digest` are the
/// pack's own; every entry of `warnings` is a finished sentence about
/// something imperfect that was *not* fatal.
pub type Rendered {
  Rendered(
    text: String,
    origin: Origin,
    version: String,
    digest: String,
    warnings: List(String),
  )
}

/// Reads the pack source this boot should use: the file
/// `LOOM_PROMPT_PACK` names, or the shipped default. An unreadable file
/// refuses rather than falling back — an operator who pointed at a pack
/// and silently got the default one would never find out.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.pack_source(option.None)
/// // -> Ok(#(system_prompt.Shipped, default.source))
/// ```
///
pub fn pack_source(path: Option(String)) -> Result(#(Origin, String), String) {
  case path {
    None -> Ok(#(Shipped, default.source))
    Some(path) ->
      case simplifile.read(path) {
        Ok(text) -> Ok(#(PackFile(path:), text))
        Error(error) -> Error(unreadable_pack(path, error))
      }
  }
}

fn unreadable_pack(path: String, error: simplifile.FileError) -> String {
  pack_path_variable
  <> " names a prompt pack that could not be read: "
  <> path
  <> ": "
  <> string.inspect(error)
}

/// Decodes a pack and renders it against a host. A pack that does not
/// decode, and a pack that renders to nothing, are both refusals worded
/// for a person and naming the pack; a pack `problems` complains about
/// still renders, and each complaint comes back as a warning.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.render_pack(system_prompt.Shipped, default.source, host)
/// // -> Ok(system_prompt.Rendered(text: "You are an agent ...", ..))
/// ```
///
pub fn render_pack(
  origin: Origin,
  source: String,
  host: Host,
) -> Result(Rendered, String) {
  use decoded <- result.try(
    pack.decode(source)
    |> result.map_error(fn(report) {
      "the prompt pack "
      <> named(origin)
      <> " is corrupt: "
      <> corruption.describe(report)
    }),
  )
  let text = pack.render(decoded, environment(host))
  case string.trim(text) {
    "" ->
      Error(
        "the prompt pack "
        <> named(origin)
        <> " rendered an empty system prompt; refusing to run without one",
      )
    _ ->
      Ok(Rendered(
        text:,
        origin:,
        version: decoded.version,
        digest: decoded.digest,
        warnings: list.map(pack.problems(decoded), fn(problem) {
          "the prompt pack "
          <> named(origin)
          <> " is incomplete: "
          <> describe_problem(problem)
        }),
      ))
  }
}

/// How one pack problem reads on a warning line.
///
/// ## Examples
///
/// ```gleam
/// assert system_prompt.describe_problem(pack.MissingSection("conduct"))
///   == "the section `conduct` is missing"
/// ```
///
pub fn describe_problem(problem: pack.Problem) -> String {
  case problem {
    pack.MissingSection(name:) -> "the section `" <> name <> "` is missing"
    pack.UnknownPlaceholder(section:, name:) ->
      "the section `"
      <> section
      <> "` uses `{"
      <> name
      <> "}`, which nothing binds; it renders empty"
  }
}

/// How an origin reads inside a sentence.
///
/// ## Examples
///
/// ```gleam
/// assert system_prompt.named(system_prompt.PackFile("/etc/loom.pack"))
///   == "/etc/loom.pack"
/// ```
///
pub fn named(origin: Origin) -> String {
  case origin {
    Shipped -> "shipped with this build"
    PackFile(path:) -> path
    Override -> override_variable
    Pinned -> system_key
  }
}

// --- the assembled prompt -------------------------------------------------

/// The prompt this boot will send, and whether it still needs pinning.
///
/// Constructor invariants: `text` is what every generation of every
/// strand in the session sends as `system`, byte for byte; `fresh` is
/// `True` exactly when the pinned cell does not already hold `text`, and
/// is what `pin` acts on.
pub type Assembled {
  Assembled(
    text: String,
    origin: Origin,
    version: String,
    digest: String,
    warnings: List(String),
    fresh: Bool,
  )
}

/// Chooses this boot's prompt from the three sources, in precedence
/// order: an explicit `LOOM_SYSTEM_PROMPT` override, then the pinned
/// cell, then a fresh render.
///
/// The override beats the pin because setting it is a deliberate
/// session-level act, and the design already prices one such act at one
/// cache write. The pin beats a render because re-deriving from mutable
/// inputs is what moves the bytes.
///
/// `render` is a thunk so that a resumed session pays nothing for it: no
/// pack file is read, no `CLAUDE.md` is read, and no helper is spawned to
/// ask whether this host is degraded.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.assemble(
/// //   pinned: Some("pinned bytes"),
/// //   override: None,
/// //   render: never_called,
/// // )
/// ```
///
pub fn assemble(
  pinned pinned: Option(String),
  override override: Option(String),
  render render: fn() -> Result(Rendered, String),
) -> Result(Assembled, String) {
  case explicit(override), pinned {
    Some(text), _ ->
      Ok(Assembled(
        text:,
        origin: Override,
        version: "",
        digest: pack.fingerprint(text),
        warnings: [],
        fresh: pinned != Some(text),
      ))
    None, Some(text) ->
      Ok(Assembled(
        text:,
        origin: Pinned,
        version: "",
        digest: pack.fingerprint(text),
        warnings: [],
        fresh: False,
      ))
    None, None -> {
      use rendered <- result.try(render())
      Ok(Assembled(
        text: rendered.text,
        origin: rendered.origin,
        version: rendered.version,
        digest: rendered.digest,
        warnings: rendered.warnings,
        fresh: True,
      ))
    }
  }
}

// An override of whitespace is no override: an empty `system` block is
// worse than none, and it is how a profile that exports the variable
// unconditionally would silently disable the pack.
fn explicit(override: Option(String)) -> Option(String) {
  case override {
    Some(text) ->
      case string.trim(text) {
        "" -> None
        _ -> Some(text)
      }
    None -> None
  }
}

// --- the pinned cell ------------------------------------------------------

// The old release wrote the text as a bare JSON string. A bound value keeps
// the text and the only mutable host fact that can make it untruthful in one
// register, so no partial commit can pair one demand with another's words.
type PinnedValue {
  Legacy(text: String)
  Bound(text: String, enforcement: String)
}

/// Reads the pinned prompt straight off an open session store, before
/// any writer exists. This is the read half of the ordering constraint:
/// `wiring.Config.system` has to hold the string before `api.open`, and
/// `api.open` is what stands the writer up.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.pinned_in(opened) == Ok(option.None)
/// ```
///
pub fn pinned_in(session: Session) -> Result(Option(String), String) {
  use pinned <- result.try(pinned_value_in(session))
  Ok(option.map(pinned, pinned_text))
}

/// Reads a pinned prompt only when it was rendered for this enforcement
/// demand. A legacy pin has no enforcement identity and is treated like no
/// pin, as is a pin made under a different demand: the boot re-renders once
/// and records the current identity rather than sending stale, stronger
/// sandbox claims to the model.
///
/// Corrupt identity is different from absence. It refuses the boot rather
/// than silently replacing evidence that the harness-owned namespace was
/// written with a shape this version never produces.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.pinned_for(opened, exec.PlatformEnforcement)
/// // == Ok(option.Some("You are an agent ..."))
/// ```
pub fn pinned_for(
  session: Session,
  demand: EnforcementDemand,
) -> Result(Option(String), String) {
  use pinned <- result.try(pinned_value_in(session))
  let demand = demand_name(demand)
  case pinned {
    None -> Ok(None)
    Some(Legacy(..)) -> Ok(None)
    Some(Bound(text:, enforcement:)) if enforcement == demand -> Ok(Some(text))
    Some(Bound(..)) -> Ok(None)
  }
}

fn pinned_value_in(session: Session) -> Result(Option(PinnedValue), String) {
  case storage.get_register(session.store, register.FactCustom, system_key) {
    Error(error) ->
      Error("the pinned system prompt is unreadable: " <> string.inspect(error))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, ..))) ->
      decode_pinned(value.payload)
      |> result.map(Some)
      |> result.map_error(refuse_corrupt)
  }
}

/// Reads the pinned prompt through the live runtime — the same cell
/// `pinned_in` reads, after the tree is up. `api.fact` is the singular
/// read, which never consulted the reservation.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.pinned(runtime) == Ok(Some("You are an agent ..."))
/// ```
///
pub fn pinned(runtime: Runtime) -> Result(Option(String), String) {
  case api.fact(runtime, system_key) {
    Error(error) ->
      Error("the pinned system prompt is unreadable: " <> string.inspect(error))
    Ok(None) -> Ok(None)
    Ok(Some(payload)) ->
      decode_pinned(payload)
      |> result.map(pinned_text)
      |> result.map(Some)
      |> result.map_error(refuse_corrupt)
  }
}

/// Writes an unbound assembled prompt and its provenance into the reserved
/// `prompt/` cells, unless the pin already holds exactly these bytes. This is
/// the legacy-compatible primitive used by embeddings and migration tests;
/// production boot uses `pin_for` so enforcement identity is atomic with the
/// text.
/// The write goes through `api.put_reserved_fact`, so it is journaled
/// like every other commit; the matching read happened before the open,
/// when nothing owned the store.
///
/// A failed write refuses the boot. The alternative is a session running
/// on a prompt it did not record, whose next boot re-derives from inputs
/// that may since have moved — which is exactly what pinning exists to
/// prevent.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.pin(runtime, assembled) == Ok(Nil)
/// ```
///
pub fn pin(runtime: Runtime, assembled: Assembled) -> Result(Nil, String) {
  case assembled.fresh {
    False -> Ok(Nil)
    True -> {
      use Nil <- result.try(write(
        runtime,
        system_key,
        json.String(assembled.text),
      ))
      write_provenance(runtime, assembled)
    }
  }
}

/// Pins the prompt and the enforcement demand it was rendered against in one
/// register. Production boot uses this paired form so a later boot can
/// distinguish a byte-stable resume from an enforcement change that must
/// re-render, without a failed write tearing identity away from text.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.pin_for(runtime, assembled, exec.PlatformEnforcement)
/// // == Ok(Nil)
/// ```
pub fn pin_for(
  runtime: Runtime,
  assembled: Assembled,
  demand: EnforcementDemand,
) -> Result(Nil, String) {
  case assembled.fresh {
    False -> Ok(Nil)
    True -> {
      use Nil <- result.try(write(
        runtime,
        system_key,
        json.Object(fields: [
          #("text", json.String(assembled.text)),
          #("enforcement", json.String(demand_name(demand))),
        ]),
      ))
      write_provenance(runtime, assembled)
    }
  }
}

// Provenance may trail the behavioural write because it is diagnostic only:
// a failed provenance commit loses attribution, never the binding between the
// words a model reads and the demand the broker enforces.
fn write_provenance(
  runtime: Runtime,
  assembled: Assembled,
) -> Result(Nil, String) {
  write(
    runtime,
    pack_key,
    json.Object(fields: [
      #("origin", json.String(named(assembled.origin))),
      #("version", json.String(assembled.version)),
      #("digest", json.String(assembled.digest)),
    ]),
  )
}

fn demand_name(demand: EnforcementDemand) -> String {
  case demand {
    exec.FullEnforcement -> "full"
    exec.PlatformEnforcement -> "platform"
    exec.BestEffort -> "best-effort"
  }
}

fn write(
  runtime: Runtime,
  key: String,
  value: JsonValue,
) -> Result(Nil, String) {
  api.put_reserved_fact(runtime, key, value)
  |> result.map_error(fn(error) {
    "the system prompt could not be pinned to "
    <> key
    <> ": "
    <> string.inspect(error)
  })
}

// The pinned cell's total decoder accepts the old bare string and the current
// exact two-field record. Any other shape means something reached past the
// reservation, and re-rendering over it would hide exactly the thing worth
// seeing.
fn decode_pinned(payload: JsonValue) -> Result(PinnedValue, CorruptionReport) {
  case payload {
    json.String(value:) -> Ok(Legacy(text: value))
    json.Object(fields:) -> decode_bound(fields, payload)
    other -> invalid_pinned(other)
  }
}

fn decode_bound(
  fields: List(#(String, JsonValue)),
  payload: JsonValue,
) -> Result(PinnedValue, CorruptionReport) {
  case list.length(fields) == 2 {
    False -> invalid_pinned(payload)
    True -> {
      use text <- result.try(pinned_string_field(fields, "text", payload))
      use enforcement <- result.try(pinned_string_field(
        fields,
        "enforcement",
        payload,
      ))
      case enforcement {
        "full" | "platform" | "best-effort" -> Ok(Bound(text:, enforcement:))
        _ -> invalid_pinned(payload)
      }
    }
  }
}

fn pinned_string_field(
  fields: List(#(String, JsonValue)),
  key: String,
  payload: JsonValue,
) -> Result(String, CorruptionReport) {
  case list.key_find(fields, key) {
    Ok(json.String(value:)) -> Ok(value)
    _ -> invalid_pinned(payload)
  }
}

fn invalid_pinned(payload: JsonValue) -> Result(a, CorruptionReport) {
  Error(corruption.report(
    at: "client/system_prompt.decode_pinned",
    on: system_key,
    expected: "a legacy prompt string or {text, enforcement} string record",
    context: string.inspect(payload),
  ))
}

fn pinned_text(pinned: PinnedValue) -> String {
  case pinned {
    Legacy(text:) | Bound(text:, ..) -> text
  }
}

fn refuse_corrupt(report: CorruptionReport) -> String {
  "the pinned system prompt is corrupt: " <> corruption.describe(report)
}

// --- reading the repository's guidance ------------------------------------

/// The root `CLAUDE.md` of a workspace, verbatim, with a warning instead
/// of a value when there is a file but it cannot be used. What reaches
/// the prompt is capped by `render` at
/// `pack.max_repository_guidance_bytes` on a line boundary, framed as
/// project-authored data, and its truncation announced — all by the
/// pack's own fragments. This function's only judgment is
/// `max_guidance_file_bytes`.
///
/// An absent file is the ordinary case and says nothing.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.guidance("/work") == #(Some("# project\n..."), [])
/// ```
///
pub fn guidance(workspace: String) -> #(Option(String), List(String)) {
  let path = workspace <> "/CLAUDE.md"
  case simplifile.file_info(path) {
    Error(_absent) -> #(None, [])
    Ok(info) -> guidance_from(path, info)
  }
}

fn guidance_from(
  path: String,
  info: simplifile.FileInfo,
) -> #(Option(String), List(String)) {
  case info.size > max_guidance_file_bytes {
    True -> #(None, [oversize_warning(path)])
    False -> read_guidance(path)
  }
}

fn oversize_warning(path: String) -> String {
  path
  <> " is larger than "
  <> int.to_string(max_guidance_file_bytes)
  <> " bytes and was not read as repository guidance"
}

fn read_guidance(path: String) -> #(Option(String), List(String)) {
  case simplifile.read(path) {
    Ok(text) -> #(Some(text), [])
    Error(error) -> #(None, [unreadable_warning(path, error)])
  }
}

fn unreadable_warning(path: String, error: simplifile.FileError) -> String {
  path
  <> " is unreadable and was left out of the system prompt: "
  <> string.inspect(error)
}

// --- the summarization pack ------------------------------------------------

fn unreadable_summary_pack(
  path: String,
  error: simplifile.FileError,
) -> String {
  summary_pack_variable
  <> " names a summarization pack that could not be read: "
  <> path
  <> ": "
  <> string.inspect(error)
}

/// The summarization pack this boot summarizes with: the file
/// `LOOM_SUMMARY_PACK` names, or the shipped one. Returns the decoded
/// pack and whatever `summary.problems` complains about, as warnings.
///
/// Refuses like the system pack refuses — an unreadable file or a
/// corrupt pack stops the boot with a worded message naming it — but
/// warns rather than refuses on a pack that merely decoded to something
/// thinner than expected, because a compaction with a thin prompt still
/// beats a server that will not start.
///
/// ## Examples
///
/// ```gleam
/// // system_prompt.summary_pack(option.None)
/// // -> Ok(#(decoded, []))
/// ```
///
pub fn summary_pack(
  path: Option(String),
) -> Result(#(pack.Pack, List(String)), String) {
  use #(named_as, source) <- result.try(case path {
    None -> Ok(#("shipped with Loom", default.summary_source))
    Some(path) ->
      case simplifile.read(path) {
        Ok(text) -> Ok(#("at " <> path, text))
        Error(error) -> Error(unreadable_summary_pack(path, error))
      }
  })
  use decoded <- result.try(
    pack.decode(source)
    |> result.map_error(fn(report) {
      "the summarization pack "
      <> named_as
      <> " is corrupt: "
      <> corruption.describe(report)
    }),
  )
  let warnings =
    list.map(summary.problems(decoded), fn(problem) {
      "the summarization pack " <> named_as <> ": " <> describe_problem(problem)
    })
  Ok(#(decoded, warnings))
}
