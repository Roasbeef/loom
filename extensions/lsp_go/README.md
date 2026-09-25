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
`go list`, so three things about `go` must hold in the jail:

- **Its GOROOT is readable.** The jail's system view holds `/usr`,
  `/opt` and, on macOS, `/opt/homebrew`; a Go installed elsewhere (a CI
  runner's tool cache, `~/sdk`) is not in it. Copy this table into
  `loom.toml` with that GOROOT added to `readable`.
- **Its caches are where the profile says.** The profile grants the
  default module cache (`~/go/pkg/mod`) and build cache
  (`<cache>/go-build`). If `go env GOMODCACHE` or `go env GOCACHE`
  prints somewhere else, copy the table into `loom.toml` naming those.
- **The build cache exists.** A writable root that does not exist
  refuses the whole jail. Any `go build`, including the `go install`
  above, creates it.

`fixture/` is a module with two packages, and the two `[[check]]`s are
`util.Greet`'s definition and its references. A `loom.toml` table named
`go` replaces this profile whole.
