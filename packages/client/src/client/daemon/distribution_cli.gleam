//// The operator commands that provision trusted distribution.
////
//// `loomd distribution` (and `loom distribution`, which forwards here the way
//// `loom ext` does, and `dist` for short) takes an operator from nothing to a
//// running deployment without openssl or any script. Provisioning happens
//// once, on one machine, and installing happens once per node:
////
//// 1. `init` writes an example plan.
//// 2. `provision PLAN OUT` mints the authority, the certificates and the
////    cookie, and writes one `<node>.loombundle` per node plus `system.json`.
////    It signs a membership ledger (protocol-change/086), puts it in every
////    bundle and in `OUT/ledger.log`, and seals the authority key under a
////    passphrase in `~/.loom/authority/<deployment id>` so that the ledger can
////    be extended. `--static` writes the older bundles that list their peers
////    and discards the key.
//// 3. The operator copies each bundle, over a channel they trust, to the
////    machine that runs that node.
//// 4. `install BUNDLE` on that machine puts the node in its role.
//// 5. `enroll`, `revoke`, `renew`, `log` and `import` (`client/daemon/ledger_cli`)
////    change and read the ledger afterwards, from the operator's machine.
////
//// `options` is the step the daemon needs before it can boot: the VM is booted
//// with TLS distribution flags before any Gleam code runs, so the options file
//// has to exist before the daemon does. It renders that file from the same
//// `[distribution]` table the daemon will read, using the same function the
//// daemon uses to check it at startup, so the two cannot disagree. `install`
//// does it as part of its work. The `bin/loomd` launcher then adds the boot
//// flags when `LOOM_DISTRIBUTION_OPTFILE` names the file.
////
//// The options file holds credential paths and public pins and no secret. It
//// is written with mode 0600 anyway, because the daemon refuses an options file
//// that other users can write.
////
//// No command prints a key, a cookie or any certificate. A bundle holds the
//// first two, and its path is all a command says about it.

import client/authority_key
import client/daemon/ledger_cli
import client/distribution
import client/distribution_bundle
import client/distribution_install.{Options}
import client/distribution_plan
import client/distribution_provision.{
  type Overwrite, RefuseExisting, ReplaceExisting,
}
import client/internal/ffi_os
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import simplifile

/// Complete help for the distribution operator command.
pub const usage =
  "usage: loom distribution <command>   (also: loomd distribution, and `dist` for short)

Provision a trusted Erlang distribution between Loom daemons with one plan, one
file per machine, and one command on each machine. No openssl is needed. The
deployment's membership is a signed ledger, so `enroll`, `revoke` and `renew`
change it later without provisioning the other nodes again.

commands:
  init [PATH]                     Write an example plan (default
                                  distribution-plan.toml). Refuses to overwrite.
  provision PLAN OUT [--force] [--drop-authority] [--passphrase-file PATH]
            [--home DIR] [--static]
                                  Read PLAN (.toml or .json), mint the CA, the
                                  node certificates and the shared cookie, and
                                  write OUT/<node>.loombundle (mode 0600) for
                                  each node plus OUT/system.json (no secrets).
                                  The bundles carry a signed membership ledger
                                  (also written to OUT/ledger.log), and the CA
                                  key is sealed under a passphrase in
                                  DIR/.loom/authority/<deployment id> (DIR
                                  defaults to $HOME) so that the ledger can be
                                  extended. The passphrase is asked for twice on
                                  the terminal, or read from PATH, a file only
                                  you can read. --drop-authority keeps no key,
                                  and the ledger can then never change. Only
                                  `loomd distribution provision` can ask on the
                                  terminal; `loom distribution provision` needs
                                  --passphrase-file or --drop-authority.
                                  --static writes the older bundles instead:
                                  each lists its peers' pins, the key is
                                  discarded, and adding a node means
                                  provisioning again. Refuses a non-empty OUT
                                  without --force.
  show OUT                        Print OUT/system.json as a table.
  install BUNDLE [--home DIR] [--config PATH] [--force]
                                  Run on the node's machine. Installs the
                                  credentials, the cookie at DIR/.erlang.cookie
                                  (default $HOME), the [distribution] and role
                                  tables in PATH (default DIR/.loom/loom.toml)
                                  and the TLS options file, then prints the
                                  command that starts the daemon. A ledger
                                  bundle also writes the ledger beside the
                                  credentials, and the node trusts that snapshot
                                  until it syncs with a peer that holds more.
                                  Running it again with the same bundle changes
                                  nothing. A different existing cookie,
                                  credential file or table is refused unless
                                  --force.
  enroll NAME --node N --role orchestrator|executor [--host H] [--port P]
         [--links A,B] [--workspace NAME=ROOT]... [--bundle-dir DIR]
         [--out DIR] [--force] [--wait SECONDS] [COMMON]
                                  Run on the operator's machine. Mints a
                                  certificate for N under the kept authority,
                                  signs a `member` entry, appends it to the
                                  operator's copy of the ledger, hands it to a
                                  daemon, writes OUT/NAME.loombundle (default
                                  OUT: the current directory) and prints which
                                  members hold the new head, after at most
                                  SECONDS (default 10). --links names the
                                  members NAME may connect to; an executor
                                  needs at least one orchestrator there, and
                                  --workspace to serve anything.
  revoke NAME [--reason TEXT] [--force] [--wait SECONDS] [COMMON]
                                  Signs a `revoke`, hands it to a daemon and
                                  prints confirmations. Refuses when the revoke
                                  would leave an executor with no orchestrator
                                  linked to it, or cut members off from the
                                  rest, unless --force. It does not check
                                  whether NAME owns sessions: a daemon cannot
                                  ask another.
  renew NAME [--bundle-dir DIR] [--out DIR] [--force] [--wait SECONDS]
         [COMMON]
                                  Mints a new certificate for a member, signs a
                                  `member` entry with the new pin and writes a
                                  new bundle. Install it with --force on the
                                  node and restart the daemon. Connections to
                                  the node are dropped when the entry is
                                  applied. Give the same --bundle-dir the node
                                  was enrolled with, so the bundle installs
                                  over its credentials in place.
  log [--json] [--config PATH] [COMMON]
                                  Print the ledger's entries with their
                                  identities, then the last refusal and each
                                  member's reported head when a daemon answers.
                                  Reads the operator's copy, or the ledger that
                                  the [distribution] table of PATH names.
  import FILE [--state-dir DIR | --addr URL --token-file PATH]
                                  Feed the lines of a ledger file to the local
                                  daemon, for a node nothing else can reach.
  options CONFIG OUTPUT           Render the TLS distribution options file for
                                  the [distribution] table of CONFIG (mode
                                  0600). `install` does this for you.

COMMON is [--home DIR] [--deployment ID] [--passphrase-file PATH]
[--state-dir DIR | --addr URL --token-file PATH]. The key is found under
DIR/.loom/authority (DIR defaults to $HOME); --deployment picks one when
several are kept. The passphrase is asked for on the terminal, which only
`loomd distribution` can do; `loom distribution enroll`, `revoke` and `renew`
need --passphrase-file. The daemon is the one on this host, found through its
state directory (default $HOME/.loom), unless --addr names another.

A .loombundle holds the node's private key and the deployment's cookie. Copy it
to its machine over a channel you trust, and delete it there after installing.

Example:
  loom dist init plan.toml
  loom dist provision plan.toml out --passphrase-file ~/.loom-passphrase
  scp out/devbox.loombundle devbox:
  ssh devbox loom dist install devbox.loombundle
  loom dist enroll laptop2 --node loom@laptop2.example --role orchestrator --links devbox --passphrase-file ~/.loom-passphrase"

/// Runs the command and exits nonzero with a one-line reason when it fails.
///
/// ## Examples
///
/// ```gleam
/// // loomd distribution provision plan.toml out
/// ```
pub fn main(arguments: List(String)) -> Nil {
  case run(arguments) {
    Ok("") -> Nil
    Ok(text) -> io.println(text)
    Error(reason) -> {
      io.println_error("loomd: " <> reason)
      ffi_os.halt(1)
    }
  }
}

/// Runs one command and returns what it prints. The only effects are the files
/// the command exists to write, and a command that is refused has written none
/// of them.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(distribution_cli.run(["install"]))
/// ```
pub fn run(arguments: List(String)) -> Result(String, String) {
  case arguments {
    ["options", ..] -> write_options(arguments) |> result.replace("")
    ["init", ..rest] -> init(rest)
    ["provision", ..rest] -> provision(rest)
    ["show", ..rest] -> show(rest)
    ["install", ..rest] -> install(rest)
    [word, ..rest] ->
      case ledger_cli.is_ledger_command(word) {
        True -> ledger_cli.run(word, rest)
        False -> Error(usage)
      }
    [] -> Error(usage)
  }
}

/// Writes the options file for `options CONFIG OUTPUT`.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(distribution_cli.write_options(["options"]))
/// ```
pub fn write_options(arguments: List(String)) -> Result(Nil, String) {
  case arguments {
    ["options", config, output] -> {
      use config <- result.try(bootstrap.absolute_path(config))
      use output <- result.try(bootstrap.absolute_path(output))
      use text <- result.try(
        simplifile.read(config)
        |> result.map_error(fn(error) {
          config <> " is unreadable: " <> simplifile.describe_error(error)
        }),
      )
      use found <- result.try(
        distribution.parse(text)
        |> result.map_error(fn(reason) { config <> ": " <> reason }),
      )
      use settings <- result.try(case found {
        Some(settings) -> Ok(settings)
        None -> Error(config <> " has no [distribution] table")
      })
      use Nil <- result.try(
        simplifile.write(output, distribution.tls_options(settings))
        |> result.map_error(fn(error) {
          output <> " is unwritable: " <> simplifile.describe_error(error)
        }),
      )
      simplifile.set_permissions_octal(output, 0o600)
      |> result.map_error(fn(error) {
        output
        <> " cannot be made private: "
        <> simplifile.describe_error(error)
      })
    }
    _ -> Error(usage)
  }
}

// --- init --------------------------------------------------------------------

fn init(arguments: List(String)) -> Result(String, String) {
  use path <- result.try(case arguments {
    [] -> Ok("distribution-plan.toml")
    [path] -> Ok(path)
    _ -> Error(usage)
  })
  use path <- result.try(bootstrap.absolute_path(path))
  use Nil <- result.try(case bootstrap.path_exists(path) {
    True -> Error(path <> " already exists; init never overwrites a plan")
    False -> Ok(Nil)
  })
  use Nil <- result.try(
    simplifile.write(path, distribution_plan.example)
    |> result.map_error(fn(error) {
      path <> " is unwritable: " <> simplifile.describe_error(error)
    }),
  )
  Ok(
    "wrote "
    <> path
    <> "\nEdit it, then run: loom distribution provision "
    <> path
    <> " OUT",
  )
}

// --- provision ---------------------------------------------------------------

fn provision(arguments: List(String)) -> Result(String, String) {
  use parsed <- result.try(parse_flags(arguments))
  use parsed <- result.try(check_provision_home(parsed))
  use #(plan_path, output) <- result.try(case parsed.positional {
    [plan, output] -> Ok(#(plan, output))
    _ -> Error(usage)
  })
  use plan_path <- result.try(bootstrap.absolute_path(plan_path))
  use output <- result.try(bootstrap.absolute_path(output))
  use format <- result.try(distribution_plan.format_of(plan_path))
  use text <- result.try(
    simplifile.read(plan_path)
    |> result.map_error(fn(error) {
      plan_path <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use plan <- result.try(
    distribution_plan.parse(text, format)
    |> result.map_error(fn(reason) { plan_path <> ": " <> reason }),
  )
  case parsed.mode {
    StaticMode -> provision_static(plan, output, parsed)
    LedgerMode -> provision_ledger(plan, output, parsed)
  }
}

fn provision_static(
  plan: distribution_plan.Plan,
  output: String,
  parsed: Parsed,
) -> Result(String, String) {
  use deployment <- result.try(distribution_provision.provision(plan))
  use _written <- result.try(distribution_provision.write(
    deployment,
    output,
    parsed.overwrite,
  ))
  Ok(provisioned(deployment, output, static_closing))
}

const static_closing =
  "The CA key was discarded. To add or renew a node, provision again."

// Ledger mode. The order leaves nothing half done. The output directory and
// the passphrase are checked before a key exists, and the sealed key is written
// before the bundles: a sealed key with no bundles is clutter, and bundles
// whose ledger can never be extended are the worse failure.
fn provision_ledger(
  plan: distribution_plan.Plan,
  output: String,
  parsed: Parsed,
) -> Result(String, String) {
  use Nil <- result.try(case plan.directory {
    [] -> Ok(Nil)
    _ ->
      Error(
        "this plan has a session directory, which cannot follow a membership "
        <> "ledger yet (its members come from [directory] members until phase "
        <> "3 of protocol-change/086); pass --static to provision it with a "
        <> "peer list",
      )
  })
  use Nil <- result.try(distribution_provision.check_output(
    output,
    parsed.overwrite,
  ))
  use sealing <- result.try(case parsed.custody {
    DropAuthority -> Ok(None)
    KeepAuthority -> {
      use passphrase <- result.try(read_passphrase(parsed.passphrase_file))
      use home <- result.try(case parsed.home {
        Some(home) -> bootstrap.absolute_path(home)
        None ->
          bootstrap.getenv("HOME")
          |> result.replace_error("HOME is unset; pass --home DIR")
      })
      Ok(Some(#(passphrase, home)))
    }
  })
  use made <- result.try(distribution_provision.provision_ledger(
    plan,
    timestamp.system_time(),
  ))
  let deployment = made.deployment
  use closing <- result.try(case sealing {
    None -> Ok(dropped_closing)
    Some(#(passphrase, home)) ->
      keep_authority(home, made, passphrase)
      |> result.map(kept_closing)
  })
  use _written <- result.try(distribution_provision.write(
    deployment,
    output,
    parsed.overwrite,
  ))
  Ok(provisioned(deployment, output, closing))
}

const dropped_closing =
  "The authority key was discarded. This ledger can never be extended."

fn kept_closing(directory: String) -> String {
  "The authority key is sealed in "
  <> directory
  <> ". Keep its passphrase: without the key and the passphrase this ledger "
  <> "cannot be extended. Add, replace and remove nodes with `loom "
  <> "distribution enroll`, `renew` and `revoke`."
}

// Seals the key and keeps the certificate and the operator's copy of the
// ledger beside it. Returns the directory.
fn keep_authority(
  home: String,
  provisioned: distribution_provision.Provisioned,
  passphrase: authority_key.Passphrase,
) -> Result(String, String) {
  let authority = provisioned.authority
  let directory = authority_key.default_directory(home, authority.deployment)
  authority_key.keep(
    directory,
    authority_key.Kept(
      deployment: authority.deployment,
      key: authority.key,
      certificate: authority.certificate,
      ledger: provisioned.ledger,
      cookie: authority.cookie,
    ),
    passphrase,
  )
  |> result.replace(directory)
  |> result.map_error(authority_key.describe)
}

fn read_passphrase(
  file: Option(String),
) -> Result(authority_key.Passphrase, String) {
  case file {
    Some(path) -> {
      use path <- result.try(bootstrap.absolute_path(path))
      authority_key.passphrase_from_file(path)
      |> result.map_error(authority_key.describe)
    }
    None ->
      authority_key.passphrase_from_terminal(authority_key.AskTwice)
      |> result.map_error(authority_key.describe)
  }
}

fn provisioned(
  deployment: distribution_provision.Deployment,
  output: String,
  closing: String,
) -> String {
  let rows =
    list.map(deployment.system.nodes, fn(node) {
      "  "
      <> output
      <> "/"
      <> node.name
      <> distribution_provision.bundle_extension
      <> "  "
      <> distribution_plan.role_word(node.role)
      <> "  "
      <> node.erlang_node
    })
  string.join(
    list.flatten([
      [
        "Provisioned "
        <> int.to_string(list.length(deployment.bundles))
        <> " nodes into "
        <> output
        <> ":",
      ],
      rows,
      [
        "  " <> output <> "/" <> distribution_provision.system_file,
      ],
      case deployment.ledger {
        Some(_) -> ["  " <> output <> "/" <> distribution_bundle.ledger_file]
        None -> []
      },
      [
        "",
        "Each .loombundle holds that node's private key and the deployment's "
          <> "cookie. Copy each one to its machine over a channel you trust, "
          <> "then run on that machine:",
        "  loom distribution install <node>.loombundle",
        closing,
      ],
    ]),
    "\n",
  )
}

// --- show --------------------------------------------------------------------

fn show(arguments: List(String)) -> Result(String, String) {
  use target <- result.try(case arguments {
    [target] -> Ok(target)
    _ -> Error(usage)
  })
  use target <- result.try(bootstrap.absolute_path(target))
  let path = case string.ends_with(target, ".json") {
    True -> target
    False -> target <> "/" <> distribution_provision.system_file
  }
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(error) {
      path <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use system <- result.try(
    distribution_provision.system_from_json(text)
    |> result.map_error(fn(reason) { path <> ": " <> reason }),
  )
  Ok(distribution_provision.render(system))
}

// --- install -----------------------------------------------------------------

fn install(arguments: List(String)) -> Result(String, String) {
  use parsed <- result.try(parse_flags(arguments))
  use Nil <- result.try(
    case parsed.mode, parsed.custody, parsed.passphrase_file {
      LedgerMode, KeepAuthority, None -> Ok(Nil)
      _, _, _ ->
        Error(
          "--static, --drop-authority and --passphrase-file belong to provision",
        )
    },
  )
  use bundle_path <- result.try(case parsed.positional {
    [path] -> Ok(path)
    _ -> Error(usage)
  })
  use bundle_path <- result.try(bootstrap.absolute_path(bundle_path))
  use home <- result.try(case parsed.home {
    Some(home) -> bootstrap.absolute_path(home)
    None ->
      bootstrap.getenv("HOME")
      |> result.replace_error("HOME is unset; pass --home DIR")
  })
  use config <- result.try(case parsed.config {
    Some(config) -> bootstrap.absolute_path(config)
    None -> Ok(distribution_install.default_config(home))
  })
  use text <- result.try(
    simplifile.read(bundle_path)
    |> result.map_error(fn(error) {
      bundle_path <> " is unreadable: " <> simplifile.describe_error(error)
    }),
  )
  use installed <- result.try(
    distribution_install.install(
      text,
      Options(home:, config:, overwrite: parsed.overwrite),
    )
    |> result.map_error(fn(reason) { bundle_path <> ": " <> reason }),
  )
  Ok(installed_text(installed))
}

fn installed_text(installed: distribution_install.Installed) -> String {
  let bundle = installed.bundle
  let steps =
    list.map(installed.steps, fn(step) {
      "  "
      <> string.pad_end(outcome_word(step.outcome), 10, " ")
      <> string.pad_end(step.what, 24, " ")
      <> step.path
    })
  string.join(
    list.flatten([
      [
        "Installed "
        <> bundle.name
        <> " ("
        <> distribution_plan.role_word(bundle.role)
        <> ", "
        <> bundle.erlang_node
        <> ")",
      ],
      steps,
      snapshot_lines(installed.snapshot),
      [
        "",
        "Start the daemon with:",
        "  " <> installed.start,
        "",
        "You can delete the .loombundle now; it held the key and the cookie.",
      ],
    ]),
    "\n",
  )
}

// A ledger bundle is a snapshot. The node trusts what it says until it meets a
// peer that holds more, so the operator is told how old it is.
fn snapshot_lines(
  snapshot: Option(distribution_install.Snapshot),
) -> List(String) {
  case snapshot {
    None -> []
    Some(snapshot) -> [
      "",
      "This node trusts the ledger as of entry "
        <> int.to_string(snapshot.seq)
        <> " ("
        <> snapshot.time
        <> ") until it syncs with a peer that holds more.",
    ]
  }
}

fn outcome_word(outcome: distribution_install.Outcome) -> String {
  case outcome {
    distribution_install.Created -> "created"
    distribution_install.Unchanged -> "unchanged"
    distribution_install.Replaced -> "replaced"
    distribution_install.Merged -> "merged"
  }
}

// --- flags -------------------------------------------------------------------

// How a deployment says who is trusted: a signed ledger, which is the default,
// or a peer list in every bundle (`--static`).
type Mode {
  StaticMode
  LedgerMode
}

// Whether `provision` keeps the authority key it minted. A ledger can only be
// extended by whoever holds the key.
type Custody {
  KeepAuthority
  DropAuthority
}

type Parsed {
  Parsed(
    positional: List(String),
    overwrite: Overwrite,
    home: Option(String),
    config: Option(String),
    mode: Mode,
    custody: Custody,
    passphrase_file: Option(String),
  )
}

// The flags may come before, between or after the positional words, as they do
// in every other `loomd` command.
fn parse_flags(arguments: List(String)) -> Result(Parsed, String) {
  use parsed <- result.try(parse_flags_loop(
    arguments,
    Parsed([], RefuseExisting, None, None, LedgerMode, KeepAuthority, None),
  ))
  check_ledger_flags(parsed)
}

// The flags that shape a ledger mean nothing in static mode. A request to drop a
// key that static mode never keeps, or to read a passphrase for a key that is
// not kept, is a mistake to name and not a flag to ignore.
fn check_ledger_flags(parsed: Parsed) -> Result(Parsed, String) {
  case parsed.mode, parsed.custody, parsed.passphrase_file {
    StaticMode, DropAuthority, _ ->
      Error("--drop-authority cannot be combined with --static: no key is kept")
    StaticMode, _, Some(_) ->
      Error(
        "--passphrase-file cannot be combined with --static: no key is kept",
      )
    LedgerMode, DropAuthority, Some(_) ->
      Error(
        "--passphrase-file and --drop-authority cannot be combined: "
        <> "no key is sealed",
      )
    _, _, _ -> Ok(parsed)
  }
}

// `--home` is `install`'s flag too, so `parse_flags` cannot refuse it. In
// `provision` only ledger mode reads it, to place the sealed key. Static mode
// writes nothing under a home directory, so the flag would be accepted and
// silently do nothing.
fn check_provision_home(parsed: Parsed) -> Result(Parsed, String) {
  case parsed.mode, parsed.home {
    StaticMode, Some(_) ->
      Error("--home cannot be combined with --static: no key is kept")
    _, _ -> Ok(parsed)
  }
}

fn parse_flags_loop(
  arguments: List(String),
  parsed: Parsed,
) -> Result(Parsed, String) {
  case arguments {
    [] -> Ok(Parsed(..parsed, positional: list.reverse(parsed.positional)))
    ["--force", ..rest] ->
      parse_flags_loop(rest, Parsed(..parsed, overwrite: ReplaceExisting))
    ["--home", value, ..rest] ->
      parse_flags_loop(rest, Parsed(..parsed, home: Some(value)))
    ["--config", value, ..rest] ->
      parse_flags_loop(rest, Parsed(..parsed, config: Some(value)))
    ["--passphrase-file", value, ..rest] ->
      parse_flags_loop(rest, Parsed(..parsed, passphrase_file: Some(value)))
    ["--static", ..rest] ->
      parse_flags_loop(rest, Parsed(..parsed, mode: StaticMode))
    ["--drop-authority", ..rest] ->
      parse_flags_loop(rest, Parsed(..parsed, custody: DropAuthority))
    ["--home"] -> Error("--home needs a value")
    ["--config"] -> Error("--config needs a value")
    ["--passphrase-file"] -> Error("--passphrase-file needs a value")
    [word, ..rest] ->
      case string.starts_with(word, "--") {
        True -> Error("unknown option " <> word)
        False ->
          parse_flags_loop(
            rest,
            Parsed(..parsed, positional: [word, ..parsed.positional]),
          )
      }
  }
}
