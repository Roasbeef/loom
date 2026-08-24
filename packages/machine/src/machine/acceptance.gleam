//// Operation acceptance — pi harness spec §3.6, transcribed.
////
//// `accept_prompt` computes the single acceptance transaction for a run,
//// standalone compaction, or navigation request. It is state-independent
//// normalization plus durable-state validation over the caller-supplied
//// snapshot; it invokes no hook, provider, or tool and consults no
//// process-local registry (unavailable captured implementations become
//// in-band configuration failures at their actual execution boundary).
//// Pre-acceptance rejections write nothing.
////
//// The acceptance transaction expects the strand-state seq the caller
//// read (`Acceptance must observe an idle strand`, pi invariant 14 —
//// Loom's structural strand serialization plus this CAS makes the losing
//// concurrent accept fail with a stale expectation and report
//// `StrandBusy` after reload).

import core/corruption.{type CorruptionReport}
import core/ids.{type EntryId, type Seq}
import core/message.{type AgentMessage}
import core/tx.{type Tx, type Write, Tx}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import machine/internal/build
import machine/operation.{
  type Operation, type OperationState, type PendingEntry, type RunSettings,
  type StructuralPreparation, CompactionIntent, CompactionState, Deciding, Inbox,
  NavigationIntent, NavigationState, Operation, PendingCustom, PendingMessage,
  RunIntent, RunState, Running, Starting, SummarizedNavigation,
  UnsummarizedNavigation,
}
import machine/strand.{type StrandState, StrandState}

/// A normalized acceptance request.
///
/// Constructor invariants: `AcceptRun.prompts` are the caller's normalized
/// prompt messages (skill/template expansion already applied);
/// `AcceptNavigation.target_known` reports whether a non-null target
/// exists in the tree — the machine cannot read the tree, so the caller
/// answers. Structural preparations are computed by the caller against an
/// observed leaf and revalidated here only through the strand-state CAS.
pub type AcceptRequest {
  /// A conversational run.
  AcceptRun(prompts: List(AgentMessage))
  /// A standalone compaction; `preparation` is `None` when there is
  /// nothing to compact.
  AcceptCompaction(
    custom_instructions: Option(String),
    preparation: Option(StructuralPreparation),
  )
  /// A navigation, optionally summarized.
  AcceptNavigation(
    target: Option(EntryId),
    summarize: Bool,
    label: Option(String),
    custom_instructions: Option(String),
    preparation: Option(StructuralPreparation),
    target_known: Bool,
  )
}

/// The durable snapshot and capabilities acceptance runs against.
///
/// Constructor invariants: `strand_state`/`strand_state_seq` and `leaf`
/// are the current values read on the strand's serialization line;
/// `settings` is the current global run-settings snapshot captured into
/// the run; `pending` holds the payloads of every id in
/// `strand_state.pending_next_run`; `generator` must be fresh (see
/// `PlannerInputs.generator`); `now` is the injected clock time.
pub type AcceptCtx {
  AcceptCtx(
    strand: String,
    now: Int,
    generator: ids.Generator,
    strand_state: StrandState,
    strand_state_seq: Seq,
    leaf: Option(EntryId),
    settings: RunSettings,
    pending: Dict(String, PendingEntry),
  )
}

/// The computed acceptance: immutable metadata, the first total state,
/// and the single transaction that commits both (plus consumed queue
/// items and prompt entries, for runs).
pub type AcceptancePlan {
  AcceptancePlan(operation: Operation, state: OperationState, tx: Tx)
}

/// Why acceptance was refused. Nothing was written in any case.
pub type RejectReason {
  /// The strand already has an open operation.
  StrandBusy
  /// Run acceptance would append zero entries.
  InvalidMessage(reason: String)
  /// Compaction was requested with an empty preparation.
  NothingToCompact
  /// The navigation request is structurally invalid (target is the
  /// current leaf, label on the root target, summarize without a target
  /// or from the root, or an empty summary preparation).
  InvalidNavigation(reason: String)
  /// A non-null navigation target does not exist.
  UnknownTarget
  /// A captured next-run id has no pending payload — storage corruption.
  QueueCorruption(report: CorruptionReport)
}

/// Computes the acceptance plan for one request against an idle strand.
/// Pure; rejections write nothing.
///
/// ## Examples
///
/// ```gleam
/// // acceptance.accept_prompt(AcceptRun(prompts: [..]), ctx)
/// //   == Ok(AcceptancePlan(..)) for an idle strand,
/// //   == Error(StrandBusy) when an operation is open.
/// ```
///
pub fn accept_prompt(
  request: AcceptRequest,
  ctx: AcceptCtx,
) -> Result(AcceptancePlan, RejectReason) {
  case ctx.strand_state.current_operation {
    Some(_) -> Error(StrandBusy)
    None ->
      case request {
        AcceptRun(prompts:) -> accept_run(prompts, ctx)
        AcceptCompaction(custom_instructions:, preparation:) ->
          accept_compaction(custom_instructions, preparation, ctx)
        AcceptNavigation(
          target:,
          summarize:,
          label:,
          custom_instructions:,
          preparation:,
          target_known:,
        ) ->
          accept_navigation(
            target,
            summarize,
            label,
            custom_instructions,
            preparation,
            target_known,
            ctx,
          )
      }
  }
}

fn accept_run(
  prompts: List(AgentMessage),
  ctx: AcceptCtx,
) -> Result(AcceptancePlan, RejectReason) {
  let captured = ctx.strand_state.pending_next_run
  case prompts, captured {
    [], [] ->
      Error(InvalidMessage(reason: "acceptance would append zero entries"))
    _, _ -> {
      // Captured next-run items place first, from their pending payloads;
      // request prompt entries follow, minted fresh.
      use #(captured_writes, after_captured) <- result.try(place_captured(
        ctx,
        ctx.leaf,
        captured,
      ))
      let #(operation_id, generator) = ids.mint_op(ctx.generator)
      let #(prompt_writes, prompt_ids, newest, _generator) =
        list.fold(
          prompts,
          #([], [], after_captured, generator),
          fn(acc, prompt) {
            let #(writes, prompt_ids, parent, generator) = acc
            let #(id, generator) = ids.mint_entry(generator)
            #(
              list.append(writes, [
                build.message_entry(id, parent, prompt, False),
              ]),
              list.append(prompt_ids, [id]),
              Some(id),
              generator,
            )
          },
        )
      let operation =
        Operation(
          id: operation_id,
          strand: ctx.strand,
          source_leaf: ctx.leaf,
          started_at: ctx.now,
          intent: RunIntent(prompt_entries: prompt_ids),
        )
      let state =
        RunState(
          control: Running,
          settings: ctx.settings,
          phase: Starting,
          inbox: Inbox(steer: [], follow_up: [], writes: []),
          latest_assistant: None,
        )
      let leaf = case newest {
        Some(id) -> Some(id)
        None -> ctx.leaf
      }
      Ok(plan(
        ctx,
        operation,
        state,
        list.flatten([
          captured_writes,
          prompt_writes,
          [
            build.set_leaf(ctx.strand, leaf),
            build.set_op_meta(operation),
            build.set_op_state(operation_id, state),
            build.set_strand_state(
              ctx.strand,
              StrandState(
                current_operation: Some(operation_id),
                pending_next_run: [],
              ),
            ),
          ],
        ]),
      ))
    }
  }
}

fn accept_compaction(
  custom_instructions: Option(String),
  preparation: Option(StructuralPreparation),
  ctx: AcceptCtx,
) -> Result(AcceptancePlan, RejectReason) {
  case preparation {
    None -> Error(NothingToCompact)
    Some(preparation) -> {
      let #(operation_id, generator) = ids.mint_op(ctx.generator)
      let #(task_entry, _generator) = ids.mint_entry(generator)
      let task_id = ids.entry_id_to_string(task_entry)
      let operation =
        Operation(
          id: operation_id,
          strand: ctx.strand,
          source_leaf: ctx.leaf,
          started_at: ctx.now,
          intent: CompactionIntent(custom_instructions:),
        )
      let state =
        CompactionState(
          control: Running,
          custom_instructions:,
          structural: Deciding(task_id:),
        )
      Ok(
        plan(ctx, operation, state, [
          build.set_preparation(operation_id, task_id, preparation),
          build.set_op_meta(operation),
          build.set_op_state(operation_id, state),
          build.set_strand_state(
            ctx.strand,
            StrandState(
              ..ctx.strand_state,
              current_operation: Some(operation_id),
            ),
          ),
        ]),
      )
    }
  }
}

fn accept_navigation(
  target: Option(EntryId),
  summarize: Bool,
  label: Option(String),
  custom_instructions: Option(String),
  preparation: Option(StructuralPreparation),
  target_known: Bool,
  ctx: AcceptCtx,
) -> Result(AcceptancePlan, RejectReason) {
  use _ <- result.try(case target == ctx.leaf {
    True -> Error(InvalidNavigation(reason: "target is the current leaf"))
    False -> Ok(Nil)
  })
  use _ <- result.try(case target, label {
    None, Some(_) ->
      Error(InvalidNavigation(reason: "label on the root target"))
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case summarize, target {
    True, None ->
      Error(InvalidNavigation(reason: "summarize with a null target"))
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case summarize, ctx.leaf {
    True, None -> Error(InvalidNavigation(reason: "summarize from the root"))
    _, _ -> Ok(Nil)
  })
  use _ <- result.try(case target, target_known {
    Some(_), False -> Error(UnknownTarget)
    _, _ -> Ok(Nil)
  })
  let #(operation_id, generator) = ids.mint_op(ctx.generator)
  let operation =
    Operation(
      id: operation_id,
      strand: ctx.strand,
      source_leaf: ctx.leaf,
      started_at: ctx.now,
      intent: NavigationIntent(
        target:,
        summarize:,
        label:,
        custom_instructions:,
      ),
    )
  case summarize, target {
    True, Some(target) ->
      case preparation {
        None -> Error(InvalidNavigation(reason: "empty summary preparation"))
        Some(preparation) -> {
          let #(task_entry, _generator) = ids.mint_entry(generator)
          let task_id = ids.entry_id_to_string(task_entry)
          let state =
            NavigationState(
              control: Running,
              navigation: SummarizedNavigation(
                target:,
                label:,
                custom_instructions:,
                structural: Deciding(task_id:),
              ),
            )
          Ok(
            plan(ctx, operation, state, [
              build.set_preparation(operation_id, task_id, preparation),
              build.set_op_meta(operation),
              build.set_op_state(operation_id, state),
              build.set_strand_state(
                ctx.strand,
                StrandState(
                  ..ctx.strand_state,
                  current_operation: Some(operation_id),
                ),
              ),
            ]),
          )
        }
      }
    _, _ -> {
      let state =
        NavigationState(
          control: Running,
          navigation: UnsummarizedNavigation(target:, label:),
        )
      Ok(
        plan(ctx, operation, state, [
          build.set_op_meta(operation),
          build.set_op_state(operation_id, state),
          build.set_strand_state(
            ctx.strand,
            StrandState(
              ..ctx.strand_state,
              current_operation: Some(operation_id),
            ),
          ),
        ]),
      )
    }
  }
}

/// Builds the placement writes for captured next-run items: entry insert
/// plus pending-register delete per item, chaining parents from the leaf.
fn place_captured(
  ctx: AcceptCtx,
  leaf: Option(EntryId),
  captured: List(EntryId),
) -> Result(#(List(Write), Option(EntryId)), RejectReason) {
  list.try_fold(captured, #([], leaf), fn(acc, id) {
    let #(writes, parent) = acc
    case dict.get(ctx.pending, ids.entry_id_to_string(id)) {
      Error(Nil) ->
        Error(
          QueueCorruption(report: corruption.report(
            at: "machine/acceptance.place_captured",
            on: ids.entry_id_to_string(id),
            expected: "a pending.entry payload for a captured next-run id",
            context: "payload absent",
          )),
        )
      Ok(PendingMessage(message:)) ->
        Ok(#(
          list.append(writes, [
            build.message_entry(id, parent, message, False),
            build.delete_pending(id),
          ]),
          Some(id),
        ))
      Ok(PendingCustom(custom_type:, data:)) ->
        Ok(#(
          list.append(writes, [
            build.custom_entry(id, parent, custom_type, data),
            build.delete_pending(id),
          ]),
          Some(id),
        ))
    }
  })
}

fn plan(
  ctx: AcceptCtx,
  operation: Operation,
  state: OperationState,
  writes: List(Write),
) -> AcceptancePlan {
  AcceptancePlan(
    operation:,
    state:,
    tx: Tx(writes:, expected: [
      build.expect_strand_state(ctx.strand, ctx.strand_state_seq),
      ..build.expect_op_absent(operation.id)
    ]),
  )
}
