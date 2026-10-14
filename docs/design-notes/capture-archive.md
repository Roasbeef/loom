# Historical UI captures

The terminal, web and website exploration captures are archived at commit
[`dc70d25d42da531284225bf399f40f82e13539d4`](https://github.com/Roasbeef/loom/tree/dc70d25d42da531284225bf399f40f82e13539d4).
The design notes link to that snapshot, so their images and mockups remain
readable after the captures leave the current tree. The archive uses the
repository's existing history; it does not reduce a full-history clone.

| Collection | Files | Uncompressed bytes | Browse archive |
|---|---:|---:|---|
| Terminal captures and mockups | 417 | 27766712 | [terminal-design](https://github.com/Roasbeef/loom/tree/dc70d25d42da531284225bf399f40f82e13539d4/docs/design-notes/terminal-design) |
| Web captures and mockups | 253 | 21663682 | [web-design](https://github.com/Roasbeef/loom/tree/dc70d25d42da531284225bf399f40f82e13539d4/docs/design-notes/web-design) |
| TUI workspace captures | 86 | 3535175 | [tui-agent-workspace](https://github.com/Roasbeef/loom/tree/dc70d25d42da531284225bf399f40f82e13539d4/docs/design-notes/tui-agent-workspace) |
| Website QA captures | 26 | 2999588 | [site/screenshots](https://github.com/Roasbeef/loom/tree/dc70d25d42da531284225bf399f40f82e13539d4/site/screenshots) |

The [SHA-256 manifest](capture-archive.sha256) lists every archived file with
its original repository path. In total, 782 files account for 55,965,157 bytes
(53.37 MiB). Useful design prose, both terminal mockup generators and the tmux
capture renderer remain in the source tree. README images, logos and website
assets under `site/public/` remain tracked.

## Recovering the captures

From a full clone containing the archive commit, export the original capture
directories into a directory outside the checkout:

```sh
mkdir -p ../loom-ui-archive
git archive dc70d25d42da531284225bf399f40f82e13539d4 \
  docs/design-notes/terminal-design \
  docs/design-notes/web-design \
  docs/design-notes/tui-agent-workspace \
  site/screenshots | tar -x -C ../loom-ui-archive
```

That export also includes the original prose and scripts in those directories.
Copy `capture-archive.sha256` into the export's root, then run
`sha256sum -c capture-archive.sha256` there (or `shasum -a 256 -c
capture-archive.sha256` on macOS) to verify the captures. A shallow clone must
fetch the archive commit first. GitHub also provides the
[original source snapshot](https://github.com/Roasbeef/loom/archive/dc70d25d42da531284225bf399f40f82e13539d4.tar.gz).

Before any history rewrite removes this commit, export the captures to an
independent durable archive and update these links. The manifest provides the
integrity check for that migration.

## New captures

Keep temporary UI captures and mockups outside the checkout. Existing terminal
generators still write alongside their scripts; those generated files are now
ignored, as are the old web exploration and website QA capture directories.
Local session journals and scratch worktrees are ignored too.

Keep curated images needed by the README or published site in `docs/images/`
or `site/public/img/`, with provenance in the corresponding documentation.
