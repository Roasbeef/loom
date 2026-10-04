//// Finite observations exercise the production manager and protocol actor.
//// These fixtures prove explicit scope, refusal instead of partial publication,
//// checked document intervals and cancellation without stopping the shared lease.

import client/internal/ffi_os
import codemode/lsp_host/manager
import codemode/lsp_host/profile
import codemode/lsp_host/resolve
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import lsp/observation
import lsp/query
import simplifile
import support/fake_lsp
import weft/poll

fn scratch() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "a working directory exists"
  let root =
    here
    <> "/build/lsp-observation-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "create the fixture"
  let assert Ok(Nil) =
    simplifile.write(root <> "/gleam.toml", "name = \"fixture\"\n")
    as "write marker"
  let assert Ok(Nil) =
    simplifile.write(root <> "/a.gleam", "pub fn greet() { 1 }\n")
    as "write source"
  root
}

fn server() -> profile.LspServer {
  profile.LspServer(
    preparation: profile.AlreadyPrepared,
    name: "fake",
    command: ["/bin/false"],
    extensions: [".gleam"],
    root_markers: ["gleam.toml"],
    project: profile.ProjectReadOnly,
    readable: [],
    writable: [],
    env: [],
    cache_env: [],
    language_id: "gleam",
    qualifier_separators: ["."],
    module_case: profile.AsWritten,
    hint: None,
  )
}

fn rig(
  root: String,
  script: fn(String, option.Option(json.JsonValue)) -> fake_lsp.Answer,
) -> #(manager.Manager, fake_lsp.Fake) {
  let fake = fake_lsp.start(fake_lsp.everything(), script)
  let timing =
    manager.Timing(
      ..manager.default_timing(),
      quiet_ms: 0,
      ready_ms: 100,
      request_ms: 10_000,
      stop_grace_ms: 200,
    )
  let assert Ok(manager) =
    manager.start(manager.Config(
      workspace: root,
      servers: [server()],
      timing:,
      backend: manager.Backend(
        metadata_roots: [root],
        connect: fn(_identity: resolve.Identity) { Ok(fake_lsp.seam(fake)) },
        search: fn(_) { panic as "an observation must never search a workspace" },
        protected: [root <> "/protected"],
      ),
    ))
    as "start the manager"
  #(manager, fake)
}

fn control(within: Int) -> observation.Control {
  observation.Control(
    deadline_ms: bootstrap.monotonic_time_ms() + within,
    now: bootstrap.monotonic_time_ms,
  )
}

fn request(root: String) -> observation.Request {
  observation.Request(server: "fake", root:, outlines: ["a.gleam"], targets: [
    query.SymbolQuery(symbol: "greet", path: Some("a.gleam"), line: Some(1)),
  ])
}

fn position(character: Int) -> json.JsonValue {
  json.Object([#("line", json.Int(0)), #("character", json.Int(character))])
}

fn span() -> json.JsonValue {
  json.Object([#("start", position(7)), #("end", position(12))])
}

fn outline() -> json.JsonValue {
  json.Array([
    json.Object([
      #("name", json.String("greet")),
      #("kind", json.Int(12)),
      #("range", span()),
      #("selectionRange", span()),
    ]),
  ])
}

fn location(path: String) -> json.JsonValue {
  json.Object([#("uri", json.String("file://" <> path)), #("range", span())])
}

fn finish(manager: manager.Manager, root: String) -> Nil {
  manager.stop(manager)
  let assert Ok(Nil) = simplifile.delete_all([root]) as "remove the fixture"
  Nil
}

pub fn explicit_scope_withholds_external_locations_without_container_fanout_test() {
  let root = scratch()
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        "textDocument/references" ->
          fake_lsp.Answer(
            json.Array([
              location(root <> "/a.gleam"),
              location("/not-admitted/secret.gleam"),
            ]),
          )
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let requested = request(root)
  let assert Ok(batch) =
    manager.observation_door(manager).collect(requested, control(5000))
    as "collect a complete scope"
  assert batch.requested == requested
  assert batch.outlined == [root <> "/a.gleam"]
  assert batch.counts.requests == 2
  assert batch.counts.withheld == 1
  assert batch.counts.facts == 4
  assert list.length(batch.targets) == 1
  assert list.length(batch.symbols) == 1
  assert list.length(batch.references) == 1
  let assert [document] = batch.documents as "only admitted source text is read"
  assert document.version != None
  assert string.starts_with(document.digest, "sha256-")
  assert string.starts_with(batch.generation, "sha256-")
  assert batch.finished_ms >= batch.started_ms
  assert list.length(
      list.filter(fake_lsp.methods(fake), fn(method) {
        method == "textDocument/documentSymbol"
      }),
    )
    == 1
  finish(manager, root)
}

pub fn path_only_seed_counts_its_outline_resolution_test() {
  let root = scratch()
  let #(manager, _fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        "textDocument/references" -> fake_lsp.Answer(json.Array([]))
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let asked = query.SymbolQuery("greet", Some("a.gleam"), None)
  let requested = observation.Request("fake", root, [], [asked])
  let assert Ok(batch) =
    manager.observation_door(manager).collect(requested, control(5000))
    as "resolve the explicit seed"
  assert batch.counts.requests == 2
  assert batch.symbols == []
  assert batch.outlined == []
  assert list.length(batch.targets) == 1
  finish(manager, root)
}

pub fn changed_disk_text_refuses_the_entire_observation_test() {
  let root = scratch()
  let #(manager, _fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        "textDocument/references" -> {
          let assert Ok(Nil) =
            simplifile.write(
              root <> "/a.gleam",
              "// changed\npub fn greet() { 1 }\n",
            )
            as "edit during collection"
          fake_lsp.Answer(json.Array([]))
        }
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let assert Error(observation.Changed(_)) =
    manager.observation_door(manager).collect(request(root), control(5000))
    as "do not publish mixed-time facts"
  finish(manager, root)
}

pub fn invalid_scope_does_not_start_or_query_the_server_test() {
  let root = scratch()
  let #(manager, fake) = rig(root, fn(_, _) { fake_lsp.Answer(json.Null) })
  let bare =
    observation.Request("fake", root, [], [
      query.SymbolQuery("greet", None, None),
    ])
  let assert Error(observation.InvalidScope(_)) =
    manager.observation_door(manager).collect(bare, control(5000))
    as "no implicit crawl"
  let too_many =
    observation.Request(
      "fake",
      root,
      [],
      list.repeat(query.SymbolQuery("greet", Some("a.gleam"), Some(1)), 33),
    )
  let assert Error(observation.InvalidScope(_)) =
    manager.observation_door(manager).collect(too_many, control(5000))
    as "enforce scope admission"
  assert fake_lsp.methods(fake) == []
  finish(manager, root)
}

pub fn a_source_outside_the_workspace_is_refused_by_name_before_any_request_test() {
  let root = scratch()
  let foreign = scratch()
  let #(manager, fake) = rig(root, fn(_, _) { fake_lsp.Answer(json.Null) })
  let assert Ok(Nil) =
    simplifile.create_symlink(to: foreign, from: root <> "/linked")
    as "the fixture directory link must be made"
  let door = manager.observation_door(manager)

  // An outline, a reference seed, and the foreign tree named as the root
  // itself: each spelling of the sibling clone is refused as a missing
  // server, with the path and the workspace root in the reason.
  let outside = [
    foreign <> "/a.gleam",
    "../" <> last_segment(foreign) <> "/a.gleam",
    "linked/a.gleam",
  ]
  list.each(outside, fn(path) {
    let seed = query.SymbolQuery("greet", Some(path), Some(1))
    let outlined = observation.Request("fake", root, [path], [])
    let targeted = observation.Request("fake", root, [], [seed])
    let rooted = observation.Request("fake", foreign, [path], [])
    list.each([outlined, targeted, rooted], fn(asked) {
      let assert Error(observation.QueryFailed(query.NoServer(reason))) =
        door.collect(asked, control(5000))
        as { "a source outside the workspace must be refused: " <> path }
      assert string.contains(reason, path)
      assert string.contains(reason, root)
    })
  })
  assert fake_lsp.methods(fake) == []
  finish(manager, root)
  let assert Ok(Nil) = simplifile.delete_all([foreign]) as "remove the foreign"
  Nil
}

fn last_segment(path: String) -> String {
  let assert Ok(last) = list.last(string.split(path, "/"))
    as "a path has a last segment"
  last
}

pub fn fixed_deadline_cancels_the_pending_request_without_stopping_the_server_test() {
  let root = scratch()
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/references" -> fake_lsp.Silent
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let assert Error(_) =
    manager.observation_door(manager).collect(request(root), control(150))
    as "the invocation bounds the entire collection"
  await_method(fake, "$/cancelRequest")
  assert !list.contains(fake_lsp.methods(fake), "shutdown")
  let assert Ok(_) = manager.door(manager).outline("a.gleam")
    as "the shared server still serves"
  finish(manager, root)
}

pub fn caller_death_cancels_fanout_and_the_pending_protocol_request_test() {
  let root = scratch()
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/references" -> fake_lsp.Silent
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let scope = request(root)
  let scope =
    observation.Request(
      ..scope,
      targets: list.append(scope.targets, scope.targets),
    )
  let caller =
    process.spawn_unlinked(fn() {
      let _ = manager.observation_door(manager).collect(scope, control(5000))
      Nil
    })
  await_method(fake, "textDocument/references")
  process.kill(caller)
  await_method(fake, "$/cancelRequest")
  assert !list.contains(fake_lsp.methods(fake), "shutdown")
  let assert Ok(_) = manager.door(manager).outline("a.gleam")
    as "the lease survives caller cancellation"
  assert list.length(
      list.filter(fake_lsp.methods(fake), fn(method) {
        method == "textDocument/references"
      }),
    )
    == 1
  finish(manager, root)
}

fn await_method(fake: fake_lsp.Fake, method: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 3000, every: 10, attempt: fn() {
      case list.contains(fake_lsp.methods(fake), method) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "the pending protocol request must be cancelled"
  Nil
}

pub fn malformed_path_only_seed_refuses_before_reference_request_test() {
  let root = scratch()
  let invalid =
    json.Object([
      #("line", json.Int(999)),
      #("character", json.Int(7)),
    ])
  let bad_span = json.Object([#("start", invalid), #("end", invalid)])
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" ->
          fake_lsp.Answer(
            json.Array([
              json.Object([
                #("name", json.String("greet")),
                #("kind", json.Int(12)),
                #("range", bad_span),
                #("selectionRange", bad_span),
              ]),
            ]),
          )
        "textDocument/references" -> fake_lsp.Answer(json.Array([]))
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let scope =
    observation.Request(server: "fake", root:, outlines: [], targets: [
      query.SymbolQuery(symbol: "greet", path: Some("a.gleam"), line: None),
    ])
  let assert Error(observation.Changed(_)) =
    manager.observation_door(manager).collect(scope, control(5000))
    as "a malformed resolver position is not a reference seed"
  assert !list.contains(fake_lsp.methods(fake), "textDocument/references")
  finish(manager, root)
}

pub fn malformed_reference_coordinates_refuse_publication_test() {
  let root = scratch()
  let #(manager, _fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        "textDocument/references" ->
          fake_lsp.Answer(
            json.Array([
              json.Object([
                #("uri", json.String("file://" <> root <> "/a.gleam")),
                #(
                  "range",
                  json.Object([
                    #("start", position(999)),
                    #("end", position(1000)),
                  ]),
                ),
              ]),
            ]),
          )
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let assert Error(observation.Changed(_)) =
    manager.observation_door(manager).collect(request(root), control(5000))
    as "clamped server coordinates are not complete facts"
  finish(manager, root)
}

pub fn complete_results_over_the_fact_bound_are_refused_test() {
  let root = scratch()
  let #(manager, _fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        "textDocument/references" ->
          fake_lsp.Answer(
            json.Array(list.repeat(location(root <> "/a.gleam"), 10_000)),
          )
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let assert Error(observation.LimitExceeded(_)) =
    manager.observation_door(manager).collect(request(root), control(5000))
    as "publish no truncated success"
  finish(manager, root)
}

pub fn complete_results_over_the_byte_bound_are_refused_test() {
  let root = scratch()
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/a.gleam",
      "pub fn greet() { 1 }" <> string.repeat("x", 4096) <> "\n",
    )
    as "write a long observed line"
  let #(manager, _fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        "textDocument/references" ->
          fake_lsp.Answer(
            json.Array(list.repeat(location(root <> "/a.gleam"), 1200)),
          )
        _ -> fake_lsp.Answer(json.Null)
      }
    })
  let assert Error(observation.LimitExceeded(_)) =
    manager.observation_door(manager).collect(request(root), control(5000))
    as "bound retained bytes independently of rows"
  finish(manager, root)
}

pub fn busy_warm_servers_are_not_treated_as_complete_empty_observations_test() {
  let root = scratch()
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        _ -> fake_lsp.Answer(json.Array([]))
      }
    })
  let assert Ok(_) = manager.door(manager).outline("a.gleam")
    as "warm the server"
  fake_lsp.notify(
    fake,
    "$/progress",
    json.Object([
      #("token", json.String("load")),
      #(
        "value",
        json.Object([
          #("kind", json.String("begin")),
          #("title", json.String("loading")),
        ]),
      ),
    ]),
  )
  let assert Error(observation.QueryFailed(query.Unavailable(_))) =
    manager.observation_door(manager).collect(request(root), control(5000))
    as "a warm active server is still busy"
  assert list.length(
      list.filter(fake_lsp.methods(fake), fn(method) {
        method == "textDocument/documentSymbol"
      }),
    )
    == 1
  finish(manager, root)
}

pub fn reported_server_failures_refuse_collection_before_semantic_queries_test() {
  let root = scratch()
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        _ -> fake_lsp.Answer(json.Array([]))
      }
    })
  let assert Ok(_) = manager.door(manager).outline("a.gleam")
    as "warm the server"
  fake_lsp.notify(
    fake,
    "window/showMessage",
    json.Object([
      #("type", json.Int(1)),
      #("message", json.String("project load failed")),
    ]),
  )
  let assert Error(observation.QueryFailed(query.Unavailable(reason))) =
    manager.observation_door(manager).collect(request(root), control(5000))
    as "retain the analysis failure"
  assert string.contains(reason, "project load failed")
  assert list.length(
      list.filter(fake_lsp.methods(fake), fn(method) {
        method == "textDocument/documentSymbol"
      }),
    )
    == 1
  finish(manager, root)
}

pub fn unsupported_requested_features_refuse_the_entire_observation_test() {
  let root = scratch()
  let fake =
    fake_lsp.start(
      json.Object([
        #("documentSymbolProvider", json.Bool(True)),
        #("textDocumentSync", json.Int(1)),
      ]),
      fn(method, _params) {
        case method {
          "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
          _ -> fake_lsp.Answer(json.Array([]))
        }
      },
    )
  let assert Ok(manager) =
    manager.start(manager.Config(
      workspace: root,
      servers: [server()],
      timing: manager.Timing(..manager.default_timing(), quiet_ms: 0),
      backend: manager.Backend(
        metadata_roots: [root],
        connect: fn(_) { Ok(fake_lsp.seam(fake)) },
        search: fn(_) { panic as "no search is admitted" },
        protected: [],
      ),
    ))
    as "start the manager"
  let assert Error(observation.QueryFailed(query.Unsupported(
    "fake",
    "textDocument/references",
  ))) = manager.observation_door(manager).collect(request(root), control(5000))
    as "one unsupported feature refuses the complete request"
  assert !list.contains(fake_lsp.methods(fake), "textDocument/references")
  finish(manager, root)
}

pub fn startup_redirect_is_refused_before_source_size_preflight_test() {
  let root = scratch()
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/protected")
    as "make the protected fixture"
  let assert Ok(Nil) =
    simplifile.write(
      root <> "/protected/private.gleam",
      string.repeat("x", observation.max_fact_bytes + 1),
    )
    as "an unauthorized read would exceed the size preflight budget"
  let fake =
    fake_lsp.start(fake_lsp.everything(), fn(_, _) {
      fake_lsp.Answer(json.Array([]))
    })
  let assert Ok(manager) =
    manager.start(manager.Config(
      workspace: root,
      servers: [server()],
      timing: manager.Timing(
        ..manager.default_timing(),
        quiet_ms: 0,
        ready_ms: 100,
      ),
      backend: manager.Backend(
        metadata_roots: [root],
        connect: fn(_identity) {
          let assert Ok(Nil) = simplifile.delete(root <> "/a.gleam")
            as "replace the source during startup"
          let assert Ok(Nil) =
            simplifile.create_symlink(
              to: root <> "/protected/private.gleam",
              from: root <> "/a.gleam",
            )
            as "redirect the earlier admitted source into protected storage"
          Ok(fake_lsp.seam(fake))
        },
        search: fn(_) { panic as "an observation must not search" },
        protected: [root <> "/protected"],
      ),
    ))
    as "start the manager before the lease is acquired"
  let scope = observation.Request("fake", root, ["a.gleam"], [])
  let assert Error(observation.Changed(_)) =
    manager.observation_door(manager).collect(scope, control(5000))
    as "admission refuses before protected text reaches the size preflight"
  assert !list.contains(fake_lsp.methods(fake), "textDocument/didOpen")
  finish(manager, root)
}

pub fn previously_open_documents_are_readmitted_before_the_observation_pull_test() {
  let root = scratch()
  let #(manager, fake) =
    rig(root, fn(method, _params) {
      case method {
        "textDocument/documentSymbol" -> fake_lsp.Answer(outline())
        _ -> fake_lsp.Answer(json.Array([]))
      }
    })
  let assert Ok(_) = manager.door(manager).outline("a.gleam")
    as "open an admitted source"
  let assert Ok(Nil) =
    simplifile.write(root <> "/b.gleam", "pub fn greet() { 1 }\n")
    as "write the observation source"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/protected")
    as "make a protected fixture"
  let assert Ok(Nil) =
    simplifile.write(root <> "/protected/private.gleam", "PRIVATE_SENTINEL")
    as "write protected text"
  let assert Ok(Nil) = simplifile.delete(root <> "/a.gleam")
    as "replace the previously admitted source"
  let assert Ok(Nil) =
    simplifile.create_symlink(
      to: root <> "/protected/private.gleam",
      from: root <> "/a.gleam",
    )
    as "redirect the old spelling into protected storage"
  let requested = observation.Request("fake", root, ["b.gleam"], [])
  let assert Ok(_) =
    manager.observation_door(manager).collect(requested, control(5000))
    as "collect only the still-admitted source"
  assert list.contains(fake_lsp.methods(fake), "textDocument/didClose")
  assert !list.any(fake_lsp.seen(fake), fn(seen) {
    case seen {
      fake_lsp.Sent(_, Some(params)) ->
        string.contains(json.to_string(params), "PRIVATE_SENTINEL")
      fake_lsp.Sent(_, None) | fake_lsp.Closed -> False
    }
  })
  finish(manager, root)
}
