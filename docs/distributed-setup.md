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
Those are covered by the client test suite, which boots two nodes from the files
that `install` writes, and are marked **Pending** here. Steps that an earlier
edition of this page ran on one machine, and that the cross-host run did not
repeat, are also **Pending**.

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
  commands below say `loomd`; from a checkout, use `bin/loomd`.
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

**Pending.** The cross-host run used `mint-fixture.sh` instead (see the end of
this section). The files are the same, and the client tests start two nodes from
the files `install` writes.

Write an example plan:

```sh
loom distribution init plan.toml
```

Success looks like `wrote /…/plan.toml`. `init` refuses to overwrite an existing
file. Edit the plan to name your nodes. A plan lists each node, its role, its
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

This writes `out/system.json`, a description of the deployment with no secrets,
and one file per node, `out/<name>.loombundle`. **A bundle contains that node's
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
role tables into `~/.loom/loom.toml`, writes the TLS options file, and prints the
command that starts the daemon. It is safe to run twice. Use `--home DIR` to
install under another home, as section 4 does. Success is a printed line of the
form `LOOM_DISTRIBUTION_OPTFILE=… loomd --config …`.

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

**Pending.** Write a plan with two nodes on the loopback address. Two nodes on
one host need different `listen_port` values, and only the executor needs a fixed
one. Save it as `plan.toml`:

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

Install each bundle under its own home:

```sh
loom distribution install out/box.loombundle --home $HOME/loom-demo/exec
```

```sh
loom distribution install out/orch.loombundle --home $HOME/loom-demo/orch
```

Each prints the command that starts its daemon. The orchestrator also needs a
`[models]` table and a `main` role in its `loom.toml`, as any daemon does;
install keeps whatever else the file holds.

### Start the executor

In one terminal, run the command install printed for the executor and add a
`--bind` address (**Pending** for the provisioned files; the cross-host run
started its daemons the same way from fixture files, with `HOME` set to the
node's home and `LOOM_DISTRIBUTION_OPTFILE` set, and the executor logged
`daemon.executor_serving`). It looks like this:

```sh
HOME=$HOME/loom-demo/exec LOOM_DISTRIBUTION_OPTFILE=$HOME/loom-demo/exec/.loom/distribution/dist.options \
  loomd --config $HOME/loom-demo/exec/.loom/loom.toml --bind 127.0.0.1:7442
```

`LOOM_DISTRIBUTION_OPTFILE` makes the launcher boot the Erlang VM with
`-proto_dist inet_tls -ssl_dist_optfile <file>`. Both the `bin/loomd` that
`make server-shipment` builds and the self-contained release launcher honour it.
Use the exact path install printed, which may differ from the one shown.

### Start the orchestrator

In another terminal:

```sh
HOME=$HOME/loom-demo/orch LOOM_DISTRIBUTION_OPTFILE=$HOME/loom-demo/orch/.loom/distribution/dist.options \
  loomd --config $HOME/loom-demo/orch/.loom/loom.toml --bind 127.0.0.1:7441
```

Each daemon prints `daemon listening on ws://127.0.0.1:<port>/v2/control` and its
token file path when it is up.

### Check that both are TLS nodes

**Pending** (run on one machine for an earlier edition of this page; the
cross-host run used `epmd -names` on each machine, which listed the executor).
From a third terminal:

```sh
epmd -names
```

The output lists both nodes next to the ports of their distribution listeners:

```text
name exec at port 49390
name orch at port 49392
```

If you are running a release without Erlang installed, `epmd` is in the release
at `erts-<version>/bin/epmd`.

To see the TLS handshake itself, connect to the executor's port with the
orchestrator's certificate. Use the port `epmd -names` printed:

```sh
openssl s_client -connect 127.0.0.1:49390 -cert $HOME/loom-demo/orch/.loom/distribution/cert.pem -key $HOME/loom-demo/orch/.loom/distribution/key.pem -CAfile $HOME/loom-demo/orch/.loom/distribution/ca.pem </dev/null
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

**In the terminal** (**Pending**; the cross-host run created sessions over the
control protocol), start `loom` as the orchestrator's user with the executor and
the registered name:

```sh
HOME=$HOME/loom-demo/orch loom --executor box --workspace proj
```

`--executor` is an `[executors.<name>]` key of the orchestrator's `loom.toml`, and
with it `--workspace` is the registered name, not a directory. The session picker
opens as it always does, with the remote sessions you already have grouped under
`PROJ  on box`. Press `n` to create a new one in that workspace on that executor.
Every `n` in that terminal does the same until you quit. Add `--model-profile
<name>` to choose a model profile. `--executor` cannot be combined with
`--session`, which opens a session that exists, and `loom sessions list` shows a
remote session's workspace as `box:proj`.

**In the browser** (**Pending**), run
`HOME=$HOME/loom-demo/orch loom ui --open`. When the orchestrator configures any
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
  daemon's configuration, in fixed words that its tests pin.
- A workspace name that holds a `/` is refused before a daemon is asked.
- A valid name creates the session, which is `opening` while the orchestrator
  attaches the workspace on the executor, then `resident`. **Verified** in both
  directions of the cross-host run `193dbd8db`.

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

### Once a session is open

**Verified** (cross-host run `193dbd8db`, both directions). With a remote session
resident, a scripted turn called `fs_write`, `bash`, `fs_read` and a `bash` that
ran `uname -n; pwd; git …`. The results came from the executor: its host name, its
checkout path and its git commit. The file the model wrote was on the executor and
nowhere on the orchestrator. Approval prompts still appear on the orchestrator's
clients.

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

## 8. Verify it is working

| Check | How | Status |
|---|---|---|
| Each daemon booted on TLS distribution | `epmd -names` on that machine lists its node name. A dial-only orchestrator (section 5) does not appear. | **Verified**, cross-host run `193dbd8db` (the box listed its executor and the Mac its orchestrator) |
| The options file matches the config | The daemon started with `LOOM_DISTRIBUTION_OPTFILE` and did not exit with an options message | **Verified**, same run |
| The peer answers as itself | `printf '\x00\x01n' \| nc -w 3 <host> 4369` prints `name <node> at port <n>`, and `openssl s_client -connect <host>:<port>` shows the node's own certificate | **Verified**, cross-host run `193dbd8db`: in the first attempt the `s_client` check showed a provider proxy's certificate, and in direction A the `epmd` request printed the node's name through the tunnel |
| The TLS handshake and pins | `openssl s_client` with the peer's certificate (section 4) shows `Verification: OK` | **Pending** |
| The orchestrator is connected to the executor | On the executor, an established connection on its `listen_port`: `lsof -nP -iTCP:9100 -sTCP:ESTABLISHED` (macOS) or `ss -tn state established '( sport = :9100 )'` (Linux) | **Pending** (the daemon connects when a remote session opens) |
| A tool ran remotely | Create a remote session, ask for `uname -n` and `pwd`, and compare with the executor's host and checkout. Check that a file the model wrote exists there and not on the orchestrator. | **Verified**, cross-host run `193dbd8db`, both directions |

Where things land on a remote session (**Verified** for the files, same run): the
checkout and the files a tool writes are on the executor, under the workspace root.
The conversation database, approvals and `~/.loom` stay on the orchestrator. The
`.blobs` and code-mode work directories are on the executor too (**Pending**).

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
  the session shows it as unavailable and waits.
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
