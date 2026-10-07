> Archived at the October 7 pause. This records its original component or
> proposal state. The current handoff governs publication status and next steps.

# Reuse the existing bounded metadata reader

The standalone executor must verify prepared Gleam dependency metadata before it treats Prepare as successful. The existing codemode metadata reader checks file size, then reads the entire file, then checks size again. That does not bound the read allocation if the file grows during the read.

`packages/host/src/host/bootstrap.gleam:346` already exposes `read_bounded(path, limit)`. Its existing Erlang implementation opens one raw regular-file handle, reads chunks within the remaining bound, checks one byte past the limit and closes that same handle. The standalone executor currently has no dependency on `host`.

The proposed package change is:

```diff
--- a/packages/executor/gleam.toml
+++ b/packages/executor/gleam.toml
@@
 core = { path = "../core" }
+host = { path = "../host" }
 codemode = { path = "../codemode" }
```

The registered LSP composition will bind its closed metadata reader to the actual `host/bootstrap.read_bounded` function. The reader will run only after the existing enrollment, authorized-root, canonical-path and protected-path checks, under the original finite deadline, with a fixed 131072-byte limit per metadata file. Preparation readiness still requires the real expected files and their parsed contents. A recipe exit code alone will not establish readiness.

This adds an acyclic dependency on an existing repository package and its transitive runtime dependencies. It does not require a client/session dependency or a new FFI implementation. The `host` package includes other platform utilities, so its package footprint is larger than this one function. A separate low-level reader package would avoid that footprint but require a broader extraction and additional dependency changes.

Verification will cover actual regular files at and above the bound, missing/invalid metadata, path refusals, original finite cancellation/deadline handling and successful real Prepare readiness through the concrete standalone composition. Existing local metadata behavior will be preserved unless separately authorized. Source changes are pending approval; this proposal changes no package manifest.
