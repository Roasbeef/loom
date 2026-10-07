# Preparing named owners and executors

An owner, or “brain,” retains the provider credentials, conversation, approvals and
session catalogue. An executor, or “hands,” owns the checkout and performs the
physical work. [Protocol 077](../protocol-change/077-registered-generations.md)
defines their registered deployment, enrollment and generation boundary;
[protocol 076](../protocol-change/076-registered-lsp.md) defines the required
executor LSP attachment.

The utility in [scripts/distributed/launch.py](../scripts/distributed/launch.py)
prepares private launch files and targets named instances. This slice supplies
packaging and configuration tooling. The release still needs actual deployment
launchers, the executor's strict physical descriptor decoder, and production
session assembly. The supplied Docker layer therefore advertises no supported
registered roles, and `start` refuses it. No distributed runtime, container
activation, physical effect or retirement was demonstrated by these utility tests.

## Choose the physical placement

| Placement | Owner | Executor | Checkout |
|---|---|---|---|
| Mac brain, Linux hands | Native macOS `loomd` | Native Linux or Linux Docker `loom-executor` | Linux executor |
| Linux brain, Mac hands | Native Linux or Linux Docker `loomd` | Native macOS `loom-executor` | Mac executor |

The roles keep the same authority regardless of the host operating system. A Mac
executor requires the Mac release and the executor's checked physical placement;
a Linux image running in Docker Desktop remains a Linux VM executor. It does not
prove macOS sandbox behavior. Native macOS is represented by configuration and
command previews here, and the utility never starts native processes.

Owner process cwd does not select the registered checkout. The owner selects an
installed executor/workspace label through its deployment table. The executor's
canonical roots and enrolled working directories select where effects run. For
Docker, a bind source is a path on the Linux Docker host, while its target is a
path inside that executor's container. Configure the physical descriptor with
those container paths, e.g. `/work/project-a`; a Mac owner need not contain that
checkout. Remote bind sources are checked on the actual Linux host at `start`,
and the executor must perform its full canonical-root checks at boot.

## Prepare the operator inventory

Use Python 3.11 or newer and an installed `openssl` command. The Python utility
uses only the standard library. Its JSON inventory describes local packaging;
it is separate from the runtime's TOML deployment authority. Unknown or duplicate
inventory keys refuse, as do duplicate instance names, full node names, workspace
selectors and overlapping mount targets. Booleans cannot stand in for epochs.

Copy [plan.example.json](../scripts/distributed/plan.example.json) and replace its
illustrative hostnames, image, checkout paths and descriptor digest. Each owner
workspace row names its executor instance and an explicitly enrolled peer. Peer
lists are reciprocal and contain one to 32 other configured instances. Instance
names use lowercase letters, digits, `_` and `-`, up to 48 bytes; node names use
bounded ASCII `name@host` spellings. The utility supports up to 33 explicitly named
instances in one inventory. Adding another hands or brain means another inventory
row, unique full node/certificate, and private state directory.

The owner TOML generator uses the exact protocol-077 fields: `schema`,
`endpoint_lifetime`, `owner`, `local_node`, membership paths, pinned peers and
workspace selections. It fixes `endpoint_lifetime = "retired_slots_v1"` and
`generation_policy = "clean_successor"`. Positive authority epochs and generation
numbers are bounded signed-32-bit values; digest spellings are 64 lowercase hex
characters. A descriptor digest must come from the installed canonical executor
descriptor, not a hash of an arbitrary file or the example's repeated digits.

For each executor, supply an `executor_template` relative to the inventory file.
The [membership fragment](../scripts/distributed/executor-membership.template.toml)
is deliberately incomplete. Extend it using the shipped executor decoder's actual
helper/pool settings, private state-root field, NativeFacts, CodeModeFacts,
compilation contract and approved LSP declarations. This tooling does not invent
those field names or validate physical facts on the coordinator. Missing or
unknown physical fields remain a runtime decoder failure, even when preparation
succeeds.

The template accepts these exact quoted string substitutions:

| Token | Replacement |
|---|---|
| `"@LOOM:LOCAL_NODE@"` | This instance's full node name |
| `"@LOOM:CA@"`, `"@LOOM:CERTIFICATE@"`, `"@LOOM:KEY@"` | This role's membership paths |
| `"@LOOM:COOKIE@"`, `"@LOOM:OPTIONS@"` | This role's private cookie and runtime-owned TLS options paths |
| `"@LOOM:STATE_ROOT@"` | This role's private state root; use in the decoder's actual state-root field |
| `"@LOOM:PIN:brain-a@"` | DER SHA-256 leaf pin for the named instance |

Executor peer rows must appear in the inventory's peer order and contain the
exact configured peer node names. The utility checks the common schema, lifetime,
local node, membership paths and complete peer list after substitution. It
preserves the remaining template declarations verbatim and records runtime
validation as pending. Deployment inputs are bounded to eight MiB before parsing.
The real runtime must still apply protocol-077 descriptor/row limits and reject
all unknown or duplicate physical keys.

Prepare a new coordinator bundle in an operator-private directory:

```sh
python3 scripts/distributed/launch.py prepare plan.json /private/loom-coordinator
python3 scripts/distributed/launch.py inspect /private/loom-coordinator
```

The output root must be absent. Preparation creates a private CA, a different
3072-bit RSA leaf/key for every full node identity, mutual client/server TLS
certificate extensions, DER SHA-256 pin files and one random membership cookie.
Each role has its own cookie file containing the same membership secret, without
a newline. Files use mode 0600 and private directories use mode 0700. The CA key
stays in `authority/ca.key` on the coordinator. Inspection prints identities and
paths, never keys or cookie contents. Generated files are covered by a bounded
SHA-256 manifest; inspection refuses changed files, widened permissions and
shared or symlinked state directories.

A failed preparation can leave a private partial directory. It never regenerates
identities over that directory. Preserve the diagnostic and choose a new absent
output after correcting the inventory; do not treat a partial bundle as launchable.

## Export each host's unbooted roles

Export explicit names to separate host bundles before any role boots:

```sh
python3 scripts/distributed/launch.py export /private/loom-coordinator /srv/loom-linux hands-a
python3 scripts/distributed/launch.py export /private/loom-coordinator /Users/operator/loom-mac brain-a
```

These paths are the intended absolute paths on the destination hosts. Export
creates the staged directory at that path on the coordinator, so its parent must
already exist and be writable there. Transfer only the selected host bundle over
an operator-controlled encrypted channel, and install it at the same absolute
path on the destination. Keep modes private during transfer. No utility command
transfers files, opens SSH, publishes a cookie, or contacts another host.

The Linux bundle contains only hands-a's membership material and a public CA;
the Mac bundle contains only brain-a's material and a public CA. Neither contains
the CA key or the other role's private key. Export retains certificate, node,
cookie and pin identities, rewrites native membership/state path literals, and
creates separate empty state directories. A per-role export reservation refuses
a second export. An unknown or failed export remains reserved; inspect that
original destination instead of manufacturing another identity. Exported bundles
cannot be exported again, and roles with nonempty state or a TLS options file
cannot be exported. The coordinator is never a runtime host bundle.

For multiple hands on one Linux host, export all their explicit names in one
command. Their Compose services and state binds remain separate. For the reverse
placement, set the Linux owner's transport to `docker`, the Mac executor's
transport to `native`, and export the corresponding names. Native physical roots
belong directly in the executor deployment. Docker workspace mount declarations
belong only to Docker roles.

Never clone an exported bundle to boot the same node identity twice. Never reuse
one state directory for different names, delete state to restart a generation, or
use `docker compose --scale` for these identities. Each new role requires its own
inventory row and enrollment. Retained state remains with its original host;
workspace snapshot migration and automatic failover are outside protocol 077.

## Package and target the Docker roles

The derived image uses the existing runnable image's release, uid 10000 and PID-1
`tini`. From the repository root, after release integration supplies both roles:

```sh
docker build -t loom-distributed:validated \
  --build-arg LOOM_RUNTIME_IMAGE=loom-runtime:dev \
  -f docker/distributed/Dockerfile .
```

The root integration must add `org.loom.distributed.protocol=077` and an exact
comma-separated `org.loom.distributed.roles` list only after real role/image
validation. The current derived Dockerfile sets neither label. Pin a tested image
digest in the inventory for repeatable deployment. The root image remains
`linux/amd64`; this layer does not add an arm64 release or a new toolchain.

`loom-distributed-role owner --deployment PATH` dispatches to `loomd`;
`loom-distributed-role executor --deployment PATH` dispatches to `loom-executor`.
The wrapper refuses missing executables or absent `--deployment` advertisement,
including direct entrypoint use. The release launcher must validate the actual
file before VM boot, create or verify private fixed TLS options, and use the
approved distribution bootstrap. The utility leaves `tls.options` for that
launcher. It supplies no alternate local startup or plaintext fallback.

On the Linux host, ensure each selected Docker role's `member` and `state`
directories, including their contents, are owned by uid 10000 while retaining
private modes. Root may be needed for ownership and for utility inspection after
handoff; do not widen key/cookie modes to make an unprivileged command succeed.
The coordinator bundle and CA key stay owned by their operator. Render and target
only the selected host bundle:

```sh
sudo python3 scripts/distributed/launch.py render /srv/loom-linux
sudo python3 scripts/distributed/launch.py start /srv/loom-linux hands-a
sudo python3 scripts/distributed/launch.py logs /srv/loom-linux hands-a
sudo python3 scripts/distributed/launch.py stop /srv/loom-linux hands-a
```

The Python command and its source must be present on that Linux host. The utility
inspects the retained image's role labels and runs a transient, read-only,
network-disabled `--check-role` help process before `compose up`. Help advertisement
is preliminary flag compatibility, not deployment validity, successful enrollment
or readiness. The actual Compose command uses explicit names, `--no-deps` and
`--pull never`; real command failures propagate. Detached `up` returning zero only
means Docker accepted the start request. Read role logs and verify runtime startup
separately. `stop` preserves state and `logs` tails only the selected services.
There is no `down`, volume deletion, global prune or implicit fleet-wide cleanup.

For a native host, `inspect` prints an argv preview for the selected role and its
private paths. Use the correctly packaged native release there. This utility
neither executes that preview nor proves the native deployment flags work.

## Connect and enroll

Generated Compose services use Linux host networking. This exposes the actual
host network namespace and avoids pretending a bridged dynamic BEAM distribution
listener is reachable through the ordinary daemon port. Configure stable DNS or
hosts entries so every complete `name@host` resolves to the intended physical
host from both sides. Several instances on one host use distinct node-name
prefixes and different leaf certificates even when their host suffix is the same.

Permit authenticated BEAM distribution between the declared hosts, including
EPMD and the actual distribution listener ports selected by the shipped runtime.
Do not assume publishing 7331 establishes this lane. The ordinary daemon client
listener remains loopback-bound; run the client on its owner host or in that
owner's network namespace. This slice adds no public owner listener, unchecked
proxy, firewall rule or new distribution port authority field.

Both roles require the enrolled CA, their own private leaf/key and cookie, and
exact pins for their configured peers. TLS membership authenticates a named peer;
it does not authorize an arbitrary workspace. The immutable deployment table,
original owner peer, exact Binding and descriptor digest govern Describe and
activation. Validate physical roots, protected membership/state paths, helper and
toolchain placement, compilation contract and approved LSP profiles on the actual
executor before enrollment. Clients supply selectors, not credential paths or
executor filesystem authority.

## Verify readiness, effects and retirement separately

A process being up, a successful TLS connection or a ready owner listener proves
no physical work. The production path must pin and read back canonical enrollment
in the durable owner companion before activation, capture the original generation
and install the original native, workspace, Compile/Launch and LSP attachments.
Required LSP attachment failure blocks full registered activation. A minimal help
preflight or incomplete executor template cannot replace those checks.

Exercise a real enrolled workspace operation, native operation, code-mode
Compile/Launch and LSP operation through that registered session, with the checkout
only on the executor. Record original admissions, exact generation links, real
helper effects and durable results. Then test close/archive and reopen/restore:
physical retirement requires original executor and owner joins, fences, removal
acknowledgement and durable readback before the next exact generation reuses a
slot. Container stop, process exit or a ready successor alone proves none of those
joins. Historical reads must retain their original generation and produce no
fresh work or replacement identity.

## Retain the measured isolation limits

This Compose generator adds no privileges, seccomp relaxation, cgroup delegation
or invented container mode. Host networking changes the network namespace only.
[docs/docker.md](docker.md) records the root image's measured Linux x86_64
postures: plain Docker enforced zero of eleven helper probes, skipped two and
failed nine; the explicitly relaxed posture with process migration enforced ten,
skipped one and failed zero. Those are existing measurements, not a fresh test of
this distributed packaging layer.

The relaxed posture shares the host cgroup tree and lifts much of Docker's own
confinement. Its delegated cgroup base and process migration were manual, and
multiple concurrent instances were not demonstrated there. Running many hands
requires distinct delegated bases and actual process placement if that posture
is chosen. This utility does not configure either operation. Docker Desktop,
macOS executor behavior, concurrent cgroup placement and registered physical
isolation each need their own evidence on the intended hosts.
