//// A terminal a test can drive: a `tmux` server on a private socket,
//// one session, one pane, and the four verbs
//// `docs/design-notes/agent-driven-tui-testing.md` names — start, keys,
//// wait, capture.
////
//// ## Why tmux and not a pseudo-terminal
////
//// The design note's L2 layer (a `creack/pty` harness in Go) and its L3
//// layer (tmux) both give the program under test a real terminal. L3 is
//// what this uses, for two reasons the note already gives: the geometry
//// is *declared* rather than inherited, so a pane cannot reflow under a
//// test and produce a diff about nothing; and the pane survives the
//// process that created it, which is what lets a person — or an agent —
//// attach to the same session afterwards and look. The cost is a
//// dependency on `tmux` being installed, which is a skip, never a pass.
////
//// The note's `wait` verb is the load-bearing one and `settled` is it:
//// every wait here is a predicate over pane content with a deadline, so
//// nothing in the terminal harness sleeps for a fixed time and hopes.
//// The note's remaining verb — a golden `capture-pane -e` snapshot — is
//// deliberately *not* built: this harness asserts on facts that can only
//// have arrived over the protocol, and an ANSI golden of a whole pane
//// would fail on every unrelated style change without proving anything
//// more about the wire.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import support/internal/ffi_proc

/// A live tmux session on its own server socket.
///
/// Constructor invariants: `tmux` is an absolute path to the binary;
/// `socket` names a server private to this test (`-L`), so nothing here
/// can reach a developer's own tmux; `session` is the session name every
/// verb targets.
pub type Terminal {
  Terminal(tmux: String, socket: String, session: String)
}

/// The `tmux` binary, or the reason a host cannot run terminal tests.
///
/// ## Examples
///
/// ```gleam
/// // terminal.available() == Ok("/usr/bin/tmux")
/// ```
///
pub fn available() -> Result(String, String) {
  ffi_proc.which("tmux")
  |> result.replace_error("tmux is not on PATH")
}

/// Starts `command` — one absolute, executable path, taking no
/// arguments — in a detached tmux session of exactly `cols` × `rows`.
///
/// The geometry is declared rather than inherited: a test whose pane
/// reflowed under it would report a difference about nothing.
///
/// ## Examples
///
/// ```gleam
/// // terminal.start(tmux, "loom-e2e", "tui", "/tmp/run.sh", 100, 32)
/// ```
///
pub fn start(
  tmux tmux: String,
  socket socket: String,
  session session: String,
  command command: String,
  cols cols: Int,
  rows rows: Int,
) -> Result(Terminal, String) {
  let terminal = Terminal(tmux:, socket:, session:)
  use _output <- result.try(
    tmux_command(terminal, [
      "new-session",
      "-d",
      "-s",
      session,
      "-x",
      int.to_string(cols),
      "-y",
      int.to_string(rows),
      command,
    ]),
  )
  Ok(terminal)
}

/// Whether the session still exists — false once the pane's command has
/// exited and tmux has reaped it.
///
/// ## Examples
///
/// ```gleam
/// // terminal.alive(terminal) == True
/// ```
///
pub fn alive(terminal: Terminal) -> Bool {
  case
    ffi_proc.run(
      terminal.tmux,
      ["-L", terminal.socket, "has-session", "-t", terminal.session],
      in: ".",
    )
  {
    Ok(#(0, _output)) -> True
    _ -> False
  }
}

/// Types `text` into the pane one keystroke at a time — one
/// `send-keys -l` per character, so each grapheme reaches the program as
/// its own write, the way a person's typing does.
///
/// Not an affectation. A whole string written at once arrives at
/// bubbletea as a single run of runes, and a run of runes is named by
/// its own text: `tea.KeyMsg{Type: KeyRunes, Runes: []rune("end")}` has
/// `String() == "end"`, which `textarea.DefaultKeyMap.LineEnd` matches —
/// so the word is swallowed as a cursor movement instead of typed.
/// (Verified directly against the vendored `bubbles`, not assumed.) That
/// is a live latent bug for anything that delivers a multi-rune write —
/// an unbracketed paste — but it is the TUI's to fix, and a harness that
/// tripped it would be asserting on the wrong thing.
///
/// ## Examples
///
/// ```gleam
/// // terminal.type_text(terminal, ":fork")
/// ```
///
pub fn type_text(terminal: Terminal, text: String) -> Result(Nil, String) {
  string.to_graphemes(text)
  |> list.try_each(fn(character) {
    tmux_command(terminal, [
      "send-keys",
      "-t",
      terminal.session,
      "-l",
      character,
    ])
  })
  |> result.replace(Nil)
}

/// Presses one named key: `Enter`, `y`, `Tab`, `C-c`.
///
/// ## Examples
///
/// ```gleam
/// // terminal.press(terminal, "Enter")
/// ```
///
pub fn press(terminal: Terminal, key: String) -> Result(Nil, String) {
  tmux_command(terminal, ["send-keys", "-t", terminal.session, key])
  |> result.replace(Nil)
}

/// The pane's visible text, with escape sequences stripped.
///
/// ## Examples
///
/// ```gleam
/// // terminal.capture(terminal)
/// ```
///
pub fn capture(terminal: Terminal) -> Result(String, String) {
  tmux_command(terminal, ["capture-pane", "-p", "-t", terminal.session])
}

/// Waits until the pane satisfies `predicate`, polling every 100ms until
/// `within_ms` has passed. Returns the settling capture, or the last one
/// seen if the deadline arrives first — the caller reports it, because
/// only the caller knows what it was waiting for.
///
/// The whole reason this exists rather than a sleep: a wait on a
/// predicate fails at a known place with the pane in hand, and a sleep
/// that usually works reads as a pass until the day it does not.
///
/// ## Examples
///
/// ```gleam
/// // terminal.settled(terminal, string.contains(_, "loom"), 5000)
/// ```
///
pub fn settled(
  terminal: Terminal,
  predicate: fn(String) -> Bool,
  within_ms within_ms: Int,
) -> Result(String, String) {
  settle_loop(terminal, predicate, { within_ms + 99 } / 100)
}

fn settle_loop(
  terminal: Terminal,
  predicate: fn(String) -> Bool,
  attempts: Int,
) -> Result(String, String) {
  let seen = result.unwrap(capture(terminal), "")
  case predicate(seen), attempts <= 0 {
    True, _ -> Ok(seen)
    False, True -> Error(seen)
    False, False -> {
      process.sleep(100)
      settle_loop(terminal, predicate, attempts - 1)
    }
  }
}

/// Waits for `needle` to appear in the pane.
///
/// ## Examples
///
/// ```gleam
/// // terminal.settled_on(terminal, "main-fork", 5000)
/// ```
///
pub fn settled_on(
  terminal: Terminal,
  needle: String,
  within_ms within_ms: Int,
) -> Result(String, String) {
  settled(terminal, string.contains(_, needle), within_ms)
}

/// Kills the whole private server, and with it the session, the pane,
/// and the program in it, and waits for it to be gone.
///
/// Safe to call twice, and the waiting is what makes it safe to call
/// *before* a start: `kill-server` returns before the socket does, so a
/// `new-session` issued straight after it can still land on the dying
/// server and be refused as a duplicate.
///
/// ## Examples
///
/// ```gleam
/// // terminal.stop(terminal)
/// ```
///
pub fn stop(terminal: Terminal) -> Nil {
  let _killed =
    ffi_proc.run(terminal.tmux, ["-L", terminal.socket, "kill-server"], in: ".")
  gone(terminal, 30)
}

fn gone(terminal: Terminal, attempts: Int) -> Nil {
  case alive(terminal), attempts <= 0 {
    False, _ | True, True -> Nil
    True, False -> {
      process.sleep(100)
      gone(terminal, attempts - 1)
    }
  }
}

/// The pane, framed for a failure message.
///
/// ## Examples
///
/// ```gleam
/// // terminal.framed("the pane never showed it", pane)
/// ```
///
pub fn framed(reason: String, pane: String) -> String {
  reason <> "\n--- pane ---\n" <> string.trim_end(pane) <> "\n--- end pane ---"
}

fn tmux_command(
  terminal: Terminal,
  args: List(String),
) -> Result(String, String) {
  let args = list.append(["-L", terminal.socket], args)
  case ffi_proc.run(terminal.tmux, args, in: ".") {
    Error(reason) -> Error("tmux could not be run: " <> reason)
    Ok(#(0, output)) -> Ok(output)
    Ok(#(status, output)) ->
      Error(
        "tmux "
        <> string.join(args, " ")
        <> " exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(output),
      )
  }
}
