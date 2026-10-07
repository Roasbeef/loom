//// Original executor-local Registered LSP attachment doors.
////
//// `checked_plan` freezes actual administration and physical placement before
//// original owner Broker clearance. `install_pending` consumes first placement
//// custody in the native Service; `submit` retains Request, Authority, admission
//// and the exact ServerLease association before returning one parked attachment.
//// `transport` installs the real consumed sink before Begin. The original Service
//// owns credit, cancellation, terminal persistence and the independent native
//// retirement observer. This wrapper creates no actor, pool or owner Broker.
////
//// Later full-host assembly must supply the real original owner-cleared request.
//// An opaque historical claim, receipt, client ACK or terminal cannot construct
//// a new pending context, reconnect an attachment or retire its lease slot. The
//// semantic manager, endpoint drain and owner/result joins remain separate from
//// `cleanup`; this module never calls the DAL's retire_lease function.

import broker/policy
import codemode/lsp_host/jail
import core/lsp_command
import executor/remote/deployment
import executor/remote/identity
import executor/remote/internal/lsp_native_plan
import executor/remote/lsp_journal
import executor/remote/registration
import executor/remote/service
import executor/remote/wire
import lsp/transport

/// Frozen physical plan, with construction restricted to checked administration.
@internal
pub type CheckedServerPlan =
  lsp_native_plan.CheckedServerPlan

/// Original one-shot Service installation, unavailable through history.
@internal
pub type PendingServerLease =
  service.PendingServerLease

/// Exact original attachment door, never a helper PID or replacement lookup.
@internal
pub type LspProtocolAttachment =
  service.LspProtocolAttachment

/// Independent original fence, managed drain, terminal and native observations.
@internal
pub type Cleanup =
  service.LspCleanup

/// Freezes actual approved placement without granting owner clearance.
///
/// ## Examples
/// Configured trusted environment values are resolved once for this plan.
@internal
pub fn checked_plan(
  descriptor: deployment.Descriptor,
  registered: registration.Registration,
  placement: jail.Placement,
  base: policy.SandboxPolicy,
  reading: fn(String) -> Result(String, Nil),
) -> Result(CheckedServerPlan, Nil) {
  lsp_native_plan.checked(descriptor, registered, placement, base, reading)
}

/// Installs original first-placement custody beside its trusted native clock.
/// Trusted assembly supplies the ClockEra paired with Service.Config.now; a
/// decoded era string is never clock provenance.
///
/// ## Examples
/// A retained lease or copied token cannot install another pending context.
@internal
pub fn install_pending(
  native: service.Service,
  store: lsp_journal.Store,
  claim: lsp_journal.LeaseStartupClaim,
  plan: CheckedServerPlan,
  era: lsp_command.ClockEra,
) -> Result(PendingServerLease, service.Error) {
  service.install_pending_lsp(native, store, claim, plan, era)
}

/// Consumes the original pending context into one parked native association.
/// The actual original owner Broker has already cleared Prepared's token.
///
/// ## Examples
/// A lost reply leaves the consumed original context unavailable for retry.
@internal
pub fn submit(
  pending: PendingServerLease,
  key: identity.RequestKey,
  prepared: wire.Prepared,
) -> Result(LspProtocolAttachment, service.Error) {
  service.submit_pending_lsp(pending, key, prepared)
}

/// Selects the Registered client profile through the real consumed transport.
///
/// ## Examples
/// The client can admit writes while its original input credit waits.
@internal
pub fn transport(attachment: LspProtocolAttachment) -> transport.Transport {
  service.lsp_transport(attachment)
}

/// Requests original cancellation without waiting on output consumption.
///
/// ## Examples
/// Closing this attachment never chooses a newly registered incarnation.
@internal
pub fn close(attachment: LspProtocolAttachment) -> Nil {
  service.close_lsp(attachment)
}

/// Reads independent cleanup facts, never a semantic or endpoint release permit.
///
/// ## Examples
/// A positive native witness remains distinct from managed drain and terminal.
@internal
pub fn cleanup(
  attachment: LspProtocolAttachment,
) -> Result(Cleanup, service.Error) {
  service.inspect_lsp_cleanup(attachment)
}
