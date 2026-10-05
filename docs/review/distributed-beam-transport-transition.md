# Trusted executor transport transition

The owner selected TLS BEAM for trusted executors. Commit `3b0372f51` records
the [protocol amendment](../../protocol-change/067-remote-workspace-services.md#addendum-trusted-executor-distribution)
and updates the design, integration guide and work-package plan. Commit
`7439bdef` prevents the executor's Erlang argument environment from becoming
satellite VM arguments. Transport replacement remains in progress.

## Decision and scope

Executors admitted to distribution share the orchestrators' runtime trust
domain. A compromised executor VM or OS account can compromise connected
owners. TLS, hidden nodes and closed application messages do not provide
isolation against that peer. Executor membership remains separate from Raft
voter membership; model-authored satellites remain outside distribution.

The implementation will replace the custom socket transport with one supported
TLS BEAM path. Canonical durable bytes, original identities/deadlines, admission,
receipts and witnessed native retirement remain required. A BEAM send or DOWN
message does not replace those facts. [Issue #825](https://github.com/Roasbeef/loom/issues/825)
tracks explicit secondary targets and artifact handoffs within one workflow;
ordinary multi-peer registration remains part of #697.

## Completed boundary check

The shared `codemode/native_command.node_env` factory excludes every occurrence
of `ERL_AFLAGS`, `ERL_FLAGS` and `ERL_ZFLAGS`. Both local and remote command
construction use the factory. The derived environment allowlist uses the same
filtered values. The existing command arguments still disable distribution
and epmd and supply no node name.

The focused launch suite passed all 26 tests with zero skips and a warning-free
build. It checks the exact filtered environment, duplicate argument variables
and the derived permission request. Codemode lint passed with zero errors and
118 warnings. Documentation checks passed with zero errors and 183 warnings.
The test scratch root was `/private/tmp/lb697`; these launch fixtures use local
Unix sockets and a fake helper, not an actual remote jail.

Earlier attempts remain failures in the verification record: a sandbox denied
dependency resolution, a source-style module name matched no compiled tests,
and a longer scratch path exceeded the macOS Unix-socket limit in one existing
test. The final suite used the compiled module name `codemode@launch_test` and
the short scratch path. No timeout or assertion was removed.

Astra's independent source review of `540e5dc0c..7439bdef` found no confirmed
new issue. It traced the factory to the actual launch environment and checked
the amendment's trust and implementation-status claims. The reviewer did not
rerun the suites.

## Remaining acceptance

Real TLS-distributed node authentication, endpoint admission/consumption bounds,
owner consumer migration and registered daemon assembly are pending. Executor
assembly must still exclude credential files and inherited descriptors from
satellites, and test actual distribution-disabled execution. The environment
test alone establishes none of those properties.

Existing framed-TLS component tests remain evidence for the old adapter only.
Separate-host ordinary tools, Compile/Launch, owner capabilities and LSP still
gate the product. Formal-model correspondence must be updated against the final
endpoint, not inferred from an unchanged abstract model.
