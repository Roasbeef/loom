//// The distillation pipeline: extract, then consolidate, then render —
//// an operator-scheduled pass over a repository's session files that
//// leaves a fresh memory digest behind.
////
//// ```sh
//// gleam run -m client/distill -- --session-dir /data --config loom.toml
//// ```
////
//// # It is a command, not a resident
////
//// Nothing inside `loomd` runs this. It is cron, or a post-session
//// hook, or a person at a terminal — "not a per-turn hook", as the
//// design note demands — and it holds the memory session's ordinary
//// writer lease for the length of the run. That lease *is* the
//// consolidation's single-writer guarantee: a second concurrent
//// `distill` loses `LeaseHeld` at the open and says so, and a `remember`
//// call landing mid-run is refused in band with the same fact. No new
//// lease type, no heartbeat, no background writer.
////
//// # Which sessions it reads, and how it skips the live ones
////
//// It walks the session directory's `*.db` files, excluding
//// `loom-memory.db` and the search index, and opens each with the
//// ordinary writer lease. **A live server holds its session's lease, so
//// the open fails and the pipeline skips that file.** That is the whole
//// of the "skip sessions that are still in use" rule: no clock
//// arithmetic, no idle heuristic, no second read path — the lease
//// already answers the question exactly.
////
//// Per-source progress is a `{seq, rewrite generation}` cursor in the
//// memory session (`client/memory.cursor_key`). A generation that no
//// longer matches voids the seq and the source is read again from zero,
//// because a precise rewrite renumbers every entry.
////
//// # What extraction is allowed to read
////
//// `extractable` is the whole answer, and it is structural rather than
//// textual: settled **assistant** text as `client/rules.scannable_text`
//// defines it — shared with the triggered-rule scanner, not restated —
//// plus compaction and branch summaries. Never user turns, never tool
//// results, never `CustomEntry`.
////
//// That single rule is the anti-feedback exclusion the security
//// paragraph asks for, obtained by type rather than by string matching:
//// an injected memory digest is a *user* message, so it is excluded by
//// role; `memory/*` rows are excluded twice over, since they are
//// `CustomEntry` and since this pipeline never opens the memory file as
//// a source at all.
////
//// **The honest limit, recorded beside erasure in `docs/spec-gaps.md`:**
//// once a summarizer has paraphrased a digest into a compaction summary,
//// no type survives to exclude. Dilution-through-summaries reaches the
//// same first-derivation boundary erasure does. Stated, not defended.
////
//// # The order of the writes is the crash safety
////
//// A consolidation appends its new `memory/*` rows first, CASes the
//// head pointer last, and writes the sidecar after that commit. A run
//// killed at any point therefore leaves the previous head, the previous
//// cursors and the previous digest standing together — the rows it had
//// already written are orphans nothing reads. `client/memory` splits
//// `append_distillates` from `advance_head` for exactly this reason, and
//// a test drives the two phases with the kill in between.
////
//// # The erasure cascade is the same command, with a flag
////
//// ```sh
//// gleam run -m client/distill -- --cascade <source-session-id>
//// ```
////
//// Run after `session/repo` has rewritten a source session, `--cascade`
//// drops from the memory head every distillate whose provenance names
//// that session and re-renders the sidecar without them (`cascade`). It
//// dispatches no model turn, so it needs no `--config`; it writes no
//// rows, because every survivor is already durable; and it moves no
//// cursor, because the rewrite generation the erase bumped already
//// forces the source to be re-extracted from zero.
////
//// It is the pipeline's ordinary head replacement, and inherits the
//// crash semantics above unchanged — a cascade killed after the CAS is
//// reconciled by the next run like any other. **First-order only**: the
//// boundary is issue #115's own, recorded in `docs/spec-gaps.md`.
////
//// **What it costs, which is more than it looks.** A head is one
//// consolidation's batch and so is uniform in provenance, so a cascade
//// that matches anything at all empties the head. Only the erased
//// source is then re-read — every other source keeps its cursor, and
//// the notes cursor sits past every note already consumed — so their
//// contribution is permanently unrecoverable by this pipeline. That is
//// a defect rather than a design: issue #124 carries the mechanism, and
//// `cascade`'s own doc spells the sequence out.
////
//// # Where the model comes in
////
//// Two provider calls per run — one extraction per source, one
//// consolidation — dispatched through the `Summarize` role when the
//// catalogue routes one and against the main entry's resolved identity
//// when it does not. The summary path's exact arrangement
//// (`client/wiring`'s `summary_target`), no new role and no protocol
//// change. Both calls' usage rows land in the memory session's own
//// ledger, so memory's cost is visible where memory lives.
////
//// The provider is reached through the `Distiller` seam below rather
//// than directly, which is what lets a test script both turns and drive
//// every phase without a network.

import argv
import broker/token
import client/catalog
import client/internal/ffi_os
import client/memory.{type Cursor, type Opened, type Provenance}
import client/notes
import client/rules
import core/clock.{type Clock}
import core/entry.{type Entry}
import core/ids.{type Generator, type Seq}
import core/json
import core/message.{type AgentMessage, type Usage}
import core/tx.{InsertUsage, Tx}
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/gateway as provider_gateway
import provider/http
import provider/model.{type RequestTarget, ForResolved, ForRole}
import provider/secret
import provider/stream
import session/session
import simplifile
import storage/sqlite
import storage/storage
import telemetry/field
import telemetry/handler
import telemetry/log.{type Logger}

// --- the seams -------------------------------------------------------------

/// What one model turn answered: its text, and what it cost.
pub type Answer {
  Answer(text: String, usage: Usage)
}

/// The pipeline's whole provider surface: one prompt in, one settled
/// answer out.
///
/// Constructor invariants: `ask` is total — it returns a worded `Error`,
/// it does not crash — and it has already decided which identity the
/// turn dispatches to (`target`). Production fills it with
/// `gateway_distiller`; a test fills it with a script and the pipeline
/// cannot tell the difference.
pub type Distiller {
  Distiller(ask: fn(String) -> Result(Answer, String))
}

/// One candidate distillate: a pipeline entry type and its text.
///
/// Constructor invariants: `kind` is one of `client/memory.pipeline_types`
/// and nothing else — `parse_candidates` is the only constructor that
/// reads model output, and it maps short names through
/// `memory.type_named`, so an answer that invents a type produces no
/// candidate rather than a row under a forged type.
pub type Candidate {
  Candidate(kind: String, text: String)
}

/// What one source session contributed: the entry ids read, the text
/// they carried, and how far the read got.
pub type Extract {
  Extract(entries: List(String), text: String, newest_seq: Seq)
}

/// One source session, harvested and ready for extraction.
pub type Harvest {
  Harvest(session: String, path: String, cursor: Cursor, extract: Extract)
}

/// What a run did, for the operator's one line.
///
/// Constructor invariants: `sources` counts the sessions that
/// contributed; `skipped` counts the ones a live lease or a read failure
/// put out of reach — **not** the ones that opened cleanly and had
/// nothing new, which are the steady state and are counted nowhere.
pub type Report {
  Report(
    sources: Int,
    skipped: Int,
    candidates: Int,
    rows: Int,
    digest: Option(Int),
  )
}

// --- the caps --------------------------------------------------------------

/// The most entries one source contributes to one run. A bound on the
/// work a single pass can cause, not on what is eventually read:
/// whatever this leaves behind stays above the cursor for the next run.
pub const default_scan_limit = 512

/// The most characters of transcript one extraction prompt carries.
/// Roughly twenty thousand tokens by the chars/4 rule — generous for a
/// cheap summarization role, and a bound rather than a hope.
pub const max_extract_chars = 80_000

/// The most notes one consolidation folds in from the `remember` door.
pub const max_notes_per_run = 64

/// How long one provider turn may take.
pub const default_timeout_ms = 300_000

// --- the pure phases -------------------------------------------------------

/// The text one entry contributes to extraction, or `None`.
///
/// **This is the anti-feedback rule**, and it is a rule about types
/// rather than about strings:
///
/// - a settled assistant message contributes its visible text, exactly
///   as `client/rules.scannable_text` defines it (shared with the
///   triggered-rule scanner — one definition of "what the model
///   actually said");
/// - a compaction or branch summary contributes its summary;
/// - **a user message contributes nothing**, which is what excludes an
///   injected memory digest from ever being re-ingested, since a digest
///   is injected as a user turn;
/// - **a `CustomEntry` contributes nothing**, which excludes `memory/*`
///   rows found in a source session.
///
/// ## Examples
///
/// ```gleam
/// // distill.extractable(user_message) == option.None
/// ```
///
pub fn extractable(item: Entry) -> Option(String) {
  case item {
    entry.CompactionEntry(summary:, ..) -> Some(summary)
    entry.BranchSummaryEntry(summary:, ..) -> Some(summary)

    // Assistant text and nothing else: `scannable_text` answers `None`
    // for every user and tool-result message, which is the exclusion.
    entry.MessageEntry(..) -> rules.scannable_text(item)
    entry.CustomEntry(..) -> None
  }
}

/// Folds a source session's entries into one extraction input: the ids
/// that contributed, their text, and the greatest seq seen.
///
/// Pure, and the reason it is: this is the function the anti-feedback
/// test asserts on directly, before any provider or store is involved.
/// The seq advances over **every** entry examined, not only the
/// contributing ones, so a stretch of user turns does not make the
/// cursor stand still and re-read them forever.
///
/// ## Examples
///
/// ```gleam
/// // distill.extraction_input(entries).entries == ["01924…"]
/// ```
///
pub fn extraction_input(entries: List(Entry)) -> Extract {
  // The texts are collected and joined once rather than concatenated as
  // the fold goes: `scan_limit` entries appended one at a time would copy
  // the whole accumulated transcript per entry, which is the quadratic
  // shape `docs/gleam-style.md` Part III tells the story of.
  let #(seen, texts, newest_seq) =
    list.fold(entries, #([], [], 0), fn(carried, item) {
      let #(seen, texts, newest) = carried
      let newest = int.max(newest, item.seq)
      case extractable(item) {
        None -> #(seen, texts, newest)
        Some(text) -> #(
          [ids.entry_id_to_string(item.id), ..seen],
          [text, ..texts],
          newest,
        )
      }
    })
  Extract(
    entries: list.reverse(seen),
    text: list.reverse(texts)
      |> string.join("\n\n")
      |> string.slice(at_index: 0, length: max_extract_chars),
    newest_seq:,
  )
}

/// The extraction prompt for one source session.
///
/// ## Examples
///
/// ```gleam
/// // distill.extraction_prompt(harvest) |> string.contains("fact:")
/// ```
///
pub fn extraction_prompt(harvest: Harvest) -> String {
  "You are distilling durable memory for a software repository, from the "
  <> "settled output of one past working session.\n\n"
  <> line_format
  <> "\n\nWrite only what will still be true and useful in a session months "
  <> "from now: how this repository is built and tested, a mistake worth not "
  <> "repeating, a stated preference. Do not restate anything a reader could "
  <> "see by opening the repository. Do not copy secrets, keys, paths to "
  <> "private files, or long verbatim excerpts. If there is nothing worth "
  <> "remembering, answer with the single word `nothing`.\n\n"
  <> "Session "
  <> harvest.session
  <> ", settled assistant output and summaries:\n\n"
  <> quoted(harvest.extract.text)
}

/// The consolidation prompt: what memory currently says, what this run
/// extracted, and what was written down by hand.
///
/// ## Examples
///
/// ```gleam
/// // distill.consolidation_prompt([], [], []) |> string.contains("nothing")
/// ```
///
pub fn consolidation_prompt(
  current: List(memory.Distillate),
  candidates: List(Candidate),
  notes: List(memory.Distillate),
) -> String {
  "You are consolidating the durable memory of a software repository. "
  <> "Merge what memory already says with what has just been distilled and "
  <> "with what was written down by hand, then write the whole of memory "
  <> "back — this replaces it.\n\n"
  <> line_format
  <> "\n\nWrite at most "
  <> int.to_string(memory.max_distillates)
  <> " lines, ordered most useful first. Merge duplicates, drop anything "
  <> "that has plainly gone stale, and keep every line short enough to read "
  <> "at a glance. Do not copy secrets or long verbatim excerpts. If "
  <> "everything below is worthless, answer with the single word "
  <> "`nothing`.\n\n"
  <> "What memory says now:\n\n"
  <> quoted(rendered_rows(current))
  <> "\n\nNewly distilled from recent sessions:\n\n"
  <> quoted(rendered_candidates(candidates))
  <> "\n\nWritten down by hand with the remember tool:\n\n"
  <> quoted(rendered_rows(notes))
}

const line_format = "Answer with one line per item, and nothing else. Each "
  <> "line is `fact: …`, `lesson: …` or `preference: …`."

fn rendered_rows(rows: List(memory.Distillate)) -> String {
  case rows {
    [] -> "(nothing)"
    found ->
      found
      |> list.map(fn(row) { memory.short_name(row.kind) <> ": " <> row.text })
      |> string.join("\n")
  }
}

fn rendered_candidates(candidates: List(Candidate)) -> String {
  case candidates {
    [] -> "(nothing)"
    found ->
      found
      |> list.map(fn(row) { memory.short_name(row.kind) <> ": " <> row.text })
      |> string.join("\n")
  }
}

// The model's own text goes inside a fence, and a fence inside it is
// broken rather than deleted — the same defence every quoted-data
// rendering in this tree uses.
fn quoted(text: String) -> String {
  "```transcript\n" <> notes.fence_safe(text) <> "\n```"
}

/// Reads a model answer as candidate distillates.
///
/// Total and unforgiving in the safe direction: a line whose prefix is
/// not one of the three pipeline short names produces nothing, so a
/// model that invents `note:` — the one type reserved for the
/// `remember` door — writes no row. Bounded by `max_distillates`,
/// because the answer is model output and its length is not a promise.
///
/// ## Examples
///
/// ```gleam
/// assert distill.parse_candidates("fact: make check is the gate")
///   == [distill.Candidate(kind: "memory/fact", text: "make check is the gate")]
/// ```
///
/// ```gleam
/// assert distill.parse_candidates("note: sneaky") == []
/// ```
///
pub fn parse_candidates(text: String) -> List(Candidate) {
  text
  |> string.split("\n")
  |> list.filter_map(candidate_line)
  |> list.take(memory.max_distillates)
}

fn candidate_line(line: String) -> Result(Candidate, Nil) {
  let bare =
    line
    |> string.trim
    |> string.replace(each: "* ", with: "")
    |> unbulleted
  use #(short, text) <- result.try(string.split_once(bare, ":"))
  use kind <- result.try(
    memory.type_named(string.lowercase(string.trim(short))),
  )
  case string.trim(text) {
    "" -> Error(Nil)
    said -> Ok(Candidate(kind:, text: said))
  }
}

fn unbulleted(line: String) -> String {
  case string.starts_with(line, "- ") {
    True -> string.drop_start(line, 2)
    False -> line
  }
}

// --- the run ---------------------------------------------------------------

/// Everything one run needs.
///
/// Constructor invariants: `directory` is the session directory (the
/// fold); `memory_path` and `digest_path` are the memory store and its
/// sidecar inside it; `distiller` has already chosen its dispatch
/// target; `entropy` seeds a fresh id generator per open.
pub type Config {
  Config(
    directory: String,
    memory_path: String,
    digest_path: String,
    distiller: Distiller,
    clock: Clock,
    entropy: fn() -> Int,
    logger: Logger,
    scan_limit: Int,
  )
}

/// The shipped configuration for a session directory: the memory store
/// and sidecar beside it, the tree's scan limit, a silent logger.
///
/// ## Examples
///
/// ```gleam
/// // distill.config_for("/data", distiller, clock:, entropy:)
/// ```
///
pub fn config_for(
  directory: String,
  distiller: Distiller,
  clock clock: Clock,
  entropy entropy: fn() -> Int,
) -> Config {
  Config(
    directory:,
    memory_path: directory <> "/" <> memory.memory_file,
    digest_path: directory <> "/" <> memory.digest_file,
    distiller:,
    clock:,
    entropy:,
    logger: log.discard(),
    scan_limit: default_scan_limit,
  )
}

/// Sets the logger a run reports on.
pub fn with_logger(config: Config, logger: Logger) -> Config {
  Config(..config, logger:)
}

/// Runs one whole pass: walk, extract, consolidate, render.
///
/// The write order is the crash contract and it is visible here — rows,
/// then the head-and-cursors CAS, then the sidecar. See the module doc.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(report) = distill.run(config)
/// ```
///
pub fn run(config: Config) -> Result(Report, String) {
  let generator = ids.generator(config.clock, seed: config.entropy())
  use opened <- result.try(
    memory.open(
      path: config.memory_path,
      owner: distill_owner,
      // The run-scale TTL, not the short one: the commits below are
      // separated by provider turns, and a lease that expired between
      // them would be stolen by any opener that arrived — losing the run
      // its next commit and every turn it had paid for.
      lease_ttl_ms: memory.run_lease_ttl_ms,
      clock: config.clock,
      generator:,
    )
    |> result.map_error(describe_fault),
  )
  let outcome = pass(config, opened)
  memory.close(opened)
  outcome
}

/// The lease owner a distillation run takes the memory session under —
/// the name a `remember` call refused mid-run is told is holding it.
pub const distill_owner = "loom-distill"

fn pass(config: Config, opened: Opened) -> Result(Report, String) {
  use #(head_ids, head_seq) <- result.try(
    memory.head(opened) |> result.map_error(describe_fault),
  )
  use current <- result.try(
    memory.head_rows(opened) |> result.map_error(describe_fault),
  )
  let #(harvests, skipped) = harvest_all(config, opened)
  use notes_cursor <- result.try(read_notes_cursor(opened))
  use notes <- result.try(
    memory.notes_after(opened, notes_cursor, limit: max_notes_per_run)
    |> result.map_error(describe_fault),
  )

  // Extraction runs before the decision, and the decision is made on
  // what it *produced* rather than on what it was offered. A repository
  // whose sources all honestly answer "nothing" has been read — its
  // cursors have to move, or the next run pays the same extraction turns
  // over the same entries, and the run after that, forever — but it has
  // nothing to consolidate, and dispatching a turn over an empty input
  // would only reach the empty-answer refusal below.
  let extracted = extract_all(config, opened, harvests)
  let cursors = cursors_of(extracted.read, notes)
  let opened = memory.Opened(..opened, generator: extracted.generator)
  let report =
    Report(
      sources: list.length(extracted.read),
      // A source whose extraction turn failed was not read this run, so
      // it counts where the leased and the unreadable ones count.
      skipped: skipped + { list.length(harvests) - list.length(extracted.read) },
      candidates: list.length(extracted.candidates),
      rows: list.length(head_ids),
      digest: None,
    )
  case extracted.candidates, notes {
    [], [] -> quiet(config, opened, cursors, report)
    _some, _none ->
      consolidated(config, opened, current, extracted, notes, head_seq, report)
  }
}

// Nothing to consolidate: record what was read and leave the head alone.
//
// The cursors-only commit is the whole point (`memory.advance_cursors`),
// and the reconciliation that follows it is why this path renders at all
// — see `reconciled`.
fn quiet(
  config: Config,
  opened: Opened,
  cursors: List(#(String, json.JsonValue)),
  report: Report,
) -> Result(Report, String) {
  use Nil <- result.try(
    memory.advance_cursors(opened, cursors) |> result.map_error(describe_fault),
  )
  log.info(config.logger, "distill.idle", [
    field.count(key: "skipped", value: report.skipped),
    field.count(key: "cursors", value: list.length(cursors)),
  ])
  reconciled(config, opened, report)
}

fn consolidated(
  config: Config,
  opened: Opened,
  current: List(memory.Distillate),
  extracted: Extracted,
  notes: List(memory.Distillate),
  head_seq: Option(Seq),
  report: Report,
) -> Result(Report, String) {
  use #(rows, generator) <- result.try(consolidate(
    config,
    opened,
    current,
    extracted.candidates,
    notes,
    extracted.generator,
  ))
  finish(
    config,
    memory.Opened(..opened, generator:),
    rows,
    head_seq,
    // Both of these are driven by the sources extraction actually got an
    // answer for, never by everything it opened. See `Extracted`.
    provenance_of(extracted.read, current, notes),
    cursors_of(extracted.read, notes),
    Report(..report, rows: list.length(rows)),
  )
}

// Rows first, head-and-cursors last, sidecar after the commit. The
// three steps are separate calls in this order and nowhere else in the
// module, which is what makes the ordering reviewable.
fn finish(
  config: Config,
  opened: Opened,
  rows: List(Candidate),
  head_seq: Option(Seq),
  provenance: Provenance,
  cursors: List(#(String, json.JsonValue)),
  report: Report,
) -> Result(Report, String) {
  use #(written, _generator) <- result.try(
    memory.append_distillates(
      opened,
      list.map(rows, fn(row) { #(row.kind, row.text) }),
      provenance,
      config.clock,
    )
    |> result.map_error(describe_fault),
  )
  use Nil <- result.try(
    memory.advance_head(opened, ids: written, expected: head_seq, cursors:)
    |> result.map_error(describe_fault),
  )
  log.info(config.logger, "distill.consolidated", [
    field.count(key: "rows", value: list.length(written)),
  ])
  reconciled(config, opened, Report(..report, rows: list.length(written)))
}

// The sidecar, made to match the head — the last thing every run does,
// consolidating or not.
//
// It is deliberately not "write the digest we just rendered". The
// sidecar is the one artifact a crash can leave behind its head: the
// head CAS commits, and then the process dies before the file is
// rewritten. Nothing would ever notice, because every later run reads
// the head rather than the file — so a repository that went quiet after
// such a crash would serve a stale digest to every session from then on.
// Reconciling here closes that, and costs a quiet run one render and one
// read.
fn reconciled(
  config: Config,
  opened: Opened,
  report: Report,
) -> Result(Report, String) {
  use written <- result.map(reconciled_digest(config, opened))
  Report(..report, digest: written)
}

// The reconciliation itself, kept in the shape `memory.reconcile_digest`
// answers in and deliberately not collapsed to a byte count: `Some(0)` is
// a sidecar this run *emptied* and `None` is one it never touched, and an
// operator's line has to tell those apart. Collapsing both to zero is
// what made a cascade that had just erased a digest report it as
// unchanged. Shared with the erasure cascade, which ends the same way and
// for the same reason.
fn reconciled_digest(
  config: Config,
  opened: Opened,
) -> Result(Option(Int), String) {
  use written <- result.map(memory.reconcile_digest(opened, config.digest_path))
  case written {
    None -> Nil
    Some(bytes) ->
      log.info(config.logger, "distill.digest_written", [
        field.count(key: "digest_bytes", value: bytes),
      ])
  }
  written
}

// Batch-level provenance: every row this consolidation writes names the
// sources this run read and the memory rows it supersedes. The
// weakening that follows — a consolidation of a consolidation carries
// its predecessor's id, not its predecessor's sources — is the
// first-derivation boundary recorded in `docs/spec-gaps.md`.
fn provenance_of(
  harvests: List(Harvest),
  current: List(memory.Distillate),
  notes: List(memory.Distillate),
) -> Provenance {
  memory.Provenance(
    sources: list.map(harvests, fn(harvest) {
      memory.SourceRef(
        session: harvest.session,
        entries: harvest.extract.entries,
      )
    }),
    derived_from: list.map(list.append(current, notes), fn(row) {
      ids.entry_id_to_string(row.id)
    }),
  )
}

fn cursors_of(
  harvests: List(Harvest),
  notes: List(memory.Distillate),
) -> List(#(String, json.JsonValue)) {
  let sources =
    list.map(harvests, fn(harvest) {
      #(
        memory.cursor_key(harvest.session),
        memory.cursor_value(memory.Cursor(
          seq: harvest.extract.newest_seq,
          generation: harvest.cursor.generation,
        )),
      )
    })
  case list.fold(notes, 0, fn(highest, note) { int.max(highest, note.seq) }) {
    0 -> sources
    newest -> [#(memory.notes_cursor_key, json.Int(newest)), ..sources]
  }
}

fn read_notes_cursor(opened: Opened) -> Result(Seq, String) {
  use found <- result.map(
    memory.cell(opened, memory.notes_cursor_key)
    |> result.map_error(describe_fault),
  )
  case found {
    Some(#(json.Int(seq), _cell_seq)) -> seq
    Some(#(_other, _cell_seq)) | None -> 0
  }
}

// --- the erasure cascade ----------------------------------------------------

/// What a cascade removed from the head.
///
/// Constructor invariants: `dropped` counts the head rows whose
/// provenance named the erased session and `kept` the rest, so the two
/// sum to the head the cascade read; `digest` is the sidecar rewrite,
/// `None` when the file already matched its head.
///
/// `unreadable` counts the kept rows whose provenance could not be
/// decoded at all, and is reported rather than folded into `kept`
/// because those rows are kept by a *different* rule than the others.
/// `provenance_of` fails safe — a row it cannot read names nothing and
/// is therefore never dropped — which means such a row is also
/// permanently invisible to every future cascade. That is the one place
/// this command under-deletes, so an operator who is erasing something
/// has to be told the count rather than left to infer it.
pub type Cascade {
  Cascade(
    session: String,
    dropped: Int,
    kept: Int,
    unreadable: Int,
    digest: Option(Int),
  )
}

/// The distiller a cascade runs under: one that refuses, because a
/// cascade dispatches no model turn.
///
/// This is why `--cascade` does not require `--config`. A run needs a
/// catalogue because it asks the model twice; a cascade only reads
/// provenance the pipeline already wrote, so demanding a catalogue would
/// be asking the operator for a credential to do arithmetic.
///
/// ## Examples
///
/// ```gleam
/// // distill.config_for(dir, distill.no_distiller(), clock:, entropy:)
/// ```
///
pub fn no_distiller() -> Distiller {
  Distiller(ask: fn(_prompt) { Error("a cascade dispatches no model turn") })
}

/// **The first-order erasure cascade** (issue #115): drops from the head
/// every distillate whose provenance names `session`, and re-renders the
/// sidecar without them.
///
/// Run by the operator *after* `session/repo` has rewritten that source
/// session — the two are deliberately separate commands, because a repo
/// erase is admin tooling above the harness and this is a pass over the
/// memory plane beside it.
///
/// Two properties are inherited rather than invented; the third is where
/// this command's real cost sits, and it is a defect rather than a
/// design:
///
/// - **Rows are write-once, so nothing is deleted.** A cascade removes
///   ids from the head, which is a pointer over append-only rows. The
///   dropped rows stay in the store and become orphans — inert, because
///   every reader goes through the head — in exactly the class
///   `docs/spec-gaps.md` already records for a crashed consolidation.
/// - **The write order is the pipeline's own**: rows if any (there are
///   none — every survivor is already durable), the head CAS, then the
///   sidecar. A cascade killed before the sidecar leaves a head ahead of
///   its digest, and the next run's reconciliation closes it, which is
///   what that reconciliation is for.
/// - **Cursors are not touched, and an emptying cascade therefore loses
///   what it emptied.** The erased source's cursor is voided by the
///   rewrite generation `repo.rewrite_sqlite` bumped, so the next run
///   re-extracts *that* source from zero on its own
///   (`memory.cursor_from`). Every other source keeps its cursor at the
///   high-water seq the last run left it at, and the notes cursor sits
///   past every note already consumed. Since a head is uniform in
///   provenance, an effective cascade empties it — so the next run
///   consolidates the erased source alone, over an empty head, no notes,
///   and no other source offering anything. **The surviving sources'
///   contribution and every hand-written note are then permanently
///   unrecoverable by the pipeline.** Re-reading the other sources is in
///   fact the only rebuild there could be; not doing it is the gap, not
///   the saving. Issue #124 carries the mechanism — a cursor rewind on
///   drop, a `--rebuild` companion, or a `--dry-run` preview — and
///   `distill_test`'s `an_emptying_cascade_loses_the_surviving_sources`
///   pins the loss until one of them lands.
///
/// **First-order, and the second order is vacuous rather than skipped.**
/// A row whose `derived_from` names a dropped row is not chased. Within
/// one head it cannot exist: a consolidation replaces the head wholesale
/// with the batch it just wrote, and that batch's `derived_from` names
/// the *previous* head's rows and the notes it consumed — none of which
/// are in the new head. So a transitive pass over `derived_from` inside
/// the head can never select a row the first pass did not. What is
/// genuinely out of reach is the weakening across derivations that
/// #115 and spec-gaps M2 item 9 record: a later consolidation carries
/// its predecessor's *id*, not its predecessor's sources.
///
/// ## Examples
///
/// ```gleam
/// // distill.cascade(config, session: "01924f7e-…")
/// ```
///
pub fn cascade(
  config: Config,
  session session: String,
) -> Result(Cascade, String) {
  let generator = ids.generator(config.clock, seed: config.entropy())
  use opened <- result.try(
    memory.open(
      path: config.memory_path,
      owner: distill_owner,
      // The **short** TTL, unlike `run`'s. The rule `client/memory` fixes
      // is that the caller sizes the lease to what sits between its
      // commits, and a cascade has nothing slow between them at all: one
      // register read, one batch entry read, one commit, one file write.
      // Taking the run-scale lease would lock the file for ten minutes
      // after a crash that cost milliseconds.
      lease_ttl_ms: memory.lease_ttl_ms,
      clock: config.clock,
      generator:,
    )
    |> result.map_error(describe_fault),
  )
  let outcome = cascaded(config, opened, session)
  memory.close(opened)
  outcome
}

fn cascaded(
  config: Config,
  opened: Opened,
  session: String,
) -> Result(Cascade, String) {
  use #(named, head_seq) <- result.try(
    memory.head(opened) |> result.map_error(describe_fault),
  )
  use pairs <- result.try(
    memory.provenance_by_id(opened, named) |> result.map_error(describe_fault),
  )
  let #(dropped, kept) =
    list.partition(pairs, fn(pair) { memory.names_source(pair.1, session) })
  use Nil <- result.try(dropped_from_head(
    config,
    opened,
    survivors: list.map(kept, fn(pair) { pair.0 }),
    expected: head_seq,
    dropped: dropped,
  ))
  use written <- result.map(reconciled_digest(config, opened))
  Cascade(
    session:,
    dropped: list.length(dropped),
    kept: list.length(kept),
    unreadable: list.count(kept, fn(pair) { pair.1 == memory.no_provenance }),
    digest: written,
  )
}

// The head CAS, made only when something was actually dropped.
//
// A cascade over a session nothing names must be a true no-op: writing
// the identical id list back would still bump the cell's seq, which is a
// visible write and would lose a concurrent run's CAS for no reason.
fn dropped_from_head(
  config: Config,
  opened: Opened,
  survivors survivors: List(String),
  expected expected: Option(Seq),
  dropped dropped: List(#(String, memory.Provenance)),
) -> Result(Nil, String) {
  use <- bool.guard(when: dropped == [], return: Ok(Nil))
  use Nil <- result.map(
    memory.replace_head(opened, named: survivors, expected:)
    |> result.map_error(describe_fault),
  )
  log.info(config.logger, "distill.cascaded", [
    field.count(key: "dropped", value: list.length(dropped)),
    field.count(key: "kept", value: list.length(survivors)),
  ])
}

// --- the walk --------------------------------------------------------------

/// The session files in `directory` that are candidate sources: every
/// `*.db` except the memory store and the search index.
///
/// ## Examples
///
/// ```gleam
/// // distill.source_files("/data") == Ok(["/data/a.db"])
/// ```
///
pub fn source_files(directory: String) -> Result(List(String), String) {
  use names <- result.map(
    simplifile.read_directory(directory)
    |> result.map_error(fn(error) {
      "the session directory "
      <> directory
      <> " is unreadable: "
      <> string.inspect(error)
    }),
  )
  names
  |> list.filter(fn(name) {
    string.ends_with(name, ".db") && !list.contains(excluded_files, name)
  })
  |> list.sort(string.compare)
  |> list.map(fn(name) { directory <> "/" <> name })
}

// The memory store is never a source (that is the anti-feedback rule's
// structural half), and the search index is not a session at all.
const excluded_files = [memory.memory_file, "loom-search.db"]

// What one candidate source turned out to be. Three of these are
// non-events and one is a fault, and they are kept apart because the
// operator's line conflating them would be useless: a directory of
// twenty quiet sessions and a directory of twenty *live* ones look
// identical once both are called "skipped".
type Harvested {
  /// Something new to distil.
  Ready(harvest: Harvest)

  /// The writer lease is held: a live session, and the whole of the
  /// live-session skip rule.
  Leased

  /// Opened cleanly and had nothing above its cursor.
  Quiet

  /// Could not be opened or read at all.
  Unreadable(reason: String)
}

// Opens every candidate source, harvesting what is new.
fn harvest_all(config: Config, opened: Opened) -> #(List(Harvest), Int) {
  case source_files(config.directory) {
    Error(reason) -> {
      log.warn(config.logger, "distill.walk_failed", [
        field.text(key: "reason", value: reason),
      ])
      #([], 0)
    }
    Ok(paths) ->
      list.fold(paths, #([], 0), fn(carried, path) {
        let #(found, skipped) = carried
        case harvest_one(config, opened, path) {
          Ready(harvest:) -> #([harvest, ..found], skipped)
          Leased -> #(found, skipped + 1)
          Quiet -> #(found, skipped)
          Unreadable(reason:) -> {
            log.warn(config.logger, "distill.source_unreadable", [
              field.text(key: "session", value: path),
              field.text(key: "reason", value: reason),
            ])
            #(found, skipped + 1)
          }
        }
      })
  }
}

fn harvest_one(config: Config, opened: Opened, path: String) -> Harvested {
  case
    session.open_sqlite(
      path:,
      owner: distill_owner,
      lease_ttl_ms: memory.lease_ttl_ms,
      clock: config.clock,
    )
  {
    // A live server holds the lease. Not logged: this is the common
    // case on a machine that is being used, not a fault.
    Error(session.SqliteOpenFailed(error: sqlite.LeaseHeld(..))) -> Leased
    Error(error) -> Unreadable(reason: string.inspect(error))
    Ok(source) -> {
      let outcome = harvested(config, opened, path, source)
      let _closed = session.close(source)
      outcome
    }
  }
}

fn harvested(
  config: Config,
  opened: Opened,
  path: String,
  source: session.Session,
) -> Harvested {
  case readable(config, opened, path, source) {
    Error(reason) -> Unreadable(reason:)
    Ok(None) -> Quiet
    Ok(Some(harvest)) -> Ready(harvest:)
  }
}

fn readable(
  config: Config,
  opened: Opened,
  path: String,
  source: session.Session,
) -> Result(Option(Harvest), String) {
  use named <- result.try(
    session.id(source)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )

  // A session that has never been through `ensure_id` has no stable name
  // to key a cursor by, and this pipeline will not mint one for it.
  // Skipped, and said out loud.
  //
  // "Writes nothing to a source" would be too strong a claim to make
  // here: taking the writer lease writes the lease row, migrate-on-open
  // will upgrade an older file's schema in place, and opening a stray
  // empty `.db` creates the schema in it before this line skips it. What
  // is true is the part that matters — no entry, no register and no
  // usage row of a source is ever authored by this pipeline.
  use named <- result.try(option.to_result(
    named,
    "the session has no canonical id; open it with a server once",
  ))
  let session_id = ids.session_id_to_string(named)
  use generation <- result.try(
    sqlite.generation(path:)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  use stored <- result.try(
    memory.cell(opened, memory.cursor_key(session_id))
    |> result.map_error(describe_fault),
  )
  let cursor =
    memory.cursor_from(option.map(stored, fn(found) { found.0 }), generation)
  use entries <- result.try(new_entries(config, source, cursor.seq))
  let extract = extraction_input(entries)
  case extract.entries {
    [] -> Ok(None)
    _found -> Ok(Some(Harvest(session: session_id, path:, cursor:, extract:)))
  }
}

fn new_entries(
  config: Config,
  source: session.Session,
  after: Seq,
) -> Result(List(Entry), String) {
  let q =
    storage.entry_scan()
    |> storage.entry_seq_range(Some(after + 1), None)
    |> storage.entry_order(storage.OldestFirst)
    |> storage.entry_limit(config.scan_limit)
  storage.scan_entries(source.store, q)
  |> result.map_error(fn(error) { string.inspect(error) })
}

// --- the two model turns ---------------------------------------------------

/// What extraction produced, and — just as load-bearing — which sources
/// it actually got an answer for.
///
/// A source whose extraction turn failed must not appear in `read`. Two
/// things downstream are driven by that list and both are wrong without
/// it: its cursor would advance past entries no model ever saw, losing
/// them permanently and silently (the one thing the cursor exists to
/// prevent), and every row written this run would name it in their
/// provenance, over-claiming a contribution it did not make — which
/// issue #115's cascade would later act on by over-deleting.
type Extracted {
  Extracted(
    candidates: List(Candidate),
    read: List(Harvest),
    generator: Generator,
  )
}

fn extract_all(
  config: Config,
  opened: Opened,
  harvests: List(Harvest),
) -> Extracted {
  let folded =
    list.fold(
      harvests,
      Extracted(candidates: [], read: [], generator: opened.generator),
      fn(carried, harvest) {
        case config.distiller.ask(extraction_prompt(harvest)) {
          Error(reason) -> {
            log.warn(config.logger, "distill.extraction_failed", [
              field.text(key: "session", value: harvest.session),
              field.text(key: "reason", value: reason),
            ])
            carried
          }
          Ok(answer) ->
            Extracted(
              candidates: list.append(
                carried.candidates,
                parse_candidates(answer.text),
              ),
              read: [harvest, ..carried.read],
              generator: record_usage(
                opened,
                carried.generator,
                answer.usage,
                "extract",
                config,
              ),
            )
        }
      },
    )
  Extracted(..folded, read: list.reverse(folded.read))
}

fn consolidate(
  config: Config,
  opened: Opened,
  current: List(memory.Distillate),
  candidates: List(Candidate),
  notes: List(memory.Distillate),
  generator: Generator,
) -> Result(#(List(Candidate), Generator), String) {
  use answer <- result.try(
    config.distiller.ask(consolidation_prompt(current, candidates, notes)),
  )
  let generator =
    record_usage(opened, generator, answer.usage, "consolidate", config)
  case parse_candidates(answer.text) {
    // A consolidation that produced nothing usable must not replace the
    // head with an empty one: memory would be erased by one malformed
    // answer, and the cursors would advance past the sources that fed
    // it. Refused, so the next run tries again over the same input.
    [] -> Error("the consolidation turn produced no usable lines")
    rows -> Ok(#(rows, generator))
  }
}

// One ledger row per model turn, in the memory session's own ledger, so
// memory's cost is visible where memory lives.
fn record_usage(
  opened: Opened,
  generator: Generator,
  usage: Usage,
  phase: String,
  config: Config,
) -> Generator {
  let #(id, generator) = ids.mint_usage(generator)
  let row =
    entry.UsageRow(
      id:,
      seq: 0,
      entry_id: None,
      adjustment: False,
      usage:,
      details: Some(json.Object([#("phase", json.String(phase))])),
    )
  case
    storage.commit(
      opened.session.store,
      Tx(writes: [InsertUsage(row)], expected: []),
    )
  {
    Ok(_result) -> Nil

    // A ledger row that would not commit is not worth failing a run for:
    // the distillate is the product, the cost record is the report.
    Error(error) ->
      log.warn(config.logger, "distill.usage_unrecorded", [
        field.text(key: "reason", value: string.inspect(error)),
      ])
  }
  generator
}

fn describe_fault(fault: memory.MemoryFault) -> String {
  case fault {
    memory.MemoryHeld(owner:) ->
      "the memory session is held by "
      <> owner
      <> "; another distillation "
      <> "run is in progress"
    memory.MemoryFailed(reason:) -> reason
  }
}

// --- the provider ----------------------------------------------------------

/// Which identity the pipeline's turns dispatch to: the `Summarize` role
/// when the catalogue routes one, and the resolved main entry otherwise.
///
/// The summary path's exact arrangement (`client/wiring`'s
/// `summary_target`), and for its reason: routing distillation to a
/// cheap model is what the role exists for, and there is no durable
/// identity contract to honour — a distillate is published as text, not
/// as a response attributed to a model.
///
/// ## Examples
///
/// ```gleam
/// // distill.target(gateway) == model.ForRole(model.Summarize, option.None)
/// ```
///
pub fn target(
  gateway: provider_gateway.Gateway,
) -> Result(RequestTarget, String) {
  case provider_gateway.resolve(gateway, model.Summarize) {
    Ok(_routed) -> Ok(ForRole(role: model.Summarize, thinking: None))
    Error(_missing) ->
      provider_gateway.resolve(gateway, model.Main)
      |> result.map(fn(resolved) { ForResolved(resolved:) })
      |> result.replace_error(
        "the catalogue routes neither a summarize nor a main model",
      )
  }
}

/// The production distiller: one prompt becomes one provider request on
/// `target`, awaited to its terminal event.
///
/// ## Examples
///
/// ```gleam
/// // distill.gateway_distiller(gateway, target, timeout_ms: 300_000)
/// ```
///
pub fn gateway_distiller(
  gateway: provider_gateway.Gateway,
  target: RequestTarget,
  timeout_ms timeout_ms: Int,
) -> Distiller {
  Distiller(ask: fn(prompt) {
    let stream.PreparedStream(handle:, begin:) =
      provider_gateway.prepare(
        gateway,
        model.ProviderRequest(
          target:,
          system: None,
          messages: [user(prompt)],
          tools: [],
          max_output_tokens: None,
        ),
      )

    // The timeout path cannot reconstruct an exit reason after a fast owner
    // has gone. Retaining the monitor before begin makes the later drain wait
    // an observation of the real exit rather than a `noproc` guess.
    let drain_witness = stream.watch_drain(handle)
    begin()
    case stream.await_terminal(handle, within: timeout_ms) {
      Error(Nil) -> {
        stream.cancel(handle)

        // `extract_all` may issue the next billable distillation request as
        // soon as this call returns. A timeout ends the receive, not the work;
        // keep this fold step private until the old provider subtree is gone.
        case stream.await_drain_forever(drain_witness) {
          stream.Drained -> Error("the model did not answer inside the timeout")
          stream.TimedOut | stream.ProofLost -> {
            process.kill(process.self())
            Error("the provider owner exited without proving drain")
          }
        }
      }
      Ok(#(_deltas, stream.Failed(error:))) -> {
        stream.release_drain(drain_witness)
        Error(string.inspect(error))
      }
      Ok(#(_deltas, stream.Delta(..))) -> {
        stream.release_drain(drain_witness)
        Error("the stream ended on a delta, which cannot happen")
      }
      Ok(#(_deltas, stream.Settled(message:, usage:))) -> {
        stream.release_drain(drain_witness)
        Ok(Answer(text: settled_text(stream.message(message)), usage:))
      }
    }
  })
}

fn user(text: String) -> AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

fn settled_text(settled: AgentMessage) -> String {
  case settled {
    message.AssistantMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.AssistantText(text:, ..) -> Ok(text)
          message.AssistantThinking(..) | message.AssistantToolCall(..) ->
            Error(Nil)
        }
      })
      |> string.join("\n")
    message.UserMessage(..)
    | message.ToolResultMessage(..)
    | message.CustomMessage(..) -> ""
  }
}

// --- the command line ------------------------------------------------------

/// Parses flags, runs one pass, and prints what it did.
///
/// ## Examples
///
/// ```gleam
/// // gleam run -m client/distill -- --session-dir /data --config loom.toml
/// ```
///
pub fn main() -> Nil {
  let logger =
    handler.install(
      threshold: handler.threshold_named(env_text(handler.level_variable)),
    )
  case parse(argv.load().arguments) {
    Error(reason) -> io.println_error("loom-distill: " <> reason)

    // Two commands behind one entry point, chosen by the flag: a pass, or
    // an erasure cascade over one already-erased source. A new binary
    // would duplicate the directory resolution, the memory path and the
    // lease for the sake of a subcommand that shares all three.
    Ok(Flags(cascade: Some(session), ..) as flags) ->
      announce_cascade(cascade_flags(flags, session, logger))
    Ok(flags) -> announce(run_flags(flags, logger))
  }
}

fn announce(outcome: Result(Report, String)) -> Nil {
  case outcome {
    Error(reason) -> io.println_error("loom-distill: " <> reason)
    Ok(report) ->
      io.println(
        "loom-distill: "
        <> int.to_string(report.sources)
        <> " sources read, "
        <> int.to_string(report.skipped)
        <> " skipped; memory holds "
        <> int.to_string(report.rows)
        <> " distillates "
        <> digest_line(report.digest),
      )
  }
}

fn announce_cascade(outcome: Result(Cascade, String)) -> Nil {
  case outcome {
    Error(reason) -> io.println_error("loom-distill: " <> reason)
    Ok(report) ->
      io.println(
        "loom-distill: cascade over "
        <> report.session
        <> ": "
        <> int.to_string(report.dropped)
        <> " distillates dropped, "
        <> int.to_string(report.kept)
        <> " kept"
        <> escaped_line(report)
        <> " "
        <> digest_line(report.digest),
      )
  }
}

// The under-deletion, said out loud when there is any. A row whose
// provenance would not decode is kept by `provenance_of`'s fail-safe and
// is invisible to every future cascade too, so an operator erasing
// something needs the count in the line rather than in a log.
fn escaped_line(report: Cascade) -> String {
  case report.unreadable {
    0 -> ""
    escaped ->
      " ("
      <> int.to_string(escaped)
      <> " kept with unreadable provenance, which no cascade can reach)"
  }
}

// Three outcomes, not two. `None` is a sidecar this run never touched;
// `Some(0)` is one it rewrote to nothing, which is what an emptying
// cascade — and the first run after a crashed one — produces. Reporting
// that second case as "unchanged" is the one reading an operator must
// not be given straight after erasing something.
fn digest_line(written: Option(Int)) -> String {
  case written {
    None -> "(digest unchanged)"
    Some(0) -> "(digest emptied)"
    Some(bytes) -> "(digest " <> int.to_string(bytes) <> " bytes)"
  }
}

type Flags {
  Flags(
    session_dir: Option(String),
    session: Option(String),
    config: Option(String),
    cascade: Option(String),
  )
}

fn parse(arguments: List(String)) -> Result(Flags, String) {
  parse_loop(
    arguments,
    Flags(session_dir: None, session: None, config: None, cascade: None),
  )
}

fn parse_loop(arguments: List(String), flags: Flags) -> Result(Flags, String) {
  case arguments {
    [] -> Ok(flags)
    ["--session-dir", value, ..rest] ->
      parse_loop(rest, Flags(..flags, session_dir: Some(value)))
    ["--session", value, ..rest] ->
      parse_loop(rest, Flags(..flags, session: Some(value)))
    ["--config", value, ..rest] ->
      parse_loop(rest, Flags(..flags, config: Some(value)))
    ["--cascade", value, ..rest] ->
      parse_loop(rest, Flags(..flags, cascade: Some(value)))
    [unknown, ..] -> Error("unknown argument `" <> unknown <> "`\n" <> usage)
  }
}

const usage = "usage: loom-distill --config <loom.toml>
  [--session-dir <dir>]    the session directory to distill (default: the current directory)
  [--session <path.db>]    a session file; its directory is the one distilled

   or: loom-distill --cascade <source-session-id>
  [--session-dir <dir>]    the session directory whose memory is cascaded
  [--session <path.db>]    a session file; its directory is the one cascaded

`--config` is required for a distillation run, which dispatches two model
turns, and the catalogue is where the `summarize` route (or the main model
it falls back to) is declared.

`--cascade` needs no catalogue and dispatches no model turn. Run it after
erasing a source session with `session/repo`: it drops from the memory
head every distillate whose provenance names that session and re-renders
the digest without them. First-order only — a distillate derived from a
dropped one keeps its predecessor's id and not its sources."

fn run_flags(flags: Flags, logger: Logger) -> Result(Report, String) {
  use directory <- result.try(directory_of(flags))
  use path <- result.try(option.to_result(
    flags.config,
    "--config is required\n" <> usage,
  ))
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      "the config file " <> path <> " is unreadable: " <> string.inspect(error)
    }),
  )
  use catalogue <- result.try(
    catalog.parse(text)
    |> result.map_error(fn(reason) { path <> ": " <> reason }),
  )
  let clock = clock.from_function(ffi_os.system_time_ms)
  let gateway =
    catalog.gateway(
      catalogue,
      transport: http.httpc_transport(),
      secrets: secret.env(),
      clock:,
    )
  use dispatch <- result.try(target(gateway))
  run(
    config_for(
      directory,
      gateway_distiller(gateway, dispatch, timeout_ms: default_timeout_ms),
      clock:,
      entropy: mixed_entropy(),
    )
    |> with_logger(logger),
  )
}

// The cascade's own flag handling: a directory, and nothing else. No
// config file is read and no gateway is built, because `no_distiller`
// says what a cascade asks the model — nothing.
fn cascade_flags(
  flags: Flags,
  session: String,
  logger: Logger,
) -> Result(Cascade, String) {
  use directory <- result.try(directory_of(flags))
  let clock = clock.from_function(ffi_os.system_time_ms)
  cascade(
    config_for(directory, no_distiller(), clock:, entropy: mixed_entropy())
      |> with_logger(logger),
    session:,
  )
}

// The two host facts an entry point supplies for itself: the wall clock
// behind the id generator, and enough entropy that two runs on one
// machine never mint the same id. Both mirror `client/serve`'s, because
// this is the second entry point and neither may reach for
// `erlang:system_time` directly (spec §0.2 rule 6).
fn env_text(name: String) -> Result(String, Nil) {
  secret.lookup(secret.env(), name)
}

fn mixed_entropy() -> fn() -> Int {
  let random_bytes = token.production_entropy()
  fn() {
    let unique = ffi_os.unique_positive_integer()
    case random_bytes(8) {
      <<random:size(64)>> -> unique * 18_446_744_073_709_551_616 + random
      _short -> unique
    }
  }
}

fn directory_of(flags: Flags) -> Result(String, String) {
  case flags.session_dir, flags.session {
    Some(directory), _ -> Ok(directory)
    None, Some(path) -> Ok(memory.directory_of(path))
    None, None ->
      simplifile.current_directory()
      |> result.map_error(fn(error) {
        "the working directory is unreadable, so there is no session "
        <> "directory to distill: "
        <> string.inspect(error)
      })
  }
}
