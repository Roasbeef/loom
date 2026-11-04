//// A spawn that carries the parent's workspace, from the sender's capture to the
//// child's copy on the receiver (protocol-change/107, slice 3).
////
//// Two nodes with a state root each stand in for the two machines. The parent's
//// machine has a real repository with committed history, an edited tracked file
//// and a new file; it captures the workspace into its store, sends the bundle in
//// pieces to the receiver's store, and the receiver's `spawn_seed.receive`
//// judges the request and applies it. The tests look at what the child would
//// find (a repository whose files equal the parent's snapshot), at what the
//// parent's checkout still is, and at every way the receiver says no: a spawner
//// whose `seed` is `none`, a placement that cannot take a copy, a state that is
//// missing or half there, a description the store contradicts, and a parent whose
//// `.git/config` names a program.

import broker/exec
import client/internal/ffi_os
import client/remote_spawn
import client/spawn_seed
import client/spawners.{type Spawner}
import client/state_capture
import client/state_node
import client/state_object.{type State, Full}
import client/state_service
import client/state_store
import client/state_transfer
import client/worktree_git
import core/clock
import core/ids
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import simplifile
import support/state_rig.{type Rig}
import support/worktree_rig
import tools/agent

// A machine: a state root laid out as a daemon leaves it, a store behind its
// service, and the sandboxed Git over the shipped helper.
type Node {
  Node(node: state_node.StateNode, store: state_store.Store, root: String)
}

fn node_at(rig: Rig, name: String) -> Node {
  let root = rig.scratch <> "/" <> name
  let assert Ok(Nil) = bootstrap.ensure_private_directory(root)
  worktree_rig.establish(root)
  let assert Ok(store) =
    state_store.open(state_store.directory(root), state_store.default_limits)
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let assert Ok(here) = simplifile.current_directory()
  let assert Ok(git) =
    worktree_git.start(worktree_git.Config(
      helper_path: here <> "/../sandbox/loom-exec",
      scratch: root <> "/state-git",
      state_root: root,
      credentials: [],
      demand: exec.BestEffort,
    ))
  Node(
    node: state_node.StateNode(
      endpoint: state_service.endpoint(service),
      store: Some(store),
      git: Some(git),
      state_root: root,
      credentials: [],
    ),
    store:,
    root:,
  )
}

// A link to a node's endpoint in this VM, which is what the real link is to a
// peer's.
fn link_to(node: Node) -> state_transfer.Link {
  let endpoint = node.node.endpoint
  state_transfer.Link(
    stage: fn(hash) {
      case endpoint.stage(hash) {
        Ok(stage) -> Ok(stage)
        Error(_) -> Error(Nil)
      }
    },
    piece: fn(piece) { Ok(endpoint.take(piece)) },
    fetch: fn(hash, offset) { Ok(endpoint.serve(hash, offset)) },
  )
}

fn spawner(directory: String, lines: String) -> Spawner {
  let text = "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[[distribution.peers]]
node = \"runner@100.64.0.7\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000003\"

[executors.runner]
node = \"runner@100.64.0.7\"

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
profile = \"cheap-review\"
" <> lines <> directory
  let assert Ok([found]) = spawners.parse(text) as "the table parses"
  found
}

fn in_directory(directory: String, seed: String) -> Spawner {
  spawner(
    "directory = \"" <> directory <> "\"\n",
    "seed = \"" <> seed <> "\"\n",
  )
}

fn site() -> remote_spawn.CallSite {
  let #(op, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 3))
  remote_spawn.CallSite(
    operation: op,
    step_id: "step-1",
    source_index: 0,
    minter: agent.ToolCall,
  )
}

fn request(state: option.Option(State)) -> remote_spawn.Request {
  remote_spawn.Request(
    purpose: "finish the cache",
    brief: "Finish the cache.",
    model: None,
    tools: None,
    within_ms: None,
    result_schema: None,
    detach: remote_spawn.Detached,
    state:,
  )
}

// The parent's workspace, edited the way a task in progress is.
fn parent(name: String) -> #(Rig, state_capture.Capturer, State) {
  let rig = state_rig.rig(name)
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let capturer =
    state_capture.new(rig.git, rig.state, [], state_service.endpoint(service))
  worktree_rig.write(rig.root <> "/README", "edited by the parent\n")
  worktree_rig.write(rig.root <> "/notes.txt", "not committed anywhere\n")
  let assert Ok(state) =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  #(rig, capturer, state)
}

fn sender_store(rig: Rig) -> state_store.Store {
  let assert Ok(store) =
    state_store.open(
      state_store.directory(rig.state),
      state_store.default_limits,
    )
  store
}

pub fn a_workspace_is_sent_applied_and_the_child_finds_it_whole_test() {
  let #(rig, _capturer, state) = parent("seed-whole")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let spawner = in_directory(directory, "workspace")
  let refs = state_rig.refs(rig.root)

  // Nothing is there yet, and the receiver says how much.
  let assert Error(remote_spawn.StateMissing(hash:, have: 0)) =
    spawn_seed.receive(receiver.node, spawner, site(), request(Some(state)))
  assert hash == state.hash

  // The sender sends what the receiver lacks, and asks again.
  assert state_transfer.send(sender_store(rig), state.hash, link_to(receiver))
    == state_transfer.Delivered
  let assert Ok(seeded) =
    spawn_seed.receive(receiver.node, spawner, site(), request(Some(state)))

  // The child's request no longer names a state, and its brief says where its
  // copy is.
  assert seeded.state == None
  let name = spawn_seed.name_of(site(), state)
  assert string.contains(seeded.brief, "seeds/" <> name)
  assert string.starts_with(seeded.brief, "Finish the cache.")

  // The copy is the parent's snapshot: the edit and the new file, on their own
  // branch, in a repository of its own inside the spawner's directory.
  let copy = directory <> "/seeds/" <> name
  assert simplifile.read(copy <> "/README") == Ok("edited by the parent\n")
  assert simplifile.read(copy <> "/notes.txt") == Ok("not committed anywhere\n")
  assert worktree_rig.git(copy, ["rev-parse", "--abbrev-ref", "HEAD"])
    == "loom/" <> name

  // The parent's checkout is untouched.
  assert state_rig.refs(rig.root) == refs
  assert simplifile.read(rig.root <> "/README") == Ok("edited by the parent\n")

  // A resend finds the copy it made and makes none.
  let assert Ok(again) =
    spawn_seed.receive(receiver.node, spawner, site(), request(Some(state)))
  assert again.brief == seeded.brief
  state_rig.stop(rig)
}

pub fn a_spawner_whose_seed_is_none_refuses_and_leaves_no_trace_test() {
  let #(rig, _capturer, state) = parent("seed-none")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  assert state_transfer.send(sender_store(rig), state.hash, link_to(receiver))
    == state_transfer.Delivered

  let assert Error(remote_spawn.StateRefused(reason)) =
    spawn_seed.receive(
      receiver.node,
      in_directory(directory, "none"),
      site(),
      request(Some(state)),
    )
  assert string.contains(reason, "seed")
  assert string.contains(reason, "[spawners.laptop]")
  assert simplifile.is_directory(directory <> "/seeds") != Ok(True)
  state_rig.stop(rig)
}

pub fn a_placement_on_an_executor_cannot_take_a_copy_test() {
  let #(rig, _capturer, state) = parent("seed-executor")
  let receiver = node_at(rig, "receiver")
  let on_executor =
    spawner(
      "executor = \"runner\"\nworkspace = \"loom\"\n",
      "seed = \"workspace\"\n",
    )
  let assert Error(remote_spawn.StateRefused(reason)) =
    spawn_seed.receive(receiver.node, on_executor, site(), request(Some(state)))
  assert string.contains(reason, "executor")
  state_rig.stop(rig)
}

pub fn a_request_with_no_state_passes_through_untouched_test() {
  let rig = state_rig.rig("seed-plain")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let plain = request(None)
  assert spawn_seed.receive(
      receiver.node,
      in_directory(directory, "none"),
      site(),
      plain,
    )
    == Ok(plain)
  state_rig.stop(rig)
}

// A sender that was cut off mid-state asks again, and the receiver says how many
// bytes of it are there so the sender continues at that offset. The state here is
// a description of a bundle larger than one piece with its first piece delivered:
// nothing judges the bytes until the last one arrives.
pub fn a_state_half_sent_resumes_where_the_receiver_stands_test() {
  let rig = state_rig.rig("seed-resume")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let state =
    state_object.State(
      hash: string.repeat("cd", 32),
      size: state_transfer.chunk_bytes * 3,
      tip: string.repeat("1", 40),
      base: None,
      dirty: state_object.Clean,
    )
  let first = <<0:size(2_097_152)>>
  assert receiver.node.endpoint.take(state_transfer.Piece(
      state:,
      offset: 0,
      bytes: first,
    ))
    == state_transfer.Accepted(held: state_transfer.chunk_bytes)

  let assert Error(remote_spawn.StateMissing(hash:, have:)) =
    spawn_seed.receive(
      receiver.node,
      in_directory(directory, "workspace"),
      site(),
      request(Some(state)),
    )
  assert hash == state.hash
  assert have == state_transfer.chunk_bytes
  state_rig.stop(rig)
}

pub fn a_description_the_store_contradicts_is_refused_test() {
  let #(rig, _capturer, state) = parent("seed-lying")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let _sent =
    state_transfer.send(sender_store(rig), state.hash, link_to(receiver))
  let lying = state_object.State(..state, tip: string.repeat("a", 40))
  let assert Error(remote_spawn.StateRefused(reason)) =
    spawn_seed.receive(
      receiver.node,
      in_directory(directory, "workspace"),
      site(),
      request(Some(lying)),
    )
  assert string.contains(reason, "description")
  state_rig.stop(rig)
}

pub fn a_state_over_the_size_limit_is_refused_test() {
  let rig = state_rig.rig("seed-big")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let big =
    state_object.State(
      hash: string.repeat("ab", 32),
      size: state_object.size_limit + 1,
      tip: string.repeat("1", 40),
      base: None,
      dirty: state_object.Clean,
    )
  let assert Error(remote_spawn.StateRefused(reason)) =
    spawn_seed.permitted(in_directory(directory, "workspace"), big)
  assert string.contains(reason, "size limit")
  state_rig.stop(rig)
}

// A parent whose `.git/config` names a program that Git would run: whatever the
// capture does with it, the program never ran, on the sender or the receiver.
pub fn a_hostile_git_config_runs_nothing_on_either_machine_test() {
  let rig = state_rig.rig("seed-hostile")
  let canary = rig.scratch <> "/canary"
  let config = rig.root <> "/.git/config"
  let assert Ok(existing) = simplifile.read(config)
  let assert Ok(Nil) =
    simplifile.write(
      config,
      existing
        <> "[core]\n\tfsmonitor = touch "
        <> canary
        <> "\n[filter \"x\"]\n\tclean = touch "
        <> canary
        <> "\n",
    )
  worktree_rig.write(rig.root <> "/hostile.txt", "present\n")
  let store = sender_store(rig)
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let capturer =
    state_capture.new(rig.git, rig.state, [], state_service.endpoint(service))
  let captured =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  assert !worktree_rig.exists(canary)

  // A capture that was refused has nothing to send; one that succeeded is
  // applied on the receiver, and nothing runs there either.
  case captured {
    Error(_) -> Nil
    Ok(state) -> {
      let receiver = node_at(rig, "receiver")
      let directory = rig.scratch <> "/scratch-dir"
      let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
      let _sent = state_transfer.send(store, state.hash, link_to(receiver))
      let _received =
        spawn_seed.receive(
          receiver.node,
          in_directory(directory, "workspace"),
          site(),
          request(Some(state)),
        )
      assert !worktree_rig.exists(canary)
    }
  }
  state_rig.stop(rig)
}
