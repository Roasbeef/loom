//// One admitted domain owns shared recall, not its sessions.
////
//// The manager retains this host's original custody witness before beginning
//// construction. Each parked child publishes cleanup before startup links are
//// transferred and effects begin. Session shutdown cannot close these shared
//// resources; the last dependency retires the domain host.

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
  Services(history: Option(history.Shared), roots: List(#(String, process.Pid)))
}

/// Domain-owned configuration, resolved independently from session settings.
@internal
pub type Config {
  Config(
    /// Exact index path and fresh bounded source authorization.
    history: history.SharedConfig,
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
  Ok(Services(Some(shared), [#("history", prepared.pid)]))
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
  Services(None, [])
}
