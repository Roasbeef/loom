//// The attention summary survives a daemon restart (protocol-change/122).
////
//// The first acceptance test of the attention inbox: a real daemon assembles a
//// real session, a refused tool call raises an approval through the production
//// escalation seam, the daemon stops with the approval still pending, and a
//// second daemon over the same catalogue reads the saved session's summary
//// without opening it. The same rig shows the reconcile rule: opening the
//// saved session rewrites a row that was made wrong on purpose.

import broker/policy
import client/daemon/domain as domain_service
import client/daemon/lifetime
import client/daemon/manager
import client/history
import client/owned_assembly_test
import client/serve
import client/wiring
import core/agency_limits
import core/clock
import core/ids
import core/json
import core/message
import filepath
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import machine/operation
import runtime/api
import runtime/effects
import runtime/escalation
import simplifile
import storage/catalogue
import telemetry/log
import tools/directory_access
import weft/poll

// A daemon whose sessions are the real assembly, with the production wiring of
// the attention report: the summary goes to the registry that holds the
// session, as `client/daemon/main` connects it.
fn start(
  store: catalogue.Catalogue,
  settings: serve.Settings,
  epoch: String,
) -> lifetime.Lifetime(serve.Instance) {
  let assert Ok(daemon) =
    lifetime.start(
      store,
      manager.Assembly(
        domain_build: fn(selected, sources, owner) {
          let assert Ok(Nil) =
            bootstrap.ensure_private_directory(filepath.directory_name(
              selected.index_path,
            ))
            as "the domain owns its projection directory"
          let assert Ok(services) =
            domain_service.build(
              domain_service.Config(history: history.SharedConfig(
                selected.index_path,
                sources,
                5000,
                100,
              )),
              owner,
            )
            as "real shared history starts without external maintenance"
          Ok(services)
        },
        build: fn(record, selected, services, owner, directory) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the catalogue supplies a canonical reserved identity"
          serve.assemble_in_domain(
            serve.Settings(
              ..settings,
              attention_report: Some(fn(summary) {
                manager.record_attention(directory, record.id, summary)
              }),
              session_path: record.path,
              session_id: record.id,
              workspace: record.workspace,
              domain_paths: Some(serve.DomainPaths(
                selected.memory_path,
                selected.index_path,
              )),
              base_policy: narrower_than_bash(record.workspace),
            ),
            id,
            log.discard(),
            owner,
            services,
          )
        },
        drain: fn(_, _) { Nil },
        fatal: serve.instance_children,
      ),
      epoch:,
      limit: 2,
    )
    as "the outer lifetime owns the real registry"
  daemon
}

// A base narrower than `bash` asks for, so the first call is refused and
// raises an approval. The environment is the dimension: `bash` passes `PATH`
// and a base that allows no names narrows it away.
fn narrower_than_bash(workspace: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(..policy.workspace_default(workspace), env_allow: [])
}

fn create(
  registry: manager.Manager(serve.Instance),
  settings: serve.Settings,
) -> manager.View {
  let assert Ok(view) =
    manager.create(
      registry,
      manager.Creation(
        request_key: "attention-restart",
        workspace: settings.workspace,
        name: "attention restart",
        configuration: "",
        profile: None,
        model: None,
        executor: "",
        pool: "",
        agency: agency_limits.empty,
        worktree: None,
      ),
      directory: filepath.directory_name(settings.session_path) <> "/sessions",
      generator: ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 41),
    )
    as "creation reserves one identity and begins assembly"
  view
}

fn resident(
  registry: manager.Manager(serve.Instance),
  id: String,
  operation: String,
) -> serve.Instance {
  let answer =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Resident(found), ..))
          if found == operation
        -> poll.Done(Nil)
        Ok(manager.View(status: manager.Opening(_), ..)) -> poll.Retry
        other -> poll.Fail(string.inspect(other))
      }
    })
  assert answer == poll.Answered(Nil)
  let assert Ok(instance) = manager.resolve(registry, id)
    as "a resident operation resolves its sole instance"
  instance
}

fn stop(daemon: lifetime.Lifetime(serve.Instance)) -> Nil {
  let monitor = process.monitor(lifetime.witness(daemon))
  lifetime.shutdown(daemon)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(10_000)
    as "the outer witness confirms every instance drained"
  Nil
}

// Waits for the registry's summary of `id` to satisfy `wanted`, because the
// write is fire-and-forget and lands in the registry's own turn.
fn summary_where(
  registry: manager.Manager(serve.Instance),
  id: String,
  wanted: fn(catalogue.AttentionSummary) -> Bool,
) -> catalogue.AttentionSummary {
  let answer =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.attention_for(registry, [id]) {
        Ok([#(_, summary)]) ->
          case wanted(summary) {
            True -> poll.Done(summary)
            False -> poll.Retry
          }
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  let assert poll.Answered(summary) = answer
    as "the summary reaches the registry's catalogue"
  summary
}

// A policy-refused `bash` call, run on the session's own workspace plane, so
// the refusal reaches the production escalation seam and nothing is simulated
// beyond the call itself.
fn refused_bash_call(instance: serve.Instance) -> Nil {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  let arguments =
    json.Object([
      #("command", json.String("true")),
      #("timeout_ms", json.Int(120_000)),
    ])
  let outcome =
    instance.plane.run(
      effects.ToolRun(
        operation:,
        step_id: "turn-1:tools",
        source_index: 0,
        strand: "main",
        call: message.ToolCall(
          id: "call_1",
          name: "bash",
          arguments:,
          thought_signature: None,
          namespace: None,
        ),
        arguments:,
        replay: operation.ReplayNever,
        grants: [],
      ),
      wiring.Authority(access: directory_access.none(), standing: []),
    )
  let assert effects.ToolCompleted(..) = outcome
    as "a refused call still completes in band"
  Nil
}

pub fn a_pending_approval_is_counted_for_the_saved_session_after_a_restart_test() {
  process.trap_exits(True)
  let settings = owned_assembly_test.settings()
  let root = filepath.directory_name(settings.session_path)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the daemon owns its metadata directory"
  let path = root <> "/catalogue.db"
  let assert Ok(store) = catalogue.open(path) as "real catalogue opens"
  let daemon = start(store, settings, "before-restart")
  let registry = lifetime.registry(daemon)
  let assert manager.View(record, manager.Opening(operation)) =
    create(registry, settings)
    as "the session begins opening"
  let instance = resident(registry, record.id, operation)

  // Opening reconciles an absent row to a row of zeros, so "never read" ends
  // at the first open.
  let opened = summary_where(registry, record.id, fn(_) { True })
  assert opened.pending_approvals == 0
  assert opened.open_asks == 0
  assert opened.open_finds == 0
  assert opened.oldest_open_at == None

  // The refusal raises an approval, and the claim that commits it writes the
  // row that says so, before anything stops the daemon.
  refused_bash_call(instance)
  let assert Ok([raised]) = api.escalations(instance.runtime)
    as "one approval is raised"
  assert raised.status == escalation.Pending
  let pending =
    summary_where(registry, record.id, fn(summary) {
      summary.pending_approvals == 1
    })
  assert pending.open_asks == 0

  // The daemon stops with the approval undecided. Nothing closes the session.
  stop(daemon)
  assert catalogue.close(store) == Ok(Nil)

  // A second daemon reads the saved session's summary without opening it.
  let assert Ok(restored) = catalogue.open(path) as "catalogue survives restart"
  let restarted = start(restored, settings, "after-restart")
  let registry = lifetime.registry(restarted)
  let assert Ok(manager.View(status: manager.Saved, ..)) =
    manager.get(registry, record.id)
    as "the session is saved and not resident"
  assert manager.resolve(registry, record.id) == Error(manager.Unavailable)
  let assert Ok([#(read_id, summary)]) =
    manager.attention_for(registry, [record.id])
    as "the saved session has a summary row"
  assert read_id == record.id
  assert summary.pending_approvals == 1
  assert summary.updated_at == pending.updated_at

  // Opening the saved session rewrites a row that was made wrong on purpose,
  // from the records, which still hold one approval. The two cases are two
  // separate opens, so each one is exercised on its own: first a count too low.
  let low = wrong_row(0, 0, 0, None, 1)
  manager.record_attention(registry, record.id, low)
  let _lowered =
    summary_where(registry, record.id, fn(summary) { summary.updated_at == 1 })
  let assert Ok(manager.Opening(first_open)) = manager.open(registry, record.id)
    as "the first explicit open admits one incarnation"
  let _instance = resident(registry, record.id, first_open)
  let repaired =
    summary_where(registry, record.id, fn(summary) { summary.updated_at != 1 })
  assert repaired.pending_approvals == 1
  assert repaired.open_asks == 0
  assert repaired.open_finds == 0
  assert repaired.oldest_open_at == None

  // Then a count too high, after the session is saved again.
  let assert Ok(_) = manager.stop_session(registry, record.id)
    as "the session retires"
  let saved_again =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.get(registry, record.id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert saved_again == poll.Answered(Nil)
  let high = wrong_row(9, 4, 2, Some(3), 2)
  manager.record_attention(registry, record.id, high)
  let _raised =
    summary_where(registry, record.id, fn(summary) { summary.updated_at == 2 })
  let assert Ok(manager.Opening(second_open)) =
    manager.open(registry, record.id)
    as "the second explicit open admits one incarnation"
  let _instance = resident(registry, record.id, second_open)
  let repaired =
    summary_where(registry, record.id, fn(summary) { summary.updated_at != 2 })
  assert repaired.pending_approvals == 1
  assert repaired.open_asks == 0
  assert repaired.open_finds == 0
  assert repaired.oldest_open_at == None

  stop(restarted)
  assert catalogue.close(restored) == Ok(Nil)
  process.trap_exits(False)
}

fn wrong_row(
  approvals: Int,
  asks: Int,
  finds: Int,
  oldest: option.Option(Int),
  at: Int,
) -> catalogue.AttentionSummary {
  catalogue.AttentionSummary(
    pending_approvals: approvals,
    open_asks: asks,
    open_finds: finds,
    oldest_open_at: oldest,
    updated_at: at,
  )
}

// An open that cannot read the records keeps the old row and still opens
// (protocol-change/122). An escalation cell that does not decode makes the
// summary unreadable, so the report logs and sends nothing.
pub fn an_open_that_cannot_read_the_records_keeps_the_old_row_test() {
  process.trap_exits(True)
  let settings = owned_assembly_test.settings()
  let root = filepath.directory_name(settings.session_path) <> "/unreadable"
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "the daemon owns its metadata directory"
  let assert Ok(store) = catalogue.open(root <> "/catalogue.db")
    as "real catalogue opens"
  let daemon = start(store, settings, "unreadable")
  let registry = lifetime.registry(daemon)
  let assert manager.View(record, manager.Opening(operation)) =
    create(registry, settings)
    as "the session begins opening"
  let instance = resident(registry, record.id, operation)
  let _zeros = summary_where(registry, record.id, fn(_) { True })

  // A marker row, and a record the summary cannot decode.
  manager.record_attention(registry, record.id, wrong_row(7, 0, 0, None, 3))
  let _marked =
    summary_where(registry, record.id, fn(summary) { summary.updated_at == 3 })
  let assert Ok(Nil) =
    api.put_reserved_fact(
      instance.runtime,
      escalation.register_key("damaged"),
      json.String("not an escalation"),
    )
    as "the damaged record is written"
  assert api.escalations(instance.runtime) |> result.is_error

  let assert Ok(_) = manager.stop_session(registry, record.id)
    as "the session retires"
  let saved =
    poll.until(within: 10_000, every: 5, attempt: fn() {
      case manager.get(registry, record.id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(string.inspect(error))
      }
    })
  assert saved == poll.Answered(Nil)
  let assert Ok(manager.Opening(reopened)) = manager.open(registry, record.id)
    as "the open admits one incarnation"

  // The session becomes resident, and the row is the marker, not a rewrite.
  let _instance = resident(registry, record.id, reopened)
  let assert Ok([#(_, kept)]) = manager.attention_for(registry, [record.id])
  assert kept.updated_at == 3
  assert kept.pending_approvals == 7

  stop(daemon)
  assert catalogue.close(store) == Ok(Nil)
  process.trap_exits(False)
}
