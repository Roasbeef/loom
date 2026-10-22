//// The operator commands that change and read a membership ledger:
//// `loom distribution enroll`, `revoke`, `renew`, `log` and `import`
//// (protocol-change/086), and `attach-file` (protocol-change/096).
////
//// `provision` signs the first ledger and keeps the authority key, sealed under
//// a passphrase, in `~/.loom/authority/<deployment id>`. These commands are
//// what that key is for. They run on the operator's machine, which need not run
//// a daemon, and each signing command does the same four things:
////
//// 1. Unlock the key and take a lock on the operator's copy of the ledger.
//// 2. Ask a daemon for its head, if one is reachable, and bring the copy up to
////    it (`client/ledger_sync`), so a second machine holding the key cannot
////    fork the ledger by accident.
//// 3. Build the entry from the fold state, run the fold on it, sign it and
////    append it to the copy (`client/ledger_operator`).
//// 4. Hand the daemon every line it lacks, then poll its status for a bounded
////    time and print which members hold the new head.
////
//// `revoke` adds checks to step 3. Before it signs, it checks the link graph,
//// asks the daemon what the orchestrators hold (`ledger.holdings`), and counts
//// the session directory's voters. It refuses when the revoke would break the
//// link graph, while the member owns sessions or has sessions placed on it (or
//// when that cannot be told), or when it would leave fewer than three directory
//// voters, unless `--force` (`checked_revoke`).
////
//// Membership changes are eventual. A member that is off learns an entry when it
//// next connects to one that has it, so the command does not wait for it: it
//// prints who confirmed and who is still pending and returns. A command with no
//// reachable daemon still succeeds. The entry is in the copy, and the operator
//// carries the copy to any member's machine and runs `import` there.
////
//// ## What each command writes
////
//// `enroll` and `renew` mint a node certificate under the kept authority and
//// write `NAME.loombundle` (`/2`), which holds that node's private key and the
//// deployment's cookie. `revoke` writes only the entry. No command prints a
//// key, a passphrase or a cookie. `log` and `import` need no passphrase:
//// the ledger is public, and `import` adds no way to adopt an entry that a
//// signature and a chain do not already allow.
////
//// ## Flow
////
//// `run` → `run_with` → `parse` → `enroll` | `renew` | `revoke` |
//// `attach_file` | `log` | `import_file`
////
//// 1. `run` hands the command to `run_with` with the socket as the way to reach
////    a daemon (`socket_daemon`); a test passes a ledger process of its own.
//// 2. `parse` reads the words with the flags of the command (`flags_of`) and
////    refuses an option nobody knows.
//// 3. A signing command checks its own fields, then `unlock` opens the kept key
////    with the passphrase.
//// 4. `sign` locks the operator's copy and `signed_under_lock` does the work:
////    status from the daemon, `ledger_sync.catch_up`, the command's own decision
////    from the ledger as it stands, seal, apply, append to the copy, the
////    command's bundle, `hand_over`.
//// 5. `confirmations_text` polls the daemon for the new head and prints who has
////    it. `log` and `import_file` read the ledger or feed it to a daemon and do
////    not sign.
////
//// ## Which daemon
////
//// By default the daemon on this host, found through its state directory
//// (`--state-dir`, default `~/.loom`). `--addr URL --token-file PATH` selects a
//// daemon on another host, as `loom access` does. The passphrase comes from the
//// terminal, which only `loomd` can ask on, or from `--passphrase-file`.

import client/authority_key
import client/daemon/admin
import client/distribution
import client/distribution_attach
import client/distribution_bundle.{type Bundle, Bundle}
import client/distribution_plan.{type Workspace, Executor, Tool, Workspace}
import client/distribution_provision.{
  type Overwrite, RefuseExisting, ReplaceExisting,
}
import client/executors
import client/internal/ffi_pki
import client/ledger_control
import client/ledger_operator.{type Enrollment, Enrollment}
import client/ledger_sync.{type Daemon, Daemon}
import client/membership_entry.{type Entry, type SignedEntry}
import client/membership_ledger.{type Ledger}
import client/membership_provision
import client/membership_signing
import client/membership_store.{type Store}
import core/json
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile

/// Whether a command is one of this module's.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_cli.is_ledger_command("enroll")
/// ```
pub fn is_ledger_command(word: String) -> Bool {
  list.contains(
    ["enroll", "revoke", "renew", "attach-file", "log", "import"],
    word,
  )
}

/// Whether the command signs, and so needs the authority key and a passphrase.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_cli.signs("renew")
/// assert !ledger_cli.signs("log")
/// ```
pub fn signs(word: String) -> Bool {
  list.contains(["enroll", "revoke", "renew", "attach-file"], word)
}

/// Runs one of the five commands and returns what it prints.
///
/// ## Examples
///
/// ```gleam
/// ledger_cli.run("log", ["--json"])
/// ```
pub fn run(command: String, arguments: List(String)) -> Result(String, String) {
  run_with(command, arguments, socket_daemon)
}

/// The same, with the way a daemon is reached given by the caller. A test
/// passes a daemon that is a ledger process in its own VM, so the commands run
/// their production path against a real ledger without a socket.
///
/// ## Examples
///
/// ```gleam
/// ledger_cli.run_with("log", [], fn(_) { unreachable })
/// ```
pub fn run_with(
  command: String,
  arguments: List(String),
  connect: Connect,
) -> Result(String, String) {
  use parsed <- result.try(parse(command, arguments))
  case command {
    "enroll" -> enroll(parsed, connect)
    "revoke" -> revoke(parsed, connect)
    "renew" -> renew(parsed, connect)
    "attach-file" -> attach_file(parsed, connect)
    "log" -> log(parsed, connect)
    _ -> import_file(parsed, connect)
  }
}

/// How a command reaches the daemon it was pointed at.
pub type Connect =
  fn(admin.Where) -> Daemon

// --- flags -------------------------------------------------------------------

// What the command line held: words, the options that take a value, and the
// switches. An option may repeat only where `repeatable` says so.
type Parsed {
  Parsed(
    positional: List(String),
    values: List(#(String, String)),
    switches: List(String),
  )
}

// The flags a command accepts: the options that take a value, the switches that
// do not, and the options that may be given more than once.
type Flags {
  Flags(valued: List(String), switches: List(String), repeatable: List(String))
}

fn flags_of(command: String) -> Flags {
  let common = [
    "--home", "--deployment", "--passphrase-file", "--state-dir", "--addr",
    "--token-file",
  ]
  case command {
    "enroll" ->
      Flags(
        list.append(common, [
          "--node", "--role", "--host", "--port", "--links", "--workspace",
          "--bundle-dir", "--out", "--wait", "--directory",
        ]),
        ["--force"],
        ["--workspace"],
      )
    "attach-file" ->
      Flags(
        list.append(common, ["--node", "--host", "--links", "--out", "--wait"]),
        ["--force"],
        [],
      )
    "revoke" ->
      Flags(list.append(common, ["--reason", "--wait"]), ["--force"], [])
    "renew" ->
      Flags(
        list.append(common, ["--bundle-dir", "--out", "--wait"]),
        ["--force"],
        [],
      )
    "log" -> Flags(list.append(common, ["--config"]), ["--json"], [])
    _ -> Flags(["--state-dir", "--addr", "--token-file"], [], [])
  }
}

fn parse(command: String, arguments: List(String)) -> Result(Parsed, String) {
  use parsed <- result.try(parse_loop(
    arguments,
    flags_of(command),
    Parsed([], [], []),
  ))
  Ok(Parsed(
    positional: list.reverse(parsed.positional),
    values: list.reverse(parsed.values),
    switches: parsed.switches,
  ))
}

fn parse_loop(
  arguments: List(String),
  flags: Flags,
  parsed: Parsed,
) -> Result(Parsed, String) {
  case arguments {
    [] -> Ok(parsed)
    [word, ..rest] -> {
      use #(parsed, rest) <- result.try(take_word(word, rest, flags, parsed))
      parse_loop(rest, flags, parsed)
    }
  }
}

// One word: an option that takes a value, a switch, an option nobody knows, or
// a positional word. Returns what it consumed beyond the word.
fn take_word(
  word: String,
  rest: List(String),
  flags: Flags,
  parsed: Parsed,
) -> Result(#(Parsed, List(String)), String) {
  case
    list.contains(flags.valued, word),
    list.contains(flags.switches, word),
    string.starts_with(word, "--")
  {
    True, _, _ -> take_value(word, rest, flags, parsed)
    _, True, _ ->
      Ok(#(Parsed(..parsed, switches: [word, ..parsed.switches]), rest))
    _, _, True -> Error("unknown option " <> word)
    _, _, False ->
      Ok(#(Parsed(..parsed, positional: [word, ..parsed.positional]), rest))
  }
}

fn take_value(
  word: String,
  rest: List(String),
  flags: Flags,
  parsed: Parsed,
) -> Result(#(Parsed, List(String)), String) {
  case rest {
    [] -> Error(word <> " needs a value")
    [value, ..after] ->
      case
        list.key_find(parsed.values, word),
        list.contains(flags.repeatable, word)
      {
        Ok(_), False -> Error(word <> " was given twice")
        _, _ ->
          Ok(#(
            Parsed(..parsed, values: [#(word, value), ..parsed.values]),
            after,
          ))
      }
  }
}

fn value(parsed: Parsed, flag: String) -> Option(String) {
  case list.key_find(parsed.values, flag) {
    Ok(text) -> Some(text)
    Error(Nil) -> None
  }
}

fn values(parsed: Parsed, flag: String) -> List(String) {
  list.filter_map(parsed.values, fn(pair) {
    case pair.0 == flag {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}

fn has(parsed: Parsed, switch: String) -> Bool {
  list.contains(parsed.switches, switch)
}

fn one_name(parsed: Parsed, command: String) -> Result(String, String) {
  case parsed.positional {
    [name] -> Ok(name)
    _ -> Error("usage: loomd distribution " <> command <> " NAME [options]")
  }
}

// Which daemon the command talks to. The two ways exclude each other, and a
// remote daemon needs both halves.
fn where_of(parsed: Parsed) -> Result(admin.Where, String) {
  case
    value(parsed, "--state-dir"),
    value(parsed, "--addr"),
    value(parsed, "--token-file")
  {
    state, None, None -> Ok(admin.ThisHost(option.unwrap(state, "")))
    None, Some(address), Some(token) -> Ok(admin.OverNetwork(address, token))
    _, _, _ ->
      Error(
        "--addr and --token-file go together, and neither combines with "
        <> "--state-dir",
      )
  }
}

fn describe_where(where_: admin.Where) -> String {
  case where_ {
    admin.ThisHost("") -> "the daemon on this host"
    admin.ThisHost(directory) -> "the daemon of " <> directory
    admin.OverNetwork(address, _) -> "the daemon at " <> address
  }
}

// The seconds to wait for confirmations, in milliseconds. Zero is allowed, and
// means to print the first status and return.
fn wait_ms(parsed: Parsed) -> Result(Int, String) {
  case value(parsed, "--wait") {
    None -> Ok(10_000)
    Some(text) ->
      case int.parse(text) {
        Ok(seconds) if seconds >= 0 && seconds <= 600 -> Ok(seconds * 1000)
        _ -> Error("--wait takes a number of seconds from 0 to 600")
      }
  }
}

// --- the authority -----------------------------------------------------------

// The kept authority, unlocked.
type Authority {
  Authority(
    directory: String,
    certificate: String,
    key: String,
    cookie: String,
    signer: membership_entry.Signer,
    verifier: membership_entry.Verifier,
  )
}

fn home_of(parsed: Parsed) -> Result(String, String) {
  case value(parsed, "--home") {
    Some(home) -> bootstrap.absolute_path(home)
    None ->
      bootstrap.getenv("HOME")
      |> result.replace_error("HOME is unset; pass --home DIR")
  }
}

// The directory of the kept authority: the one named by `--deployment`, or the
// only one under the home.
fn authority_directory(parsed: Parsed) -> Result(String, String) {
  use home <- result.try(home_of(parsed))
  let root = home <> "/.loom/authority"
  case value(parsed, "--deployment") {
    Some(id) -> {
      let directory = authority_key.default_directory(home, id)
      case authority_key.is_kept(directory) {
        True -> Ok(directory)
        False -> Error("no authority key is kept in " <> directory)
      }
    }
    None ->
      case simplifile.read_directory(root) {
        Error(_) ->
          Error(
            "no authority key is kept under "
            <> root
            <> ". It exists only for a deployment provisioned with a ledger "
            <> "and without --drop-authority",
          )
        Ok(entries) ->
          case list.sort(entries, string.compare) {
            [only] -> Ok(root <> "/" <> only)
            [] -> Error("no authority key is kept under " <> root)
            several ->
              Error(
                "several deployments are kept under "
                <> root
                <> "; pass --deployment with one of: "
                <> string.join(several, ", "),
              )
          }
      }
  }
}

fn unlock(parsed: Parsed) -> Result(Authority, String) {
  use directory <- result.try(authority_directory(parsed))
  let deployment = last_segment(directory)
  use passphrase <- result.try(case value(parsed, "--passphrase-file") {
    Some(path) -> {
      use path <- result.try(bootstrap.absolute_path(path))
      authority_key.passphrase_from_file(path)
      |> result.map_error(authority_key.describe)
    }
    None ->
      authority_key.passphrase_from_terminal(authority_key.AskOnce)
      |> result.map_error(authority_key.describe)
  })
  use key <- result.try(
    authority_key.load(directory, deployment, passphrase)
    |> result.map_error(authority_key.describe),
  )
  use signer <- result.try(
    membership_signing.signer(key)
    |> result.replace_error("the kept key cannot sign"),
  )
  use certificate <- result.try(read_text(directory <> "/ca.pem"))
  use verifier <- result.try(
    membership_signing.verifier(certificate)
    |> result.map_error(fn(_) { directory <> "/ca.pem is not a certificate" }),
  )
  use cookie <- result.try(
    authority_key.cookie(directory)
    |> result.map_error(authority_key.describe),
  )
  Ok(Authority(directory:, certificate:, key:, cookie:, signer:, verifier:))
}

fn last_segment(path: String) -> String {
  case list.last(string.split(path, "/")) {
    Ok(segment) -> segment
    Error(Nil) -> path
  }
}

fn read_text(path: String) -> Result(String, String) {
  simplifile.read(path)
  |> result.map_error(fn(error) {
    path <> " is unreadable: " <> simplifile.describe_error(error)
  })
}

// --- a signing run -----------------------------------------------------------

// Where a signed entry went.
type Delivery {
  // A daemon holds it, with the status it last reported.
  Delivered(daemon: Daemon, status: ledger_control.StatusView, where_: String)

  // Only the operator's copy holds it, for this reason.
  Offline(reason: String)
}

// What a signing run produced.
type Signed {
  Signed(entry: SignedEntry, ledger: Ledger, store: Store, delivery: Delivery)
}

// What a command decides once it sees the ledger as it stands: the entry, and
// whatever else it needs to carry to the end (a bundle's key, say).
type Decision(a) {
  Decision(entry: Entry, extra: a)
}

// Runs the steps every signing command shares. `decide` sees the ledger after
// the copy has caught up with the daemon. `before_send` runs once the entry is
// in the operator's copy and before the daemon is told, so a bundle that cannot
// be written is found while the entry is still the operator's alone.
fn sign(
  authority: Authority,
  where_: admin.Where,
  connect: Connect,
  decide: fn(Ledger) -> Result(Decision(a), String),
  before_send: fn(Signed, a) -> Result(Nil, String),
) -> Result(#(Signed, a), String) {
  let lock_path = authority.directory <> "/ledger.lock"
  use lock <- result.try(
    bootstrap.try_launch_lock(lock_path)
    |> result.map_error(fn(_) {
      "another command holds the lock on this ledger copy: " <> lock_path
    }),
  )
  let done = signed_under_lock(authority, where_, connect, decide, before_send)
  bootstrap.release_launch_lock(lock)
  done
}

fn signed_under_lock(
  authority: Authority,
  where_: admin.Where,
  connect: Connect,
  decide: fn(Ledger) -> Result(Decision(a), String),
  before_send: fn(Signed, a) -> Result(Nil, String),
) -> Result(#(Signed, a), String) {
  let path = authority.directory <> "/" <> authority_key.ledger_file
  use opened <- result.try(
    membership_store.open(path, authority.verifier)
    |> result.map_error(fn(_) {
      path <> " is not a valid ledger for this authority"
    }),
  )
  let daemon = connect(where_)
  let reached = daemon.status()

  // A daemon that answers brings the copy up to its head, or stops the command
  // when the two disagree. One that does not answer is a reason, and the entry
  // goes to the copy alone.
  use #(store, ledger, delivery) <- result.try(case reached {
    Ok(status) -> {
      use #(store, ledger) <- result.map(
        ledger_sync.catch_up(
          opened.store,
          opened.ledger,
          authority.verifier,
          daemon,
          status,
        )
        |> result.map_error(ledger_sync.describe),
      )
      #(store, ledger, Delivered(daemon, status, describe_where(where_)))
    }
    Error(reason) -> Ok(#(opened.store, opened.ledger, Offline(reason)))
  })
  use Decision(entry:, extra:) <- result.try(decide(ledger))
  use signed <- result.try(
    membership_entry.seal(entry, authority.signer)
    |> result.map_error(fn(error) {
      case error {
        membership_entry.SigningFailed -> "the authority key could not sign"
        membership_entry.TooLarge -> "the entry is larger than a reader accepts"
      }
    }),
  )
  use applied <- result.try(
    membership_ledger.apply(ledger, signed)
    |> result.map_error(fn(refusal) { ledger_operator.describe(refusal) }),
  )
  use next <- result.try(case applied {
    membership_ledger.Applied(ledger: next, entry: _) -> Ok(next)
    _ -> Error("the entry did not extend the ledger")
  })
  use store <- result.try(
    membership_store.append(store, signed)
    |> result.map_error(fn(error) {
      let membership_store.Unwritable(reason:) = error
      path <> " cannot be written: " <> reason
    }),
  )
  let result = Signed(entry: signed, ledger: next, store:, delivery:)
  use Nil <- result.try(before_send(result, extra))
  hand_over(result) |> result.map(fn(handed) { #(handed, extra) })
}

// Gives the daemon every line it lacks. A daemon that refuses leaves the entry
// in the copy and the operator with the reason.
fn hand_over(signed: Signed) -> Result(Signed, String) {
  case signed.delivery {
    Offline(_) -> Ok(signed)
    Delivered(daemon:, status:, where_:) ->
      case ledger_sync.hand_over(signed.store, daemon, status.head.seq) {
        Ok(_) -> Ok(signed)
        Error(reason) ->
          Ok(
            Signed(
              ..signed,
              delivery: Offline(where_ <> " refused the entry: " <> reason),
            ),
          )
      }
  }
}

// The lines of the operator's copy, which a bundle carries.
fn lines_of(store: Store) -> List(String) {
  membership_store.lines_after(
    store,
    -1,
    membership_ledger.max_entries,
    membership_store.max_file_bytes,
  )
  |> list.filter_map(bit_array.to_string)
}

fn now() -> String {
  membership_provision.time_text(timestamp.system_time())
}

// --- the report --------------------------------------------------------------

// Waits for confirmations, bounded, and prints which members hold the entry.
fn confirmations_text(
  signed: Signed,
  wait: Int,
  unreachable: List(String),
) -> List(String) {
  let seq = signed.entry.entry.seq
  case signed.delivery {
    Offline(reason:) -> [
      "No daemon took the entry: " <> reason <> ".",
      "It is entry "
        <> int.to_string(seq)
        <> " in the operator's copy of the ledger, "
        <> signed.store |> membership_store.path
        <> ". Copy that file to a member's machine and run "
        <> "`loom distribution import FILE` there, or run this command again "
        <> "with a daemon reachable.",
    ]
    Delivered(daemon:, status:, where_:) -> {
      let #(latest, _) =
        ledger_sync.await(daemon, seq, wait, unreachable, status)
      let rows = ledger_operator.confirmations(latest, seq)
      let held =
        list.count(rows, fn(row) { row.1 == ledger_operator.Confirmed })
      list.flatten([
        [
          "Handed to "
          <> where_
          <> ". Members that hold entry "
          <> int.to_string(seq)
          <> ":",
        ],
        list.map(rows, fn(row) {
          "  " <> string.pad_end(row.0, 16, " ") <> confirmation_word(row.1)
        }),
        [
          int.to_string(held)
          <> " of "
          <> int.to_string(list.length(rows))
          <> " members hold it. A member that is off, or not started yet, learns "
          <> "it when it next connects to one that does.",
        ],
      ])
    }
  }
}

fn confirmation_word(confirmation: ledger_operator.Confirmation) -> String {
  case confirmation {
    ledger_operator.Confirmed -> "confirmed"
    ledger_operator.Pending(Some(seq)) ->
      "pending (at entry " <> int.to_string(seq) <> ")"
    ledger_operator.Pending(None) -> "pending (has not reported)"
  }
}

// --- enroll ------------------------------------------------------------------

fn enroll(parsed: Parsed, connect: Connect) -> Result(String, String) {
  use name <- result.try(one_name(parsed, "enroll"))
  use request <- result.try(enrollment_of(parsed, name))
  use Nil <- result.try(ledger_operator.check_enrollment(request))
  use where_ <- result.try(where_of(parsed))
  use wait <- result.try(wait_ms(parsed))
  use out <- result.try(out_directory(parsed))
  let bundle_path = out <> "/" <> name <> distribution_provision_extension
  use Nil <- result.try(refuse_existing(bundle_path, overwrite_of(parsed)))
  use authority <- result.try(unlock(parsed))
  let time = now()
  use #(signed, _) <- result.try(
    sign(
      authority,
      where_,
      connect,
      fn(ledger) {
        use #(certificate, key) <- result.try(mint(authority, request))
        use pin <- result.try(pin_of(certificate))
        use entry <- result.map(ledger_operator.enroll(
          ledger,
          request,
          pin,
          time,
        ))
        Decision(entry:, extra: #(certificate, key))
      },
      fn(signed, issued) {
        write_bundle(
          bundle_path,
          authority,
          signed,
          request,
          issued.0,
          issued.1,
        )
        |> or_bundle_not_written(name, "enrolled", signed)
      },
    ),
  )
  Ok(string.join(
    list.flatten([
      [
        "Enrolled "
          <> name
          <> " ("
          <> distribution_plan.role_word(request.role)
          <> ", "
          <> request.node
          <> ") as entry "
          <> int.to_string(signed.entry.entry.seq)
          <> ".",
        "Bundle: "
          <> bundle_path
          <> " (it holds the node's private key and the deployment's cookie; "
          <> "copy it over a channel you trust, then run `loom distribution "
          <> "install` on that machine).",
      ],
      confirmations_text(signed, wait, [name]),
    ]),
    "\n",
  ))
}

const distribution_provision_extension = ".loombundle"

// --- attach-file -------------------------------------------------------------

// Enrolls a tool as a member and writes the credentials a generic Erlang node
// needs, in place of the bundle `enroll` writes. The files go in a directory
// made before anything is signed, so a directory the operator cannot write is
// refused while the ledger is still unchanged.
fn attach_file(parsed: Parsed, connect: Connect) -> Result(String, String) {
  use name <- result.try(one_name(parsed, "attach-file"))
  use request <- result.try(tool_enrollment_of(parsed, name))
  use Nil <- result.try(ledger_operator.check_enrollment(request))
  use where_ <- result.try(where_of(parsed))
  use wait <- result.try(wait_ms(parsed))
  use out <- result.try(required(parsed, "--out"))
  use out <- result.try(bootstrap.absolute_path(out))
  let files = distribution_attach.files_in(out)
  use options <- result.try(distribution_attach.options(files))
  use Nil <- result.try(refuse_occupied(out, overwrite_of(parsed)))
  use Nil <- result.try(
    bootstrap.ensure_private_directory(out)
    |> result.map_error(fn(reason) { out <> " is unwritable: " <> reason }),
  )
  use authority <- result.try(unlock(parsed))
  let time = now()
  use #(signed, _) <- result.try(
    sign(
      authority,
      where_,
      connect,
      fn(ledger) {
        use #(certificate, key) <- result.try(mint(authority, request))
        use pin <- result.try(pin_of(certificate))
        use entry <- result.map(ledger_operator.enroll(
          ledger,
          request,
          pin,
          time,
        ))
        Decision(entry:, extra: #(certificate, key))
      },
      fn(signed, issued) {
        write_attachment(
          files,
          options,
          request.node,
          authority,
          issued.0,
          issued.1,
        )
        |> result.map_error(fn(reason) {
          name
          <> " is enrolled as entry "
          <> int.to_string(signed.entry.entry.seq)
          <> " in the operator's copy of the ledger, but its files could not "
          <> "be written: "
          <> reason
          <> ". `revoke` it and run `attach-file` again."
        })
      },
    ),
  )
  let daemons =
    list.filter_map(request.links, fn(link) {
      membership_ledger.member(signed.ledger, link)
      |> result.map(fn(member) { member.node })
    })
  Ok(string.join(
    list.flatten([
      [
        "Enrolled "
          <> name
          <> " (tool, "
          <> request.node
          <> ") as entry "
          <> int.to_string(signed.entry.entry.seq)
          <> ".",
        "Files in "
          <> out
          <> " (they hold the tool's private key and the deployment's "
          <> "cookie; keep the directory private).",
        "",
        distribution_attach.instructions(files, request.node, daemons),
        "",
      ],
      confirmations_text(signed, wait, []),
    ]),
    "\n",
  ))
}

// The directory is made private, and six files are written into it, so a
// directory that already holds anything is refused without `--force`. That
// keeps `--out ~` from replacing `~/.erlang.cookie` or changing the mode of a
// home directory, and a directory that does not exist yet is fine.
fn refuse_occupied(out: String, overwrite: Overwrite) -> Result(Nil, String) {
  case simplifile.read_directory(out), overwrite {
    Ok([_, ..]), RefuseExisting ->
      Error(
        out
        <> " is not empty. attach-file writes ca.pem, tool.pem, tool.key, "
        <> ".erlang.cookie, node and ssl_dist.conf there and makes the directory "
        <> "private, so name an empty or new directory, or pass --force to "
        <> "use this one",
      )
    _, _ -> Ok(Nil)
  }
}

fn links_of(parsed: Parsed) -> List(String) {
  case value(parsed, "--links") {
    None -> []
    Some(text) ->
      string.split(text, ",")
      |> list.map(string.trim)
      |> list.filter(fn(link) { link != "" })
  }
}

fn tool_enrollment_of(
  parsed: Parsed,
  name: String,
) -> Result(Enrollment, String) {
  use node <- result.try(required(parsed, "--node"))
  Ok(Enrollment(
    name:,
    node:,
    role: Tool,
    host: value(parsed, "--host"),
    listen_port: None,
    links: links_of(parsed),
    directory: membership_entry.NotInDirectory,
    workspaces: [],
    bundle_dir: None,
  ))
}

// The key and the cookie are written mode 0600 and the options file last, so a
// directory that holds an options file holds all the files it names.
fn write_attachment(
  files: distribution_attach.Files,
  options: String,
  node: String,
  authority: Authority,
  certificate: String,
  key: String,
) -> Result(Nil, String) {
  [
    #(files.ca, authority.certificate),
    #(files.certificate, certificate),
    #(files.key, key),
    #(files.cookie, authority.cookie),
    #(files.node, node <> "\n"),
    #(files.options, options),
  ]
  |> list.try_each(fn(file) {
    bootstrap.atomic_write_private(file.0, file.1)
    |> result.map_error(fn(reason) { file.0 <> ": " <> reason })
  })
}

fn enrollment_of(parsed: Parsed, name: String) -> Result(Enrollment, String) {
  use node <- result.try(required(parsed, "--node"))
  use role <- result.try(
    required(parsed, "--role")
    |> result.try(distribution_plan.role_from_word),
  )
  use directory <- result.try(case value(parsed, "--directory") {
    None | Some("none") -> Ok(membership_entry.NotInDirectory)
    Some("voter") -> Ok(membership_entry.Voter)
    Some("learner") -> Ok(membership_entry.Learner)
    Some(_) -> Error("--directory takes voter, learner or none")
  })
  use listen_port <- result.try(case value(parsed, "--port") {
    None -> Ok(None)
    Some(text) ->
      int.parse(text)
      |> result.map(Some)
      |> result.replace_error("--port takes a number")
  })
  use workspaces <- result.try(list.try_map(
    values(parsed, "--workspace"),
    workspace_of,
  ))
  Ok(Enrollment(
    name:,
    node:,
    role:,
    host: value(parsed, "--host"),
    listen_port:,
    links: links_of(parsed),
    directory:,
    workspaces:,
    bundle_dir: value(parsed, "--bundle-dir"),
  ))
}

fn required(parsed: Parsed, flag: String) -> Result(String, String) {
  value(parsed, flag) |> option.to_result(flag <> " is required")
}

fn workspace_of(text: String) -> Result(Workspace, String) {
  case string.split_once(text, "=") {
    Ok(#(name, root)) -> Ok(Workspace(name:, root:))
    Error(Nil) -> Error("--workspace takes NAME=ROOT, got " <> text)
  }
}

fn out_directory(parsed: Parsed) -> Result(String, String) {
  bootstrap.absolute_path(option.unwrap(value(parsed, "--out"), "."))
}

// Whether a bundle already at the path may be replaced: only with `--force`.
fn overwrite_of(parsed: Parsed) -> Overwrite {
  case has(parsed, "--force") {
    True -> ReplaceExisting
    False -> RefuseExisting
  }
}

// A bundle holds a private key, so one that is already there is not replaced
// without `--force`.
fn refuse_existing(path: String, overwrite: Overwrite) -> Result(Nil, String) {
  case bootstrap.path_exists(path), overwrite {
    True, RefuseExisting ->
      Error(path <> " already exists; pass --force to replace the bundle")
    _, _ -> Ok(Nil)
  }
}

// The entry is in the operator's copy by the time a bundle is written, so a
// bundle that cannot be written leaves the member changed in the ledger with
// no certificate that anyone holds. The sentence says so, and names the command
// that mints a new certificate and writes the bundle again. That command also
// hands the entry to a daemon, which the failed one stopped before doing.
fn or_bundle_not_written(
  written: Result(Nil, String),
  name: String,
  done: String,
  signed: Signed,
) -> Result(Nil, String) {
  result.map_error(written, fn(reason) {
    name
    <> " is "
    <> done
    <> " as entry "
    <> int.to_string(signed.entry.entry.seq)
    <> " in the operator's copy of the ledger, "
    <> membership_store.path(signed.store)
    <> ", but its bundle could not be written: "
    <> reason
    <> ". Run `loom distribution renew "
    <> name
    <> "` to mint a new certificate and write the bundle; it also hands the "
    <> "entry to a daemon."
  })
}

// A certificate and key for the node, issued by the kept authority for its node
// name and its host.
fn mint(
  authority: Authority,
  request: Enrollment,
) -> Result(#(String, String), String) {
  issue(authority, request.name, [request.node, ledger_operator.host(request)])
}

fn issue(
  authority: Authority,
  name: String,
  names: List(String),
) -> Result(#(String, String), String) {
  ffi_pki.issue(authority.certificate, authority.key, name, list.unique(names))
  |> result.map_error(fn(_) { "could not issue a certificate for " <> name })
}

fn pin_of(certificate: String) -> Result(BitArray, String) {
  ffi_pki.pin(certificate)
  |> result.replace_error("the issued certificate cannot be pinned")
}

// Writes the bundle of an enrolled or renewed node, after checking that it
// decodes as the installer will read it.
fn write_bundle(
  path: String,
  authority: Authority,
  signed: Signed,
  request: Enrollment,
  certificate: String,
  key: String,
) -> Result(Nil, String) {
  let rows =
    list.filter_map(request.links, fn(link) {
      case membership_ledger.member(signed.ledger, link) {
        Ok(member) if member.role == Executor ->
          Ok(executors.plain(member.name, member.node))
        _ -> Error(Nil)
      }
    })
  let bundle =
    Bundle(
      name: request.name,
      role: request.role,
      erlang_node: request.node,
      host: ledger_operator.host(request),
      listen_port: request.listen_port,
      bundle_dir: request.bundle_dir,
      trust: distribution_bundle.SignedLedger(lines_of(signed.store)),
      executors: case request.role {
        Executor -> []
        _ -> rows
      },
      workspaces: request.workspaces,
      directory: [],
      ca: authority.certificate,
      certificate:,
      key:,
      cookie: authority.cookie,
    )
  store_bundle(path, bundle)
}

fn store_bundle(path: String, bundle: Bundle) -> Result(Nil, String) {
  let text = distribution_bundle.encode(bundle)
  use _checked <- result.try(
    distribution_bundle.decode(text)
    |> result.map_error(fn(reason) {
      "the bundle would not install: " <> reason
    }),
  )
  use Nil <- result.try(
    simplifile.create_directory_all(parent(path))
    |> result.map_error(fn(error) {
      parent(path) <> " is unwritable: " <> simplifile.describe_error(error)
    }),
  )
  bootstrap.atomic_write_private(path, text)
  |> result.map_error(fn(reason) { path <> " is unwritable: " <> reason })
}

fn parent(path: String) -> String {
  case list.reverse(string.split(path, "/")) {
    [_, ..rest] -> string.join(list.reverse(rest), "/")
    [] -> "/"
  }
}

// --- renew -------------------------------------------------------------------

fn renew(parsed: Parsed, connect: Connect) -> Result(String, String) {
  use name <- result.try(one_name(parsed, "renew"))
  use where_ <- result.try(where_of(parsed))
  use wait <- result.try(wait_ms(parsed))
  use out <- result.try(out_directory(parsed))
  let bundle_path = out <> "/" <> name <> distribution_provision_extension
  use Nil <- result.try(refuse_existing(bundle_path, overwrite_of(parsed)))
  use authority <- result.try(unlock(parsed))
  let time = now()
  use #(signed, _) <- result.try(
    sign(
      authority,
      where_,
      connect,
      fn(ledger) {
        use member <- result.try(
          membership_ledger.member(ledger, name)
          |> result.map_error(fn(_) { name <> " is not an active member" }),
        )
        use #(certificate, key) <- result.try(
          issue(authority, name, [member.node, member.host]),
        )
        use pin <- result.try(pin_of(certificate))
        use #(entry, renewed) <- result.map(ledger_operator.renew(
          ledger,
          name,
          pin,
          time,
        ))
        Decision(entry:, extra: #(certificate, key, renewed))
      },
      fn(signed, issued) {
        let #(certificate, key, member) = issued

        // The node already has its executor rows and workspaces in its
        // configuration, and a row the bundle repeated would conflict with an
        // operator's edits to it, so a renewal's bundle carries neither. The
        // ledger does not record where the node was installed, so a node
        // installed under a custom directory is renewed in place only if the
        // operator names that directory again.
        let bundle =
          Bundle(
            name: member.name,
            role: member.role,
            erlang_node: member.node,
            host: member.host,
            listen_port: member.listen_port,
            bundle_dir: value(parsed, "--bundle-dir"),
            trust: distribution_bundle.SignedLedger(lines_of(signed.store)),
            executors: [],
            workspaces: [],
            directory: [],
            ca: authority.certificate,
            certificate:,
            key:,
            cookie: authority.cookie,
          )
        store_bundle(bundle_path, bundle)
        |> or_bundle_not_written(name, "renewed", signed)
      },
    ),
  )
  Ok(string.join(
    list.flatten([
      [
        "Renewed "
          <> name
          <> " as entry "
          <> int.to_string(signed.entry.entry.seq)
          <> ". Its old certificate is refused from now on, and connections made with it are dropped when a node applies the entry.",
        "Bundle: "
          <> bundle_path
          <> ". Install it on that machine with `loom distribution install --force` and restart the daemon; until then the node's new handshakes are refused.",
      ],
      confirmations_text(signed, wait, [name]),
    ]),
    "\n",
  ))
}

// --- revoke ------------------------------------------------------------------

fn revoke(parsed: Parsed, connect: Connect) -> Result(String, String) {
  use name <- result.try(one_name(parsed, "revoke"))
  use where_ <- result.try(where_of(parsed))
  use wait <- result.try(wait_ms(parsed))
  use authority <- result.try(unlock(parsed))
  let reason = option.unwrap(value(parsed, "--reason"), "")
  let time = now()
  let daemon = connect(where_)
  use #(signed, checked) <- result.try(
    sign(
      authority,
      where_,
      connect,
      fn(ledger) {
        use entry <- result.try(ledger_operator.revoke(
          ledger,
          name,
          reason,
          time,
        ))
        use after <- result.try(
          membership_ledger.check(ledger, entry)
          |> result.map_error(ledger_operator.describe),
        )
        use checked <- result.map(case has(parsed, "--force") {
          True -> Ok(unchecked_text(name))
          False -> checked_revoke(ledger, after, name, daemon)
        })
        Decision(entry:, extra: checked)
      },
      fn(_, _) { Ok(Nil) },
    ),
  )
  Ok(string.join(
    list.flatten([
      [
        "Revoked "
        <> name
        <> " as entry "
        <> int.to_string(signed.entry.entry.seq)
        <> ". "
        <> checked
        <> " Enrolling the same name again restores access, and destroys "
        <> "nothing.",
      ],
      confirmations_text(signed, wait, []),
    ]),
    "\n",
  ))
}

// What a `revoke` that was not forced checks before it signs, and the sentence
// that says it passed. Three things are checked, and all are reported together
// when more than one fails, so one refusal tells the operator everything to
// decide on: the link graph after the revoke, the sessions the revoke would
// leave unreachable, which the daemon learns by asking the orchestrators it is
// linked to, and the session directory's voters, which must not fall below
// three. A daemon that cannot be asked, or an orchestrator that does not answer,
// is unknown and not empty, so it refuses too.
fn checked_revoke(
  ledger: Ledger,
  after: Ledger,
  name: String,
  daemon: Daemon,
) -> Result(String, String) {
  let links =
    list.map(ledger_operator.concerns(ledger, after), fn(concern) {
      ledger_operator.describe_concern(concern)
    })
  let strandings = case daemon.holdings() {
    Ok(answers) -> ledger_operator.strandings(ledger, name, answers)
    Error(reason) -> [ledger_operator.Unasked(reason)]
  }
  let stranded =
    list.map(strandings, fn(stranding) {
      ledger_operator.describe_stranding(name, stranding)
    })
  let voters = case ledger_operator.check_voters(ledger, after) {
    Ok(Nil) -> []
    Error(why) -> [why]
  }
  case links, stranded, voters {
    [], [], [] ->
      case membership_ledger.member(ledger, name) {
        Ok(member) ->
          Ok("Checked first: " <> ledger_operator.describe_clear(member))
        Error(Nil) -> Ok("Checked first.")
      }
    _, _, _ ->
      Error(string.join(
        list.flatten([
          refusal_section(name, "would break the link graph", links),
          refusal_section(name, "may strand sessions", stranded),
          refusal_section(name, "would leave too few directory voters", voters),
          case voters {
            [] -> []
            _ -> [wedge_warning]
          },
          ["Nothing was signed. Pass --force to revoke anyway."],
        ]),
        "
",
      ))
  }
}

fn refusal_section(
  name: String,
  heading: String,
  lines: List(String),
) -> List(String) {
  case lines {
    [] -> []
    _ -> [
      "revoking " <> name <> " " <> heading <> ":",
      ..list.map(lines, fn(line) { "  " <> line })
    ]
  }
}

// What an operator forcing a revoke below three voters needs to know before
// choosing which voter: with two voters, revoking the leader leaves a directory
// that cannot elect, and revoking the follower does not. Giving the leader the
// standing `none` by hand does the same, since the leader is then removed.
const wedge_warning =
  "With --force and two voters, revoke the follower and not the leader: revoking the leader (or giving it the standing `none` by hand) leaves a directory that cannot elect."

// The sentence of a forced revoke: nothing was looked at.
fn unchecked_text(name: String) -> String {
  "Not checked (--force): the link graph, whether "
  <> name
  <> " owns sessions or has sessions placed on it, and the directory's voters."
}

// --- log ---------------------------------------------------------------------

// Where the ledger to print is: the operator's copy, or the file that a node's
// configuration names.
fn log_source(
  parsed: Parsed,
) -> Result(#(String, membership_entry.Verifier), String) {
  case value(parsed, "--config") {
    Some(config) -> {
      use config <- result.try(bootstrap.absolute_path(config))
      use text <- result.try(read_text(config))
      use found <- result.try(
        distribution.parse(text)
        |> result.map_error(fn(reason) { config <> ": " <> reason }),
      )
      use settings <- result.try(option.to_result(
        found,
        config <> " has no [distribution] table",
      ))
      use path <- result.try(
        distribution.ledger_path(settings)
        |> option.to_result(config <> " names no ledger"),
      )
      use pem <- result.try(read_text(
        distribution.credential_files(settings).ca,
      ))
      use verifier <- result.map(
        membership_signing.verifier(pem)
        |> result.replace_error("distribution.ca is not a certificate"),
      )
      #(path, verifier)
    }
    None -> {
      use directory <- result.try(authority_directory(parsed))
      use pem <- result.try(read_text(directory <> "/ca.pem"))
      use verifier <- result.map(
        membership_signing.verifier(pem)
        |> result.map_error(fn(_) {
          directory <> "/ca.pem is not a certificate"
        }),
      )
      #(directory <> "/" <> authority_key.ledger_file, verifier)
    }
  }
}

fn log(parsed: Parsed, connect: Connect) -> Result(String, String) {
  use where_ <- result.try(where_of(parsed))
  use #(path, verifier) <- result.try(log_source(parsed))
  use opened <- result.try(
    membership_store.open(path, verifier)
    |> result.map_error(fn(_) { path <> " is not a valid ledger" }),
  )
  use entries <- result.try(
    lines_of(opened.store)
    |> list.try_map(fn(line) {
      membership_entry.read(bit_array.from_string(line), verifier)
      |> result.map_error(fn(_) { path <> " holds a line that does not verify" })
    }),
  )
  let daemon = connect(where_)
  let status = daemon.status()
  case has(parsed, "--json") {
    True -> Ok(log_json(entries, status))
    False -> Ok(log_text(entries, status, describe_where(where_)))
  }
}

fn kind_text(entry: SignedEntry) -> String {
  case entry.entry.kind {
    membership_entry.Genesis(deployment:, ..) ->
      "genesis  deployment " <> deployment
    membership_entry.Upsert(member:) ->
      "member   "
      <> member.name
      <> "  "
      <> distribution_plan.role_word(member.role)
      <> "  "
      <> member.node
      <> "  links ["
      <> string.join(member.links, ",")
      <> "]  pin "
      <> string.slice(
        bit_array.base16_encode(member.pin) |> string.lowercase,
        0,
        12,
      )
    membership_entry.Revoke(name:, reason:, ..) ->
      "revoke   "
      <> name
      <> case reason {
        "" -> ""
        text -> "  \"" <> text <> "\""
      }
  }
}

fn log_text(
  entries: List(SignedEntry),
  status: Result(ledger_control.StatusView, String),
  where_: String,
) -> String {
  let rows =
    list.map(entries, fn(entry) {
      string.pad_start(int.to_string(entry.entry.seq), 4, " ")
      <> "  "
      <> entry.entry.time
      <> "  "
      <> string.slice(membership_entry.id_to_hex(entry.id), 0, 12)
      <> "  "
      <> kind_text(entry)
    })
  let daemon_rows = case status {
    Error(reason) -> [
      "",
      "No daemon answered (" <> reason <> "), so no member's head is shown.",
    ]
    Ok(view) ->
      list.flatten([
        [
          "",
          "As reported by "
            <> where_
            <> " (head entry "
            <> int.to_string(view.head.seq)
            <> "):",
        ],
        list.map(view.members, fn(member) {
          "  "
          <> string.pad_end(member.name, 16, " ")
          <> case member.reported_seq {
            Some(seq) -> "entry " <> int.to_string(seq)
            None -> "has not reported"
          }
        }),
        case view.last_refusal {
          None -> ["Last refusal: none."]
          Some(refusal) -> [
            "Last refusal: step "
            <> refusal.step
            <> case refusal.seq {
              Some(seq) -> " at entry " <> int.to_string(seq)
              None -> ""
            }
            <> ".",
          ]
        },
      ])
  }
  string.join(list.append(rows, daemon_rows), "\n")
}

fn log_json(
  entries: List(SignedEntry),
  status: Result(ledger_control.StatusView, String),
) -> String {
  let listed =
    list.map(entries, fn(entry) {
      json.Object([
        #("seq", json.Int(entry.entry.seq)),
        #("id", json.String(membership_entry.id_to_hex(entry.id))),
        #("time", json.String(entry.entry.time)),
        #("kind", json.String(membership_entry.kind_word(entry.entry.kind))),
        #("body", json.String(bit_array_text(entry.body))),
      ])
    })
  let reported = case status {
    Error(_) -> json.Null
    Ok(view) ->
      json.Object([
        #("head", json.Int(view.head.seq)),
        #(
          "members",
          json.Array(
            list.map(view.members, fn(member) {
              json.Object([
                #("name", json.String(member.name)),
                #("reported_seq", case member.reported_seq {
                  Some(seq) -> json.Int(seq)
                  None -> json.Null
                }),
              ])
            }),
          ),
        ),
      ])
  }
  json.to_string(
    json.Object([#("entries", json.Array(listed)), #("daemon", reported)]),
  )
}

fn bit_array_text(bytes: BitArray) -> String {
  result.unwrap(bit_array.to_string(bytes), "")
}

// --- import ------------------------------------------------------------------

fn import_file(parsed: Parsed, connect: Connect) -> Result(String, String) {
  use path <- result.try(case parsed.positional {
    [path] -> Ok(path)
    _ -> Error("usage: loomd distribution import FILE")
  })
  use where_ <- result.try(where_of(parsed))
  use path <- result.try(bootstrap.absolute_path(path))
  use text <- result.try(read_text(path))
  let lines =
    string.split(text, "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" })
  use Nil <- result.try(case lines {
    [] -> Error(path <> " holds no ledger lines")
    _ -> Ok(Nil)
  })
  let daemon = connect(where_)
  use applied <- result.try(
    list.try_fold(ledger_control.pages(lines), #(0, None), fn(state, page) {
      use view <- result.map(
        daemon.append(page)
        |> result.map_error(fn(reason) {
          describe_where(where_) <> " refused the file: " <> reason
        }),
      )
      #(state.0 + view.applied, Some(view.head))
    }),
  )
  let head = case applied.1 {
    Some(head) -> head.seq
    None -> 0
  }
  Ok(
    "Applied "
    <> int.to_string(applied.0)
    <> " new entries from "
    <> path
    <> "; "
    <> describe_where(where_)
    <> " is at entry "
    <> int.to_string(head)
    <> ".",
  )
}

// --- the socket --------------------------------------------------------------

// The four ledger commands of the daemon at `where_`, each decoded.
fn socket_daemon(where_: admin.Where) -> Daemon {
  Daemon(
    status: fn() {
      call(where_, "ledger.status", [])
      |> result.try(ledger_control.decode_status)
    },
    entries: fn(after, limit) {
      call(where_, "ledger.entries", [
        #("after", json.Int(after)),
        #("limit", json.Int(limit)),
      ])
      |> result.try(ledger_control.decode_entries)
    },
    append: fn(lines) {
      call(where_, "ledger.append", [
        #("lines", json.Array(list.map(lines, json.String))),
      ])
      |> result.try(ledger_control.decode_applied)
    },
    holdings: fn() {
      call(where_, "ledger.holdings", [])
      |> result.try(ledger_control.decode_holdings)
    },
  )
}

fn call(
  where_: admin.Where,
  command: String,
  fields: List(#(String, json.JsonValue)),
) -> Result(json.JsonValue, String) {
  use request <- result.try(admin.ledger_request(where_, command, fields))
  admin.execute(request)
}
