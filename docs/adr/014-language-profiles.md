# ADR-014: a language server is a profile, and profiles ship as extensions

**Status**: accepted · **Date**: 2026-09-25 · **Supersedes**: nothing ·
**Builds on**: ADR-013 (language servers as jailed leases), ADR-007
(extension tiers) · **Issue**: #515

## The question

ADR-013 made Loom's language-server path language-neutral in its
mechanism: the protocol, the jail, settlement, rename through hashline
and the symbol-addressed tools know no language. What a language needs
beyond that lives in an `[lsp.<name>]` table the operator writes into
`loom.toml`. That table is where every language-specific fact lives: the
command, the extensions, the root markers, and the roots the jail must
grant. Take `gopls` as an example. Its build cache is in `~/.cache` on
Linux and in `~/Library/Caches` on macOS, and granting the wrong one
leaves it loading no packages at all. That is the table an operator
should not have to derive for themselves.

Two further facts were left out of the table and hard-wired instead,
each as a default that fits the two measured servers:

- **The `languageId`** a document is opened with is its server's first
  extension without the dot. It is right for `gleam` and `go`, and wrong
  for TypeScript (`typescript`, not `ts`).
- **A qualified symbol** is split on `.`, and its qualifier must end the
  definition's module path. That fits Gleam and Go. It cannot express
  Rust's or C++'s `::`, or Elixir's `MyApp.Accounts` in
  `my_app/accounts.ex`.

So adding a language today means an operator who knows its server's
cache layout, and for some languages a change to Loom itself. The
question is what "support a language" should mean, so that adding one
is neither.

Three answers were on the table (#515):

1. **Leave it.** Every operator writes their own tables. Nothing is
   shared, nothing is checked, and the two hard-wired defaults stay
   wrong for the languages they do not fit.
2. **Move language servers wholly into extensions.** The extension would
   hold the client, the protocol and the tools. It would take five new
   platform capabilities first: long-lived child processes with
   streaming stdio, extension state across calls, concurrent calls into
   one satellite, a conditional write for rename's stale check, and
   code-mode reach into extension tools. Each widens what extensions
   may do. It would also move the safety properties of ADR-013
   (hashline landing, the exfiltration gate on server-named paths, the
   enforcement probe, the lease cap) out of the one place they are
   audited.
3. **Profiles as data.** The harness keeps the mechanism. A language is
   described by a declarative profile, the same schema whether an
   operator writes it in `loom.toml` or an extension ships it, and the
   profile carries the per-language facts the defaults used to guess.

## Decision

Option 3.

### 1. One schema, one decoder

A **language profile** is the `[lsp.<name>]` table. Its decoder moves
out of `client/catalog` into `client/lsp/profile`, a pure module, and
both `loom.toml` and an extension manifest decode through it. The two
cannot drift into accepting different things, and a profile copied
from an extension into `loom.toml` means exactly what it meant there.

### 2. The schema grows five optional keys and one path form

Each key's default is exactly the behaviour ADR-013 shipped, so every
existing table means what it meant.

- **`language_id`** — the `languageId` a document is opened with.
  Default: the first extension without its dot. Grammar
  `[a-z0-9][a-z0-9+._-]*`, at most 40 characters.
- **`qualifier_separators`** — the separators a qualified symbol is
  split on, e.g. `["::"]`. Default `["."]`. Longest first when several
  are listed. Each is non-empty, holds no whitespace, and is not `/`.
  `/` keeps its ADR-013 meaning of a path inside a qualifier
  (`pkg/mod.name`).
- **`module_case`** — how a qualifier's segments are compared with
  directory and file names. `"as-written"` (default) compares them
  verbatim. `"snake"` first maps each segment from CamelCase to
  snake_case (`MyApp` → `my_app`, `HTTPServer` → `http_server`), which
  is how Elixir and Ruby lay modules out on disk.
- **`hint`** — one line, at most 200 bytes, printable, telling the model
  how this language spells a qualified name ("Qualify as
  module::name, without crate::"). It is appended once, to
  `lsp_definition`'s description, for sessions that configure the
  server, and nowhere else; every other symbol-taking tool already
  addresses symbols the same way. A convention the resolver cannot
  express (Rust's leading `crate::`) is one the hint tells the model to
  leave out, rather than one more key.
  It is operator-approved text in the model's context, exactly as an
  extension's tool description is, and it costs nothing in a session
  that does not configure the server.
- **`<cache>/rest`** in `readable` and `writable`, beside `/abs` and
  `~/rest`: the per-user cache directory. On Linux that is
  `$XDG_CACHE_HOME` when the daemon was started with an absolute one,
  else `$HOME/.cache`. On macOS it is `$HOME/Library/Caches`. It is
  expanded where `~/` is, against the daemon's own environment, once.
- **`cache_env`** — a table of environment variable name to a relative
  directory name, e.g. `cache_env = { XDG_CACHE_HOME = "xdg" }`. Each
  variable is set to `<cache>/loom/lsp/<server>/<dir>`, a directory
  Loom owns and shares with no host tool; the harness creates it
  (`mkdir -p`) before the jail starts, grants it writable, and sets the
  variable to it. Default: none.
  It is the one value-carrying environment the schema allows, and the
  value can only ever point into that private cache. The reason is a
  hazard `writable` cannot express: a server's tools often keep a cache
  the host's own tools trust unverified. `go build` reads `GOCACHE`
  without checking it, and `go list` in the jail runs cgo with the
  project's `#cgo` flags, which the model can write, so a jail that
  shared the operator's `~/.cache/go-build` could plant entries a later
  host build links. That is the hazard `lsp_rust` refuses for
  `~/.cargo`, and `cache_env` is how a server gets a writable cache
  without it.
  The rules: a name follows the `env` grammar, is listed once, and is
  none the harness owns (`PATH`, `HOME`, `TMPDIR` and the rest `env`
  refuses); a name also in `env` is refused, as two sources for one
  variable; a directory is non-empty and relative, with no empty, `.` or
  `..` component, and lies inside no other entry's directory, since the
  server can write the outer one and could swap the inner for a link
  before the next start binds it. Each refusal names
  `lsp.<name>.cache_env.<VAR>`.

Nothing else is added. Code actions, formatting and completion are
still not built (ADR-013). Server-specific `initializationOptions` are
the next candidate, and wait for a server that needs them.

### 3. Profiles ship as `profile`-tier extensions

An extension manifest gains a second tier:

```toml
[extension]
name = "lsp_go"
version = "0.1.0"
description = "gopls for Loom's language-server tools"
license = "Apache-2.0"
tier = "profile"

[lsp.go]
command = ["gopls"]
extensions = [".go"]
root_markers = ["go.mod"]
readable = ["~/go/pkg/mod"]
cache_env = { XDG_CACHE_HOME = "xdg", GOCACHE = "go-build", GOPLSCACHE = "gopls" }
env = ["GOFLAGS"]
```

A profile extension holds data and nothing that runs:

- **Allowed contents.** It declares at least one `[lsp.<name>]` table
  and may declare `[[check]]`s (§5).
- **Refused tables.** It declares no `[[tool]]`, `[[hook]]` or `[net]`,
  and the decoder refuses each by name.
- **The install.** It is fetch, extract, manifest and record. There is
  nothing to vet and nothing to compile, so it needs no code-mode
  toolchain.
- **Extra files are inert.** A fixture, a README or a `.gleam` file in
  the tree is never vetted, compiled or loaded.

**The record keeps what was approved.** An install's approval covers
what the profile makes the jail grant: the command it runs, the
extensions it claims, the root markers that choose its project, the
roots and environment names it passes, and its private caches. The
approval prints two grants the jail derives rather than reads from a
key: the command's own executable directory, mounted read-only (a
link's target directory as well, never an install prefix), and each
`cache_env` directory.
The install record carries each approved profile in full, beside the
tier, for the reason it already carries approved hooks: the grant is
part of the approval, not something re-read from a file that may have
changed. The record format moves to 3. A format-2 record is still read,
as a jailed extension with no profiles; a format-2 record cannot hold a
profile, so reading it that way loses nothing and forces no reinstall.

**A load re-derives the approval.** It checks, in order:

- the record;
- the directory's name;
- the tree digest;
- the manifest, decoded again;
- that the manifest's tier equals the record's;
- that the manifest's profiles equal the record's.

The tier check is not redundant. Without it, a jailed record edited to
say `profile`, with no profiles, would pass the profile comparison
(`[] == []`) and skip re-vetting and the artifact check a jailed
extension owes.

**An install keeps the fixtures.** A profile install keeps the
manifest, the tree's README and licence, and every file under each
check's fixture, and prunes the rest. The jailed tier's prune keeps
only what vetting admits, which would delete the fixtures `loom ext
check` runs against. Kept files must be UTF-8, as the load's own
reading requires.

A mismatch refuses the extension, and `loom ext list` says why. That is
the jailed tier's rule without the two steps a profile has no subject
for, re-vetting and the artifact check.

### 4. Precedence: the operator's file wins, and a conflict refuses the install

A session's servers are its `loom.toml` tables plus every loaded
profile whose server name `loom.toml` does not use:

- **Replacement is whole.** A `loom.toml` table replaces an installed
  profile of the same name entirely, never field by field. A merged
  profile would be a grant nobody wrote down.
- **A conflict refuses the installed side.** An extension claimed twice
  across the combined set, or two installed profiles sharing a server
  name, refuses every installed profile involved. The refusal is logged
  as `lsp.profile_refused`, naming the other claimant, and the boot
  continues. The operator's own tables are never the refused side.
- **Refusal, not first-wins.** Install order is not an order anybody
  chose, so letting one win would decide by accident.
- **Within `loom.toml`,** a conflict stays a parse error, as ADR-013
  made it.

### 5. A profile proves itself against its own fixture

A profile is a claim about a server's behaviour, and ADR-013 was built
by measuring servers rather than reading their documentation. So a
profile extension may carry checks:

```toml
[[check]]
server = "go"
fixture = "fixture"            # a directory in the tree; the default
query = "definition"           # "definition" or "references"
symbol = "util.Greet"
expect = ["util/util.go:3"]    # fixture-relative path:line, as a set
```

`loom ext check <name>` writes the fixture into a scratch workspace
from the tree the install's digest was verified over, never copying it
from disk again (a copy would follow a link planted since). It starts
the profile's server under the ordinary jail, the enforcement probe and
the operator's demand included, and runs each check through the same
door the tools use. An answer whose sites differ from `expect`
as a set fails that check, naming both sets, and the verb exits 1.

Checks are for authors and for CI. They are not run at install or at
boot: an install is not a benchmark, and starting a server at boot is
what ADR-013 §1 made lazy.

### 6. First-party profiles are extensions, not built-ins

Loom's repository ships `extensions/lsp_gleam`, `extensions/lsp_go` and
`extensions/lsp_rust`. Each is a profile extension with a fixture and
checks, installable with `loom ext install ./extensions/lsp_go`. CI
installs all three and runs their checks in the jail lane. Rust is there
because it is the language the old defaults could not serve: it needs
`qualifier_separators = ["::"]`.

A profile names only roots a normal install has already created, because
a missing writable root refuses the whole jail: bwrap needs a read-write
bind's source to exist. `lsp_go` needs a writable build cache, or
`go list` loads no packages, and it must not be the host's own
`<cache>/go-build`, for the reason `cache_env` exists (§2). So it grants
no writable root at all and sets
`cache_env = { XDG_CACHE_HOME = "xdg", GOCACHE = "go-build", GOPLSCACHE = "gopls" }`:
the harness creates `go-build`, `gopls` and `xdg` under
`<cache>/loom/lsp/go/`; `go` in the jail builds into the first, `gopls`
keeps its file cache in the second, and anything else that reads
`XDG_CACHE_HOME` (the `goimports` cache gopls keeps) uses the third.
`GOCACHE` and `GOPLSCACHE` are named rather than derived from
`XDG_CACHE_HOME` because Go and gopls read that variable on Linux only;
on macOS their defaults are under `~/Library/Caches`, which the jail
does not grant, so naming them keeps both caches private on every
platform. Measured on Linux with the fixture: both checks pass, gopls
writes into the private `gopls` directory, and the host's
`~/.cache/go-build` is untouched by the check.
Otherwise `env` passes names only, never values, so a profile cannot
point a tool somewhere of its own choosing: `lsp_rust` carries no
`CARGO_TARGET_DIR`, and grants `~/.rustup` and `~/.cargo/registry`
read-only and nothing writable, which measurement showed is enough for a
crate with a committed `Cargo.lock`.

`docs/examples/loom.toml` keeps its two example tables, pointing at the
extensions as the maintained versions.

### 7. A freshly started server is not queried until it is ready

Measuring `rust-analyzer` for its profile found a behaviour neither
ADR-013 server has. It answers requests while it is still loading the
Cargo workspace, and answers them with **empty results rather than
errors**:

- a definition came back empty;
- references held only the declaration;
- a rename edited one of the two files it had to.

`gopls` and `gleam lsp` hold a request until they can answer it, so the
problem never showed on them.

The answer is standard LSP, not a profile key:

- **The client declares `window.workDoneProgress`** and tracks the
  server's active work-done tokens (`$/progress` begin and end).
- **After a fresh start, the manager waits for quiet.** It waits until
  no token has been active for a continuous 300 ms, bounded at 60 s.
  The window exists because a server may not have begun its progress
  when `initialized` is sent. Measured: the manager asked 37 ms after
  the handshake and `rust-analyzer`'s first progress began 4 ms later.
  Without the window, the same definition answered empty in 114 ms.
- **A server still loading at the bound is answered, not guessed.** The
  answer is `Unavailable`, naming the progress titles ("still loading
  (Indexing); ask again in a moment"), never an empty list.
- **Warm queries do not wait.** A server that begins a token and never
  ends it would otherwise stall every later query for the whole bound.
  Waiting only after a start heals itself: one "still loading" answer,
  then warm queries proceed. Stale answers during a re-index after an
  edit are the server's own behaviour, as they are for any client.

Measured through the jail on a two-file crate, `rust-analyzer` was quiet
3.75 s after the handshake. Every site then answered correctly,
including a call inside `println!`, which needs the standard library's
macros.

## What it costs

- **A new tier.** The extension trust model gains one, which is strictly
  narrower than the jailed tier (no code). It carries one authority the
  jailed tier does not: naming a binary for the harness to run in a
  jail. That authority is exactly what an `[lsp.<name>]` table already
  holds, and the install record makes its approval explicit.
- **Record format 3.** Readers accept 2 and 3.
- **The hint** adds up to 200 bytes per configured server to the cached
  tool descriptions.
- **Per-language CI.** One toolchain per first-party profile in the jail
  lane: `gleam`, `go` with `gopls`, and `rust-analyzer` with `rust-src`.
- **A private cache per server that asks for one.** `lsp_go` builds
  into its own `<cache>/loom/lsp/go/go-build` rather than the host's Go
  cache, so the first query on a host starts cold and the directory
  then duplicates what the host's cache holds for the same packages.
- **Up to 60 s on a cold start** for a server that reports long work
  done, answered as "still loading" rather than as an empty result.

## What would prove this wrong

A language whose server cannot be served by data alone:

- one needing per-request adaptation;
- one needing a qualified-name rule no separator and case mapping
  express;
- one needing an `initializationOptions` payload computed from the
  host;
- one whose tools need an environment value that is neither a name the
  daemon supplies nor a private cache Loom owns, such as a path into the
  project or a shared host directory.

The first two are the signal to revisit option 2. That starts with the
streaming child-process capability #515 names, which DAP (#26) would
use as well. The third is a schema key, not a mechanism. The fourth would mean
`cache_env`'s one kind of value was too narrow, and the answer is a
second, equally closed kind, never a free-form value.
