//// Original Compile allocations outlive finite preparation and observation workers.
//// The permanent Compile actor parks this linked resource-free owner before work.
//// Exclusive mkdir installs directory custody before fallible layout or Ready SQL.
//// Successful artifacts remain owned until exact original scope-native retirement.
//// Parent shutdown is best effort and never reconstructs physical release proof.
////
//// ## Flow
////
//// `park` pins original endpoints; `prepare` consumes the one preparation message.
//// `handle` installs acquisition before `write_layout` and `publish_ready`.
//// `release` consumes the actual proof ACK and original Normal within one deadline.
//// `begin_release` and `checkpoint` install physical and selected observation state.
//// `clean` records deletion before release COMMIT and exact original SQL readback.
//// `release_digest` binds those original facts; `validate_release` checks the owner.
//// `live` and `check_live` fence captured endpoint loss before further work.
//// `remaining` and `refuse` retain uncertainty without reissuing preparation.

import broker/enrollment
import broker/internal/call
import codemode/build
import codemode/compile
import codemode/service_input as input
import codemode/service_resources as resources
import core/command
import core/generation
import core/json
import core/msgpack as mp
import executor/remote/resource_journal as journal
import executor/remote/service as native
import gleam/crypto
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import weft/actor

/// Fixed internal test boundaries; production construction supplies no probe.
@internal
pub type Boundary {
  /// The aggregate and original monitor are retained before work is released.
  RunPermit

  /// The actual permanent owner is retained before the Begin response.
  BeginPermit

  /// Exclusive mkdir succeeded and directory ownership is installed.
  DirectoryAcquired

  /// Actual Ready COMMIT completed before its response.
  ReadyReply

  /// Explicit cleanup proof was sent, while actual owner exit remains held.
  OwnerExit
}

/// The two existing concrete aggregate inventories have distinct observations.
@internal
pub type RunKind {
  /// Actual fresh Compile continuation.
  ActiveRun

  /// Actual finite metadata/control continuation.
  ControlRun
}

/// Closed observations retain only actual original identities and one-use permits.
@internal
pub type Checkpoint {
  /// Installed original aggregate and monitor, before typed work permission.
  BeforeRunPermit(kind: RunKind, pid: process.Pid, permit: process.Subject(Nil))

  /// Installed original permanent preparation owner, before Begin permission.
  BeforeBeginPermit(pid: process.Pid, permit: process.Subject(Nil))

  /// Installed exclusive directory, before any layout/seed write.
  AcquiredDirectory(pid: process.Pid, permit: process.Subject(Nil))

  /// Actual Ready transaction, before its possibly lost response.
  BeforeReadyReply(pid: process.Pid, permit: process.Subject(Nil))

  /// Cleanup ACK precedes this held original owner exit.
  BeforeOwnerExit(pid: process.Pid, permit: process.Subject(Nil))
}

/// A finite closed test selection; it contains no replacement effect functions.
@internal
pub opaque type Probe {
  /// Closed fixed observations without effect substitution.
  Probe(
    /// Observer door receives actual retained-state checkpoints.
    observations: process.Subject(Checkpoint),
    /// Only these finite named boundaries are held.
    boundaries: List(Boundary),
  )
}

/// Original local ownership; copying the handle grants no second acquisition.
@internal
pub opaque type Owner {
  /// Private construction retains actual original identity.
  Owner(
    /// Original private preparation door.
    subject: process.Subject(Message),
    /// Original physical owner actor, observed before release.
    pid: process.Pid,
    /// Actual permanent constructor caller, never a finite worker.
    parent: process.Pid,
    /// Same original durable resource endpoint.
    book: journal.Journal,
    /// Complete immutable original input and identity.
    original: journal.Input,
    /// Retained original native Service; never compared as a function-bearing record.
    native: native.Service,
    /// Exact enrollment-derived canonical allocation.
    root: String,
  )
}

/// Actual original removal, SQL release/readback and owner identity, before exit.
@internal
pub opaque type ReleaseProof {
  /// Private construction retains actual original identity.
  ReleaseProof(
    /// Exact original private preparation door.
    subject: process.Subject(Message),
    /// Actual original actor that produced this cleanup ACK.
    pid: process.Pid,
    /// Actual retained permanent constructor caller.
    parent: process.Pid,
    /// Same original durable resource endpoint used for COMMIT/readback.
    book: journal.Journal,
    /// Complete original identity and input bytes.
    original: journal.Input,
    /// Only the actually owned original path.
    root: String,
    /// Canonical actual physical, native and SQL release account.
    digest: generation.Digest,
  )
}

/// Closed failure never creates replacement ownership or native authority.
pub type Error {
  /// Exact original inputs/endpoints or proof differ.
  Invalid

  /// The unchanged original deadline elapsed.
  Expired

  /// Actual custody, cleanup or a reply may be unavailable.
  Uncertain

  /// Known pre-native layout refusal.
  Preparation(error: compile.CompileError)

  /// Exact durable original operation refused.
  Custody(error: journal.Error)
}

type EndpointCustody {
  LiveEndpoints
  LostEndpoints
}

type Allocation {
  NoDirectory
  OriginalDirectory
  RemovedDirectory
}

type Phase {
  Parked
  Acquiring
  Writing
  Publishing
  Retained
  Refused
}

type Work {
  Work(
    admitted: input.AdmittedCompile,
    claim: journal.Claim,
    deadline: Int,
    reply: process.Subject(Result(Nil, Error)),
  )
}

type State {
  State(
    owner: Owner,
    phase: Phase,
    allocation: Allocation,
    ready: Option(resources.Ready),
    work: Option(Work),
    probe: Option(Probe),
    paused: Option(#(Message, process.Subject(Nil))),
    selector: process.Selector(Message),
    endpoints: EndpointCustody,
    release: Option(
      #(
        native.ScopeCloseProof,
        Int,
        process.Subject(Result(ReleaseProof, Error)),
      ),
    ),
  )
}

type Message {
  Prepare(Work)
  EndpointDown
  Acquire
  ObserveAcquired
  FinishLayout
  PublishReady
  FinishRelease
  Resume
  ReplyReady(Result(Nil, Error))
  ExitOwner
  Release(
    native.ScopeCloseProof,
    Int,
    process.Subject(Result(ReleaseProof, Error)),
  )
}

/// Selects only named internal boundaries for deterministic custody controls.
///
/// ## Examples
///
/// `probe(observed, [DirectoryAcquired])` leaves other boundaries unheld.
@internal
pub fn probe(
  observed: process.Subject(Checkpoint),
  boundaries: List(Boundary),
) -> Probe {
  Probe(observed, list.unique(boundaries))
}

/// Tests whether this closed boundary is selected; production None never holds.
///
/// ## Examples
///
/// `observes(None, RunPermit) == False`.
@internal
pub fn observes(probe: Option(Probe), boundary: Boundary) -> Bool {
  case probe {
    None -> False
    Some(probe) -> list.contains(probe.boundaries, boundary)
  }
}

/// Emits an actual installed-state observation to the selected internal observer.
///
/// ## Examples
///
/// `notify(probe, BeforeOwnerExit(pid, permit))` transfers no execution authority.
@internal
pub fn notify(probe: Option(Probe), checkpoint: Checkpoint) -> Nil {
  case probe {
    None -> Nil
    Some(probe) -> process.send(probe.observations, checkpoint)
  }
}

/// Starts under the actual caller without allocating paths or opening SQL.
///
/// ## Examples
///
/// `park(book, native, original)` precedes the original typed Begin permit.
@internal
pub fn park(
  book: journal.Journal,
  native: native.Service,
  original: journal.Input,
) -> Result(Owner, Error) {
  park_observed(book, native, original, None)
}

/// Parks the same original resource-free owner with fixed internal observations.
///
/// ## Examples
///
/// `park_observed(book, native, original, Some(probe))` changes no effect source.
@internal
pub fn park_observed(
  book: journal.Journal,
  native: native.Service,
  original: journal.Input,
  probe: Option(Probe),
) -> Result(Owner, Error) {
  use root <- result.try(
    enrollment.compile_path(journal.enrolled(book), original.key)
    |> result.replace_error(Invalid),
  )
  use Nil <- result.try(
    case
      command.service_role(original.key) == command.CompileService
      && journal.native_endpoint(book) == native.configuration(native).journal
    {
      True -> Ok(Nil)
      False -> Error(Invalid)
    },
  )
  let parent = process.self()
  actor.new_with_initialiser(1000, fn(subject) {
    let owner =
      Owner(subject, process.self(), parent, book, original, native, root)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_specific_monitor(
        process.monitor(journal.pid(book)),
        fn(_) { EndpointDown },
      )
      |> process.select_specific_monitor(
        process.monitor(native.pid(native)),
        fn(_) { EndpointDown },
      )
    Ok(
      actor.initialised(State(
        owner,
        Parked,
        NoDirectory,
        None,
        None,
        probe,
        None,
        selector,
        LiveEndpoints,
        None,
      ))
      |> actor.selecting(selector)
      |> actor.returning(owner),
    )
  })
  |> actor.trapping_exits(True)
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.replace_error(Uncertain)
}

/// Projects only this original owner PID for preinstalled lifecycle observation.
///
/// ## Examples
///
/// `process.monitor(pid(owner))` precedes its release ask.
@internal
pub fn pid(owner: Owner) -> process.Pid {
  owner.pid
}

/// Asks the already retained owner to consume exactly one original preparation.
///
/// ## Examples
///
/// `prepare(owner, admitted, claim, deadline)` cannot retry an uncertain mkdir.
@internal
pub fn prepare(
  owner: Owner,
  admitted: input.AdmittedCompile,
  claim: journal.Claim,
  deadline: Int,
) -> Result(Nil, Error) {
  use wait <- result.try(remaining(owner.native, deadline))
  call.try_call(owner.subject, waiting: wait, sending: fn(reply) {
    Prepare(Work(admitted, claim, deadline, reply))
  })
  |> result.unwrap(Error(Uncertain))
}

/// Requires actual original native safety, explicit cleanup ACK and Normal DOWN.
/// The same original deadline covers the ask and join; a lost proof is unavailable.
///
/// ## Examples
///
/// `release(owner, native_proof, deadline)` never deletes a preexisting path.
@internal
pub fn release(
  owner: Owner,
  proof: native.ScopeCloseProof,
  deadline: Int,
) -> Result(ReleaseProof, Error) {
  let watch = process.monitor(owner.pid)
  let outcome = {
    use wait <- result.try(remaining(owner.native, deadline))
    use answer <- result.try(
      call.try_call(owner.subject, waiting: wait, sending: Release(
        proof,
        deadline,
        _,
      ))
      |> result.unwrap(Error(Uncertain)),
    )
    use _ <- result.try(validate_release(owner, answer))
    use wait <- result.try(remaining(owner.native, deadline))
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) {
      case down {
        process.ProcessDown(reason: process.Normal, ..) -> Ok(answer)
        process.ProcessDown(..) | process.PortDown(..) -> Error(Uncertain)
      }
    })
    |> process.selector_receive(wait)
    |> result.unwrap(Error(Uncertain))
  }
  process.demonitor_process(watch)
  outcome
}

/// Checks the exact immutable original owner after its successful exit.
///
/// ## Examples
///
/// `validate_release(original, proof)` rejects a replacement actor.
@internal
pub fn validate_release(
  owner: Owner,
  proof: ReleaseProof,
) -> Result(generation.Digest, Error) {
  case
    owner.subject == proof.subject
    && owner.pid == proof.pid
    && owner.parent == proof.parent
    && owner.book == proof.book
    && owner.original == proof.original
    && owner.root == proof.root
  {
    True -> Ok(proof.digest)
    False -> Error(Invalid)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    EndpointDown -> {
      case state.work {
        Some(work) -> process.send(work.reply, Error(Uncertain))
        None -> Nil
      }
      actor.continue(
        State(..state, endpoints: LostEndpoints, phase: Refused, work: None),
      )
    }
    Prepare(work) -> {
      let #(key, decoded, _) = input.admitted_compile(work.admitted)
      let allowed = {
        use Nil <- result.try(check_live(state))
        case
          state.phase == Parked
          && input.encode_compile(decoded) == state.owner.original.body
          && key == state.owner.original.key
          && journal.original(work.claim) == state.owner.original
          && journal.claim_journal(work.claim) == state.owner.book
        {
          True -> Ok(Nil)
          False -> Error(Invalid)
        }
      }
      case allowed {
        Ok(Nil) ->
          actor.continue(State(..state, phase: Acquiring, work: Some(work)))
          |> actor.then_handle(Acquire)
        Error(error) -> {
          process.send(work.reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Acquire -> {
      case state.phase, state.work {
        Acquiring, Some(work) -> {
          let acquired = {
            use Nil <- result.try(check_live(state))
            use _ <- result.try(remaining(state.owner.native, work.deadline))
            simplifile.create_directory(state.owner.root)
            |> result.replace_error(
              Preparation(compile.WorkspaceSetupFailed(
                "allocation already exists or cannot be created",
              )),
            )
          }
          case acquired {
            Ok(Nil) ->
              actor.continue(
                State(..state, allocation: OriginalDirectory, phase: Writing),
              )
              |> actor.then_handle(ObserveAcquired)
            Error(error) -> refuse(state, work.reply, error)
          }
        }
        _, _ -> actor.continue(state)
      }
    }
    ObserveAcquired -> checkpoint(state, DirectoryAcquired, FinishLayout)
    Resume -> {
      case state.paused {
        Some(#(next, permit)) -> {
          let selector = process.deselect(state.selector, permit)
          actor.continue(State(..state, paused: None, selector: selector))
          |> actor.with_selector(selector)
          |> actor.then_handle(next)
        }
        None -> actor.continue(state)
      }
    }
    ReplyReady(published) -> {
      case state.work {
        Some(work) -> process.send(work.reply, published)
        None -> Nil
      }
      actor.continue(State(..state, phase: Retained, work: None))
    }
    ExitOwner -> actor.stop()
    FinishLayout -> {
      case state.phase, state.work {
        Writing, Some(work) -> {
          let prepared = {
            use Nil <- result.try(check_live(state))
            write_layout(
              state.owner.book,
              state.owner.native,
              work.admitted,
              state.owner.root,
              work.deadline,
            )
          }
          case prepared {
            Ok(ready) ->
              actor.continue(
                State(..state, phase: Publishing, ready: Some(ready)),
              )
              |> actor.then_handle(PublishReady)
            Error(error) -> refuse(state, work.reply, error)
          }
        }
        _, _ -> actor.continue(state)
      }
    }
    PublishReady -> {
      case state.phase, state.work, state.ready {
        Publishing, Some(work), Some(ready) -> {
          let published = {
            use Nil <- result.try(check_live(state))
            publish_ready(state.owner.native, work.claim, ready, work.deadline)
          }
          checkpoint(state, ReadyReply, ReplyReady(published))
        }
        _, _, _ -> actor.continue(state)
      }
    }
    Release(proof, deadline, reply) ->
      begin_release(state, proof, deadline, reply)
    FinishRelease -> {
      case state.release {
        None -> actor.continue(state)
        Some(#(proof, deadline, reply)) -> {
          case clean(state, proof, deadline) {
            Ok(answer) -> {
              process.send(reply, Ok(answer))
              checkpoint(State(..state, release: None), OwnerExit, ExitOwner)
            }
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(State(..state, release: None))
            }
          }
        }
      }
    }
  }
}

/// Shared existing layout/seed sequence, retaining the original monotonic cap.
/// Neither this helper nor its Ready value grants a fresh preparation claim.
///
/// ## Examples
///
/// `write_layout(book, native, admitted, owned_root, deadline)` runs no compiler.
@internal
pub fn write_layout(
  book: journal.Journal,
  native: native.Service,
  admitted: input.AdmittedCompile,
  root: String,
  deadline: Int,
) -> Result(resources.Ready, Error) {
  let #(key, decoded, vetted) = input.admitted_compile(admitted)
  let facts = input.compile_facts(decoded)
  let enrolled = journal.enrolled(book)
  use _ <- result.try(remaining(native, deadline))
  use _ <- result.try(
    compile.prepare_workspace(vetted, root, facts.dependencies)
    |> result.map_error(Preparation),
  )
  use _ <- result.try(remaining(native, deadline))
  let code = enrollment.code_mode_facts(enrolled)
  use Nil <- result.try(
    build.prepare_seed(
      build.PreparationConfig(code.seed_root, facts.dependencies),
      root,
      facts.generated,
    )
    |> result.map_error(Preparation),
  )
  use _ <- result.try(remaining(native, deadline))
  resources.admit_compile_locations(enrolled, key, root)
  |> result.map(resources.CompileReady)
  |> result.replace_error(Invalid)
}

/// Uses the unchanged original DAL Ready transaction and remaining budget.
///
/// ## Examples
///
/// `publish_ready(native, claim, ready, deadline)` grants no native admission.
@internal
pub fn publish_ready(
  native: native.Service,
  claim: journal.Claim,
  ready: resources.Ready,
  deadline: Int,
) -> Result(Nil, Error) {
  use _ <- result.try(
    journal.commit_ready(claim, ready) |> result.map_error(Custody),
  )
  remaining(native, deadline) |> result.replace(Nil)
}

fn begin_release(
  state: State,
  proof: native.ScopeCloseProof,
  deadline: Int,
  reply: process.Subject(Result(ReleaseProof, Error)),
) -> actor.Next(State, Message) {
  let allowed = {
    use _ <- result.try(remaining(state.owner.native, deadline))
    use _ <- result.try(
      native.validate_scope_close(state.owner.native, proof)
      |> result.replace_error(Invalid),
    )
    use Nil <- result.try(case state.phase {
      Parked | Refused | Retained -> Ok(Nil)
      Acquiring | Writing | Publishing -> Error(Uncertain)
    })
    case state.allocation {
      NoDirectory | RemovedDirectory -> Ok(Nil)
      OriginalDirectory ->
        simplifile.delete(state.owner.root)
        |> result.replace_error(Uncertain)
    }
  }
  case allowed {
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
    Ok(Nil) ->
      actor.continue(
        State(
          ..state,
          allocation: RemovedDirectory,
          release: Some(#(proof, deadline, reply)),
        ),
      )
      |> actor.then_handle(FinishRelease)
  }
}

// Actual deletion is already installed by begin_release before this SQL turn.
// A released row alone cannot reconstruct either original physical ownership.
fn clean(
  state: State,
  proof: native.ScopeCloseProof,
  deadline: Int,
) -> Result(ReleaseProof, Error) {
  use _ <- result.try(remaining(state.owner.native, deadline))
  use Nil <- result.try(case state.allocation {
    RemovedDirectory -> Ok(Nil)
    NoDirectory | OriginalDirectory -> Error(Uncertain)
  })
  use status <- result.try(
    journal.mark_released(
      state.owner.book,
      state.owner.original,
      journal.ResourceOwnerCleaned,
    )
    |> result.map_error(Custody),
  )
  use saved <- result.try(
    journal.inspect(state.owner.book, state.owner.original)
    |> result.map_error(Custody),
  )
  use Nil <- result.try(
    case status == saved && saved == journal.Released(state.ready) {
      True -> Ok(Nil)
      False -> Error(Uncertain)
    },
  )
  use digest <- result.try(release_digest(state.owner, proof, saved))
  use _ <- result.try(remaining(state.owner.native, deadline))
  Ok(ReleaseProof(
    state.owner.subject,
    state.owner.pid,
    state.owner.parent,
    state.owner.book,
    state.owner.original,
    state.owner.root,
    digest,
  ))
}

// A selected test boundary parks in the actual actor's selector, rather than
// blocking its parent shutdown. Releasing the permit consumes this state once.
fn checkpoint(
  state: State,
  boundary: Boundary,
  next: Message,
) -> actor.Next(State, Message) {
  case observes(state.probe, boundary) {
    False -> actor.continue(state) |> actor.then_handle(next)
    True -> {
      let permit = process.new_subject()
      let selected = case boundary {
        DirectoryAcquired -> AcquiredDirectory(state.owner.pid, permit)
        ReadyReply -> BeforeReadyReply(state.owner.pid, permit)
        OwnerExit -> BeforeOwnerExit(state.owner.pid, permit)
        RunPermit -> BeforeRunPermit(ActiveRun, state.owner.pid, permit)
        BeginPermit -> BeforeBeginPermit(state.owner.pid, permit)
      }
      let selector =
        process.select_map(state.selector, permit, fn(_) { Resume })
      notify(state.probe, selected)
      actor.continue(
        State(..state, paused: Some(#(next, permit)), selector: selector),
      )
      |> actor.with_selector(selector)
    }
  }
}

fn release_digest(
  owner: Owner,
  proof: native.ScopeCloseProof,
  saved: journal.Status,
) -> Result(generation.Digest, Error) {
  use native_digest <- result.try(
    native.validate_scope_close(owner.native, proof)
    |> result.replace_error(Invalid),
  )
  let ready = case saved {
    journal.Released(Some(ready)) ->
      resources.encode(ready)
      |> result.replace_error(Uncertain)
    journal.Released(None) -> Ok(<<>>)
    _ -> Error(Uncertain)
  }
  use ready <- result.try(ready)
  use bytes <- result.try(
    mp.encode(
      mp.ArrayValue([
        mp.StringValue("loom.compile.original-release/1"),
        mp.StringValue(
          json.to_string(command.encode_service(owner.original.key)),
        ),
        mp.BinaryValue(journal.digest(owner.original.body)),
        mp.StringValue(owner.root),
        mp.StringValue(string.inspect(owner.pid)),
        mp.StringValue(string.inspect(owner.parent)),
        mp.StringValue(string.inspect(journal.pid(owner.book))),
        mp.BinaryValue(generation.digest_bytes(native_digest)),
        mp.BinaryValue(ready),
      ]),
    )
    |> result.replace_error(Uncertain),
  )
  crypto.hash(crypto.Sha256, bytes)
  |> generation.digest
  |> result.replace_error(Uncertain)
}

// Endpoint loss fences every not-yet-admitted acquisition/layout/Ready turn.
// Already executing synchronous effects may finish before queued loss is handled.
fn live(state: State) -> Bool {
  state.endpoints == LiveEndpoints
  && process.is_alive(state.owner.parent)
  && process.is_alive(journal.pid(state.owner.book))
  && process.is_alive(native.pid(state.owner.native))
}

fn check_live(state: State) -> Result(Nil, Error) {
  case live(state) {
    True -> Ok(Nil)
    False -> Error(Uncertain)
  }
}

fn remaining(native: native.Service, deadline: Int) -> Result(Int, Error) {
  let wait = deadline - native.configuration(native).now()
  case wait > 0 {
    True -> Ok(wait)
    False -> Error(Expired)
  }
}

fn refuse(
  state: State,
  reply: process.Subject(Result(Nil, Error)),
  error: Error,
) -> actor.Next(State, Message) {
  process.send(reply, Error(error))
  actor.continue(State(..state, phase: Refused, work: None))
}
