//// The system-prompt pack: a swappable file of named sections, a total
//// decoder for it, and a pure renderer over a typed environment.
////
//// ## Why the words are not in this file
////
//// The system prompt is text that will be optimized — mutated, scored,
//// and replaced — without a release. So the words live in a *pack*: a
//// small text file of named, ordered sections carrying `{placeholder}`
//// holes, decoded here and rendered by `render`. Gleam holds the
//// mechanism; the pack holds every sentence a model ever reads. The
//// default pack ships as a string constant in `prompt/default`, and a
//// host may point at another one — mutate the pack, run the evaluation,
//// keep the winner, and never touch Gleam.
////
//// ## The format
////
//// A pack is UTF-8 text. Lines beginning with `%%` in column zero are
//// directives; every other line is body text of the section currently
//// open, kept **verbatim**, with no escaping of any kind. That is the
//// whole point of not using JSON here: prompt prose is full of quotes,
//// braces, backslashes and blank lines, and a format that makes an
//// author escape them is a format that will be edited wrongly.
////
//// ```text
//// %% loom-prompt-pack 1
//// %% version default-1
//// %% # a comment; ignored
//// %% section identity
//// You are an agent running as a strand inside Loom.
////
//// %% section environment
//// Workspace root: {workspace}
//// ```
////
//// Three directives exist and no others:
////
//// - `%% loom-prompt-pack <n>` — the *format* version, required, first.
////   `n` must equal `format_version`; anything else is corruption
////   rather than tolerated drift.
//// - `%% version <id>` — the *pack's own* identity, required, once,
////   before the first section. It is what telemetry records so a cache
////   miss can be attributed to a prompt change.
//// - `%% section <name>` — opens a section. Names are `[a-z0-9_]+`.
////
//// A line starting with `%%` whose content begins with `#` is a comment.
//// Any other unrecognized directive is corruption: a pack with a typo in
//// it is refused loudly rather than silently rendering the directive as
//// prose. The cost of that strictness is that a body line may not begin
//// with `%%`; indent it by one space if you ever need one.
////
//// ## Fragments
////
//// A section whose name begins with `_` is a **fragment**: it is never
//// rendered in its own right, only reached through a placeholder whose
//// value is chosen by the environment. That is how the sandbox section
//// says one thing on a fully enforced host and another on a degraded
//// one without the alternative wordings living in Gleam source.
////
//// ## Rendering is single-pass and never re-scans
////
//// `render` walks each template once, and a substituted value is emitted
//// straight to the output — it is never scanned for placeholders again.
//// So repository guidance containing the literal text `{shell}` renders
//// as `{shell}`, and no pack and no injected file can drive expansion in
//// a loop. Fragments are resolved one level deep, against the literal
//// bindings only, for the same reason.
////
//// ## Byte stability is the contract
////
//// A session's system prompt is rendered once, pinned, and sent
//// byte-identically on every request behind a one-hour cache
//// breakpoint; the tool array sits ahead of it in the cached prefix. A
//// single changed byte costs a full cache write at 2× base input, on
//// every strand, for the rest of the session. `render` is therefore a
//// pure function of exactly two values, and `Environment` is built so
//// that a clock, a date, a token count, a cost, a git state, an id or a
//// random value cannot be threaded through it: it has no numeric field
//// at all and this package depends on `core` and `gleam_stdlib` only,
//// so there is no time source in its dependency graph to reach for.
//// Volatile facts belong in run-start injections, which land *after*
//// the cached prefix. See `prompt/CLAUDE.md`.
////
//// Every list-valued field is sorted and de-duplicated when the
//// `Environment` is constructed, so a caller that happens to hand the
//// same set in a different order gets the same bytes.

import core/corruption.{type CorruptionReport}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// --- the format ----------------------------------------------------------

/// The only pack format version this module speaks. A pack declaring any
/// other number is corruption, never a best-effort decode: the format is
/// the boundary between a file someone edits by hand and the text a
/// model is given as its instructions.
pub const format_version = 1

/// The prefix that makes a line a directive rather than body text.
pub const directive_prefix = "%%"

/// The longest a section name or a pack version string may be, in
/// graphemes. Both are identifiers, not prose; the bound keeps a hostile
/// pack from putting a megabyte into an error report's subject.
pub const max_name_length = 64

/// The byte budget for injected repository guidance. Guidance longer
/// than this is cut at a line boundary and the cut is announced by the
/// `_repository_guidance_truncated` fragment — never silently.
pub const max_repository_guidance_bytes = 16_384

/// One named section of a pack, in the order the file listed it.
///
/// Invariants, established by `decode` and relied on by `render`:
/// `name` is non-empty, at most `max_name_length` graphemes, and drawn
/// from `[a-z0-9_]`; names are unique within a pack; `template` is the
/// section's body with leading and trailing whitespace trimmed, and
/// contains no line beginning with `directive_prefix`. A name beginning
/// with `_` marks a fragment, which `render` never emits on its own.
pub type Section {
  Section(name: String, template: String)
}

/// A decoded pack: its identity, its sections in file order, and a
/// fingerprint of the source it was decoded from.
///
/// Invariants: `version` is a non-empty `[a-z0-9._-]` identifier;
/// `sections` holds unique names in render order; `digest` is
/// `fingerprint` of the exact source text, and is a change-detection
/// fingerprint for cache attribution — **not** an integrity check, and
/// not to be used as one.
pub type Pack {
  Pack(version: String, digest: String, sections: List(Section))
}

// --- the environment -----------------------------------------------------

/// What kind of confinement the host actually delivers, stated
/// behaviourally rather than as a list of kernel layers.
///
/// The three values are exactly what the harness can know at session
/// open without inventing a probe: the demanded posture (`serve`'s
/// `demand`, `FullEnforcement` unless `--best-effort` was passed) paired
/// with the coarse `degraded` flag the helper advertises in its hello
/// (`broker/exec.degraded_features`). Nothing here enumerates layers,
/// because no per-layer report exists at open — the `skip:` list lives
/// inside an `ExecResult`, after a run, and the `ENFORCED`/`SKIPPED`
/// table is a separate `--self-test` process invocation.
pub type Enforcement {
  /// Full enforcement demanded and the helper advertises no degradation:
  /// a command that could not be confined as specified is refused rather
  /// than run unconfined, so a command that runs, ran jailed.
  FullyEnforced
  /// Full enforcement demanded but the helper advertises degradation.
  /// Every jailed execution fails — refused before dispatch, and refused
  /// again after the run if its enforcement report carries a `skip:`.
  /// This is a **host failure, not a policy denial**: escalation cannot
  /// clear it and retrying cannot either.
  DegradedRefusing
  /// Best effort was explicitly demanded — development containers and
  /// self-tests. Commands run with whatever the kernel here provides,
  /// which may be less than the policy asked for.
  BestEffort
}

/// The network posture the session's base policy composes to, mirrored
/// from `broker/policy.NetworkPolicy` because a pure package cannot
/// depend on the broker. Only what changes behaviour is carried: the
/// proxy address is deliberately absent.
pub type NetworkPosture {
  /// No egress. The net namespace is unshared and non-unix sockets are
  /// denied below the model.
  NetworkBlocked
  /// Egress only through the harness proxy, and only to `allow`, a list
  /// of host globs. Sorted and de-duplicated by `environment`.
  NetworkProxied(allow: List(String))
  /// No network restriction on this host.
  NetworkOpen
}

/// Everything the harness knows about where the agent is running.
///
/// Opaque on purpose. Every value goes in through `environment`, which
/// normalizes the list fields, so there is one construction path to
/// audit and no record-update shortcut through which a field could be
/// bolted on at a call site. The invariant every field must keep: **it
/// is fixed for the whole life of the session.** There is no numeric
/// field here and there must never be one — a millisecond, a token
/// count or a cost is what a timestamp arrives disguised as.
pub opaque type Environment {
  Environment(
    workspace: String,
    platform: String,
    shell: String,
    tools: List(String),
    enforcement: Enforcement,
    network: NetworkPosture,
    protected_paths: List(String),
    repository_guidance: Option(String),
  )
}

/// Builds an `Environment`, normalizing every list field: entries are
/// trimmed, empties dropped, then sorted and de-duplicated. Repository
/// guidance that is `Some("")` or whitespace becomes `None`, so an empty
/// guidance file does not render an empty frame.
///
/// Normalizing here rather than in `render` is what makes the byte
/// stability contract hold against a careless caller: two callers that
/// discovered the same tools in different orders render the same bytes.
///
/// ## Examples
///
/// ```gleam
/// let environment =
///   pack.environment(
///     workspace: "/work",
///     platform: "linux/x86_64",
///     shell: "/bin/bash",
///     tools: ["grep", "bash", "bash"],
///     enforcement: pack.FullyEnforced,
///     network: pack.NetworkBlocked,
///     protected_paths: [],
///     repository_guidance: option.None,
///   )
/// assert pack.tools(environment) == ["bash", "grep"]
/// ```
///
pub fn environment(
  workspace workspace: String,
  platform platform: String,
  shell shell: String,
  tools tools: List(String),
  enforcement enforcement: Enforcement,
  network network: NetworkPosture,
  protected_paths protected_paths: List(String),
  repository_guidance repository_guidance: Option(String),
) -> Environment {
  Environment(
    workspace:,
    platform:,
    shell:,
    tools: normalize(tools),
    enforcement:,
    network: case network {
      NetworkProxied(allow:) -> NetworkProxied(allow: normalize(allow))
      other -> other
    },
    protected_paths: normalize(protected_paths),
    repository_guidance: case repository_guidance {
      Some(text) ->
        case string.trim(text) {
          "" -> None
          _ -> Some(text)
        }
      None -> None
    },
  )
}

/// The environment's normalized tool names. Exposed because it is the
/// one field a caller may want to read back — the tool array on the wire
/// must be sorted for the same cache reason, and this is the sorted
/// list.
///
/// ## Examples
///
/// ```gleam
/// let environment =
///   pack.environment(
///     workspace: "/w",
///     platform: "p",
///     shell: "s",
///     tools: ["b", "a"],
///     enforcement: pack.BestEffort,
///     network: pack.NetworkOpen,
///     protected_paths: [],
///     repository_guidance: option.None,
///   )
/// assert pack.tools(environment) == ["a", "b"]
/// ```
///
pub fn tools(environment: Environment) -> List(String) {
  environment.tools
}

// Trims, drops empties, sorts, and de-duplicates — the normalization
// every list-valued environment field gets, so ordering at the call site
// cannot reach the rendered bytes.
fn normalize(values: List(String)) -> List(String) {
  values
  |> list.map(string.trim)
  |> list.filter(fn(value) { value != "" })
  |> list.sort(string.compare)
  |> list.unique
}

// --- names the pack and the renderer agree on ----------------------------

/// The sections a complete pack carries, in the order the design settled
/// on. `render` uses the pack's own order, not this one; this is the
/// list `problems` checks a pack against.
pub const canonical_sections = [
  "identity", "tool_discipline", "delegation", "conduct", "environment",
  "sandbox", "repository_guidance",
]

/// The fragments the bindings can select. A pack missing one of these
/// still renders — the placeholder resolves to empty — but it will be
/// silent about something on some host, which is why `problems` reports
/// it.
pub const required_fragments = [
  "_enforcement_enforced", "_enforcement_degraded", "_enforcement_best_effort",
  "_network_blocked", "_network_proxied", "_network_open", "_protected_paths",
  "_repository_guidance", "_repository_guidance_truncated",
]

/// Every placeholder name a pack may use. The closed list is half of why
/// a volatile value cannot get into the prompt: adding one would mean
/// adding a name here, a field to `Environment`, and a binding — three
/// visible edits in a file whose module doc says not to.
pub const binding_names = [
  "workspace", "platform", "shell", "tools", "protected_paths", "network_allow",
  "repository_guidance_text", "enforcement", "network", "protected",
  "repository_guidance",
]

/// Something wrong with a pack that is not bad syntax: the file decoded,
/// but it will not render what the harness expects it to.
pub type Problem {
  /// A canonical section or a selectable fragment is absent.
  MissingSection(name: String)
  /// A section uses a placeholder no binding provides. It renders as
  /// empty, which is usually a typo rather than an intention.
  UnknownPlaceholder(section: String, name: String)
}

/// Whether a problem reads as a mistake or as a choice.
///
/// The axis is here for the optimizer this whole format exists to serve.
/// A variant that scored badly because `{platfrom}` silently rendered
/// empty and a variant that scored badly because it deliberately dropped
/// `conduct` are indistinguishable in one flat list, so the fitness
/// signal carries corruption the optimizer cannot see. Split, the first
/// is discardable and the second is a measurement.
pub type Severity {
  /// The pack names something it does not carry: a placeholder no
  /// binding provides, or a fragment a binding selects. Nothing is said
  /// where something was meant to be, and the shortfall is invisible in
  /// the rendered bytes. Read it as a mistake; a caller may reasonably
  /// refuse a pack carrying one.
  Corrupting
  /// The pack is smaller than the canonical shape: a section is absent.
  /// That may be exactly what a mutation intended — a pack that drops a
  /// section is still a valid pack — so it is a difference to report,
  /// not a fault to refuse on.
  Shaping
}

/// Classifies one problem, as a pure function of the problem alone.
///
/// A missing *fragment* is corrupting: a fragment exists only to be
/// selected by a binding, so its absence makes a section that is present
/// say nothing on some host. A missing *canonical section* is shaping:
/// the pack is simply smaller, and that is allowed.
///
/// ## Examples
///
/// ```gleam
/// assert pack.severity(pack.MissingSection("conduct")) == pack.Shaping
/// ```
///
/// ```gleam
/// assert pack.severity(pack.MissingSection("_network_open"))
///   == pack.Corrupting
/// ```
///
/// ```gleam
/// assert pack.severity(pack.UnknownPlaceholder("environment", "platfrom"))
///   == pack.Corrupting
/// ```
///
pub fn severity(problem: Problem) -> Severity {
  case problem {
    UnknownPlaceholder(..) -> Corrupting
    MissingSection(name:) ->
      case is_fragment(name) {
        True -> Corrupting
        False -> Shaping
      }
  }
}

/// A pack's problems already split by `severity`, in the order
/// `problems` reported them.
///
/// The split is what a caller keys on. `corrupting == []` is the
/// optimizer's question — is this variant scorable at all — as one
/// expression, and `shaping` is what an operator is told about a pack
/// that runs anyway. Between them they hold exactly what `problems`
/// returns and nothing more.
pub type Assessment {
  Assessment(corrupting: List(Problem), shaping: List(Problem))
}

/// Reports a pack's problems already split along the severity axis.
/// Equivalent to partitioning `problems` by `severity`, and offered as
/// one call because refusing on corruption is a whole-pack decision.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) =
///   pack.decode("%% loom-prompt-pack 1\n%% version t\n%% section identity\nhi")
/// assert pack.assess(decoded).corrupting != []
/// ```
///
pub fn assess(pack: Pack) -> Assessment {
  let #(corrupting, shaping) =
    list.partition(problems(pack), fn(problem) {
      severity(problem) == Corrupting
    })
  Assessment(corrupting:, shaping:)
}

/// Reports what is missing or misspelled in a decoded pack. Empty means
/// the pack is complete. This is deliberately *not* part of `decode`: a
/// mutated pack that drops a section is still a valid pack, and the
/// harness decides whether to run with it or refuse.
///
/// The list is flat and unranked. A caller deciding what to do about a
/// problem wants `severity`, or `assess` for the whole pack at once.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) =
///   pack.decode("%% loom-prompt-pack 1\n%% version t\n%% section identity\nhi\n")
/// assert list.contains(pack.problems(decoded), pack.MissingSection("conduct"))
/// ```
///
pub fn problems(pack: Pack) -> List(Problem) {
  let present = list.map(pack.sections, fn(section) { section.name })
  let missing =
    list.append(canonical_sections, required_fragments)
    |> list.filter(fn(name) { !list.contains(present, name) })
    |> list.map(MissingSection)
  let unknown =
    list.flat_map(pack.sections, fn(section) {
      placeholders(section.template)
      |> list.filter(fn(name) { !list.contains(binding_names, name) })
      |> list.map(fn(name) { UnknownPlaceholder(section: section.name, name:) })
    })
  list.append(missing, unknown)
}

/// The placeholder names a template refers to, in first-appearance
/// order, without duplicates.
///
/// ## Examples
///
/// ```gleam
/// assert pack.placeholders("{a} and {a} and {b}") == ["a", "b"]
/// ```
///
/// ```gleam
/// assert pack.placeholders("{ not one } {}") == []
/// ```
///
pub fn placeholders(template: String) -> List(String) {
  placeholder_loop(string.to_graphemes(template), [])
  |> list.reverse
  |> list.unique
}

fn placeholder_loop(
  graphemes: List(String),
  found: List(String),
) -> List(String) {
  case graphemes {
    [] -> found
    ["{", ..rest] -> {
      let #(name, tail) = take_name(rest, [])
      case tail {
        ["}", ..after] if name != "" -> placeholder_loop(after, [name, ..found])
        _ -> placeholder_loop(rest, found)
      }
    }
    [_, ..rest] -> placeholder_loop(rest, found)
  }
}

// --- decoding ------------------------------------------------------------

// The decoder's running state. Sections and body lines accumulate
// reversed and are flipped when a section closes, so decoding stays
// linear in the source length.
type Reading {
  Reading(
    header: Bool,
    version: Option(String),
    done: List(Section),
    open: Option(#(String, List(String))),
  )
}

/// Decodes pack source. Total: every malformed input — a missing header,
/// an unknown directive, a duplicate section, a bad name — is a
/// `CorruptionReport` naming the line, never a crash and never a partial
/// pack.
///
/// Line endings are normalized: a trailing carriage return is dropped
/// from every line, so a pack edited on Windows renders the same bytes
/// as one edited anywhere else.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) =
///   pack.decode("%% loom-prompt-pack 1\n%% version v1\n%% section conduct\nBe terse.\n")
/// assert decoded.sections == [pack.Section("conduct", "Be terse.")]
/// ```
///
/// ```gleam
/// let assert Error(report) = pack.decode("hello")
/// assert report.boundary == "prompt/pack.decode"
/// ```
///
pub fn decode(source: String) -> Result(Pack, CorruptionReport) {
  let start = Reading(header: False, version: None, done: [], open: None)
  use reading <- result.try(
    string.split(source, on: "\n")
    |> list.map(strip_carriage_return)
    |> list.index_fold(Ok(start), fn(state, line, index) {
      result.try(state, read_line(_, line, index + 1))
    }),
  )
  use version <- result.try(case reading.header, reading.version {
    False, _ ->
      Error(report_at(
        0,
        "a `%% loom-prompt-pack "
          <> int.to_string(format_version)
          <> "` header line",
        "",
      ))
    True, None -> Error(report_at(0, "a `%% version <id>` directive", ""))
    True, Some(version) -> Ok(version)
  })
  Ok(Pack(
    version:,
    digest: fingerprint(source),
    sections: list.reverse(close_open(reading).done),
  ))
}

// One line of the source. Directives are recognized only in column zero,
// which is what lets every other line be kept byte for byte.
fn read_line(
  reading: Reading,
  line: String,
  number: Int,
) -> Result(Reading, CorruptionReport) {
  case string.starts_with(line, directive_prefix), reading.open {
    True, _ -> read_directive(reading, line, number)
    False, Some(#(name, body)) ->
      Ok(Reading(..reading, open: Some(#(name, [line, ..body]))))
    // Outside any section only blank lines are allowed: stray prose
    // before the first `%% section` would otherwise vanish silently,
    // and a vanished instruction is the worst kind of pack bug.
    False, None ->
      case string.trim(line) {
        "" -> Ok(reading)
        _ -> Error(report_at(number, "a directive or a blank line", line))
      }
  }
}

fn read_directive(
  reading: Reading,
  line: String,
  number: Int,
) -> Result(Reading, CorruptionReport) {
  let content = string.trim(string.drop_start(line, 2))
  case string.starts_with(content, "#") {
    True -> Ok(reading)
    False -> {
      // A directive with no argument keeps an empty one and is rejected
      // by the reader it belongs to, so `%% section` fails as a bad name
      // rather than as a separate shape of error.
      let #(keyword, argument) = case string.split_once(content, on: " ") {
        Ok(#(keyword, argument)) -> #(keyword, string.trim(argument))
        Error(Nil) -> #(content, "")
      }
      case keyword {
        "loom-prompt-pack" -> read_header(reading, argument, number)
        "version" -> read_version(reading, argument, number)
        "section" -> read_section(reading, argument, number)
        _ ->
          Error(report_at(
            number,
            "one of `loom-prompt-pack`, `version`, `section`",
            content,
          ))
      }
    }
  }
}

fn read_header(
  reading: Reading,
  argument: String,
  number: Int,
) -> Result(Reading, CorruptionReport) {
  case reading.header, int.parse(argument) {
    True, _ -> Error(report_at(number, "exactly one pack header", argument))
    False, Ok(version) if version == format_version ->
      Ok(Reading(..reading, header: True))
    False, _ ->
      Error(report_at(
        number,
        "format version " <> int.to_string(format_version),
        argument,
      ))
  }
}

fn read_version(
  reading: Reading,
  argument: String,
  number: Int,
) -> Result(Reading, CorruptionReport) {
  case reading.header, reading.version, reading.open {
    False, _, _ -> Error(report_at(number, "the pack header first", argument))
    _, Some(_), _ ->
      Error(report_at(number, "exactly one version directive", argument))
    _, _, Some(_) ->
      Error(report_at(number, "the version before the first section", argument))
    True, None, None ->
      case valid_name(argument, version_alphabet) {
        True -> Ok(Reading(..reading, version: Some(argument)))
        False ->
          Error(report_at(
            number,
            "a version of 1-"
              <> int.to_string(max_name_length)
              <> " characters from [a-z0-9._-]",
            argument,
          ))
      }
  }
}

fn read_section(
  reading: Reading,
  argument: String,
  number: Int,
) -> Result(Reading, CorruptionReport) {
  let closed = close_open(reading)
  let taken = list.map(closed.done, fn(section) { section.name })
  case closed.header, closed.version {
    False, _ -> Error(report_at(number, "the pack header first", argument))
    _, None ->
      Error(report_at(number, "a version before the first section", argument))
    True, Some(_) ->
      case valid_name(argument, name_alphabet), list.contains(taken, argument) {
        False, _ ->
          Error(report_at(
            number,
            "a section name of 1-"
              <> int.to_string(max_name_length)
              <> " characters from [a-z0-9_]",
            argument,
          ))
        // Two sections of one name have no single meaning — the same
        // rule `core`'s codecs apply to duplicate keys.
        True, True ->
          Error(report_at(number, "a section name used once", argument))
        True, False -> Ok(Reading(..closed, open: Some(#(argument, []))))
      }
  }
}

// Closes whatever section is open, trimming its body. Trimming is what
// makes a trailing newline, or a blank line before the next directive,
// invisible to the rendered bytes.
fn close_open(reading: Reading) -> Reading {
  case reading.open {
    None -> reading
    Some(#(name, body)) -> {
      let template =
        list.reverse(body)
        |> string.join("\n")
        |> string.trim
      Reading(
        ..reading,
        done: [Section(name:, template:), ..reading.done],
        open: None,
      )
    }
  }
}

const name_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789_"

const version_alphabet = "abcdefghijklmnopqrstuvwxyz0123456789._-"

fn valid_name(name: String, alphabet: String) -> Bool {
  let length = string.length(name)
  length > 0
  && length <= max_name_length
  && list.all(string.to_graphemes(name), string.contains(alphabet, _))
}

fn strip_carriage_return(line: String) -> String {
  case string.ends_with(line, "\r") {
    True -> string.drop_end(line, 1)
    False -> line
  }
}

fn report_at(
  number: Int,
  expected: String,
  context: String,
) -> CorruptionReport {
  corruption.report(
    at: "prompt/pack.decode",
    on: case number {
      0 -> "the pack as a whole"
      _ -> "line " <> int.to_string(number)
    },
    expected:,
    context:,
  )
}

// --- encoding ------------------------------------------------------------

/// Renders a pack back to source. `decode` of the result is the pack it
/// was given, for any pack `decode` produced — which is what a prompt
/// optimizer needs to write its mutations back out.
///
/// The one caveat, on a `Pack` built in Gleam rather than decoded: a
/// template line beginning with `%%` would come back as a directive.
/// `decode` cannot produce such a template, so a round trip is safe by
/// construction for everything that came from a file.
///
/// ## Examples
///
/// ```gleam
/// let source = "%% loom-prompt-pack 1\n%% version v1\n%% section conduct\nBe terse."
/// let assert Ok(decoded) = pack.decode(source)
/// assert pack.decode(pack.encode(decoded)) == Ok(decoded)
/// ```
///
pub fn encode(pack: Pack) -> String {
  let head =
    directive_prefix
    <> " loom-prompt-pack "
    <> int.to_string(format_version)
    <> "\n"
    <> directive_prefix
    <> " version "
    <> pack.version
    <> "\n"
  list.fold(pack.sections, head, fn(text, section) {
    text
    <> directive_prefix
    <> " section "
    <> section.name
    <> "\n"
    <> section.template
    <> "\n"
  })
}

// --- rendering -----------------------------------------------------------

/// Renders a pack against an environment into the session's system
/// prompt.
///
/// Total by construction: an unknown placeholder renders as empty, an
/// unclosed or non-identifier brace renders literally, a missing section
/// is simply absent, and a section that renders to nothing is dropped
/// along with the blank line that would have followed it. Fragments —
/// sections named with a leading `_` — are never emitted directly.
///
/// The output is normalized: sections joined by one blank line, runs of
/// blank lines collapsed to one, trailing whitespace removed from every
/// line, no trailing newline. Normalizing is a stability measure — an
/// editor that leaves a trailing space in the pack must not cost a cache
/// write.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(decoded) =
///   pack.decode("%% loom-prompt-pack 1\n%% version v1\n%% section environment\nRoot: {workspace}")
/// let host =
///   pack.environment(
///     workspace: "/work",
///     platform: "linux/x86_64",
///     shell: "/bin/bash",
///     tools: [],
///     enforcement: pack.FullyEnforced,
///     network: pack.NetworkBlocked,
///     protected_paths: [],
///     repository_guidance: option.None,
///   )
/// assert pack.render(decoded, host) == "Root: /work"
/// ```
///
pub fn render(pack: Pack, environment: Environment) -> String {
  let bindings = bindings(pack, environment)
  pack.sections
  |> list.filter(fn(section) { !is_fragment(section.name) })
  |> list.map(fn(section) {
    string.trim(substitute(section.template, bindings))
  })
  |> list.filter(fn(body) { body != "" })
  |> string.join("\n\n")
  |> tidy
}

fn is_fragment(name: String) -> Bool {
  string.starts_with(name, "_")
}

// The bindings are built in two tiers. Literal bindings are plain
// strings taken from the environment. Selected bindings name a
// *fragment* whose body the environment chooses, and that body is
// substituted against the literal tier only — one level, no recursion,
// so no pack can drive expansion in a loop.
fn bindings(pack: Pack, environment: Environment) -> Dict(String, String) {
  let literal =
    dict.from_list([
      #("workspace", environment.workspace),
      #("platform", environment.platform),
      #("shell", environment.shell),
      #("tools", join(environment.tools)),
      #("protected_paths", join(environment.protected_paths)),
      #("network_allow", join(allowed_hosts(environment.network))),
      #("repository_guidance_text", guidance_text(pack, environment)),
    ])
  let selected = [
    #(
      "enforcement",
      fragment(pack, enforcement_fragment(environment.enforcement), literal),
    ),
    #("network", fragment(pack, network_fragment(environment.network), literal)),
    #("protected", case environment.protected_paths {
      [] -> ""
      _ -> fragment(pack, "_protected_paths", literal)
    }),
    #("repository_guidance", case environment.repository_guidance {
      None -> ""
      Some(_) -> fragment(pack, "_repository_guidance", literal)
    }),
  ]
  dict.merge(literal, dict.from_list(selected))
}

fn enforcement_fragment(enforcement: Enforcement) -> String {
  case enforcement {
    FullyEnforced -> "_enforcement_enforced"
    DegradedRefusing -> "_enforcement_degraded"
    BestEffort -> "_enforcement_best_effort"
  }
}

fn network_fragment(network: NetworkPosture) -> String {
  case network {
    NetworkBlocked -> "_network_blocked"
    NetworkProxied(_) -> "_network_proxied"
    NetworkOpen -> "_network_open"
  }
}

fn allowed_hosts(network: NetworkPosture) -> List(String) {
  case network {
    NetworkProxied(allow:) -> allow
    NetworkBlocked | NetworkOpen -> []
  }
}

// A fragment body with the literal bindings filled in, or the empty
// string when the pack does not carry it. `problems` is what tells an
// operator the fragment is missing; `render` stays total.
fn fragment(pack: Pack, name: String, literal: Dict(String, String)) -> String {
  case body(pack, name) {
    Ok(template) -> substitute(template, literal)
    Error(Nil) -> ""
  }
}

fn body(pack: Pack, name: String) -> Result(String, Nil) {
  list.find_map(pack.sections, fn(section) {
    case section.name == name {
      True -> Ok(section.template)
      False -> Error(Nil)
    }
  })
}

fn join(values: List(String)) -> String {
  string.join(values, ", ")
}

// Repository guidance is project-authored data, not the operator's
// words. It is capped at a line boundary, and a cut is announced with
// the pack's own truncation fragment rather than a sentence welded in
// here. The text itself is inserted verbatim and never re-scanned, so a
// guidance file containing `{workspace}` renders those characters.
fn guidance_text(pack: Pack, environment: Environment) -> String {
  case environment.repository_guidance {
    None -> ""
    Some(text) ->
      case cap(text, max_repository_guidance_bytes) {
        #(kept, False) -> kept
        #(kept, True) ->
          kept
          <> "\n\n"
          <> result.unwrap(body(pack, "_repository_guidance_truncated"), "")
      }
  }
}

// Keeps whole lines while they fit the byte budget. A first line that
// alone exceeds the budget keeps nothing: cutting mid-line is how a
// truncation marker ends up inside a sentence it appears to be part of.
fn cap(text: String, budget: Int) -> #(String, Bool) {
  cap_loop(string.split(text, on: "\n"), budget, [])
}

fn cap_loop(
  lines: List(String),
  remaining: Int,
  kept: List(String),
) -> #(String, Bool) {
  case lines {
    [] -> #(string.join(list.reverse(kept), "\n"), False)
    [line, ..rest] -> {
      let cost = byte_size(line) + 1
      case cost <= remaining {
        True -> cap_loop(rest, remaining - cost, [line, ..kept])
        False -> #(string.join(list.reverse(kept), "\n"), True)
      }
    }
  }
}

fn byte_size(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}

// One pass over the template. A substituted value goes straight into the
// output and is never looked at again, which is the property that makes
// injected file content inert here.
fn substitute(template: String, bindings: Dict(String, String)) -> String {
  substitute_loop(string.to_graphemes(template), bindings, [])
}

fn substitute_loop(
  graphemes: List(String),
  bindings: Dict(String, String),
  acc: List(String),
) -> String {
  case graphemes {
    [] -> string.concat(list.reverse(acc))
    ["{", ..rest] -> {
      let #(name, tail) = take_name(rest, [])
      case tail {
        ["}", ..after] if name != "" ->
          substitute_loop(after, bindings, [
            result.unwrap(dict.get(bindings, name), ""),
            ..acc
          ])
        // Not a placeholder: emit the brace and rescan from the next
        // grapheme, so `{ "a": 1 }` and a lone `{` survive untouched.
        _ -> substitute_loop(rest, bindings, ["{", ..acc])
      }
    }
    [grapheme, ..rest] -> substitute_loop(rest, bindings, [grapheme, ..acc])
  }
}

fn take_name(
  graphemes: List(String),
  taken: List(String),
) -> #(String, List(String)) {
  case graphemes {
    [grapheme, ..rest] ->
      case string.contains(name_alphabet, grapheme) {
        True -> take_name(rest, [grapheme, ..taken])
        False -> #(string.concat(list.reverse(taken)), graphemes)
      }
    [] -> #(string.concat(list.reverse(taken)), graphemes)
  }
}

// Collapses the gaps an absent fragment leaves behind: trailing
// whitespace off every line, runs of blank lines down to one, and no
// blank line at either end.
fn tidy(text: String) -> String {
  string.split(text, on: "\n")
  |> list.fold([], fn(kept, line) {
    let trimmed = string.trim_end(line)
    case trimmed == "", kept {
      True, [] -> kept
      True, ["", ..] -> kept
      True, _ -> ["", ..kept]
      False, _ -> [trimmed, ..kept]
    }
  })
  |> list.drop_while(fn(line) { line == "" })
  |> list.reverse
  |> string.join("\n")
}

// --- fingerprinting ------------------------------------------------------

/// A 64-bit FNV-1a fingerprint of a string, as 16 lowercase hex digits.
///
/// This exists so a cache miss can be attributed to a prompt change: the
/// digest is recorded once per session beside the usage ledger. It is
/// **not** a cryptographic hash and must not be used as an integrity or
/// authenticity check; a pure package has no hash primitive and does not
/// need one for change detection.
///
/// ## Examples
///
/// ```gleam
/// assert pack.fingerprint("") == "cbf29ce484222325"
/// ```
///
/// ```gleam
/// assert pack.fingerprint("a") != pack.fingerprint("b")
/// ```
///
pub fn fingerprint(text: String) -> String {
  hex(fnv_loop(bit_array.from_string(text), fnv_offset_basis), 16, "")
}

const fnv_offset_basis = 14_695_981_039_346_656_037

const fnv_prime = 1_099_511_628_211

const fnv_mask = 18_446_744_073_709_551_615

fn fnv_loop(bytes: BitArray, hash: Int) -> Int {
  case bytes {
    <<byte, rest:bits>> ->
      fnv_loop(
        rest,
        int.bitwise_and(
          int.bitwise_exclusive_or(hash, byte) * fnv_prime,
          fnv_mask,
        ),
      )
    _ -> hash
  }
}

fn hex(value: Int, digits: Int, acc: String) -> String {
  case digits {
    0 -> acc
    _ ->
      hex(
        int.bitwise_shift_right(value, 4),
        digits - 1,
        hex_digit(int.bitwise_and(value, 15)) <> acc,
      )
  }
}

fn hex_digit(nibble: Int) -> String {
  case nibble {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    10 -> "a"
    11 -> "b"
    12 -> "c"
    13 -> "d"
    14 -> "e"
    _ -> "f"
  }
}
