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
//// 3. The operator copies each bundle, over a channel they trust, to the
////    machine that runs that node.
//// 4. `install BUNDLE` on that machine puts the node in its role.
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

import client/distribution
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
import host/bootstrap
import simplifile

/// Complete help for the distribution operator command.
pub const usage =
  "usage: loom distribution <command>   (also: loomd distribution, and `dist` for short)

Provision a trusted Erlang distribution between Loom daemons with one plan, one
file per machine, and one command on each machine. No openssl is needed.

commands:
  init [PATH]                     Write an example plan (default
                                  distribution-plan.toml). Refuses to overwrite.
  provision PLAN OUT [--force]    Read PLAN (.toml or .json), mint the CA, the
                                  node certificates and the shared cookie, and
                                  write OUT/<node>.loombundle (mode 0600) for
                                  each node plus OUT/system.json (no secrets).
                                  Refuses a non-empty OUT without --force.
  show OUT                        Print OUT/system.json as a table.
  install BUNDLE [--home DIR] [--config PATH] [--force]
                                  Run on the node's machine. Installs the
                                  credentials, the cookie at DIR/.erlang.cookie
                                  (default $HOME), the [distribution] and role
                                  tables in PATH (default DIR/.loom/loom.toml)
                                  and the TLS options file, then prints the
                                  command that starts the daemon. Running it
                                  again with the same bundle changes nothing.
                                  A different existing cookie, credential file
                                  or table is refused unless --force.
  options CONFIG OUTPUT           Render the TLS distribution options file for
                                  the [distribution] table of CONFIG (mode
                                  0600). `install` does this for you.

A .loombundle holds the node's private key and the deployment's cookie. Copy it
to its machine over a channel you trust, and delete it there after installing.

Example:
  loom dist init plan.toml
  loom dist provision plan.toml out
  scp out/devbox.loombundle devbox:
  ssh devbox loom dist install devbox.loombundle"

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
    _ -> Error(usage)
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
  use deployment <- result.try(distribution_provision.provision(plan))
  use _written <- result.try(distribution_provision.write(
    deployment,
    output,
    parsed.overwrite,
  ))
  Ok(provisioned(deployment, output))
}

fn provisioned(
  deployment: distribution_provision.Deployment,
  output: String,
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
        "",
        "Each .loombundle holds that node's private key and the deployment's "
          <> "cookie. Copy each one to its machine over a channel you trust, "
          <> "then run on that machine:",
        "  loom distribution install <node>.loombundle",
        "The CA key was discarded. To add or renew a node, provision again.",
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

fn outcome_word(outcome: distribution_install.Outcome) -> String {
  case outcome {
    distribution_install.Created -> "created"
    distribution_install.Unchanged -> "unchanged"
    distribution_install.Replaced -> "replaced"
    distribution_install.Merged -> "merged"
  }
}

// --- flags -------------------------------------------------------------------

type Parsed {
  Parsed(
    positional: List(String),
    overwrite: Overwrite,
    home: Option(String),
    config: Option(String),
  )
}

// The flags may come before, between or after the positional words, as they do
// in every other `loomd` command.
fn parse_flags(arguments: List(String)) -> Result(Parsed, String) {
  parse_flags_loop(arguments, Parsed([], RefuseExisting, None, None))
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
    ["--home"] -> Error("--home needs a value")
    ["--config"] -> Error("--config needs a value")
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
