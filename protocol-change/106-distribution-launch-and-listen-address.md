# protocol-change/106: the launcher renders the TLS options file, and `[distribution]` gains `listen_address`

**Status**: PROPOSED 2026-11-01 and built on `dist/launcher-optfile`.
**Affects**: the `[distribution]` table of `loom.toml` (one new optional key,
`listen_address`) and the launcher contract of
[protocol-change/078](078-distributed-runtime.md), under which an operator
renders the options file and exports `LOOM_DISTRIBUTION_OPTFILE` before any
daemon with a `[distribution]` table can boot. The options file text, the boot
checks in `distribution.start`, `BootRefusal`, the wire protocol, the bundle
format and `system.json` do not change. Part of issue #1137.
**Builds on**: [078](078-distributed-runtime.md) and
[086](086-membership-ledger.md), which recorded the other `[distribution]` keys.

## Problem

Two things stood between an operator and a correctly booted distributed daemon.

A daemon with a `[distribution]` table refuses to start unless its VM was booted
with `-proto_dist inet_tls -ssl_dist_optfile FILE`. Those flags must precede any
Gleam code, so `bin/loomd` adds them only when `LOOM_DISTRIBUTION_OPTFILE` names
the file, and the file is rendered by `loomd distribution options CONFIG OUT`.
`loom distribution install` does both once. A later restart through the client
(`loom`, `loom ui`, `loom run -p`, ACP) did neither: the client started
`bin/loomd` with the operator's environment, so a client run from a shell that
did not export the variable got a boot refusal in the daemon log. The client held
the configuration and the server path and could have rendered the file itself.

Separately, an orchestrator with no peer orchestrators is never dialled
([distributed.md, Who dials whom](../docs/architecture/distributed.md#who-dials-whom)),
yet its distribution listener binds every interface. The only remedy was
`-kernel inet_dist_use_interface {127,0,0,1}` in `ERL_FLAGS`, which the setup
guide mentions and the configuration does not.

## What was considered

**Make `bin/loomd` render the file.** A shell script cannot read TOML, so it
would have to find `--config` and `--state-dir` in the daemon's arguments the way
the daemon does, and then boot a VM to run the renderer before it boots the one
that matters. Both launchers (`make server-shipment` and `scripts/release.sh`)
would carry that logic, and every use of the launcher would pay a second VM boot,
including `loomd access` and `loomd ext`, unless each subcommand were also
recognised in shell. A grep for `[distribution]` as a gate is cheaper and wrong
for a table written in another TOML form, such as `distribution = { ... }`. Not
taken. A daemon started directly through `bin/loomd` therefore still needs the
variable, as before, and its refusal message now says so.

**Render in the client process.** The text names the daemon's verify function and
pin encoding, which live in `packages/client`; `packages/tui` cannot depend on it
because the client's tests depend on the tui. Not taken.

**Have the daemon re-exec itself with the flags.** The VM boot flags are fixed at
emulator start, and the launcher fences the process it spawned by pid and birth
identity. A replacement process would break that fence. Not taken.

**A new `Launch.environment` field and an environment argument on
`host.spawn_server`.** It changes the signature of the launch record and of its
every constructor, including the tests of other work in flight, to carry one
variable. Not taken: `env VAR=value loomd ...` sets the variable and executes the
daemon in place, so the fenced pid is still the daemon's.

**For the listener, a value of `any`, a list, or `::1`.** The key exists to keep
a listener off the network, so only a loopback address is meaningful. An address
that names a real interface passes on one machine and fails to bind on the next.
`::1` is refused because the distribution carrier is IPv4 (`inet_tls`).

## Decision

1. When the client starts a daemon, and only then, it checks the configuration
   the daemon will load for a `[distribution]` key, the daemon's own test. If
   there is one and the launcher's environment does not already set a non-empty
   `LOOM_DISTRIBUTION_OPTFILE`, it deletes `<state>/distribution-launch.options`,
   runs `<loomd> distribution options CONFIG <that path>`, and starts the daemon
   with the variable set to that path. A failed render fails the launch with the
   renderer's output and leaves no file. An explicit variable is passed through
   untouched and nothing is rendered. A daemon that is already running is never
   touched, since the render sits inside the launch callback that runs only for a
   vacant endpoint under the launch lock.
2. `[distribution]` accepts `listen_address`, a string holding an IPv4 loopback
   address (`127.a.b.c`, canonical decimal, no sign or leading zero). Anything
   else is refused when the file is read, with a sentence naming the key. When
   set, `distribution.start` sets the kernel parameter `inet_dist_use_interface`
   to that address before it starts `net_kernel`, as it already does for
   `listen_port`. Unset, the listener binds every interface, as before.

The address is a kernel parameter and not a TLS option, so it is not in the
options file. The boot-argument comparison in `distribution.start` therefore still
compares exactly the file the configuration generates, and `distribution options`
output does not change. A guest executor must leave the key unset: the
orchestrator's connections arrive from the virtual gateway at 192.168.127.1, which
a loopback listener would refuse.

## What it costs

The client spends one extra short VM boot (about a second) on each cold daemon
start whose configuration has a `[distribution]` table, and none otherwise. The
rendered file is rewritten at every launch, so the file's mtime says nothing about
the configuration. A daemon started by hand still takes the two operator steps.

`loom distribution install` of a bundle into a configuration whose
`[distribution]` table also carries `listen_address` is refused as a different
table unless `--force` is given, because the installer compares the whole table
with the bundle's. Plans and bundles do not carry the key; the operator adds it to
`loom.toml` after installing.

## Verification

`tui/distribution_launch_test` holds the decision, the command and a render
against a stand-in `loomd`. `client/distribution_test` holds the strict decoder and
two real-emulator scenarios that read the table through the production reader and
inspect the address the listener is bound to, with the key and without it.
The live check, on macOS under an isolated `HOME`, state directory and
`ERL_EPMD_PORT`: a static two-node plan provisioned with `loomd distribution
provision --static` and one bundle installed with `loomd distribution install`;
a daemon started by `loom sessions list --server bin/loomd --state-dir ... --config
...` with no `LOOM_DISTRIBUTION_OPTFILE` in the environment, which wrote
`<state>/distribution-launch.options` (mode 0600), registered with `epmd`
(`name orch at port 14471`) and listened on `*:14471` under `lsof -nP
-iTCP:14471 -sTCP:LISTEN`; then the same with `listen_address = "127.0.0.1"` in
`[distribution]`, which listened on `127.0.0.1:14471` only.
