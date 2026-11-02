//// The scratch judgement session of a live verdict: the router's prompt and
//// model, asked what it would do with one recorded trigger, with nothing it
//// could do reaching the project.
////
//// A verdict has to measure the router and may not feed the project's engine.
//// The router's own session cannot be used, because its `route` tool applies
//// decisions to the ledger and its conversation is long-lived, so a trial
//// would see the trials before it. Each trial therefore opens a session of its
//// own, in memory, through `harness` (the embedding door that needs no daemon),
//// and stops it when the trial ends.
////
//// ## What the session holds
////
//// - The router's pack, rendered the way the router's is, and the router's
////   resolved model: the head of the `router` role, else `subagent`, else the
////   model `main` routes (`serve.routed_identity`).
//// - One tool, `route`, with the router's name, schema and wording
////   (`tools/project.judge_tools`). Its executor records the items the model
////   gave and applies nothing, and a successful call ends the run. There is no
////   `project_read`, `reply`, `bash`, `code_mode`, extension or peer tool, so
////   there is nothing for a trigger's text to steer the model into using.
//// - A broker-free tool context (`harness.Embedded`), which refuses every
////   jailed execution. The tools it can run are plain functions.
//// - The trigger's text under the same `TriggerOrigin` the router sees, so it
////   reaches the model fenced, labelled untrusted, and with a marker longer
////   than any run of `=` the text holds. The thread as it stood comes first, as
////   host text outside the fence, from the tape and nothing later.
////
//// ## Why the trials are independent
////
//// Each trial opens its own in-memory session, so the model's context holds
//// that trial's messages and no other's. A decision that depended on an earlier
//// trial would be a property of the order the trials ran in, and the verdict
//// would measure that and not the router.
////
//// ## Where it stops
////
//// `trial` closes its session after the model has answered or failed, on every
//// path that opened one. A trial cancelled from outside, by the run's wall
//// limit or a failed sibling, cannot close what it opened, because its process
//// is killed. Linking is not enough either: the in-memory store dies with the
//// trial and the session's supervisor restarts a writer that cannot work, and
//// that goes on until its restart budget is spent. So the trial hands the
//// session's root to the run (`project_judge.Custody`, a weft managed task's
//// ledger) before it sends anything. The run closes the session when it
//// cancels the trial and holds the trial's slot until the root has exited,
//// and the project actor's own stopping ends the run, which does the same.
////
//// ## Flow
////
//// `ground_of` → `judge_for` → `trial` → `converse`
////
//// 1. `ground_of` reads a router's settings once: its gateway, model, facts and
////    rendered prompt.
//// 2. `judge_for` closes over that ground and the run's limits.
//// 3. `trial` opens the session, runs `converse`, reads the spend, closes the
////    session and reports.
//// 4. `converse` sends the thread and the fenced trigger, waits for the run,
////    and reads the items the model's call recorded.

import client/catalog
import client/internal/ffi_os
import client/project_judge.{
  type Decision, type Failure, type Judge, type Limits, type Spend, Decision,
  Failure, Judge, Spend,
}
import client/project_packs
import client/serve
import client/system_prompt
import client/wiring
import core/clock
import core/message
import core/origin
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import harness
import harness/model_facts
import machine/operation
import machine/strand as machine_strand
import project/judge
import project/model
import project/tape.{type Frame}
import provider/gateway as provider_gateway
import provider/model as provider_model
import runtime/api
import runtime/writer
import session/session
import storage/storage
import tools/project as project_tools
import tools/tool
import weft/actor

/// A path for the broker-free tool context. The scratch session's one tool
/// reads no file and the context refuses every jailed execution, so the path is
/// never opened. It is absolute because the context requires that.
const unused_root = "/nonexistent/loom-project-judge"

/// A session's default is to retry a failed request without limit, which is
/// right for a conversation a person is waiting on and wrong here: a rejected
/// key would hold a trial, and with it the run, until the wall limit. Three
/// attempts ride out a rate limit or a dropped connection, and a trial that
/// still fails ends the run with the provider's own words.
const trial_retries =
  operation.NormalizedRetryPolicy(
    attempts: operation.Bounded(max_attempts: 3),
    base_delay_ms: 1000,
    max_delay_ms: 8000,
  )

/// Everything a trial needs from the daemon, read once for a run.
pub type Ground {
  Ground(
    /// The provider gateway the router's own requests go through.
    gateway: provider_gateway.Gateway,
    /// The role asked whether it still routes. The first of `router`,
    /// `subagent` and `main` that does.
    role: provider_model.Role,
    /// The strand's model and thinking level, seeded as the router's are.
    strand: machine_strand.StrandConfiguration,
    /// The model facts of the router's catalogue.
    lookup: model_facts.Lookup,
    /// The figures for a model the catalogue does not know.
    fallback: model_facts.Fallback,
    /// The router's pack, rendered.
    system: String,
    /// Told each session as it opens, before the trial uses it. The daemon
    /// does nothing with it, and a test uses it to learn which processes a
    /// run started and to check that they stopped.
    opened: fn(api.Runtime) -> Nil,
  )
}

/// Reads a router's ground from the settings its session would open with,
/// before the project standing is applied. `Error` is a sentence for the owner:
/// no model routes the router, or its pack does not render.
///
/// ## Examples
///
/// ```gleam
/// // project_judge_session.ground_of(settings)
/// ```
pub fn ground_of(settings: serve.Settings) -> Result(Ground, String) {
  use role <- result.try(routing_role(settings.gateway))
  use rendered <- result.map(rendered_pack(settings))
  let identity = serve.routed_identity(settings)

  // A strand starts at the thinking its catalogue entry declares, as the
  // router's strand does, and at off for a model the catalogue does not know.
  let thinking = case catalog.find(settings.catalog, identity.provider) {
    Ok(entry) -> wiring.strand_thinking_level(entry.thinking)
    Error(Nil) -> machine_strand.ThinkingOff
  }

  Ground(
    gateway: settings.gateway,
    role:,
    strand: machine_strand.StrandConfiguration(
      model: identity,
      thinking_level: thinking,
      active_tool_names: [project_tools.route_tool_name],
    ),
    lookup: lookup_of(serve.catalogue_facts(settings.catalog)),
    fallback: model_facts.Fallback(
      api: settings.api,
      context_window: settings.context_window,
      max_output_tokens: settings.max_output_tokens,
    ),
    system: rendered,
    opened: fn(_) { Nil },
  )
}

/// The first of the router's roles that routes to a usable model. The router's
/// own session falls back the same way, so a daemon with no `router` role
/// judges with the model its router uses.
fn routing_role(
  gateway: provider_gateway.Gateway,
) -> Result(provider_model.Role, String) {
  [catalog.router_role, provider_model.Subagent, provider_model.Main]
  |> list.find(fn(role) {
    result.is_ok(provider_gateway.resolve(gateway, role))
  })
  |> result.replace_error(
    "no model is configured for the router, subagent or main role, so a live verdict has no model to ask.",
  )
}

/// The catalogue's facts seam as `harness` names it. The catalogue keeps its
/// own `ImageReading`, and this is the one place the two are mapped.
fn lookup_of(
  facts: fn(machine_strand.ModelIdentity) ->
    Result(#(provider_model.ResolvedModel, String, catalog.ImageReading), Nil),
) -> model_facts.Lookup {
  fn(identity) {
    facts(identity)
    |> result.map(fn(known) {
      let #(resolved, api, reading) = known
      model_facts.Known(resolved:, api:, reading: case reading {
        catalog.ReadsImages -> model_facts.ReadsImages
        catalog.TextOnly -> model_facts.TextOnly
      })
    })
  }
}

/// The router's pack rendered for a session that holds one tool. The router's
/// own prompt names its three tools and the operator's instruction files, and
/// this one names `route` alone and carries no instruction files, so the model
/// is never told of a tool the scratch session lacks.
fn rendered_pack(settings: serve.Settings) -> Result(String, String) {
  let registry = tool.registry(project_tools.judge_tools(unused_route))
  system_prompt.render_pack(
    system_prompt.Provided(label: "the project router's pack"),
    project_packs.router(),
    system_prompt.Host(
      workspace: settings.workspace,
      platform: ffi_os.platform(),
      shell: "/bin/sh",
      tools: tool.names(registry),
      available_tools: tool.snippets(registry),
      demand: settings.demand,
      degraded: False,
      base_policy: settings.base_policy,
      guidance: None,
    ),
  )
  |> result.map(fn(rendered) { rendered.text })
}

/// A `route` that is only rendered, never run.
fn unused_route(
  _ctx: tool.Ctx,
  _items: List(project_tools.Item),
) -> Result(List(project_tools.ItemOutcome), project_tools.Refusal) {
  Error(project_tools.Unavailable("the prompt's tool is not run"))
}

/// The judge for a ground: each trial is a scratch session, and the run is
/// bounded by `limits`.
///
/// ## Examples
///
/// ```gleam
/// // project_judge_session.judge_for(ground, project_judge.Limits(4, 1_200_000))
/// ```
pub fn judge_for(ground: Ground, limits: Limits) -> Judge {
  Judge(
    decide: fn(frame, _index, custody) {
      trial(ground, limits.wall_ms, frame, custody)
    },
    limits:,
  )
}

/// One trial: a fresh session, one fenced trigger, the model's `route` call
/// read back as a choice. The session is closed on every path after it opens,
/// and the spend is read before it closes so a failed trial still reports what
/// it cost.
fn trial(
  ground: Ground,
  wait_ms: Int,
  frame: Frame,
  custody: project_judge.Custody,
) -> Result(Decision, Failure) {
  let items = process.new_subject()

  // A session that did not open has cost nothing and has nothing to close.
  case open(ground, items, custody) {
    Error(words) -> Error(Failure(words, project_judge.no_spend))
    Ok(Held(runtime:, custodian:)) -> {
      ground.opened(runtime)
      let answered = converse(runtime, wait_ms, frame, items)
      let spent = spend_of(runtime)
      let closed = api.close(runtime)

      // The custodian closes the session too, which finds it closed and ends
      // the custodian, so the run's custody of this trial is over.
      process.send(custodian, Close)

      // A session that will not close still holds its writer lease, so the
      // trial is reported as failed even when the model answered.
      case answered, closed {
        Ok(#(choice, routing)), Ok(Nil) ->
          Ok(Decision(choice:, routing:, spend: spent))
        Error(words), _ -> Error(Failure(words, spent))
        Ok(_), Error(_) ->
          Error(Failure("a scratch session did not stop cleanly.", spent))
      }
    }
  }
}

/// A session and the process that closes it when the run asks.
type Held {
  Held(runtime: api.Runtime, custodian: Subject(Close))
}

/// The one message of a custodian: close the session and end.
type Close {
  Close
}

/// Builds an in-memory session with the one tool and the router's prompt. A
/// session that opened and then could not be configured is closed before the
/// failure is reported. It runs in the custodian's process, so the session's
/// store and its supervision tree belong to the custodian and not to the trial.
fn build(
  ground: Ground,
  items: Subject(List(project_tools.Item)),
) -> Result(api.Runtime, String) {
  let now = clock.from_function(ffi_os.system_time_ms)
  use opened <- result.try(
    session.open_memory(now)
    |> result.map_error(fn(error) {
      "a scratch session did not open: " <> string.inspect(error)
    }),
  )
  let registry = registry_of(items)
  let configured =
    harness.new(
      harness.Settings(
        ..harness.settings(
          gateway: ground.gateway,
          session: opened,
          registry:,
          clock: now,
          fallback: ground.fallback,
          tools: harness.Embedded(
            workspace: unused_root,
            blob_root: unused_root <> "/blobs",
          ),
        ),
        system: Some(ground.system),
        role: ground.role,
        lookup: ground.lookup,
      ),
    )

  // A configuration the harness refuses leaves the session it was built over
  // open, and nothing else holds it.
  case configured {
    Error(error) -> {
      let _closed = session.close(opened)
      Error("the scratch session was refused: " <> string.inspect(error))
    }
    Ok(config) ->
      harness.open(
        config,
        api.Options(
          ..api.default_options(ground.strand),
          poll_interval_ms: 25,
          idle_poll_interval_ms: 25,
          retry_policy: trial_retries,
        ),
      )
  }
}

/// Opens the session under a custodian and hands the custodian to the run
/// before the trial sends anything. A trial cancelled from outside, by the
/// run's wall limit, a failed sibling or the project actor stopping, ends its
/// own process at once and cannot close what it opened, and a session left to
/// die with it would keep restarting a writer whose store is gone. The
/// custodian is a process of its own that opens the session, so the session
/// does not depend on the trial staying alive. It closes the session and ends
/// normally when it is told to or when the trial's process goes down, and the
/// run holds it as the trial's owner: it asks it to close when it cancels the
/// trial, and keeps the trial's slot until it has ended. The session's own root
/// cannot be the owner, because a supervisor's orderly stop is not the `normal`
/// exit that proves a drain. A run that is already ending refuses the
/// custodian, and the trial closes the session and does not start.
fn open(
  ground: Ground,
  items: Subject(List(project_tools.Item)),
  custody: project_judge.Custody,
) -> Result(Held, String) {
  let trial = process.self()

  use started <- result.try(
    actor.new_with_initialiser(10_000, fn(self) {
      use runtime <- result.map(build(ground, items))
      let watch =
        process.new_selector()
        |> process.select(self)
        |> process.select_specific_monitor(process.monitor(trial), fn(_down) {
          Close
        })
      actor.initialised(runtime)
      |> actor.selecting(watch)
      |> actor.returning(Held(runtime:, custodian: self))
    })
    |> actor.on_message(fn(runtime, _close: Close) {
      let _closed = api.close(runtime)
      actor.stop()
    })
    |> actor.unlinked
    |> actor.start
    |> result.map_error(fn(error) {
      "a scratch session did not start: " <> string.inspect(error)
    }),
  )
  let held = started.data

  // The run takes custody of the session or is already ending. In the second
  // case the session is closed before it did anything.
  case custody(started.pid, fn() { process.send(held.custodian, Close) }) {
    Ok(Nil) -> Ok(held)
    Error(Nil) -> {
      process.send(held.custodian, Close)
      Error("the run was ending, so this trial did not start.")
    }
  }
}

/// The tools a scratch session holds: the router's `route` over an executor
/// that records, ending the run on a successful call, and no other tool. The
/// strand's active list names `route` alone as well, so a second tool here
/// would be registered and still not offered. A test reads the registry's names
/// to hold the first of those two limits.
///
/// ## Examples
///
/// ```gleam
/// assert tool.names(project_judge_session.registry_of(process.new_subject())) == ["route"]
/// ```
pub fn registry_of(items: Subject(List(project_tools.Item))) -> tool.Registry {
  tool.registry(project_tools.judge_tools(recording(items)) |> list.map(ending))
}

/// The router's `route` with nothing behind it. It records the items the model
/// gave and says each was applied, which is what the model needs to be told for
/// the call to look like the router's, and applies nothing. The items go to the
/// trial's own subject and nowhere else, so no decision reaches the project.
fn recording(
  items: Subject(List(project_tools.Item)),
) -> fn(tool.Ctx, List(project_tools.Item)) ->
  Result(List(project_tools.ItemOutcome), project_tools.Refusal) {
  fn(_ctx, given) {
    process.send(items, given)
    Ok(list.map(given, fn(_) { project_tools.Applied }))
  }
}

/// A tool whose successful call ends the run. The model has said what it
/// would do, and a further request would be spend with nothing to read. A
/// failed call does not end it, so the model may correct its arguments.
fn ending(routed: tool.Tool) -> tool.Tool {
  tool.Tool(..routed, run: fn(ctx, arguments) {
    let outcome = routed.run(ctx, arguments)

    // A call the tool refused ends nothing, and one it accepted ends the run.
    case outcome.is_error {
      True -> outcome
      False -> tool.ToolOutcome(..outcome, terminate: tool.TerminateRun)
    }
  })
}

/// Sends the thread and the fenced trigger, waits for the run, and reads the
/// choice. A run that finished without a `route` call naming the candidate is
/// the project leaving it unrouted.
fn converse(
  runtime: api.Runtime,
  wait_ms: Int,
  frame: Frame,
  items: Subject(List(project_tools.Item)),
) -> Result(#(judge.Choice, project_judge.Routing), String) {
  use sent <- result.try(
    messages(frame)
    |> result.try(fn(prompts) {
      api.prompt(runtime, prompts)
      |> result.map_error(fn(error) {
        "the scratch session refused its prompt: " <> string.inspect(error)
      })
    }),
  )

  // Only a run that completed has a choice to read. A run that failed, was
  // aborted or never finished is no decision, and the trial fails with why.
  case api.await_result(runtime, sent, within_ms: wait_ms) {
    Error(Nil) ->
      Error("the router's model did not finish a trial within the wall limit.")
    Ok(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) ->
      Ok(choice_of(drain(items, []), frame.trigger.id))
    Ok(operation.RunLastResult(outcome: operation.RunFailed(error:), ..)) ->
      Error("the router's model failed: " <> error.message)
    Ok(operation.RunLastResult(outcome: operation.RunAborted, ..)) ->
      Error("a trial was aborted before the model answered.")
    Ok(operation.CompactionLastResult(..))
    | Ok(operation.NavigationLastResult(..)) ->
      Error("a trial ended in an operation it did not start.")
  }
}

/// Every `route` call the run recorded, oldest first.
fn drain(
  items: Subject(List(project_tools.Item)),
  found: List(project_tools.Item),
) -> List(project_tools.Item) {
  case process.receive(items, 0) {
    Ok(given) -> drain(items, list.append(found, given))
    Error(Nil) -> found
  }
}

/// The choice the items make for the candidate. The first item that names it
/// decides: any action but `ignore` takes the trigger on, because the tape
/// records an accept, an attach, a resume and a stop alike as the project
/// taking it. Items that name another trigger do not count.
fn choice_of(
  items: List(project_tools.Item),
  candidate: model.TriggerId,
) -> #(judge.Choice, project_judge.Routing) {
  case list.find(items, fn(item) { item.trigger == candidate }) {
    Error(Nil) -> #(judge.Pass, project_judge.Unrouted)
    Ok(item) ->
      case item.action {
        project_tools.Ignore -> #(judge.Pass, project_judge.Routed)
        project_tools.Accept(..)
        | project_tools.Attach(..)
        | project_tools.Resume(..)
        | project_tools.Stop(..) -> #(judge.Take, project_judge.Routed)
      }
  }
}

/// The messages of a trial. The thread comes first as the host's own text, the
/// ids and whether each message was received or only recorded, oldest first,
/// which is what the router reads through `project_read`. The trigger comes
/// second with the origin the router's would carry, so provider projection
/// fences it. An origin the fence refuses fails the trial, as the router's own
/// delivery would be refused.
///
/// ## Examples
///
/// ```gleam
/// // project_judge_session.messages(frame)
/// ```
pub fn messages(frame: Frame) -> Result(List(message.AgentMessage), String) {
  let trigger = frame.trigger
  use fenced <- result.map(
    origin.validate_trigger(
      trigger.source.value,
      trigger.id.value,
      trigger.actor.value,
    )
    |> result.map_error(fn(_) {
      "trigger " <> trigger.id.value <> " has an id the fence refuses."
    }),
  )
  let now = ffi_os.system_time_ms()
  [
    message.UserMessage(
      content: [message.UserText(thread_note(frame), None)],
      timestamp: now,
      origin: None,
    ),
    message.UserMessage(
      content: [message.UserText(frame.text, None)],
      timestamp: now,
      origin: Some(fenced),
    ),
  ]
}

/// The thread as it stood, in the words the host would use. Only entries up to
/// and including the trigger are in the frame, so nothing later is named.
///
/// ## Examples
///
/// ```gleam
/// // project_judge_session.thread_note(frame)
/// ```
pub fn thread_note(frame: Frame) -> String {
  let entries =
    list.reverse(frame.thread)
    |> list.map(fn(entry) {
      let received = reception_word(entry.reception)

      // The candidate is one of the entries, and the model is told which.
      let marker = case entry.trigger == frame.trigger.id {
        True -> " (the candidate below)"
        False -> ""
      }

      "- " <> entry.trigger.value <> ", " <> received <> marker
    })
  string.join(
    [
      "Candidate "
        <> frame.trigger.id.value
        <> " arrived on thread "
        <> frame.trigger.thread.value
        <> ". The thread as it stood, oldest message first:",
      ..entries
    ],
    "\n",
  )
}

/// Whether the gate let a message through, in the words `project_read` shows.
fn reception_word(reception: model.Reception) -> String {
  case reception {
    model.Received -> "received"
    model.Recorded -> "recorded"
  }
}

/// What the session's provider requests cost: how many, and the tokens the
/// provider reported. A ledger that cannot be read counts as nothing spent.
fn spend_of(runtime: api.Runtime) -> Spend {
  case writer.scan_usage(runtime.tree.writer, storage.usage_scan()) {
    Ok(rows) ->
      Spend(
        calls: list.length(rows),
        tokens: list.fold(rows, 0, fn(total, row) {
          total + row.usage.total_tokens
        }),
      )
    Error(_) -> project_judge.no_spend
  }
}
