//// The updater is a terminal command with no interactive-session admission.
//// It resolves and verifies a release, stages complete trees, publishes them
//// through the existing installer, then performs authenticated daemon restart.
//// Old installed trees are retained because live processes may still use them.

import gleam/bool
import gleam/erlang/application
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import host/bootstrap as host
import host/endpoint
import simplifile
import tui/bootstrap
import tui/daemon
import tui/update/files
import tui/update/lifecycle
import tui/update/manifest
import tui/update/options
import tui/update/source
import tui/update/version

/// Runs a parsed update with an injected bounded download implementation.
///
/// The temporary directory is always private and exclusively created. Cleanup
/// touches only that directory; published installations and their predecessors
/// are never removed, even if a later restart fails.
///
/// ## Examples
///
/// ```gleam
/// // update.run(choices, "linux-arm64", "/tmp", fetch)
/// ```
pub fn run(
  choices: options.Options,
  platform: String,
  temporary_parent: String,
  fetch: source.Fetch,
) -> Result(Nil, String) {
  use <- bool.guard(
    !list.contains(
      ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64"],
      platform,
    ),
    Error("this client lacks a supported native build platform"),
  )
  use stage <- result.try(files.staging(temporary_parent))
  let outcome = staged(choices, platform, stage, fetch)
  let _cleanup = simplifile.delete(stage)
  outcome
}

fn staged(choices: options.Options, platform, stage, fetch) {
  use release <- result.try(source.resolve(choices, platform, stage, fetch))
  io.println(
    "Selected "
    <> release.manifest.tag
    <> " ("
    <> release.manifest.commit
    <> ") for "
    <> platform,
  )
  case release.signature {
    source.Present ->
      io.println(
        "Release manifest signature verified with the supplied local keyring.",
      )
    source.Absent ->
      io.println(
        "Release manifest is unsigned; artifact SHA-256 checks remain mandatory.",
      )
  }
  case choices.action {
    options.Check -> Ok(Nil)
    options.Update | options.InstallOnly ->
      install(choices, release, stage, fetch)
  }
}

fn install(choices: options.Options, release: source.Release, stage, fetch) {
  use Nil <- result.try(case choices.selection {
    options.Latest ->
      version.allow_latest(
        host.getenv("LOOM_BUILD_VERSION") |> result.unwrap(""),
        release.manifest.version,
      )
    options.Tag(_) | options.Commit(_) -> Ok(Nil)
  })
  use prefix <- result.try(installation_prefix(choices.prefix))
  use client <- result.try(client_shape(choices.client, prefix))
  let library = prefix <> "/lib/loom"
  use Nil <- result.try(
    simplifile.create_directory_all(library)
    |> result.replace_error("cannot create installation directory"),
  )
  use lock <- result.try(host.try_launch_lock(library <> "/update.lock"))
  let outcome = install_locked(choices, release, stage, fetch, prefix, client)
  host.release_launch_lock(lock)
  outcome
}

fn install_locked(
  choices: options.Options,
  release: source.Release,
  stage,
  fetch,
  prefix,
  client,
) {
  use server <- result.try(component(release.manifest, "server"))
  let selected_client = case client {
    "slim" -> "slim"
    _ -> "client"
  }
  use terminal <- result.try(component(release.manifest, selected_client))
  use Nil <- result.try(stage_component(
    release.base,
    server,
    stage,
    stage <> "/build/release/loom",
    fetch,
  ))
  let destination = case client {
    "slim" -> stage <> "/slim"
    _ -> stage <> "/build/release/loom-client"
  }
  use Nil <- result.try(stage_component(
    release.base,
    terminal,
    stage,
    destination,
    fetch,
  ))
  use Nil <- result.try(prepare_slim(client, stage))
  let daemon_options =
    bootstrap.Options(
      "",
      "",
      prefix <> "/bin/loomd",
      choices.state,
      choices.config,
    )
  case choices.action {
    options.InstallOnly -> files.publish(stage, prefix, client)
    options.Update ->
      restart_install(
        choices,
        daemon_options,
        release.manifest.commit,
        stage,
        prefix,
        client,
      )
    options.Check -> Error("check-only update reached installation")
  }
}

fn restart_install(
  choices: options.Options,
  daemon_options,
  commit,
  stage,
  prefix,
  client,
) {
  use state <- result.try(state_directory(choices.state))
  use paths <- result.try(endpoint.paths(state))
  use previous <- result.try(lifecycle.capture(paths))
  let installed = files.publish(stage, prefix, client)
  case installed {
    Ok(Nil) -> {
      io.println("Release installed; gracefully restarting the shared daemon.")
      lifecycle.restart(previous, daemon_options, commit)
    }
    Error(reason) -> {
      case previous {
        None -> Nil
        option.Some(connected) -> daemon.close(connected.control)
      }
      Error(reason)
    }
  }
}

fn component(document: manifest.Manifest, name) {
  list.find(document.artifacts, fn(artifact) { artifact.component == name })
  |> result.replace_error("release lacks the selected component")
}

fn stage_component(
  base,
  artifact: manifest.Artifact,
  stage,
  destination,
  fetch,
) {
  let path = stage <> "/" <> artifact.name
  use presence <- result.try(source.acquire(
    base <> "/" <> artifact.name,
    path,
    artifact.size,
    fetch,
  ))
  use <- bool.guard(
    presence == source.Absent,
    Error("release artifact is missing: " <> artifact.name),
  )
  files.unpack(path, artifact, destination)
}

fn prepare_slim(client, stage) {
  case client {
    "slim" ->
      simplifile.rename(
        stage <> "/slim/build/tui-erlang-shipment",
        stage <> "/build/tui-erlang-shipment",
      )
      |> result.replace_error("cannot prepare slim client installation")
    _ -> Ok(Nil)
  }
}

fn installation_prefix(explicit) {
  case explicit {
    "" ->
      case host.getenv("LOOM_INSTALL_PREFIX") {
        Ok(prefix) -> host.absolute_path(prefix)
        Error(_) -> infer_prefix()
      }
    prefix -> host.absolute_path(prefix)
  }
}

fn infer_prefix() {
  use executable <- result.try(
    host.getenv("LOOM_EXECUTABLE")
    |> result.replace_error("unmanaged client: specify --prefix"),
  )
  use <- bool.guard(
    !string.ends_with(executable, "/bin/loom"),
    Error("cannot infer install prefix; specify --prefix"),
  )
  let prefix = string.drop_end(executable, 9)
  use <- bool.guard(
    !host.path_exists(prefix <> "/lib/loom/server"),
    Error("unmanaged client: specify --prefix"),
  )
  host.absolute_path(prefix)
}

fn client_shape(explicit, prefix) {
  let selected = case explicit {
    "" -> host.getenv("LOOM_INSTALL_CLIENT") |> result.unwrap("")
    client -> client
  }
  case selected {
    "bundled" | "slim" -> Ok(selected)
    "" -> infer_client_shape(prefix)
    _ -> Error("installed client shape must be bundled or slim")
  }
}

fn state_directory(explicit) {
  case explicit {
    "" -> {
      use home <- result.try(
        host.getenv("HOME") |> result.replace_error("HOME is not set"),
      )
      host.absolute_path(home <> "/.loom")
    }
    path -> host.absolute_path(path)
  }
}

fn infer_client_shape(prefix) {
  let private =
    application.priv_directory("tui")
    |> result.replace_error("missing client private directory")
    |> result.try(host.canonical_path)
    |> result.unwrap("")
  case string.starts_with(private, prefix <> "/lib/loom/tui.") {
    True -> Ok("slim")
    False ->
      case string.starts_with(private, prefix <> "/lib/loom/client.") {
        True -> Ok("bundled")
        False ->
          case
            host.path_exists(prefix <> "/lib/loom/client"),
            host.path_exists(prefix <> "/lib/loom/tui")
          {
            True, True ->
              Error(
                "both client shapes exist; specify --client for this unmanaged invocation",
              )
            False, True -> Ok("slim")
            _, _ -> Ok("bundled")
          }
      }
  }
}
