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
import gleam/erlang/process
import gleam/list
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

// A parent whose `.git/config` names programs that Git would run, with an
// attribute that makes the clean filter apply to a file in the tree. What is
// guaranteed is that they cannot write outside the jail, on either machine: the
// jail is the guarantee for a filter, and the `-c` overrides are for hooks and
// the file-system monitor. The control is what makes the test mean something: the
// same configuration under ordinary Git, outside any jail, does create its canary.
pub fn a_hostile_git_config_cannot_write_outside_the_jail_test() {
  let rig = state_rig.rig("seed-hostile")
  let jailed = rig.scratch <> "/canary-jailed"
  let native = rig.scratch <> "/canary-native"
  let config = rig.root <> "/.git/config"
  let assert Ok(existing) = simplifile.read(config)
  let hostile = fn(canary) {
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
    Nil
  }
  worktree_rig.write(rig.root <> "/.gitattributes", "hostile.txt filter=x\n")
  worktree_rig.write(rig.root <> "/hostile.txt", "present\n")

  // The configuration names the jailed canary and the sandboxed capture runs.
  hostile(jailed)
  let store = sender_store(rig)
  let assert Ok(service) =
    state_service.start(store, fn() { ffi_os.system_time_ms() / 1000 })
  let capturer =
    state_capture.new(rig.git, rig.state, [], state_service.endpoint(service))
  let captured =
    state_capture.capture(capturer, rig.root, state_rig.identity(), Full)
  assert !worktree_rig.exists(jailed)

  // A capture that was refused has nothing to send; one that succeeded is
  // applied on the receiver, and nothing is written outside the jail there
  // either.
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
      assert !worktree_rig.exists(jailed)
    }
  }

  // The control: the same configuration naming another canary, under ordinary
  // Git outside the jail, runs the filter and creates it.
  hostile(native)
  let _added = worktree_rig.git(rig.root, ["add", "hostile.txt"])
  assert worktree_rig.exists(native)
  state_rig.stop(rig)
}

// --- the sessions can write the workspace the copy lands in -------------------

// A sent state, ready to be received.
fn sent(rig: Rig, receiver: Node, state: State) -> Nil {
  assert state_transfer.send(sender_store(rig), state.hash, link_to(receiver))
    == state_transfer.Delivered
  Nil
}

// `seeds` is a link a session planted to a directory elsewhere: the daemon's
// rename would land the repository there, outside every jail, so the copy is
// refused and nothing reaches the link's target.
pub fn a_link_planted_at_seeds_is_refused_and_nothing_lands_behind_it_test() {
  let #(rig, _capturer, state) = parent("seed-link-dir")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let outside = rig.scratch <> "/outside"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(outside)
  let assert Ok(Nil) = simplifile.create_symlink(outside, directory <> "/seeds")
  sent(rig, receiver, state)

  let assert Error(remote_spawn.StateRefused(_)) =
    spawn_seed.receive(
      receiver.node,
      in_directory(directory, "workspace"),
      site(),
      request(Some(state)),
    )
  assert simplifile.read_directory(outside) == Ok([])

  // What the failed apply leaves in the stage is its verdict and nothing else.
  let name = spawn_seed.name_of(site(), state)
  assert simplifile.read_directory(rig.scratch <> "/receiver/seed-staging")
    == Ok([name <> ".refused"])
  state_rig.stop(rig)
}

// The copy's own name is a link: a resend must not take it for a finished copy,
// and the rename must not follow it.
pub fn a_link_planted_at_the_copys_name_is_refused_test() {
  let #(rig, _capturer, state) = parent("seed-link-name")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let outside = rig.scratch <> "/outside"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(outside)
  let assert Ok(Nil) = simplifile.create_directory(directory <> "/seeds")
  let name = spawn_seed.name_of(site(), state)
  let assert Ok(Nil) =
    simplifile.create_symlink(outside, directory <> "/seeds/" <> name)
  sent(rig, receiver, state)

  let assert Error(remote_spawn.StateRefused(_)) =
    spawn_seed.receive(
      receiver.node,
      in_directory(directory, "workspace"),
      site(),
      request(Some(state)),
    )
  assert simplifile.read_directory(outside) == Ok([])
  state_rig.stop(rig)
}

// --- an apply slower than the asker ------------------------------------------

// The attempt releases its stage and its claim after it has made the copy whole,
// so the directory is polled until it is empty, with a bound.
fn staging_drains(rig: Rig) -> Bool {
  drained(rig.scratch <> "/receiver/seed-staging", 200)
}

fn drained(path: String, tries: Int) -> Bool {
  case simplifile.read_directory(path), tries {
    Ok([]), _ -> True
    _, 0 -> False
    _, _ -> {
      process.sleep(50)
      drained(path, tries - 1)
    }
  }
}

// Asks until the copy is there, with a window too short for any apply.
fn asked_until_made(
  receiver: Node,
  spawner: Spawner,
  state: State,
  tries: Int,
) -> Result(remote_spawn.Request, remote_spawn.SpawnRefusal) {
  case
    spawn_seed.receive_within(
      receiver.node,
      spawner,
      site(),
      request(Some(state)),
      1,
    )
  {
    Error(remote_spawn.NotYetOpen(_)) if tries > 0 -> {
      process.sleep(100)
      asked_until_made(receiver, spawner, state, tries - 1)
    }
    other -> other
  }
}

// The asker's window ends long before the apply does. The first ask is told to
// ask again, the apply goes on without it, and a later ask finds the copy whole.
pub fn an_apply_slower_than_the_asker_finishes_and_a_resend_finds_it_test() {
  let #(rig, _capturer, state) = parent("seed-slow")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let spawner = in_directory(directory, "workspace")
  sent(rig, receiver, state)

  let assert Error(remote_spawn.NotYetOpen(_)) =
    spawn_seed.receive_within(
      receiver.node,
      spawner,
      site(),
      request(Some(state)),
      1,
    )
  let assert Ok(seeded) = asked_until_made(receiver, spawner, state, 300)
  let name = spawn_seed.name_of(site(), state)
  assert string.contains(seeded.brief, "seeds/" <> name)
  assert simplifile.read(directory <> "/seeds/" <> name <> "/README")
    == Ok("edited by the parent\n")

  // No stage and no claim outlives the apply.
  assert staging_drains(rig)
  state_rig.stop(rig)
}

// Two asks for the same copy while one apply runs: both end with the one whole
// copy, and neither removed the other's tree.
pub fn two_concurrent_attempts_end_with_one_whole_copy_test() {
  let #(rig, _capturer, state) = parent("seed-concurrent")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let spawner = in_directory(directory, "workspace")
  sent(rig, receiver, state)

  let done = process.new_subject()
  list.each([1, 2], fn(_attempt) {
    process.spawn(fn() {
      process.send(done, asked_until_made(receiver, spawner, state, 300))
    })
  })
  let assert Ok(first) = process.receive(done, 60_000)
  let assert Ok(second) = process.receive(done, 60_000)
  assert first == second
  let name = spawn_seed.name_of(site(), state)
  assert simplifile.read_directory(directory <> "/seeds") == Ok([name])
  assert simplifile.read(directory <> "/seeds/" <> name <> "/notes.txt")
    == Ok("not committed anywhere\n")
  assert staging_drains(rig)
  state_rig.stop(rig)
}

// A claim is exclusive, and one whose owner died is taken over once it is old.
pub fn a_claim_is_exclusive_until_it_is_stale_test() {
  let rig = state_rig.rig("seed-claim")
  let parent = rig.scratch <> "/claims"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(parent)
  let now = ffi_os.system_time_ms() / 1000
  assert spawn_seed.claim(parent, "seed-a", now) == Ok(spawn_seed.Claimed)
  assert spawn_seed.claim(parent, "seed-a", now) == Ok(spawn_seed.Busy)
  assert spawn_seed.claim(parent, "seed-b", now) == Ok(spawn_seed.Claimed)
  assert spawn_seed.claim(parent, "seed-a", now + spawn_seed.claim_stale_s + 10)
    == Ok(spawn_seed.Claimed)
  state_rig.stop(rig)
}

// An apply that fails after the asker's window has gone is answered by the
// verdict it kept: the resend is refused at once with the same reason, and no
// second apply starts (an ask that found the claim free would be told to ask again,
// not refused). The failure is a link planted at `seeds`, which the apply meets
// only when it comes to move the finished repository, after all its Git work.
pub fn an_apply_that_fails_after_its_asker_left_is_answered_by_its_verdict_test() {
  let #(rig, _capturer, state) = parent("seed-verdict")
  let receiver = node_at(rig, "receiver")
  let directory = rig.scratch <> "/scratch-dir"
  let outside = rig.scratch <> "/outside"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(directory)
  let assert Ok(Nil) = bootstrap.ensure_private_directory(outside)
  let assert Ok(Nil) = simplifile.create_symlink(outside, directory <> "/seeds")
  let spawner = in_directory(directory, "workspace")
  sent(rig, receiver, state)

  // The first ask is told to ask again, because the apply is still going.
  let assert Error(remote_spawn.NotYetOpen(_)) =
    spawn_seed.receive_within(
      receiver.node,
      spawner,
      site(),
      request(Some(state)),
      1,
    )

  // The refusal arrives once the apply has failed, and is the same every time.
  let assert Error(remote_spawn.StateRefused(reason)) =
    asked_until_made(receiver, spawner, state, 300)
  list.each([1, 2, 3], fn(_resend) {
    assert spawn_seed.receive_within(
        receiver.node,
        spawner,
        site(),
        request(Some(state)),
        1,
      )
      == Error(remote_spawn.StateRefused(reason))
  })
  assert simplifile.read_directory(outside) == Ok([])
  state_rig.stop(rig)
}
