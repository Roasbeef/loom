# Setting up a distributed Loom

A distributed Loom splits one session across two machines. One machine thinks
and the other works on your files. This page shows how to set that up, from
nothing, in the order you would do it.

The design is in [the distributed runtime note](design-notes/distributed-runtime.md)
and [protocol-change/078](../protocol-change/078-distributed-runtime.md). You do
not need either to follow this page.

## How to read the status marks

Some steps depend on commands that are still landing. Each command block is
marked so you know what to trust.

| Mark | Meaning |
|---|---|
| **Verified** | Run on the commit this page was written against, with the output described. |
| **Pending** | Needs `loom distribution provision` and `install`, or the executor role (remote tool calls), which are being built in parallel. Not yet run. |
| **Not run** | Depends on your network or operating system (Tailscale, a firewall, SSH). Standard commands, but not run while writing this page. |

## 1. The two roles

Both roles are the same release. A node's configuration decides which role it
plays.

| | Orchestrator ("brains") | Executor ("hands") |
|---|---|---|
| Runs | The agent loop, approvals, budgets | Tools, shell commands, language servers, code mode, background jobs |
| Holds | The conversation database (SQLite), session catalogue, approvals and grants, provider API keys, your `~/.loom` and user-level hooks | The checkout (files, `.git`, uncommitted edits), toolchains and caches, the sandbox, the record of tool calls in flight |
| Talks to | Clients (terminal, web), the model provider, the executor | The orchestrator only |
| Configured with | `[distribution]` and `[executors.<name>]` | `[distribution]` and `[workspaces.<name>]` |

Either machine can play either role. A laptop can be the orchestrator with a
Linux box as the executor, or the reverse. One machine can run both, as in the
first quick start.

The rule behind the table: settings that name a path on a machine live on that
machine. The orchestrator never reads the executor's disk, and the executor
never opens the conversation database.

The two nodes connect over Erlang distribution inside TLS. A connected node has
the full power of an Erlang node on the other side, so only join machines you
administer.

## 2. Before you start

You need:

- The same Loom release on both machines (`loomd`, and `loom` for clients). See
  [running Loom](running.md) for installing it, or build from a checkout.
- `openssl` on the machine where you mint credentials. Nothing else is needed
  for that step.
- A network path from the orchestrator to the executor. Only the orchestrator
  dials. Section 5 says which ports.
- For the Docker quick start, Docker with the Compose plugin and an x86_64
  Linux host. See [the Docker guide](docker.md) for why.

Node names matter. A node is named `name@host`. The host part must contain a
dot, so use a DNS name (`box.example.com`), a Tailscale name, or an IP address
(`10.0.0.5`). The orchestrator uses the host part to find the executor, so it
must resolve from the orchestrator.

## 3. Create the credentials

Every node gets a certificate signed by one private authority that you create,
and every node learns the SHA-256 fingerprint ("pin") of each peer's
certificate. A node accepts a peer only if the certificate chains to your
authority, hashes to the pin, and names exactly that peer's node name. All
nodes also share one cookie.

You do not do any of this by hand. The `loom distribution` commands do it for
you. (`loom dist` is a shorthand for `loom distribution`; this page uses the
full form.)

**Pending.** Write an example plan, then edit it to name your nodes:

```sh
loom distribution init > plan.toml
```

The plan lists each node, its role, its node name, and for an executor its
workspaces (a short name and an absolute path on that machine). Then mint
everything:

```sh
loom distribution provision plan.toml out/
```

This writes `out/system.json`, a description of the deployment, and one file per
node, `out/<node>.loombundle`. **A bundle contains that node's private key and
the shared cookie.** Copy each bundle to its machine over a channel you trust
(`scp` is fine) and delete your copies you do not need. Do not commit bundles.

On each machine, install the bundle you were given:

```sh
loom distribution install <node>.loombundle
```

Install puts the certificates and key under the daemon's home, writes the cookie
to `$HOME/.erlang.cookie`, merges the role tables into `loom.toml`, writes the
TLS options file, and prints the command that starts the daemon. Use that
command.

### What install produces

You can write these files by hand, and the troubleshooting section refers to
them. This is a complete pair for one orchestrator and one executor. Each file
goes on its own machine.

The orchestrator's `loom.toml`:

```toml
[distribution]
node = "orch@10.0.0.1"
ca = "/home/me/.loom/distribution/ca.pem"
certificate = "/home/me/.loom/distribution/cert.pem"
key = "/home/me/.loom/distribution/key.pem"
cookie = "/home/me/.erlang.cookie"
listen_port = 9100

[[distribution.peers]]
node = "exec@10.0.0.2"
sha256 = "<64 hex characters: the executor certificate's pin>"

[executors.box]
node = "exec@10.0.0.2"
```

The executor's `loom.toml` (the `[workspaces]` table needs the executor role;
**Pending**):

```toml
[distribution]
node = "exec@10.0.0.2"
ca = "/home/me/.loom/distribution/ca.pem"
certificate = "/home/me/.loom/distribution/cert.pem"
key = "/home/me/.loom/distribution/key.pem"
cookie = "/home/me/.erlang.cookie"
listen_port = 9100

[[distribution.peers]]
node = "orch@10.0.0.1"
sha256 = "<the orchestrator certificate's pin>"

[workspaces.proj]
root = "/home/me/src/myproj"
```

Every key is in [the configuration reference](configuration.md). Three rules
trip people up:

- `cookie` must be exactly `$HOME/.erlang.cookie` of the user that runs the
  daemon. The Erlang VM reads its cookie from that file and nowhere else.
- `key` and `cookie` must be mode 0600.
- The certificate must carry the node name as a DNS name in its subject
  alternative names, and only one name containing an `@`.

## 4. Quick start A: two daemons on one machine

This is the fastest way to see it work. Both daemons run on your machine, each
in its own terminal, each with its own `HOME` so each has its own cookie and
state.

### Mint the credentials

With the provision command (**Pending**), put two nodes in the plan, such as
`orch@127.0.0.1` and `exec@127.0.0.1`, provision, and install each bundle with
`HOME` set to a different empty directory:

```sh
HOME=$HOME/loom-demo/orch loom distribution install out/orch.loombundle
HOME=$HOME/loom-demo/exec loom distribution install out/exec.loombundle
```

Without it (**Verified**), the repository has an openssl-only fixture that
writes the same files. It is for tests and demos, not for real deployments:

```sh
scripts/distributed/mint-fixture.sh ~/loom-demo \
  orch@127.0.0.1 ~/loom-demo/orchestrator/home \
  exec@127.0.0.1 ~/loom-demo/executor/home \
  proj ~/src/myproj
```

The arguments are: output directory, orchestrator node and its home, executor
node and its home, workspace name and root. The script refuses to overwrite an
existing directory. It writes each node's certificate, key, cookie and
`loom.toml` under `<output>/<role>/home`, and prints no secret. It writes
`[workspaces.proj]` only when this tree's configuration reference documents that
table, so it works before the executor role lands.

### Start the executor

In one terminal (**Verified**):

```sh
export HOME=$HOME/loom-demo/executor/home
bin/loomd distribution options $HOME/.loom/loom.toml $HOME/.loom/distribution.options
LOOM_DISTRIBUTION_OPTFILE=$HOME/.loom/distribution.options \
  bin/loomd --config $HOME/.loom/loom.toml --bind 127.0.0.1:7442
```

The first command renders the TLS options file from the `[distribution]` table.
The second starts the daemon. The variable `LOOM_DISTRIBUTION_OPTFILE` makes the
launcher boot the Erlang VM with `-proto_dist inet_tls -ssl_dist_optfile <file>`.
Both the `bin/loomd` that `make server-shipment` builds and the self-contained
release launcher honour it. Rerun the first command whenever you edit
`[distribution]`, because the daemon refuses an options file that does not match
its configuration.

### Start the orchestrator

In another terminal (**Verified**):

```sh
export HOME=$HOME/loom-demo/orchestrator/home
bin/loomd distribution options $HOME/.loom/loom.toml $HOME/.loom/distribution.options
LOOM_DISTRIBUTION_OPTFILE=$HOME/.loom/distribution.options \
  bin/loomd --config $HOME/.loom/loom.toml --bind 127.0.0.1:7441
```

Each daemon prints `daemon listening on ws://127.0.0.1:<port>/v2/control` and
its token file path when it is up.

### Check that both are TLS nodes

From a third terminal (**Verified**):

```sh
epmd -names
```

The output lists both nodes next to the ports of their distribution listeners:

```text
name exec at port 49390
name orch at port 49392
```

If you are running a release without Erlang installed, `epmd` is in the
release at `erts-<version>/bin/epmd`.

To see the TLS handshake itself (**Verified**), connect to the executor's port
with the orchestrator's certificate. Replace the port with the one `epmd -names`
printed:

```sh
openssl s_client -connect 127.0.0.1:49390 \
  -cert $HOME/loom-demo/orchestrator/home/.loom/distribution/cert.pem \
  -key  $HOME/loom-demo/orchestrator/home/.loom/distribution/key.pem \
  -CAfile $HOME/loom-demo/orchestrator/home/.loom/distribution/ca.pem </dev/null
```

Look for `Verification: OK` and `Protocol: TLSv1.3`.

Stop each daemon with Ctrl-C in its terminal when you are done.

## 5. Quick start B: a laptop and a Linux box

The orchestrator dials the executor. Nothing dials the orchestrator over
distribution. So the executor's machine must accept inbound connections on two
TCP ports, and the orchestrator's machine needs only outbound access.

| Port | What | Notes |
|---|---|---|
| 4369 | `epmd`, the Erlang name service | The orchestrator asks it which port the executor's node listens on. |
| `listen_port` | The executor's distribution listener | Set `listen_port` in `[distribution]` so you can open one known port. Without it the port is random. |

Open exactly those two ports, to the orchestrator's address only. The TLS pins
and the cookie protect the connection, but an open port is still more than you
need to show.

### Laptop orchestrator, Linux executor

1. Choose how the laptop reaches the Linux box and write its address as the
   host part of the executor's node name (`exec@<address>`). Options are below.
2. Write the plan with both nodes and a workspace on the executor, for example
   `proj` at `/home/me/src/myproj`. Provision (**Pending**).
3. Copy `exec.loombundle` to the Linux box and install it there (**Pending**).
   Install `orch.loombundle` on the laptop the same way.
4. On the Linux box, start the executor with the command install printed. By
   hand, this is the executor start from section 4 with `--bind` left at its
   default (**Pending**, as it needs the `[workspaces]` table).
5. On the laptop, start the orchestrator the same way.

### Linux orchestrator, Mac executor

The same steps with the roles swapped. The Mac now has to accept inbound
connections, so it needs an address the Linux box can reach, which usually means
Tailscale. Allow `loomd` in the macOS firewall when it asks. The executor on
macOS is weaker than on Linux; see the troubleshooting section.

### Reaching the executor

**Tailscale** (**Not run**). Install it on both machines and sign in to the same
tailnet. Use the executor's MagicDNS name or its `100.x.y.z` address as the host
in the node name, such as `exec@box.tailnet-name.ts.net`. Tailscale already
limits who can connect, so a firewall rule is optional. If the Linux box has
`ufw`:

```sh
sudo ufw allow in on tailscale0 to any port 4369,9100 proto tcp
```

**A private network or LAN** (**Not run**). Use the executor's LAN address in
its node name and allow the two ports from the orchestrator's address only:

```sh
sudo ufw allow from 192.168.1.20 to any port 4369,9100 proto tcp
```

**An SSH tunnel** (**Not run**). Use this only if neither of the above is
possible, because it is the fiddliest. The tunnel must carry both ports, and
the node name's host must be an address that reaches the tunnel. On a Linux
orchestrator, give the tunnel its own loopback address so it does not collide
with the local `epmd`:

```sh
sudo ip addr add 127.0.0.2/8 dev lo
ssh -N -L 127.0.0.2:4369:127.0.0.1:4369 -L 127.0.0.2:9100:127.0.0.1:9100 me@box
```

Then name the executor `exec@127.0.0.2` in both nodes' configuration and plan.
This does not work with the default `127.0.0.1` for both nodes, because the
orchestrator's own `epmd` would answer. Prefer Tailscale.

## 6. Quick start C: Docker Compose

Compose runs an orchestrator container and an executor container from the same
`loom-runtime` image on one private network. Only the orchestrator's client port
is published, and only on the host's loopback. Distribution stays on the private
network.

The files are in `docker/distributed/`.

Build the image on an x86_64 Linux host. The repository `Dockerfile` is amd64 only, and
building it under emulation on an Apple Silicon Mac fails; see
[the Docker guide](docker.md):

```sh
make docker-image
```

Provision with a plan that names the nodes `orchestrator@orchestrator.loom.internal`
and `executor@executor.loom.internal`, and gives the executor a workspace rooted at
`/work/project` (**Pending**):

```sh
loom distribution provision plan.toml out/
cp out/orchestrator.loombundle out/executor.loombundle docker/distributed/
```

Start both containers (**Pending**, as the executor needs the `[workspaces]`
table to boot):

```sh
docker compose -f docker/distributed/compose.yaml up -d
docker compose -f docker/distributed/compose.yaml ps
```

Each container mounts its own bundle read-only. At start, its entrypoint copies
the bundle into the container's home, runs `loomd distribution install`, and
starts the daemon with `LOOM_DISTRIBUTION_OPTFILE` set. You do nothing else.

To put your code on the executor, copy it into the checkout volume, or point
`EXECUTOR_CHECKOUT` at a host directory before `up`:

```sh
docker compose -f docker/distributed/compose.yaml cp ./myproj executor:/work/project
```

To reach the orchestrator from a client on the host, start the forwarder. It
exists because the daemon only binds the container's loopback (see
[the Docker guide](docker.md), "The bind restriction"), which a published port
cannot reach:

```sh
docker compose -f docker/distributed/compose.yaml --profile client-port up -d
docker compose -f docker/distributed/compose.yaml cp orchestrator:/var/lib/loom/owner.token ./owner.token
```

The client then connects to `127.0.0.1:7331` with that token. Set
`LOOM_CLIENT_PORT` to publish a different host port.

### Postures

| Posture | How | What it gives | What it costs |
|---|---|---|---|
| Plain (default) | `compose.yaml` alone | Docker's boundary is the jail. The orchestrator is fine here, since it runs no model-written code. | Loom's own sandbox does not come up: `loom-exec --self-test` enforces 0 of 11 probes. A model's commands share the container with the daemon's state. |
| Full isolation | Add `compose.isolated.yaml` | Loom's own bubblewrap, Landlock, seccomp and cgroup limits come up for the executor: 10 of 11 probes. | Removes pieces of Docker's confinement from the executor container (host cgroup namespace, `SYS_ADMIN`, no seccomp, no AppArmor, unmasked `/proc` and `/sys`). Needs a Linux host with cgroup v2. |

For an executor that runs model-written commands you want full isolation.
Start it with both files:

```sh
docker compose -f docker/distributed/compose.yaml \
  -f docker/distributed/compose.isolated.yaml up -d
docker compose -f docker/distributed/compose.yaml exec executor loom-exec --self-test
```

Expect 10 of 11 probes enforced, as in the measured table in
[the Docker guide](docker.md). The compose override does the cgroup delegation
from the entrypoint, which that guide did by hand; this has not been verified,
so run the self-test and read its output before relying on it.

The smoke test (`make docker-distributed-smoke`) starts the pair with
throwaway credentials, waits for both daemons to be ready, checks that each
container lists its node in `epmd`, and tears down only what it started. It
skips with a message when Docker is missing or the image cannot be built on the
host. It has not been run against the real image on the machine this page was
written on, which is an Apple Silicon Mac.

## 7. Create and use a remote session

A remote session is a normal session whose workspace is a name registered on an
executor instead of a directory on the orchestrator. A client asks for one by
passing `executor` and `workspace` to `sessions.create`
([client protocol, section 3.7](client-protocol.md)).

Both clients can create one. Each needs a `loom.toml` on the orchestrator that
defines at least one model and a `main` role, as any session does. The
workspace name is the executor's `[workspaces.<name>]` key. It is a name and not
a path: the orchestrator never looks for it on its own disk.

**In the terminal** (**Verified** against the pair from section 4), start `loom`
as the orchestrator's user with the executor and the registered name:

```sh
HOME=$HOME/loom-demo/orchestrator/home loom --executor box --workspace proj
```

`--executor` is an `[executors.<name>]` key of the orchestrator's `loom.toml`,
and with it `--workspace` is the registered name, not a directory. The session
picker opens as it always does, with the remote sessions you already have
grouped under `PROJ  on box`. Press `n` to create a new one in that workspace on
that executor. Every `n` in that terminal does the same until you quit. Add
`--model-profile <name>` to choose a model profile. `--executor` cannot be
combined with `--session`, which opens a session that exists, and
`loom sessions list` shows a remote session's workspace as `box:proj`.

**In the browser** (**Verified** against the same pair), run
`HOME=$HOME/loom-demo/orchestrator/home loom ui --open`. When the orchestrator
configures any executor, the home page's "Other folders" section has a "New
session on an executor" button. It opens a form with the executor to choose, the
registered workspace name to type, and an optional session name. A remote
session is listed under a `box:proj` heading, and that heading has no "New
session" button of its own: use the form.

What to expect:

- A name that is not an `[executors.<name>]` key is refused with
  `executor_unknown`. The terminal says `executor_unknown: no executor with that
  name is configured on this daemon; --executor must be an [executors.<name>] key
  of the daemon's configuration` (**Verified**). The page says the executor is
  not in the daemon's configuration, in fixed words that its tests pin.
- A workspace name that holds a `/` is refused before a daemon is asked. The
  terminal refuses it at launch (**Verified**), and the page's daemon refuses it
  in fixed words (tests only).
- A valid name creates the session. If the executor cannot be reached, the
  session fails to open with a reason that begins `executor_unavailable:`. The
  terminal shows it as `session startup failed (executor_unavailable): <reason>`,
  and the page shows the reason after saying whether the session was kept
  (**Pending**: an unreachable executor was not run against these clients).
  A reachable executor assembles the session on its side. In the run behind this
  page the executor ran the session's startup commands, but the orchestrator then
  reported `stale_operation` and an open that "did not open in time", so opening
  the session was not verified (**Pending**).

Once a remote session is open (**Pending**), tool calls such as `fs_read`, `bash`
and `grep` run on the executor, in the registered workspace, and their results
come back into the conversation. Approval prompts still appear on the
orchestrator's clients.

## 8. Verify it is working

| Check | How | Status |
|---|---|---|
| Each daemon booted on TLS distribution | `epmd -names` on that machine lists its node name | **Verified** |
| The options file matches the config | `loomd distribution options` ran without error and you started with `LOOM_DISTRIBUTION_OPTFILE` | **Verified** |
| The TLS handshake and pins | `openssl s_client` with the peer's certificate (section 4) shows `Verification: OK` | **Verified** |
| The orchestrator is connected to the executor | On the executor, an established connection on its `listen_port`: `lsof -nP -iTCP:9100 -sTCP:ESTABLISHED` (macOS) or `ss -tn state established '( sport = :9100 )'` (Linux) | **Pending** (the daemon connects when a remote session opens) |
| A tool ran remotely | Create a remote session, ask for `pwd` or a file listing, and compare with the executor's checkout | **Pending** |

Where things land on a remote session (**Pending**): the checkout, its `.git`,
`.blobs` and the code-mode work directories are on the executor, under the
workspace root and its state directory. The conversation database, approvals
and `~/.loom` stay on the orchestrator.

The daemon prints JSON lines to its standard output. When a boot check fails, it
prints one plain line first (see below) and exits with status 1.

## 9. Troubleshooting

**`[distribution] is configured but this VM was not booted with -proto_dist
inet_tls`** (**Verified**). You started the daemon without
`LOOM_DISTRIBUTION_OPTFILE`, or you started it by some route that does not use
`bin/loomd`. Generate the options file and start through `bin/loomd` with the
variable set. The daemon exits without opening anything.

**`... booted without -ssl_dist_optfile`, or `ERL_FLAGS` conflicts.** `ERL_FLAGS`
must not set `-name`, `-sname`, `-setcookie` or `-ssl_dist_opt`. Unset it.

**`... options file is not private or was generated from a different
configuration`.** Rerun `loomd distribution options` after editing
`[distribution]`.

**The daemon exits with a message about credentials.** One of the four files is
missing, too large, or too open; the key and the cookie must be mode 0600; the
cookie must be 16 or more characters of `A-Z a-z 0-9 _ -` with no trailing
newline; the cookie path must be exactly `$HOME/.erlang.cookie` for the user
running the daemon (a different `HOME` means a different file); and this node's
certificate must carry its own node name as a DNS name. Check the name with
`openssl x509 -in cert.pem -noout -ext subjectAltName`.

**Pin mismatch** (**Pending**). The orchestrator cannot connect and reports the
executor as unavailable. Either the pin in `[[distribution.peers]]` is not the
hash of that peer's current certificate, or the peer presents a certificate for
a different node name. Recompute the pin and compare:

```sh
openssl x509 -in cert.pem -outform DER | openssl dgst -sha256
```

Reissuing a certificate changes its pin, and both sides must be updated. A
mismatch is reported as a plain failure, not a detailed one, on purpose.

**The peers cannot connect and nothing mentions a pin** (**Not run**). Check, in
order: the executor's node name host resolves from the orchestrator; port 4369
and the `listen_port` are open from the orchestrator's address
(`nc -vz <host> 4369`); `epmd -names` on the executor lists its node; the clocks
on both machines are within a few minutes of each other, because certificates
have validity dates.

**The nodes share no cookie.** Every node must hold the same cookie. A bundle set
from one `provision` run does. If you hand-edited one `.erlang.cookie`, copy
the same file everywhere.

**Two daemons on one machine fight over a cookie.** The cookie is per `HOME`.
Give each daemon its own `HOME`, as in section 4.

**The executor on macOS enforces less.** On Linux the executor jails commands
with bubblewrap, Landlock, seccomp and cgroup limits, and the daemon requires
all of them. On macOS the jail is a Seatbelt profile, and the daemon accepts
three reported gaps that Linux does not have (see "The sandbox" in
[running Loom](running.md)). `--full-enforcement` demands the full
cross-platform contract and refuses to start on a Mac; `--best-effort` accepts
broader gaps. A Linux Docker container on a Mac is still a Linux VM with Linux
enforcement, but it needs the full-isolation posture (section 6). Choose the
Linux executor for untrusted work.

## 10. Limits of this phase

This phase moves a whole tool call to the machine that holds the checkout. It
does not yet do the following.

- **One executor per session, chosen at creation.** There are no pools, no
  failover to a second executor, and no moving a session from one executor to
  another. If the executor is down, the session shows it as unavailable and
  waits.
- **No extension tools on remote sessions.** Extensions are installed under the
  orchestrator's home and would have to run beside the checkout. A remote
  session refuses them.
- **No operator-added directories on remote sessions.** They are validated
  against the orchestrator's disk.
- **No background code mode and no MCP facades in code mode on remote
  sessions.** Foreground `code_mode` works, without those two features.
- **No automatic connection.** Nodes connect only to the peers you list, only
  when asked.

The orchestrator and executor trust each other completely. Do not put an
executor on a machine you would not trust with the orchestrator's provider keys.
