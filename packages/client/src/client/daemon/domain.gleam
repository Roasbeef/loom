//// One admitted domain owns shared recall and maintenance, not its sessions.
////
//// The manager retains this host's original custody witness before beginning
//// construction. Each parked child publishes cleanup before startup links are
//// transferred and effects begin. Session shutdown cannot close these shared
//// resources; the last dependency quiesces maintenance before host retirement.

import client/distillpass
import client/history
import client/internal/instance_owner as custody
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import weft/registry as address

/// The concrete capabilities shared by sessions in one retained domain slot.
@internal
pub opaque type Services {
  Services(
    history: Option(history.Shared),
    cadence: Option(address.Address(distillpass.DomainMessage)),
    roots: List(#(String, process.Pid)),
  )
}

/// Domain-owned configuration, resolved independently from session settings.
@internal
pub type Config {
  Config(
    /// Exact index path and fresh bounded source authorization.
    history: history.SharedConfig,
    /// Resolves the optional maintenance child under its own namespace.
    maintenance: fn(address.Address(distillpass.DomainMessage)) ->
      Result(Option(distillpass.DomainConfig), String),
  )
}

/// Builds shared children only after their cleanup capabilities are retained.
///
/// ## Examples
///
/// ```gleam
/// // domain.build(config, owner)
/// ```
@internal
pub fn build(config: Config, owner: custody.Owner) -> Result(Services, String) {
  use namespace <- result.try(
    address.start() |> result.map_error(string.inspect),
  )
  use Nil <- result.try(
    custody.publish(owner, custody.Namespace, fn() { address.stop(namespace) }),
  )
  process.unlink(address.owner(namespace))
  use prepared <- result.try(history.prepare_shared(config.history))
  use Nil <- result.try(custody.publish(
    owner,
    custody.Services,
    prepared.retire,
  ))
  process.unlink(prepared.pid)
  use shared <- result.try(prepared.begin())

  let name = address.new_address(namespace)
  use maintenance <- result.try(config.maintenance(name))
  use cadence <- result.try(start_maintenance(maintenance, owner))
  let roots = case cadence {
    None -> [#("history", prepared.pid)]
    Some(started) -> [#("history", prepared.pid), #("maintenance", started)]
  }
  Ok(Services(Some(shared), option_name(cadence, name), roots))
}

fn option_name(cadence, name) {
  case cadence {
    None -> None
    Some(_) -> Some(name)
  }
}

fn start_maintenance(
  config: Option(distillpass.DomainConfig),
  owner: custody.Owner,
) {
  case config {
    None -> Ok(None)
    Some(config) -> {
      use started <- result.try(
        distillpass.prepare_domain(config) |> result.map_error(string.inspect),
      )
      use Nil <- result.try(
        custody.publish(owner, custody.Runtime, fn() {
          distillpass.stop_domain(config.name, waiting_ms: 5000)
        }),
      )
      process.unlink(started.pid)
      distillpass.begin_domain(started.data)
      Ok(Some(started.pid))
    }
  }
}

/// Returns original fatal roots; a replacement must not hide lost custody.
///
/// ## Examples
///
/// ```gleam
/// // domain.children(services)
/// ```
@internal
pub fn children(services: Services) -> List(#(String, process.Pid)) {
  services.roots
}

/// Returns the shared history capability without exposing its database handle.
///
/// ## Examples
///
/// ```gleam
/// // domain.history(services)
/// ```
@internal
pub fn history(services: Services) -> Option(history.Shared) {
  services.history
}

/// Coalesces a notification only after the session's original custody retired.
///
/// ## Examples
///
/// ```gleam
/// // domain.notify_closed(services)
/// ```
@internal
pub fn notify_closed(services: Services) -> Result(Nil, String) {
  case services.cadence {
    None -> Ok(Nil)
    Some(name) -> distillpass.notify_domain(name)
  }
}

/// Waits for all previously coalesced work without blocking the registry.
/// The actor remains alive so the original custody cleanup performs its stop.
///
/// ## Examples
///
/// ```gleam
/// // domain.quiesce(services, reply)
/// ```
@internal
pub fn quiesce(
  services: Services,
  reply: process.Subject(distillpass.Pass),
) -> Result(Nil, String) {
  case services.cadence {
    None -> {
      process.send(
        reply,
        distillpass.Refused("maintenance explicitly disabled"),
      )
      Ok(Nil)
    }
    Some(name) -> distillpass.request_quiesce(name, reply)
  }
}

/// Lifts the fence `quiesce` took, so revived services schedule maintenance.
///
/// The registry calls this where it hands a fenced idle domain's services back
/// to a new session. Without it the cadence stays fenced for the life of the
/// domain and the reopened workspace runs no scheduled distillation at all. A
/// domain configured with no cadence has no fence to lift, which is why it
/// answers `Ok(Nil)` rather than a refusal: nothing about the revival failed.
///
/// ## Examples
///
/// ```gleam
/// // domain.resume(services)
/// ```
@internal
pub fn resume(services: Services) -> Result(Nil, String) {
  case services.cadence {
    None -> Ok(Nil)
    Some(name) -> distillpass.request_resume(name)
  }
}

/// Supplies no effects only for explicit manager fixtures and disabled hosts.
/// Production domain construction never substitutes this for a failed open.
///
/// ## Examples
///
/// ```gleam
/// // domain.inert()
/// ```
@internal
pub fn inert() -> Services {
  Services(None, None, [])
}
