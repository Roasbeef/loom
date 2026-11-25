//// The Jev pass inside the project actor, over a real ledger and the real
//// engine, with the transport to Jev replaced by a fake fetch. Nothing here
//// reaches the network or a key.
////
//// What the fake stands for: `fetch` is the one function a request passes
//// through after the client has built it and added its header, so these tests
//// see the very request that would be sent and answer with a body, a status or
//// a failure. The claims are about the actor: that the pass decides before the
//// router is offered, that a failure leaves the candidate for the router with
//// a recorded reason, that an agent is committed before its routing and starts
//// the worker, and that the router's turn clock does not run during a pass.

import client/codex/network
import client/daemon/project_host
import client/internal/ffi_os
import client/jev as transport
import client/peer_mail
import client/project_settings.{Agent, JevRouter}
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import project/model
import provider/http
import simplifile
import storage/project_ledger
import support/project_ports
import tools/project as tools

type Seen {
  Started(request: project_host.StartRequest)
  Sent(session: String, command: peer_mail.Command)
  Fetching(authorization: String, body: String)
  Fetched(body: String)
}

type Rig {
  Rig(config: project_host.Config, seen: Subject(Seen))
}

/// What the fake service does with a request.
type Service {
  Answers(body: String)
  Down
  SlowDown(ms: Int)

  /// The body is chosen from the request's own, since the questions asked
  /// depend on the tickets listed.
  Chosen(pick: fn(String) -> String)

  /// A request whose body holds `text` takes `ms` and then fails. Any other
  /// fails at once.
  SlowFor(text: String, ms: Int)
}

// A response to the question set of an explicit trigger with no listed ticket
// and no catalogue: only `clear_alone` is asked.
const clear_body =
  "{\"model\":\"jev-1.14.0\",\"answers\":{\"clear_alone\":{\"type\":\"noul\",\"noul\":0.95}},\"usage\":{\"input_tokens\":100,\"output_tokens\":5}}"

// The same with a two-agent catalogue: the `agent` Choice is asked as well, and
// answers `agent_2`.
// The same when a ticket is listed: the continues Noul is asked as well.
const listed_body =
  "{\"model\":\"jev-1.14.0\",\"answers\":{\"clear_alone\":{\"type\":\"noul\",\"noul\":0.95},\"continues_listed_ticket\":{\"type\":\"noul\",\"noul\":0.05}},\"usage\":{\"input_tokens\":110,\"output_tokens\":6}}"

const agent_body =
  "{\"model\":\"jev-1.14.0\",\"answers\":{\"clear_alone\":{\"type\":\"noul\",\"noul\":0.95},\"agent\":{\"type\":\"choice\",\"choice\":\"agent_2\",\"confidence\":0.8,\"probabilities\":{\"agent_2\":0.75,\"agent_1\":0.25}}},\"usage\":{\"input_tokens\":120,\"output_tokens\":7}}"

fn agents() -> List(project_settings.Agent) {
  [
    Agent(
      name: "small fixes",
      use_for: "small fixes",
      profile: Some("cheap"),
      model: None,
    ),
    Agent(
      name: "refactors",
      use_for: "large refactors",
      profile: None,
      model: Some("opus"),
    ),
  ]
}

fn rig(
  name: String,
  service: Service,
  catalogue: List(project_settings.Agent),
) -> Rig {
  let directory =
    "build/project-jev-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
    as "the scratch directory is made"
  let seen = process.new_subject()
  let fetch = fn(request: http.HttpRequest, _limit, _timeout) {
    process.send(seen, Fetching(authorization_of(request), request.body))
    let answered = case service {
      Answers(body) -> Ok(network.Response(200, body))
      Chosen(pick) -> Ok(network.Response(200, pick(request.body)))
      Down -> Error("request_transport_failed")
      SlowDown(ms) -> {
        process.sleep(ms)
        Error("request_timed_out")
      }
      SlowFor(text, ms) -> {
        case string.contains(request.body, text) {
          True -> process.sleep(ms)
          False -> Nil
        }
        Error("request_timed_out")
      }
    }
    process.send(seen, Fetched(request.body))
    answered
  }
  let ports =
    project_host.Ports(
      ..project_ports.inert(),
      start_session: fn(request: project_host.StartRequest) {
        process.send(seen, Started(request))
        Ok("session-" <> request.key)
      },
      endpoint_of: fn(session) {
        Ok(
          peer_mail.Endpoint(session, fn(command) {
            process.send(seen, Sent(session, command))
            Ok(json.Null)
          }),
        )
      },
      jev: transport.client_with(Some("sekret"), 3000, fetch),
    )
  Rig(
    config: project_host.Config(
      project: "p1",
      workspace: "/work/repo",
      router_session: "router-1",
      ledger_path: directory <> "/ledger.db",
      max_workers: 2,
      tick_ms: 50,
      router_turn_ms: 100,
      policy: project_host.Policy(
        ..project_host.idle_policy,
        router: JevRouter,
        agents: catalogue,
      ),
      ports: fn() { ports },
    ),
    seen:,
  )
}

fn authorization_of(request: http.HttpRequest) -> String {
  case list.key_find(request.headers, "authorization") {
    Ok(value) -> value
    Error(Nil) -> ""
  }
}

fn start(rig: Rig) -> project_host.Handle {
  let assert Ok(handle) = project_host.start(rig.config)
    as "the project actor starts"
  handle
}

// Everything the fakes recorded so far, oldest first, after a pause long enough
// for the actor to finish what it was asked.
fn drain(seen: Subject(Seen)) -> List(Seen) {
  case process.receive(seen, 400) {
    Ok(one) -> [one, ..drain(seen)]
    Error(Nil) -> []
  }
}

fn to_router(seen: List(Seen)) -> List(String) {
  list.filter_map(seen, fn(each) {
    case each {
      Sent("router-1", peer_mail.Trigger(from:, ..)) -> Ok(from.trigger)
      _ -> Error(Nil)
    }
  })
}

fn started(seen: List(Seen)) -> List(project_host.StartRequest) {
  list.filter_map(seen, fn(each) {
    case each {
      Started(request) -> Ok(request)
      _ -> Error(Nil)
    }
  })
}

// The ledger's lines, oldest first, read from the file the actor writes.
fn ledger_lines(rig: Rig) -> List(String) {
  let assert Ok(ledger) = project_ledger.open(rig.config.ledger_path)
    as "the ledger opens"
  let assert Ok(stored) = project_ledger.replay(ledger, 0, 500)
    as "the ledger replays"
  let assert Ok(Nil) = project_ledger.close(ledger) as "the ledger closes"
  list.map(stored, fn(each) { each.event_json })
}

pub fn jev_settles_a_clear_trigger_before_the_router_is_offered_test() {
  let rig = rig("settles", Answers(clear_body), [])
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let seen = drain(rig.seen)

  // The request carried the key as a bearer header, and the worker started.
  assert list.any(seen, fn(each) {
    case each {
      Fetching(authorization, _) -> authorization == "Bearer sekret"
      _ -> False
    }
  })
  let assert [request] = started(seen)
  assert request.key == "project:p1:t-a:1"
  assert request.agent == None

  // The router was never offered a trigger Jev settled, and the ledger says
  // Jev did, with no fallback.
  assert to_router(seen) == []
  let lines = ledger_lines(rig)
  assert list.any(lines, string.contains(_, "\"judgement\""))
  assert !list.any(lines, string.contains(_, "jev_fallback"))
}

pub fn the_jev_pin_is_announced_before_the_decisions_it_measures_test() {
  let rig = rig("pin", Answers(clear_body), [])
  let handle = start(rig)
  project_host.pin_router(handle, "sha256:router", "profile:default model:x")
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let _ = drain(rig.seen)
  let lines = ledger_lines(rig)
  let position = fn(needle: String) {
    list.index_map(lines, fn(line, index) { #(index, line) })
    |> list.find(fn(entry) { string.contains(entry.1, needle) })
    |> option.from_result
    |> option.map(fn(entry) { entry.0 })
  }
  let assert Some(pinned) = position("router_pin_set")
  let assert Some(routed) = position("\"t\":\"routed\"")
  assert pinned < routed

  // The pin names the model the response reported, in the Jev form.
  assert list.any(lines, string.contains(_, "jev/jev-1.14.0/"))
}

pub fn a_second_batch_reaches_jev_once_the_first_is_settled_test() {
  let pick = fn(body: String) {
    case string.contains(body, "ticket_") || string.contains(body, "tickets") {
      True -> listed_body
      False -> clear_body
    }
  }
  let rig = rig("second", Chosen(pick), [])
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok(_) = project_host.post(handle, "b", "fix b")
  let seen = drain(rig.seen)

  // Settling a batch whole ends the router's turn, so the second candidate is
  // offered next, and the router is never involved.
  assert list.map(started(seen), fn(request) { request.key })
    == ["project:p1:t-a:1", "project:p1:t-b:1"]
  assert to_router(seen) == []
}

pub fn the_board_names_who_decided_and_why_jev_left_a_trigger_test() {
  let settled = rig("board-jev", Answers(clear_body), [])
  let handle = start(settled)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let _ = drain(settled.seen)
  let assert Ok(shown) = project_host.board(handle, 0)
  let text = json.to_string(json.Array(shown.decisions))
  assert string.contains(text, "\"decider\":\"jev\"")
  assert string.contains(text, "\"model\":\"jev-1.14.0\"")
  assert string.contains(text, "\"decision\":\"accepted\"")

  // The probability is the clarity of the message, since no ticket was listed
  // to continue.
  assert string.contains(text, "\"probability\":9500")

  // A trigger the router decided after Jev failed says why Jev left it.
  let slow = rig("board-down", Down, [])
  let down =
    Rig(
      ..slow,
      config: project_host.Config(..slow.config, router_turn_ms: 3_600_000),
    )
  let other = start(down)
  let assert Ok(_) = project_host.post(other, "a", "fix a")
  let _ = drain(down.seen)
  let assert Ok(_) = project_host.route(other, [accept("a")])
  let assert Ok(after) = project_host.board(other, 0)
  let later = json.to_string(json.Array(after.decisions))
  assert string.contains(later, "\"decider\":\"model\"")
  assert string.contains(later, "\"fallback\":\"unavailable\"")
}

pub fn an_unavailable_service_leaves_the_trigger_to_the_router_test() {
  let rig = rig("down", Down, [])
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let seen = drain(rig.seen)
  // The router keeps its own offers and turn deadline, so it may be offered
  // the trigger again once its turn ends. What the test claims is that it was
  // offered, and that no worker started on Jev's behalf.
  let offered = to_router(seen)
  assert offered != []
  assert list.all(offered, fn(trigger) { trigger == "a" })
  assert started(seen) == []
  assert list.any(ledger_lines(rig), fn(line) {
    string.contains(line, "jev_fallback")
    && string.contains(line, "unavailable")
  })
}

pub fn a_chosen_agent_is_committed_before_its_routing_and_starts_the_worker_test() {
  let rig = rig("agent", Answers(agent_body), agents())
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let seen = drain(rig.seen)
  let assert [request] = started(seen)
  let assert Some(agent) = request.agent
  assert agent.name == "refactors"
  assert agent.model == Some("opus")

  // The agent event is earlier in the ledger than the routing it belongs to.
  let lines = ledger_lines(rig)
  let position = fn(needle: String) {
    list.index_map(lines, fn(line, index) { #(index, line) })
    |> list.find(fn(entry) { string.contains(entry.1, needle) })
    |> option.from_result
    |> option.map(fn(entry) { entry.0 })
  }
  let assert Some(chosen) = position("agent_chosen")
  let assert Some(routed) = position("\"t\":\"routed\"")
  assert chosen < routed
}

pub fn the_routers_turn_clock_does_not_run_during_a_pass_test() {
  // The first trigger goes to the router, which stamps the turn clock. The
  // second waits in the queue and, once the first is routed, is put to Jev
  // under a request that takes four times the router's turn deadline. Were the
  // stamp of the first turn still in force, a tick would end the turn and
  // re-offer the second trigger to the router while the pass is still waiting.
  let rig = rig("clock", SlowFor("fix b", 400), [])
  let handle = start(rig)
  let assert Ok(_) = project_host.post(handle, "a", "fix a")
  let assert Ok(_) = project_host.post(handle, "b", "fix b")
  let seen =
    collected(rig.seen, [], 120, fn(all) { list.contains(to_router(all), "b") })

  // The router's first sight of `b` follows the end of the request about `b`.
  let before_router =
    list.take_while(seen, fn(each) {
      case each {
        Sent("router-1", peer_mail.Trigger(from:, ..)) -> from.trigger != "b"
        _ -> True
      }
    })
  let asked_about_b =
    list.count(seen, fn(each) {
      case each {
        Fetching(_, body) -> string.contains(body, "fix b")
        _ -> False
      }
    })
  assert asked_about_b == 1
  assert list.any(before_router, fn(each) {
    case each {
      Fetched(body) -> string.contains(body, "fix b")
      _ -> False
    }
  })
  assert list.contains(to_router(seen), "b")
}

// Everything the fakes record, oldest first, until `enough` holds of what has
// been seen or `polls` waits of 50 ms have passed.
fn collected(
  seen: Subject(Seen),
  so_far: List(Seen),
  polls: Int,
  enough: fn(List(Seen)) -> Bool,
) -> List(Seen) {
  case enough(so_far) || polls == 0 {
    True -> so_far
    False ->
      case process.receive(seen, 50) {
        Ok(one) -> collected(seen, list.append(so_far, [one]), polls, enough)
        Error(Nil) -> collected(seen, so_far, polls - 1, enough)
      }
  }
}

fn accept(trigger: String) -> tools.Item {
  tools.Item(
    trigger: model.TriggerId(trigger),
    action: tools.Accept(model.title("work on " <> trigger)),
    holds: [],
    related: [],
    prior_hand_back: None,
  )
}
