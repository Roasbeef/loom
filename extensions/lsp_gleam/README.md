# lsp_gleam

The Gleam language server, `gleam lsp`, as a Loom language profile
(ADR-014). It is the maintained version of the `[lsp.gleam]` example in
`docs/examples/loom.toml`.

```sh
loomd ext install ./extensions/lsp_gleam
loomd ext check lsp_gleam
```

The host needs `gleam` on the daemon's `PATH` (or code mode's located
toolchain, which a bare `gleam` means in a session) and `rg`, which a
bare-name question searches the project with. The server writes
`manifest.toml` and `build/` into the project, so the project is
writable; it needs nothing outside it.

`fixture/` is a two-module project, and the two `[[check]]`s in
`extension.toml` are a qualified definition (`util.greet`) and the
references across both modules. A `loom.toml` table named `gleam`
replaces this profile whole.
