//// Confirmed deletion follows the daemon's positive retirement observation.
//// A failed stop or a replacement incarnation cannot become permission to
//// delete, and uncertain mutation replies are never replayed by the client.

import gleam/erlang/process
import gleam/list
import gleam/option
import tui/daemon/protocol
import tui/daemon/selection

fn row(status) {
  protocol.Session(
    "selected",
    "/workspace",
    "Selected",
    1000,
    status,
    option.None,
    option.None,
  )
}

fn observed(commands) {
  case process.receive(commands, 0) {
    Ok(command) -> [command, ..observed(commands)]
    Error(_) -> []
  }
}

pub fn delete_waits_for_positive_retirement_before_removing_the_selected_session_test() {
  let commands = process.new_subject()
  let result =
    selection.delete_using("selected", fn(command, _) {
      process.send(commands, command)
      case command {
        protocol.StopSession("selected") ->
          Ok(protocol.LifecycleReply(protocol.Stopping("incarnation")))
        protocol.GetSession("selected") ->
          Ok(protocol.SessionReply(row(protocol.Saved)))
        protocol.DeleteSession("selected") ->
          Ok(protocol.DeletedReply("selected"))
        _ -> Error("unexpected command")
      }
    })
  assert result == Ok("selected")
  assert observed(commands)
    == [
      protocol.StopSession("selected"),
      protocol.GetSession("selected"),
      protocol.DeleteSession("selected"),
    ]
}

pub fn delete_keeps_the_session_when_retirement_is_unconfirmed_or_overtaken_test() {
  list.each(
    [
      protocol.RecoveryBlocked,
      protocol.Resident("replacement"),
      protocol.Stopping("replacement"),
    ],
    fn(status) {
      let commands = process.new_subject()
      let result =
        selection.delete_using("selected", fn(command, _) {
          process.send(commands, command)
          case command {
            protocol.StopSession("selected") ->
              Ok(protocol.LifecycleReply(protocol.Stopping("original")))
            protocol.GetSession("selected") ->
              Ok(protocol.SessionReply(row(status)))
            _ -> Error("delete must never be issued")
          }
        })
      let assert Error(_) = result
        as "uncertain cleanup or a replacement keeps the registration"
      assert observed(commands)
        == [protocol.StopSession("selected"), protocol.GetSession("selected")]
    },
  )
}

pub fn delete_does_not_repeat_a_stop_or_delete_with_an_unknown_outcome_test() {
  list.each(["stop", "delete"], fn(lost) {
    let commands = process.new_subject()
    let result =
      selection.delete_using("selected", fn(command, _) {
        process.send(commands, command)
        case command, lost {
          protocol.StopSession("selected"), "stop" -> Error("stop reply lost")
          protocol.StopSession("selected"), _ ->
            Ok(protocol.LifecycleReply(protocol.Saved))
          protocol.DeleteSession("selected"), _ -> Error("delete reply lost")
          _, _ -> Error("unexpected command")
        }
      })
    let assert Error(_) = result
      as "an uncertain mutation reply is returned to the caller"
    let sent = observed(commands)
    assert list.count(sent, fn(command) {
        command == protocol.StopSession("selected")
      })
      == 1
    assert list.count(sent, fn(command) {
        command == protocol.DeleteSession("selected")
      })
      == case lost {
        "stop" -> 0
        _ -> 1
      }
  })
}

/// The retirement wait gives each `GetSession` read what is left of its own
/// deadline rather than a fixed two seconds, so one reply slower than that
/// cannot end a wait that still has most of its minute left. The seam records
/// the budget each read was handed; the first read of a fresh wait must be
/// offered far more than the old flat budget.
///
/// ## Examples
///
/// `scripts/test.sh tui --match retirement_reads_spend_the_wait` runs this.
pub fn retirement_reads_spend_the_wait_not_a_fixed_budget_test() {
  let budgets = process.new_subject()
  let result =
    selection.delete_using("selected", fn(command, within) {
      case command {
        protocol.StopSession("selected") ->
          Ok(protocol.LifecycleReply(protocol.Stopping("incarnation")))
        protocol.GetSession("selected") -> {
          process.send(budgets, within)
          Ok(protocol.SessionReply(row(protocol.Saved)))
        }
        protocol.DeleteSession("selected") ->
          Ok(protocol.DeletedReply("selected"))
        _ -> Error("unexpected command")
      }
    })
  assert result == Ok("selected")
  let assert Ok(within) = process.receive(budgets, 0)
    as "retirement was read once"
  assert within > 50_000 && within <= 60_000
}
