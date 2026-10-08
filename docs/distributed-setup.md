# Setting up a distributed Loom

A distributed Loom splits one session across two machines. One machine runs the
agent loop and the other runs the tools against your files. This page shows how
to set that up, in the order you would do it.

The design is in [the distributed runtime note](design-notes/distributed-runtime.md)
and [protocol-change/078](../protocol-change/078-distributed-runtime.md). You do
not need either to follow this page.

## How to read the status marks

Each procedure carries a mark that says how far to trust it.

| Mark | Meaning |
|---|---|
| **Verified** | Observed in a named run, with the result described. The run is named at the mark. |
| **Pending** | Written from the code and its tests. Not observed in a named run on this commit. |
| **Not run** | Depends on your network or operating system, and nobody has run it. |

There is one run behind the **Verified** marks, the cross-host run on candidate
commit `193dbd8db`. It joined a Mac and a Linux box over SSH tunnels and has
three parts:

- **First attempt:** no tunnel, so the Mac could not reach the box. It observed
  the failure path of section 7.
- **Direction A:** the orchestrator on the Mac and the executor on the Linux box.
- **Direction B:** the orchestrator on the Linux box and the executor on the Mac.

All three minted their credentials with `scripts/distributed/mint-fixture.sh`,
and drove sessions over the control protocol with a scripted model provider. None
used `loom distribution provision` or `install`, the terminal or the web page.

A second run covers those, the local provisioning run on commit `46a3d0112`. It
ran on one Mac, with the orchestrator and the executor as two daemons under
separate home directories on the loopback address. It followed sections 3, 4, 7
and 8 literally: `init`, `provision`, `show` and `install`, the start commands
that `install` prints, a scripted model provider, a remote session created from
the terminal and from the web page, and the checks of section 8. It could not
observe anything that depends on two machines, such as a host name that differs
between the two roles, a tunnel or a firewall, so those marks stay with the
cross-host run or stay **Pending**.

Steps that an earlier edition of this page ran on one machine, and that neither
run repeated, are also **Pending**.

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
  [running Loom](running.md) for installing it, or build from a checkout. The
  commands below say `loomd` and `loom`; from a checkout, use `bin/loomd` and
  `bin/loom`. A checkout builds them, the sandbox helper and the code-mode seed
  with:

  ```sh
  make codemode-seed server-shipment tui-shipment sandbox
  install -m 0755 packages/sandbox/loom-exec bin/loom-exec
  ```

  `bin/loomd` finds `bin/loom-exec` beside it, which is what an executor needs to
  run commands. Build `bin/loom` from the same commit as `bin/loomd`: the terminal
  warns that the daemon build differs from its own when the two commits differ.
- A network path from the orchestrator to the executor. Only the orchestrator
  dials. Section 5 says which ports.
- For the Docker quick start, Docker with the Compose plugin and an x86_64
  Linux host. See [the Docker guide](docker.md) for why.

Node names matter. A node is named `name@host`. The host part must contain a
dot, so use a DNS name (`box.example.com`), a Tailscale name, or an IP address
(`10.0.0.5`). The orchestrator dials the host part of the executor's name, and
that same host is a name in the executor's certificate, so the address you put
here must be the address the orchestrator really connects to. Section 5 uses
this for tunnels.

## 3. Create the credentials

Every node gets a certificate signed by one private authority that `provision`
creates, and every node learns the SHA-256 fingerprint ("pin") of each peer's
certificate. A node accepts a peer only if the certificate chains to that
authority, hashes to the pin, and names exactly that peer's node name. All nodes
share one cookie.

You do not make these by hand. `loom distribution` does it, in three steps: write
a plan, provision it once, and install one bundle per machine. (`loom dist` is a
shorthand for `loom distribution`; this page uses the full form.) It needs no
`openssl`, because the Erlang runtime mints the certificates.

**Verified** (local provisioning run `46a3d0112`: `init`, `provision`, `show` and
`install` for one orchestrator and one executor, then both daemons started from
the files `install` wrote). The cross-host run used `mint-fixture.sh` instead (see
the end of this section). The files are the same.

Write an example plan:

```sh
loom distribution init plan.toml
```

Success prints `wrote /…/plan.toml` and a line that names the next command.
`init` refuses to overwrite an existing file. Edit the plan to name your nodes. A plan lists each node, its role, its
Erlang node name, and for an executor its workspaces (a short name and an
absolute path on that machine). This one has a laptop orchestrator and a Linux
box executor:

```toml
[[node]]
name = "laptop"
role = "orchestrator"
erlang_node = "orch@10.0.0.1"
executors = ["box"]

[[node]]
name = "box"
role = "executor"
erlang_node = "exec@10.0.0.2"
listen_port = 9100

[node.workspaces]
proj = "/home/me/src/myproj"
```

`name` is the bundle name, and for an executor it is also the
`[executors.<name>]` key on the orchestrator, which clients pass as
`--executor`. [The configuration reference](configuration.md#provisioning-a-deployment)
lists every plan key.

Then mint everything:

```sh
loom distribution provision plan.toml out
```

This prints each bundle's path, role and node name, and writes
`out/system.json`, a description of the deployment with no secrets, and one file
per node, `out/<name>.loombundle`. `loom distribution show out` prints
`system.json` as a table of nodes, pins and peer edges. **A bundle contains that node's
private key and the shared cookie.** Copy each bundle to its machine over a
channel you trust and delete the copies you do not need. Do not commit bundles.

```sh
scp out/box.loombundle me@box:
```

On each machine, install the bundle it was given:

```sh
loom distribution install box.loombundle
```

Install puts the certificates and key under `~/.loom/distribution` (or the
plan's `bundle_dir`), writes the cookie to `$HOME/.erlang.cookie`, merges the
role tables into `~/.loom/loom.toml`, writes the TLS options file next to the
certificates as `dist.options`, and prints the command that starts the daemon. It
is safe to run twice. Use `--home DIR` to install under another home, as section 4
does. It lists each file as `created`, and success ends with a printed line of the
form `HOME=… LOOM_DISTRIBUTION_OPTFILE=… loomd --config …`. That line names the
installed home, the options file and the configuration, and adds no flag of its
own: add `--bind` as section 4 shows, and from a checkout write `bin/loomd` for
`loomd`.

An orchestrator's installed `loom.toml` declares nothing about its executors.
Add `platform`, `enforcement` or `toolchains` to an `[executors.<name>]` table by
hand when a pool needs them (section 7).

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

[[distribution.peers]]
node = "exec@10.0.0.2"
sha256 = "<64 hex characters: the executor certificate's pin>"

[executors.box]
node = "exec@10.0.0.2"
```

The executor's `loom.toml`:

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

### The test fixture

`scripts/distributed/mint-fixture.sh` writes the same files with plain `openssl`.
It is for tests and demos, not for real deployments, and the smoke test
(`make docker-distributed-smoke`) and the cross-host run used it. Its arguments
are the output directory, the orchestrator's node and home, the executor's node
and home, and a workspace name and root. It refuses to overwrite an existing
directory, writes each node's files under `<output>/<role>/home`, and prints no
secret. Environment variables `EXEC_LISTEN_PORT`, `ORCH_LISTEN_PORT`, `EXEC_NAME`
and `WORKSPACES` are described at the top of the script. With the fixture you
render the options file yourself:

```sh
loomd distribution options $HOME/.loom/loom.toml $HOME/.loom/distribution.options
```

and start the daemon with `LOOM_DISTRIBUTION_OPTFILE` pointing at it. Rerun that
command whenever you edit `[distribution]`, because the daemon refuses an options
file that does not match its configuration. `install` does this for you.

## 4. Quick start A: two daemons on one machine

This is the fastest way to see it work. Both daemons run on your machine, each in
its own terminal, each with its own home directory so each has its own cookie and
state.

### Provision and install

**Verified** (local provisioning run `46a3d0112`, with `/Users/me/src/myproj`
replaced by a small git repository and `listen_port` 9150). Write a plan with two
nodes on the loopback address. Only the executor needs a fixed `listen_port`,
because the orchestrator dials and does not need to be dialled. Save it as
`plan.toml`:

```toml
[[node]]
name = "orch"
role = "orchestrator"
erlang_node = "orch@127.0.0.1"
executors = ["box"]

[[node]]
name = "box"
role = "executor"
erlang_node = "exec@127.0.0.1"
listen_port = 9100

[node.workspaces]
proj = "/Users/me/src/myproj"
```

```sh
loom distribution provision plan.toml out
```

The workspace path is a directory on the executor's machine. It does not need to
exist when you provision. Install each bundle under its own home. `install`
creates the home directory if it is missing:

```sh
loom distribution install out/box.loombundle --home $HOME/loom-demo/exec
```

```sh
loom distribution install out/orch.loombundle --home $HOME/loom-demo/orch
```

Each prints the command that starts its daemon. The orchestrator's `loom.toml`
also needs a `[models]` table and a `main` role, as any daemon's does, and
`install` does not write them. Append them to
`$HOME/loom-demo/orch/.loom/loom.toml`; `install` keeps whatever else the file
holds. A minimal pair for one Anthropic model looks like this, and
[the configuration reference](configuration.md#modelsname) lists every key and
the other dialects:

```toml
[models.main]
dialect = "anthropic"
api_key_env = "ANTHROPIC_API_KEY"
model_id = "<the model id your provider expects>"
context_window = 200000
max_output_tokens = 8192

[roles]
main = ["main"]
```

`api_key_env` names an environment variable, and the orchestrator reads it from
the environment of the process that runs `loomd`. Set it on the orchestrator's
start command below, and not in the file. The executor needs no model, and no key.

### Start the executor

In one terminal, run the command install printed for the executor and add a
`--bind` address (**Verified**, local provisioning run `46a3d0112`: the executor
started from the provisioned files and logged `daemon.executor_serving`, and the
cross-host run started its daemons the same way from fixture files). It looks like
this:

```sh
HOME=$HOME/loom-demo/exec LOOM_DISTRIBUTION_OPTFILE=$HOME/loom-demo/exec/.loom/distribution/dist.options \
  loomd --config $HOME/loom-demo/exec/.loom/loom.toml --bind 127.0.0.1:7442
```

`LOOM_DISTRIBUTION_OPTFILE` makes the launcher boot the Erlang VM with
`-proto_dist inet_tls -ssl_dist_optfile <file>`. Both the `bin/loomd` that
`make server-shipment` builds and the self-contained release launcher honour it.
Use the exact path install printed, which may differ from the one shown. From a
checkout, `loomd` is `bin/loomd`.

The daemon writes JSON log lines to its standard output, and starting TLS
distribution adds many `"event":"erlang"` progress records first. Look for the
`daemon.executor_serving` line, which an executor logs when it is ready to serve
its workspaces.

Code mode is off on an executor until you give it a seed, because `loomd` looks
for one at `<workspace>/build/codemode-seed` and then in the release. A remote
session then starts with a notice that code mode is unavailable and the
`code_mode` tool is not registered; every other tool works. From a checkout, add
`--codemode-seed <checkout>/build/codemode-seed` to the executor's command, after
`make codemode-seed`.

### Start the orchestrator

In another terminal. This is the command install printed with `--bind` added and
the model's key in front (**Verified**, same run):

```sh
ANTHROPIC_API_KEY=… HOME=$HOME/loom-demo/orch LOOM_DISTRIBUTION_OPTFILE=$HOME/loom-demo/orch/.loom/distribution/dist.options \
  loomd --config $HOME/loom-demo/orch/.loom/loom.toml --bind 127.0.0.1:7441
```

Add `--ui` to this command if you want the web page of section 7. Each daemon
prints `daemon listening on ws://127.0.0.1:<port>/v2/control` and its token file
path when it is up.

### Check that both are TLS nodes

**Verified** (local provisioning run `46a3d0112`; the cross-host run used
`epmd -names` on each machine). From a third terminal:

```sh
epmd -names
```

The output lists both nodes next to the ports of their distribution listeners:

```text
name exec at port 9150
name orch at port 49392
```

The executor shows the `listen_port` from the plan. The orchestrator shows a port
the system chose. Any other Erlang node on the machine is listed too.

If you are running a release without Erlang installed, `epmd` is in the release
at `erts-<version>/bin/epmd`.

To see the TLS handshake itself, connect to the executor's port with the
orchestrator's certificate. Use the port `epmd -names` printed for the executor,
which is its `listen_port`:

```sh
openssl s_client -connect 127.0.0.1:9150 -cert $HOME/loom-demo/orch/.loom/distribution/cert.pem -key $HOME/loom-demo/orch/.loom/distribution/key.pem -CAfile $HOME/loom-demo/orch/.loom/distribution/ca.pem </dev/null
```

Look for `Verification: OK` and `Protocol: TLSv1.3`. The certificate shown has
the executor's bundle name as its subject (`CN=box`), the deployment's authority
as issuer, and the node name in its subject alternative names.

Stop each daemon with Ctrl-C in its terminal when you are done.

## 5. Quick start B: a laptop and a Linux box

The orchestrator dials the executor. Nothing dials the orchestrator over
distribution. So the executor's machine must accept inbound connections on two
TCP ports, and the orchestrator's machine needs only outbound access.

| Port | What | Notes |
|---|---|---|
| 4369 | `epmd`, the Erlang name service | The orchestrator asks it which port the executor's node listens on. |
| `listen_port` | The executor's distribution listener | Set `listen_port` in the executor's plan entry so you can open one known port. Without it the port is random. |

Open exactly those two ports, to the orchestrator's address only. The TLS pins
and the cookie protect the connection, but an open port is still more than you
need to show.

The steps for either direction are the same as in section 4 with the roles on
different machines:

1. Choose how the orchestrator reaches the executor, and write that address as
   the host part of the executor's node name (`exec@<address>`).
2. Write the plan with both nodes and a workspace on the executor, and provision
   it (section 3).
3. Copy each bundle to its machine and install it there.
4. Start the executor first, then the orchestrator, each with the command its
   install printed.

### Reaching the executor

Pick the first of these that your network allows.

**Tailscale** (**Not run**). Install it on both machines and sign in to the same
tailnet. Use the executor's MagicDNS name or its `100.x.y.z` address as the host
in the node name, such as `exec@box.tailnet-name.ts.net`. Tailscale already
limits who can connect, so a firewall rule is optional. If the Linux box has
`ufw`:

```sh
sudo ufw allow in on tailscale0 to any port 4369,9100 proto tcp
```

**A private network or LAN** (**Not run**). Use the executor's LAN address in its
node name and allow the two ports from the orchestrator's address only:

```sh
sudo ufw allow from 192.168.1.20 to any port 4369,9100 proto tcp
```

**An SSH tunnel.** Use this when the executor's ports are not reachable from the
orchestrator, as on a hosted VM behind a provider proxy. Two tunnel recipes were
run in both directions, and they differ because of where each machine's own
`epmd` listens. In both, the node name's host is the address the tunnel is
reached at, and the executor's `listen_port` is the same number on both ends of
the tunnel.

#### Brains on the Mac, hands on Linux

**Verified** (cross-host run `193dbd8db`, direction A). The orchestrator runs on
a Mac and the executor on a Linux box that the Mac cannot reach directly. The
Mac's own `epmd` already listens on all addresses on port 4369. macOS allows a
second listener on one specific address and the same port, so the tunnel binds the
Mac's Tailscale or LAN address instead of `127.0.0.1`:

```sh
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -L 100.64.0.10:4369:127.0.0.1:4369 -L 100.64.0.10:9101:127.0.0.1:9101 me@box
```

Here `100.64.0.10` is the Mac's own address and `9101` is the executor's
`listen_port`. Leave this running in its own terminal. The tunnel's address is the
executor's node name, even though the executor runs on the box, so that the
certificate names what the Mac dials. In the plan:

```toml
[[node]]
name = "box"
role = "executor"
erlang_node = "exec@100.64.0.10"
listen_port = 9101
```

The orchestrator's node needs no special name. Start both daemons normally. The
executor registers with the box's own `epmd`. The Mac then asks
`100.64.0.10:4369`, which the tunnel carries to that `epmd`, and dials
`100.64.0.10:9101`, which the tunnel carries to the executor.

Check the tunnel from the Mac before you start the orchestrator (section 9 explains
why `nc -vz` is not enough):

```sh
printf '\x00\x01n' | nc -w 3 100.64.0.10 4369
```

The output must contain `name exec at port 9101`. In the run this printed
`name xhexec at port 9101`.

A Linux orchestrator cannot use this recipe. Linux does not let a second
listener share port 4369 with a wildcard `epmd`, so use the next recipe.

#### Brains on Linux, hands on the Mac

**Verified** (cross-host run `193dbd8db`, direction B). The orchestrator runs on a
Linux box and the executor on a Mac. The box already runs its own `epmd` on port
4369, and `sshd` binds a reverse forward to the box's loopback only. So the reverse
tunnel carries the Mac's `epmd` to an alternate port on the box, and the
orchestrator is told to use that port. Run this on the Mac, where the executor
listens on 9201:

```sh
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=5 -R 127.0.0.1:14369:127.0.0.1:4369 -R 127.0.0.1:9201:127.0.0.1:9201 me@box
```

Name the executor with the loopback address, because that is where the box reaches
it, and give the orchestrator the same host part:

```toml
[[node]]
name = "orch"
role = "orchestrator"
erlang_node = "orch@127.0.0.1"
executors = ["mac"]

[[node]]
name = "mac"
role = "executor"
erlang_node = "exec@127.0.0.1"
listen_port = 9201
```

The orchestrator on the box must not start its own `epmd` or open a listener: the
box's `epmd` already holds port 4369, and the orchestrator only dials. It also
must look peers up at the forwarded port. Both are set in the environment of the
process that starts `loomd`, in front of the command install printed:

```sh
ERL_FLAGS="-dist_listen false -start_epmd false" ERL_EPMD_PORT=14369 LOOM_DISTRIBUTION_OPTFILE=$HOME/.loom/distribution/dist.options loomd --config $HOME/.loom/loom.toml
```

`ERL_FLAGS` and `ERL_EPMD_PORT` belong to that command line, to the shell that
runs it or to the service unit that supervises it (`Environment=` in systemd).
The launcher appends its own `-proto_dist` flags to whatever `ERL_FLAGS` already
holds. The daemon refuses `ERL_FLAGS` that set `-name`, `-sname`, `-setcookie` or
`-ssl_dist_opt`, and accepts these two. `ERL_EPMD_PORT` must equal the local port
of the forwarded `epmd` (14369 here). A node that runs this way does not register
with `epmd`, so it does not appear in `epmd -names`; that is expected.

Check the tunnel from the box before you start the orchestrator:

```sh
printf '\x00\x01n' | nc -w 3 127.0.0.1 14369
```

The output must contain `name exec at port 9201`.

#### Keeping a dial-only orchestrator off the network

**Not run.** An orchestrator that never receives connections still opens a
distribution listener on every address unless you tell it otherwise. If it can
skip the listener (the Linux recipe above does), it should. If it must keep one, as
the Mac in direction A does, restrict it to loopback by adding the kernel option
to `ERL_FLAGS`:

```sh
ERL_FLAGS="-kernel inet_dist_use_interface {127,0,0,1}"
```

TLS, the pins and the cookie still apply to a reachable listener, so this reduces
exposure and does not replace them. The first cross-host attempt saw the Mac
orchestrator's listener on all interfaces.

#### Running a tunnel

If you start `ssh` in the background through a shell wrapper, there are two
processes. To drop the tunnel, stop the `ssh` process, not the wrapper.

## 6. Quick start C: Docker Compose

Compose runs an orchestrator container and an executor container from the same
`loom-runtime` image on one private network. Only the orchestrator's client port
is published, and only on the host's loopback. Distribution stays on the private
network.

The files are in `docker/distributed/`. Each container mounts one of two things
at `/bundle`. For a real deployment, that is the node's `.loombundle` from
`loom distribution provision`. The entrypoint also accepts the directory that
`scripts/distributed/mint-fixture.sh` writes, and the smoke test uses that. Compose
itself was not run for this page.

Build the image on an x86_64 Linux host. The repository `Dockerfile` is amd64
only, and building it under emulation on an Apple Silicon Mac fails; see
[the Docker guide](docker.md):

```sh
make docker-image
```

Provision with a plan that names the nodes `orchestrator@orchestrator.loom.internal`
and `executor@executor.loom.internal`, and gives the executor a workspace rooted at
`/work/project` (**Pending**):

```sh
loom distribution provision plan.toml out
```

```sh
cp out/orchestrator.loombundle out/executor.loombundle docker/distributed/
```

Start both containers (**Pending**):

```sh
docker compose -f docker/distributed/compose.yaml up -d
```

```sh
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
```

```sh
docker compose -f docker/distributed/compose.yaml cp orchestrator:/var/lib/loom/owner.token ./owner.token
```

The client then connects to `127.0.0.1:7331` with that token. Set
`LOOM_CLIENT_PORT` to publish a different host port.

### Postures

| Posture | How | What it gives | What it costs |
|---|---|---|---|
| Plain (default) | `compose.yaml` alone | Docker's boundary is the jail. The orchestrator is fine here, since it runs no model-written code. | Loom's own sandbox does not come up: `loom-exec --self-test` enforces 0 of 11 probes. A model's commands share the container with the daemon's state. |
| Full isolation | Add `compose.isolated.yaml` | Loom's own bubblewrap, Landlock, seccomp and cgroup limits come up for the executor: 10 of 11 probes. | Removes pieces of Docker's confinement from the executor container (host cgroup namespace, `SYS_ADMIN`, no seccomp, no AppArmor, unmasked `/proc` and `/sys`). Needs a Linux host with cgroup v2. |

For an executor that runs model-written commands you want full isolation. Start it
with both files:

```sh
docker compose -f docker/distributed/compose.yaml -f docker/distributed/compose.isolated.yaml up -d
```

```sh
docker compose -f docker/distributed/compose.yaml exec executor loom-exec --self-test
```

Expect 10 of 11 probes enforced, as in the measured table in
[the Docker guide](docker.md). The compose override does the cgroup delegation
from the entrypoint, which that guide did by hand; this has not been verified, so
run the self-test and read its output before relying on it.

The smoke test (`make docker-distributed-smoke`) starts the pair with throwaway
credentials from `mint-fixture.sh`, waits for both daemons to be ready, checks that
each container lists its node in `epmd`, and tears down only what it started. It
skips with a message when Docker is missing or the image cannot be built on the
host. It has not been run against the real image on the machine this page was
written on, which is an Apple Silicon Mac.

## 7. Create and use a remote session

A remote session is a normal session whose workspace is a name registered on an
executor instead of a directory on the orchestrator. A client asks for one by
passing `executor` and `workspace` to `sessions.create`
([client protocol, section 3.7](client-protocol.md)).

Both clients can create one. Each needs a `loom.toml` on the orchestrator that
defines at least one model and a `main` role, as any session does. The workspace
name is the executor's `[workspaces.<name>]` key. It is a name and not a path: the
orchestrator never looks for it on its own disk.

**In the terminal** (**Verified**, local provisioning run `46a3d0112`; the
cross-host run created sessions over the control protocol), start `loom` as the
orchestrator's user with the executor and the registered name. It needs a real
terminal, and exits with `interactive mode requires terminal input and output`
when its input or output is not one:

```sh
HOME=$HOME/loom-demo/orch loom --executor box --workspace proj
```

`--executor` is an `[executors.<name>]` key of the orchestrator's `loom.toml`, and
with it `--workspace` is the registered name, not a directory. The session picker
opens as it always does, with the remote sessions you already have grouped under
`PROJ on box`, or with `No saved sessions. Press n to create one.` when there are
none. Press `n` to create a new one in that workspace on that executor. The
session is `resident` once it opens, and the composer takes your prompt. Every `n`
in that terminal does the same until you quit. Add `--model-profile
<name>` to choose a model profile. `--executor` cannot be combined with
`--session`, which opens a session that exists, and `loom sessions list` shows a
remote session's workspace as `box:proj`.

**In the browser** (**Verified**, same run), start the orchestrator's daemon with
`--ui` (or set `[daemon] ui = true`), then run
`HOME=$HOME/loom-demo/orch loom ui --open`. Without `--ui` on that daemon,
`loom ui` answers `the running daemon was started without --ui` and starts
nothing, because it will not stop a daemon that other terminals may be using. When
the orchestrator configures any
executor, the home page's "Other folders" section has a "New session on an
executor" button. It opens a form with the executor to choose, the registered
workspace name to type, and an optional session name. A remote session is listed
under a `box:proj` heading, and that heading has no "New session" button of its
own: use the form.

What to expect:

- A name that is not an `[executors.<name>]` key is refused with
  `executor_unknown`. The terminal says `executor_unknown: no executor with that
  name is configured on this daemon; --executor must be an [executors.<name>] key
  of the daemon's configuration`. The page says the executor is not in the
  daemon's configuration, in fixed words that its tests pin. **Verified** for the
  terminal message, local provisioning run `46a3d0112`.
- A workspace name that holds a `/` is refused before a daemon is asked, with
  `--workspace with --executor needs a registered workspace name: 1 to 128 bytes
  with no / and no NUL, not a path`. `--executor` with `--session` is refused with
  `--executor and --pool name where a new session is created; --session opens an
  existing one`. **Verified**, same run.
- A valid name creates the session, which is `opening` while the orchestrator
  attaches the workspace on the executor, then `resident`. **Verified** in both
  directions of the cross-host run `193dbd8db`, and from the terminal and from the
  web form in the local provisioning run `46a3d0112`.

### When the executor cannot be reached

**Verified** (cross-host run `193dbd8db`, first attempt, over a real network with
no tunnel). `sessions.create` answered `opening`, and polling `operations.get`
returned `start_failed` with a message that begins `executor_unavailable:`:

```text
executor_unavailable: OTP could not start distribution or reach the peer; check
that epmd is reachable, the listen port is free, and the peer pins and
certificates match
```

The terminal shows the same reason as `session startup failed
(executor_unavailable): <reason>` (**Pending**; the run used the control protocol).
The reason names what failed: the connection,
a refusal by the executor (full, wrong incarnation, workspace not registered), or
a contradicted declaration. The daemon also logs it, as `reason` on the
`daemon.session_start_failed` record with `class` `executor_unavailable`. A reason
that contains a path is left out of the log and stays in `operations.get`.

**A failed open leaves the session `reserved`.** In the first attempt, the
session's state was `reserved` afterwards, and `sessions.open` answered
`not_initialized` with the message `request refused`. A reserved row has no
database behind it. Only a `sessions.create` retry under the original request key
finishes it, so a client that sees `not_initialized` must send the create again
with the same key, not call `sessions.open`. The protocol documents this in
[the status table (section 3.4)](client-protocol.md) and in
[the control codes (section 7.2)](client-protocol.md). Fix the cause first, and
check it with section 9. A session that has opened once and then fails to reopen
stays `saved`, and `sessions.open` retries it on the same executor.

**Verified** (local provisioning run `46a3d0112`) for the reopen case. With the
executor stopped, `sessions.open` on a saved remote session answered `opening` and
then `start_failed` with the same `executor_unavailable:` message as above. The
session stayed `saved`, and the orchestrator logged `daemon.session_start_failed`
with `stage` `runtime_assembly`, `class` `executor_unavailable` and that `reason`.
After the executor was started again, `sessions.open` on the same session reached
`resident`.

### Once a session is open

**Verified** (cross-host run `193dbd8db`, both directions). With a remote session
resident, a scripted turn called `fs_write`, `bash`, `fs_read` and a `bash` that
ran `uname -n; pwd; git …`. The results came from the executor: its host name, its
checkout path and its git commit. The file the model wrote was on the executor and
nowhere on the orchestrator. Approval prompts still appear on the orchestrator's
clients.

**Verified** on one machine (local provisioning run `46a3d0112`, from the terminal,
with a scripted provider). The same four tool calls ran, and the file landed in the
registered workspace on the executor and nowhere under the orchestrator's home. One
machine cannot show a different host name, so that part of the check needs two
machines. The `bash` call that ran `ls -la` exited 1 with `Operation not
permitted` for `.blobs/`, because the executor's sandbox protects that directory,
so the terminal summarised the turn as `1 failed`; the model's other calls and the
turn itself succeeded. The executor creates `.blobs/` and `.codemode/` in the
workspace root, each with its own `.gitignore`, so `git status` there stays clean.
Stopping the session and opening it again reattached at the next incarnation, and
a command in a second turn read the file written in the first.

Stopping the session closed the executor's scope, recorded as `closed` with
`all_retired`. Opening it
again reattached at the next incarnation, and a command in the second turn read
the file written in the first.

A call in flight when the tunnel dropped also survived. A 75-second command was
started, the tunnel was cut after about 12 seconds in direction A (and mid-call in
direction B), and the tunnel came back 16 to 30 seconds later. The command ran
exactly once, and the model received its result after recovery. Partitions of
other lengths were not run.

### Several executors: pools

With more than one executor you can let the orchestrator choose (**Pending**; the
shipped end-to-end test below covers it). A pool is a named list of executors in
the orchestrator's `loom.toml`:

```toml
[executors.box]
node = "exec@10.0.0.2"
platform = "linux/x86_64"
enforcement = "enforced"

[executors.spare]
node = "spare@10.0.0.3"
platform = "linux/x86_64"
enforcement = "enforced"

[pools.linux]
executors = ["box", "spare"]
platform = "linux/x86_64"
```

Create a session in the pool with `loom --pool linux --workspace proj`, or send
`pool` in place of `executor` to `sessions.create`. Every executor of the pool
needs a `[workspaces.proj]` of its own, because the orchestrator sends only the
name. `loom distribution provision` writes `[executors.<name>]` tables with no
declarations and no `[pools]`, so add both by hand. The rules are short:

- **Order, not balance.** The orchestrator tries the executors in the order the
  pool lists them. It goes to the next one only when the first could not hold the
  session: the connection to it failed, or it answered that it already holds the
  most scopes it admits (16 unless `LOOM_EXECUTOR_MAX_SCOPES` lowers it).
- **A session stays where it landed.** The first open records the executor in the
  session's own store. Every later open goes to that executor and never chooses
  again, because the checkout exists only there. If that executor is full or down,
  the open fails with `executor_unavailable:` and no other machine is tried.
  `loom sessions list` shows the session as `box:proj` once it has landed.
- **Declarations are claims you make.** `platform` is `<os>/<architecture>` as the
  system prompt writes it (`linux/x86_64`, `macos/arm64`), `enforcement` is
  `enforced` or `degraded`, and `toolchains` lists `codemode` or the key of an
  `[lsp.<name>]` server. A pool that sets one of them skips the executors that did
  not declare it. When a session attaches, the executor's answer is compared with
  its declaration, and a contradiction (an executor declared as `linux/x86_64`
  that reports `macos/arm64`) closes the scope and fails the open with both values
  in the message. Fix the file and open again.
- **A pool that is full everywhere fails and keeps nothing.** The next open starts
  from the whole pool again.

The repository's shipped end-to-end test boots an orchestrator and two executors
and creates sessions with `pool` over the control protocol. It checks that a pool
skips an executor that declares the wrong platform, that a contradicted declaration
closes its scope and fails the open, that a full executor is moved past, and that a
reopen into a full executor fails without moving. That test is not the cross-host
run. The terminal's `--pool` flag is covered by its own unit tests and was not run
against these daemons. The web home does not offer pools yet.

### Moving a session to another orchestrator

You can hand a remote session from one orchestrator to another while the
executor's checkout stays where it is. Use it to retire a machine that runs an
orchestrator, or to put a session where its owner now works. The session's
conversation database moves. The files, the checkout and the executor do not.

Only a session that lives on an executor can move. A local session's checkout is a
directory on the orchestrator, so there is nothing for a second orchestrator to
attach to. A session also has to have opened at least once, so that the executor
holds a scope for it, and it cannot be archived.

**What you need** (**Pending** as a hand-run procedure; the shipped move test,
described below, runs it over the control protocol). Both orchestrators and the
executor are distribution nodes under one authority and one cookie (section 3).
Each orchestrator pins the other and the executor, and the executor pins both:

```toml
# On orchestrator alpha, the one that holds the session.
[executors.box]
node = "exec@10.0.0.2"

[orchestrators.bravo]
node = "bravo@10.0.0.4"
address = "wss://bravo.example.com:8443/v2/control"
```

```toml
# On orchestrator bravo, the one that will receive it.
[executors.box]
node = "exec@10.0.0.2"

[orchestrators.alpha]
node = "alpha@10.0.0.1"
```

Each `[orchestrators.<name>]` node must also be a `[[distribution.peers]]` entry.
The name is yours to choose, and each daemon uses its own name for the other.
`address` is optional, and is only what a client is told when it asks the wrong
orchestrator where a session is. The receiver must list the sender as an
orchestrator, because it recognises the machine that hands it a session by its
node, and it must list the same `[executors.box]`, because it attaches to the
executor when the session opens. A session registered on the executor under one
name is attached under that name, so the executor name must match on both.

**1. Pick the session.** On the orchestrator that holds it, list the sessions and
find the one on the executor:

```sh
loom sessions list
```

A remote session shows its workspace as `box:proj`. The first column is the
session id.

**2. Start the move.** Name the session and the orchestrator that receives it:

```sh
loom sessions move 0198c0de-0000-7000-8000-000000000001 --to bravo
```

It prints `moving 0198c0de-0000-7000-8000-000000000001 to bravo (operation
<id>)` and returns. That means the daemon has stopped the session, recorded the
move, and will carry it out. The command does not wait. Asking again for the same
destination prints the same operation. Naming a destination that is not in the
`[orchestrators.<name>]` tables is refused with `orchestrator_unknown`. A local
session is refused with `not_movable`, and so is a session that was moved here
until the orchestrator it came from has finished that move; ask again a little
later.

**3. Wait for it to finish.** On the source, a session that is moving cannot be
opened. `sessions.open` answers `moving`, naming the destination and the
operation. When the move finishes it answers `not_owner`, naming the destination
and the address in your `[orchestrators.bravo]` row, and `sessions.get` reports
`moved` with `to`. The control protocol reports both
([client protocol, sections 3.5 and 3.27](client-protocol.md)). A move of an
ordinary session takes seconds: the executor closes the scope, the file is
copied, and the receiver checks it. The source daemon's log records
`daemon.move_finished` when it ends.

**4. Open it on the receiver.** Connect to the receiver as you would to any
orchestrator, with a credential for that daemon:

```sh
loom --addr wss://bravo.example.com:8443/v2/control --session 0198c0de-0000-7000-8000-000000000001 --token-file ~/bravo-owner.token
```

The session is saved there, so the terminal opens it. The executor attaches it at
the next incarnation, and a tool call reads the files the first incarnation wrote.

**What to expect.** The shipped move test runs three real daemons, two
orchestrators and one executor, and checks each of these over the control protocol
(**Verified**, the test `daemon_shipped_remote_move_test` on commit `56b384df4`,
on macOS). The `loom sessions move` command and the terminal launch above were not
run by hand.

- The executor's scope for the session is closed `all_retired` at incarnation 1
  before the copy is cut, and a background job the session had started is gone, so
  the file it appended to stops growing. A move does not carry running processes.
- The source keeps its file as `<id>.db.moved` and no file under the session's
  name. The receiver has the file under its sessions directory.
- The receiver opens the session at incarnation 2. The source's old token is
  refused by the executor.
- With `LOOM_MOVE_CRASH_AFTER` halting the source after each of the six steps, a
  restart finishes the move without being asked, and the session ends in the same
  place as a move with no fault. That variable belongs to the test; an operator
  never sets it.

**When a move does not finish.** The source retries a move that cannot proceed and
keeps it as `moving` in the meantime, so the session is not lost and is not served
by two orchestrators. The reason is in the source daemon's log as
`daemon.move_stalled`, repeated until it clears:

| Reason in the log | What to check |
|---|---|
| `the orchestrator bravo did not answer` | The receiver is down, the nodes are not connected, or its pins are wrong. Section 9 has the checks. The move continues when it answers. |
| `the executor box did not answer the close` | The executor is down, or the source does not list it. The move continues when the executor answers. |
| `the session file is held by ...` | A writer's lease has not expired, as after a crash of this daemon. Wait; it is at most a minute. |
| `this daemon does not list an orchestrator named bravo` | The configuration changed after the move began. Restore the `[orchestrators.bravo]` row and restart the daemon. |

A move that ends is logged as `daemon.move_aborted` with the reason, and the
session is the source's again and can be opened there. The reasons are final: the
executor could not prove it had retired every child of the scope; the file is
larger than 256 MiB or fails its own checks; or the receiver refused. The receiver
refuses when it does not list the sender, does not list the executor, holds the
session already, or finds that the copy's scope is not closed cleanly. Its own log
has `daemon.move_refused` with the same words. Fix the cause and start a new move.

A daemon that restarts resumes every move it had in flight. A receiver that is
restarted in the middle holds at most a partial file, which is never taken for a
copy, so the source sends the file again from the start.

**What does not move.** The memory the session distilled stays with the source's
workspace. Members and their grants stay on the source, which still lists them for
a session it no longer serves; the receiver's owner grants access on the receiver.
Nothing follows a client from the source to the receiver, so a client that held
the session open reconnects to the receiver and catches up from there.

The source keeps a tombstone. The session stays in its listing, shown as saved, and
opening it, archiving it, restoring it or deleting it names the new owner. The
tombstone is what stops a late message of the move from bringing the session back,
and what lets the session return to the source later: moving it from the receiver
back to the source is a new move, and the source takes it in over the tombstone.
If you remove `[distribution]` from a daemon while a move is in flight, the move
cannot resume, and the daemon logs `daemon.moves_cannot_resume` at startup.

## 8. Verify it is working

| Check | How | Status |
|---|---|---|
| Each daemon booted on TLS distribution | `epmd -names` on that machine lists its node name. A dial-only orchestrator (section 5) does not appear. | **Verified**, cross-host run `193dbd8db` (the box listed its executor and the Mac its orchestrator), and local provisioning run `46a3d0112` (both nodes listed, the executor at its `listen_port`) |
| The options file matches the config | The daemon started with `LOOM_DISTRIBUTION_OPTFILE` and did not exit with an options message | **Verified**, both runs |
| The peer answers as itself | `printf '\x00\x01n' \| nc -w 3 <host> 4369` prints `name <node> at port <n>`, and `openssl s_client -connect <host>:<port>` shows the node's own certificate | **Verified**, cross-host run `193dbd8db`: in the first attempt the `s_client` check showed a provider proxy's certificate, and in direction A the `epmd` request printed the node's name through the tunnel. In the local provisioning run `46a3d0112` the `epmd` request listed both nodes and `s_client` showed the executor's own certificate (`CN=box`, issued by the deployment's authority) |
| The TLS handshake and pins | `openssl s_client` with the peer's certificate (section 4) shows `Verification: OK` | **Verified**, local provisioning run `46a3d0112`: `Verification: OK`, `Protocol: TLSv1.3`, and the pin recomputed with `openssl dgst -sha256` equal to the `sha256` in the orchestrator's `[[distribution.peers]]` |
| The orchestrator is connected to the executor | On the executor, an established connection on its `listen_port`: `lsof -nP -iTCP:9100 -sTCP:ESTABLISHED` (macOS) or `ss -tn state established '( sport = :9100 )'` (Linux), with your `listen_port` for 9100. The daemon connects when a remote session opens, so create one first. | **Verified** on macOS, local provisioning run `46a3d0112`: after a session opened, `lsof` listed the connection from the orchestrator's VM to the executor's `listen_port`, established at both ends. The `ss` form is **Pending**. |
| A tool ran remotely | Create a remote session, ask for `uname -n` and `pwd`, and compare with the executor's host and checkout. Check that a file the model wrote exists there and not on the orchestrator. | **Verified**, cross-host run `193dbd8db`, both directions. On one machine (local provisioning run `46a3d0112`) the file check passed, and the host-name comparison cannot tell the two roles apart. |

Where things land on a remote session (**Verified** for the files, same run): the
checkout and the files a tool writes are on the executor, under the workspace root.
The conversation database, approvals and `~/.loom` stay on the orchestrator. The
`.blobs` and `.codemode` work directories are in the workspace root on the executor
too (**Verified**, local provisioning run `46a3d0112`).

The daemon prints JSON lines to its standard output. When a boot check fails, it
prints one plain line first (see below) and exits with status 1.

## 9. Troubleshooting

**`[distribution] is configured but this VM was not booted with -proto_dist
inet_tls`** (**Pending**). You started the daemon without
`LOOM_DISTRIBUTION_OPTFILE`, or you started it by some route that does not use
`bin/loomd`. Generate the options file and start through `bin/loomd` with the
variable set. The daemon exits without opening anything.

**`... booted without -ssl_dist_optfile`, or `ERL_FLAGS` conflicts.** `ERL_FLAGS`
must not set `-name`, `-sname`, `-setcookie` or `-ssl_dist_opt`. Remove those.
Other flags, such as `-dist_listen false` and `-start_epmd false` (section 5), are
accepted.

**`... options file is not private or was generated from a different
configuration`.** Rerun `loomd distribution options` after editing
`[distribution]`, or install the bundle again.

**The daemon exits with a message about credentials.** One of the four files is
missing, too large, or too open; the key and the cookie must be mode 0600; the
cookie must be 16 or more characters of `A-Z a-z 0-9 _ -` with no trailing
newline; the cookie path must be exactly `$HOME/.erlang.cookie` for the user
running the daemon (a different `HOME` means a different file); and this node's
certificate must carry its own node name as a DNS name. Check the name with
`openssl x509 -in cert.pem -noout -ext subjectAltName`.

**After an executor restart, a remote session will not open: `could not prove N
children of the closed scope are gone`** (**Pending**). The executor daemon
restarted while the session was open. The new daemon has no workspace for the
session's scope, so when the session closed, the executor could not prove the
scope's processes were gone and recorded unknown cleanup. It refuses every open of
that session after that, and a scope that was left closing by a daemon that ended
in the middle of a close is refused the same way (`... is closing`). The open does
not retry, because the executor will not decide for itself that the processes are
gone. Check on the executor that nothing from the session still runs, stop the
executor daemon, and release the scope:

```sh
loom executor release SESSION --state-dir ~/.loom
```

`SESSION` is the session id in the refusal. The command closes the scope as retired
and records the release in the executor's ledger, and it refuses to run while the
daemon is up. A daemon started while it runs is refused, and `loom` may report that
the daemon is still starting until you start it again. Start the daemon again and open the session. It reopens the scope, even when the orchestrator never recorded the close that the release replaced. A
scope that is open is refused by the command, because its session may be running:
close the session first. See "Releasing an executor's stuck scope" in
[configuration](configuration.md).

**A remote session fails to open with `executor_unavailable:`.** The reason after
the colon says what to check. It is in `operations.get` and in the daemon's
`daemon.session_start_failed` log record. For an unreachable executor, work
through these checks from the orchestrator's machine, in order.

1. The executor's node name host resolves, and the address is the one the
   orchestrator really reaches (or the tunnel's address, section 5).
2. `epmd` on that address answers. **Do not trust `nc -vz <host> 4369`.** Behind a
   TCP or TLS proxy, as on some hosted VMs, it prints `succeeded` because the
   proxy accepts the connection, though nothing of yours is behind it. Ask `epmd`
   a question instead:

   ```sh
   printf '\x00\x01n' | nc -w 3 <host> 4369
   ```

   The reply must contain the line `name <node> at port <n>`, after a few binary
   bytes. Silence, or no matching line, means the request did not reach an
   `epmd` that has your node registered. In the first cross-host attempt, `nc -vz`
   succeeded on both ports while this request returned nothing.
3. The distribution port answers as the node, not as a proxy:

   ```sh
   openssl s_client -connect <host>:<port> </dev/null
   ```

   The certificate shown must be the node's own (its subject alternative name is
   the node name, and it chains to your authority). In the first attempt this
   returned a certificate with subject `CN=exe.xyz`, which belonged to the
   provider's proxy. If the executor demands a client certificate, offer the
   orchestrator's with `-cert` and `-key`, as in section 4.
4. The clocks on both machines are within a few minutes of each other, because
   certificates have validity dates.

If the reason is a pin mismatch, see the next entry. After fixing the cause, retry
the create under its original request key (section 7).

**Pin mismatch** (**Pending**). The orchestrator cannot connect and reports the
executor as unavailable. Either the pin in `[[distribution.peers]]` is not the
hash of that peer's current certificate, or the peer presents a certificate for a
different node name. Recompute the pin and compare:

```sh
openssl x509 -in cert.pem -outform DER | openssl dgst -sha256
```

Reissuing a certificate changes its pin, and both sides must be updated. A
mismatch is reported as a plain failure, not a detailed one, on purpose.

**The nodes share no cookie.** Every node must hold the same cookie. A bundle set
from one `provision` run does. If you hand-edited one `.erlang.cookie`, copy the
same file everywhere.

**Two daemons on one machine fight over a cookie.** The cookie is per `HOME`. Give
each daemon its own `HOME`, as in section 4.

**The executor on macOS enforces less.** On Linux the executor jails commands with
bubblewrap, Landlock, seccomp and cgroup limits, and the daemon requires all of
them. On macOS the jail is a Seatbelt profile, and the daemon accepts three
reported gaps that Linux does not have (see "The sandbox" in
[running Loom](running.md)). `--full-enforcement` demands the full cross-platform
contract and refuses to start on a Mac; `--best-effort` accepts broader gaps. A
Linux Docker container on a Mac is still a Linux VM with Linux enforcement, but it
needs the full-isolation posture (section 6). Choose the Linux executor for
untrusted work.

## 10. Limits of this phase

This phase moves a whole tool call to the machine that holds the checkout. It does
not yet do the following.

- **One executor per session, chosen at its first open.** A pool picks the
  executor in the order you list, but there is no failover to a second executor
  and no moving a session from one executor to another. If the executor is down,
  the session shows it as unavailable and waits. A session can move between
  orchestrators (section 7), but it keeps its executor.
- **No extension tools on remote sessions.** Extensions are installed under the
  orchestrator's home and would have to run beside the checkout. A remote session
  refuses them.
- **No operator-added directories on remote sessions.** They are validated against
  the orchestrator's disk.
- **No background code mode and no MCP facades in code mode on remote sessions.**
  Foreground `code_mode` works, without those two features.
- **No automatic connection.** Nodes connect only to the peers you list, only when
  asked.
- **Provisioning is one-shot.** `provision` discards the authority's key, so adding
  a node or renewing a certificate means provisioning again and installing every
  bundle with `--force`.

The orchestrator and executor trust each other completely. Do not put an executor
on a machine you would not trust with the orchestrator's provider keys.
