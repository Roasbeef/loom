# lsp_rust

`rust-analyzer` as a Loom language profile (ADR-014). Rust is here
because Loom's old defaults could not serve it: it qualifies names with
`::`, which the profile's `qualifier_separators` configures.

```sh
rustup component add rust-analyzer rust-src
RUSTC_BOOTSTRAP=1 cargo fetch --target "$(rustc -vV | sed -n 's/^host: //p')" \
  --manifest-path "$(rustc --print sysroot)/lib/rustlib/src/rust/library/Cargo.toml"
loomd ext install ./extensions/lsp_rust
loomd ext check lsp_rust
```

## What the host must hold

`rust-analyzer` loads the standard library as a Cargo workspace of its
own, from `rust-src`, and resolving it needs std's own dependencies
(`hashbrown`, `libc` and a few more) from `~/.cargo/registry`. The jail
has no network, so they must already be there. Without them std loads
incompletely, and a call inside `println!` — a std macro — is never
found. `cargo fetch` above puts them there, once, online. It needs
`RUSTC_BOOTSTRAP=1` because std's manifest uses an unstable Cargo
feature (without it, a stable `cargo` refuses to parse the manifest),
and `--target` limits it to the host, which is all `rust-analyzer`
resolves.

## What the jail grants

The profile grants `~/.rustup` and `~/.cargo/registry`, read-only, and
nothing writable. It assumes rustup's default layout; if `RUSTUP_HOME`
or `CARGO_HOME` point elsewhere, copy the table into `loom.toml` with
those directories instead.

- **Nothing under `~/.cargo` is writable.** A project's build scripts
  run inside the server's jail, and one that could write there could
  plant Cargo configuration or edit crate sources that later build on
  the host. Measured, Cargo works with it read-only.
- **The project is read-only too.** A crate therefore needs a committed
  `Cargo.lock`, since `cargo metadata` would otherwise write one and
  fail, and the crate would never load. `cargo check`, which
  `rust-analyzer` runs for build scripts and proc macros, cannot write
  `target/`. A crate that has neither is fully analysed; one that does
  loses what they generate.

Ask for a qualified name as the code spells it, without a leading
`crate::`: `util::greet`. The profile's `hint` tells the model the same.
A `loom.toml` table named `rust` replaces this profile whole.
