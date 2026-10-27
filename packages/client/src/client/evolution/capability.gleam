//// The route from a code-mode program to the session's evolution doors.
////
//// A program reaches evolution through `cap/evolution` and nothing else.
//// The host's code-mode configuration is produced together with the
//// `code_mode` tool, inside the workspace plane, and the evolution plane is
//// opened after that, because it needs the finished configuration for its
//// build identity and as the host its candidates run under. Construction
//// order is why the configuration cannot capture the doors. It holds a
//// builder over a *name*, and this module is both ends of that name: the cell
//// that is registered under it once the plane is open, and the builder that
//// borrows the doors from it on every call.
////
//// ## Flow
////
//// `start` → `borrow` → `door_over` → `outcome`
////
//// 1. `start` registers a cell under the name the configuration was given,
////    holding the finished `Door`. Until it runs, every operation answers
////    that the plane is not open, which is the honest answer for a program
////    that races session boot.
//// 2. `door_over` is what the configuration holds. Per execution it receives
////    the dispatching `tool.Ctx` and returns six closures bound to it.
//// 3. Each closure `borrow`s the door from the cell, so a restarted or closed
////    plane is noticed on the next call rather than captured stale, and runs
////    the door on the calling process under the program's own coordinates.
//// 4. `outcome` words the door's `ToolOutcome` as the plain JSON or refusal
////    sentence the router forwards.
////
//// ## Why a cell and not a captured door
////
//// A captured door would need the plane opened first, and the plane is opened
//// from the configuration the door would be captured into. Restructuring the
//// workspace plane to hand the configuration out before the tool exists would
//// remove that ordering. A named cell removes it without a mutable field in
//// the configuration, in the same way the Agency, the scratch store and the
//// jobs actor are reached by name.
//// The cell holds one immutable value for the life of the plane and answers
//// only a borrow, so it has no state to get wrong.

import broker/broker
import broker/exec
import broker/internal/call
import broker/policy
import client/owner_services.{type OwnerCapCall}
import codemode/evolution as codemode_evolution
import core/clock.{type Clock}
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tools/directory_access
import tools/evolution as evolution_tool
import tools/tool
import weft/actor
import weft/registry as address

/// What the cell is asked.
pub opaque type Message {
  Borrow(Subject(evolution_tool.Door))
  Stop
}

/// A started cell, kept by the plane's custody so it is retired with it.
pub type Cell {
  Cell(pid: Pid)
}

/// How long a borrow waits. The cell does no work, so a cell that has not
/// answered in a second is gone or wedged and the call is better refused.
const borrow_ms = 1000

/// Registers the doors under `name`.
///
/// The cell is linked to the caller, which is the session's assembly process
/// until `detach` hands the link to custody.
///
/// ## Examples
///
/// ```gleam
/// // capability.start(name, door)
/// ```
///
pub fn start(
  name: address.Address(Message),
  door: evolution_tool.Door,
) -> Result(Cell, String) {
  actor.new(door)
  |> actor.on_message(handle)
  |> actor.addressed(name)
  |> actor.start
  |> result.map(fn(started) { Cell(started.pid) })
  |> result.map_error(string.inspect)
}

/// Handles cell messages, either replying with the stored evolution door handle
/// or shutting down the actor loop upon custody release.
fn handle(
  door: evolution_tool.Door,
  message: Message,
) -> actor.Next(evolution_tool.Door, Message) {
  // Dispatch incoming requests between lending the door reference and stopping.
  case message {
    Borrow(reply) -> {
      process.send(reply, door)
      actor.continue(door)
    }
    Stop -> actor.stop()
  }
}

/// Stops the cell. A borrow after this answers that the plane is not open.
///
/// ## Examples
///
/// ```gleam
/// // capability.stop(name)
/// ```
///
pub fn stop(name: address.Address(Message)) -> Nil {
  let _sent = address.send(name, Stop)
  Nil
}

/// Transfers the startup link after custody has retained `stop`, so an
/// assembly process that exits normally does not take the cell with it.
///
/// ## Examples
///
/// ```gleam
/// // capability.detach(cell)
/// ```
///
pub fn detach(cell: Cell) -> Nil {
  process.unlink(cell.pid)
}

/// The doors registered under `name`, or a sentence saying there are none.
///
/// ## Examples
///
/// ```gleam
/// // capability.borrow(name) == Error("the evolution plane is not open")
/// ```
///
pub fn borrow(
  name: address.Address(Message),
) -> Result(evolution_tool.Door, String) {
  use subject <- result.try(
    address.lookup(name) |> result.replace_error(not_open),
  )
  call.try_call(subject, waiting: borrow_ms, sending: Borrow)
  |> result.replace_error(not_open)
}

const not_open = "Unavailable: the evolution plane is not open"

/// The builder a code-mode configuration holds: given one execution's
/// dispatching context, six operations that borrow the doors from the cell
/// under `name` and run them under that context.
///
/// ## Examples
///
/// ```gleam
/// // codemode.over_evolution(config, Some(capability.door_over(name)))
/// ```
///
pub fn door_over(
  name: address.Address(Message),
) -> fn(tool.Ctx) -> codemode_evolution.Door {
  fn(ctx) {
    codemode_evolution.Door(
      propose: operation(name, ctx, 0, fn(door) { door.propose }),
      test_candidate: operation(name, ctx, 1, fn(door) { door.test_candidate }),
      inspect: operation(name, ctx, 2, fn(door) { door.inspect }),
      catalogue: operation(name, ctx, 3, fn(door) { door.catalogue }),
      invoke: operation(name, ctx, 4, fn(door) { door.invoke }),
      trace: operation(name, ctx, 5, fn(door) { door.trace }),
    )
  }
}

/// The builder an owner holds for a workspace on another node: given one
/// owner-bound call, six operations that borrow the doors from the cell under
/// `name` and run them under that call's coordinates.
///
/// The owner has no checkout, so the context carries the call's strand,
/// operation, step and source index and nothing machine-local: the workspace,
/// policy and filesystem are empty, and the clearance runner refuses. That is
/// all the doors of a session on an executor read, because the machine behind
/// them (`machine/remote`) sends the coordinates and the executor rebuilds the
/// rest from its own machine. The key an operation is admitted under is the
/// `code_mode` call's, with the capability's slot and ordinal folded into the
/// source index by `call_index`, as for a local program.
///
/// ## Examples
///
/// ```gleam
/// // owner_side.evolution = Some(capability.door_for_call(name, clock))
/// ```
///
pub fn door_for_call(
  name: address.Address(Message),
  clock: Clock,
) -> fn(OwnerCapCall) -> codemode_evolution.Door {
  fn(call: OwnerCapCall) { door_over(name)(context_of(call, clock)) }
}

/// The context an owner-bound call runs its doors under: the call's
/// coordinates, with everything that belongs to a machine left empty.
fn context_of(call: OwnerCapCall, clock: Clock) -> tool.Ctx {
  tool.Ctx(
    workspace: "",
    strand: call.strand,
    op_id: call.op_id,
    step_id: call.step_id,
    source_index: call.source_index,
    base_policy: policy.workspace_default(""),
    directory_access: directory_access.none(),
    grants: [],
    demand: exec.BestEffort,
    env: [],
    clock:,
    filesystem: tool.FileSystem(
      read: fn(path) { Error(tool.FsNotFound(path:)) },
      write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
      create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
      is_file: fn(_path) { Ok(False) },
      read_link: fn(_path) { Ok(tool.LinkMissing) },
      rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
    ),
    blob_root: "",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
    observe_output: tool.ignore_output(),
  )
}

/// Doors that refuse every operation with `reason`, for a session whose
/// executor cannot compile candidates.
///
/// The cell is registered under the same name a working plane would use, so a
/// program that reaches the owner's evolution route reads why there is none
/// instead of a sentence about a plane that is not open.
///
/// ## Examples
///
/// ```gleam
/// // capability.start(name, capability.refusing(reason))
/// ```
///
pub fn refusing(reason: String) -> evolution_tool.Door {
  let refuse = fn(_ctx, _arguments) { tool.failure("Unavailable: " <> reason) }
  evolution_tool.Door(
    propose: refuse,
    test_candidate: refuse,
    inspect: refuse,
    catalogue: refuse,
    invoke: refuse,
    trace: refuse,
  )
}

/// Builds a code-mode evolution operation that borrows the cell door, adjusts the
/// call index to keep concurrent tool invocations isolated, and translates the outcome.
fn operation(
  name: address.Address(Message),
  ctx: tool.Ctx,
  slot: Int,
  pick: fn(evolution_tool.Door) -> fn(tool.Ctx, JsonValue) -> tool.ToolOutcome,
) -> codemode_evolution.Operation {
  fn(ordinal, arguments) {
    use door <- result.try(borrow(name))
    let called =
      tool.Ctx(..ctx, source_index: call_index(ctx.source_index, slot, ordinal))
    outcome(pick(door)(called, arguments))
  }
}

/// The source index one evolution call runs under.
///
/// A scratch directory for a candidate test or a program run is named from the
/// operation and the source index, and every call of one execution shares its
/// operation. The execution's own index is the same for all of them, so it
/// cannot tell two concurrent calls apart. This folds in the operation's slot
/// (0 to 5, in the order of the six names) and its ordinal among that name's
/// calls, which the host bounds below 128. The result is distinct for every
/// call of one execution and never equals a real tool call's index, which is
/// a position within one assistant message.
///
/// The ledger the broker pools on is `{operation, step}` and does not read the
/// source index, so this adds no second budget (ADR-005).
///
/// ## Examples
///
/// ```gleam
/// assert capability.call_index(2, 1, 3) == 3131
/// ```
///
pub fn call_index(execution_index: Int, slot: Int, ordinal: Int) -> Int {
  { execution_index + 1 } * 1000 + slot * 128 + int.min(ordinal, 127)
}

/// Words a door's `ToolOutcome` as the router's plain answer.
///
/// An in-band failure is the refusal sentence. A success carries its JSON in
/// `details` when the door set it, and otherwise in its text, which every
/// door writes as one JSON document; text that is not JSON is returned as a
/// string rather than lost.
///
/// ## Examples
///
/// ```gleam
/// assert capability.outcome(tool.failure("Stale")) == Error("Stale")
/// ```
///
pub fn outcome(outcome: tool.ToolOutcome) -> codemode_evolution.Outcome {
  let text =
    outcome.content
    |> list.filter_map(fn(block) {
      case block {
        message.ToolResultText(text:, ..) -> Ok(text)
        message.ToolResultImage(..) -> Error(Nil)
      }
    })
    |> string.join("\n")

  // Map the tool outcome to either an error text string or structured result details.
  case outcome.is_error, outcome.details {
    True, _ -> Error(text)
    False, Some(details) -> Ok(details)
    False, None -> Ok(json.parse(text) |> result.unwrap(or: json.String(text)))
  }
}
