# lsp_go

`gopls` as a Loom language profile (ADR-014). It is the maintained
version of the `[lsp.go]` example in `docs/examples/loom.toml`.

```sh
go install golang.org/x/tools/gopls@latest
loomd ext install ./extensions/lsp_go
loomd ext check lsp_go
```

The host needs `gopls` and `go` on the daemon's `PATH` (`go install`
puts `gopls` in `~/go/bin`, which is on few), and `rg`. `gopls` runs
`go list`, so these must hold for `go` in the jail:

- **Its GOROOT is readable.** The jail's system view holds `/usr`,
  `/opt` and, on macOS, `/opt/homebrew`; a Go installed elsewhere (a CI
  runner's tool cache, `~/sdk`) is not in it. Copy this table into
  `loom.toml` with that GOROOT added to `readable`.
- **Its module cache is where the profile says.** The profile grants
  the default module cache (`~/go/pkg/mod`) read-only. If
  `go env GOMODCACHE` prints somewhere else, copy the table into
  `loom.toml` naming that.
- **Its caches are Loom's, not yours.** `cache_env` sets `GOCACHE` to
  `<cache>/loom/lsp/go/go-build`, `GOPLSCACHE` to
  `<cache>/loom/lsp/go/gopls` and `XDG_CACHE_HOME` to
  `<cache>/loom/lsp/go/xdg`, directories Loom creates and grants
  writable. The host's own `~/.cache/go-build` is never granted: the
  host's `go build` trusts that cache without verifying it, and
  `go list` in the jail runs cgo with flags the project, and so the
  model, can write.
- **`GOCACHE` is named, not left to follow `XDG_CACHE_HOME`.** Go
  derives its default build cache from `XDG_CACHE_HOME` on Linux and
  the other Unixes, but on macOS from `~/Library/Caches`, which the jail
  does not grant. Naming it makes the build cache private on every
  platform. The two directories are siblings because a cache inside
  another is refused: the server could swap the inner one for a link.
- **`GOPLSCACHE` is named for the same reason.** gopls keeps its file
  cache in `$GOPLSCACHE` when that is set, and otherwise in the
  platform's user cache directory, which on macOS is
  `~/Library/Caches/gopls` whatever `XDG_CACHE_HOME` says. Naming it
  makes gopls's cache private on every platform.
- **`XDG_CACHE_HOME` stays** for the other tools that read it, such as
  the `goimports` cache gopls keeps.

`fixture/` is a module with two packages, and the two `[[check]]`s are
`util.Greet`'s definition and its references. A `loom.toml` table named
`go` replaces this profile whole.
