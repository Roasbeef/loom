# MicroVM guest root: upgrade in place and first clone

`RootUpgrade.tla` is a [TLA+](https://lamport.azurewebsites.net/tla/tla.html)
model of what `loom vm up` does to a guest's root directory: the first clone
of the exported guest root, and the upgrade in place of a kept root after a
loom update. `make model-check` checks it.

The model exists because both are sequences of file operations on the host
(clone, rename, delete, record), `up` can be stopped between any two of them,
and the next `up` decides what to do from what it finds on disk and nothing
else. The claims are that no stop loses the workspaces the agent edited, that
a guest never boots on a root that is partial, stale or missing its
workspaces, and that `up` always finishes once it is no longer interrupted.
TLC checks them over every interleaving of steps and stops, with at most
three stops in one behaviour.

The model checks the order of the steps, not the code. The code is
`vm_spec.root_step` and `vm_spec.carry_over` in
`packages/client/src/client/vm_spec.gleam`, and `prepare_root`,
`replace_root`, `build_next_root`, `upgrade_steps`, `swap_roots` and `stage`
in `packages/client/src/client/vm_cli.gleam`. The tests that run that code
are in `packages/client/test/client/vm_cli_test.gleam`, and
`docs/architecture/microvm.md`, "A kept root after a loom upgrade", is the
prose account.

## What is modelled

| Variable | Meaning |
|---|---|
| `root` | The guest's `root`: `none`, `old` (cloned from an older build), `wreck` (partly copied or partly deleted) or `new` (a whole clone of the manifest's export). |
| `building`, `bslot` | `root.building`, where a clone is made, and what is at its `srv/workspaces`: nothing, the export's own directory (`junk`) or the real workspaces. |
| `next`, `nslot` | `root.next`, the new root waiting to take the old one's place, and its `srv/workspaces`. |
| `ws` | Where the developer's workspaces are: `root`, `building`, `next`, `gone`, or `unmade` before the first copy. |
| `record` | The host's `root-revision` record: `old` (or absent) or `new`. |
| `pc` | Where `up` is. A stop sets it to `idle` and leaves the disk as it was. |
| `crashes` | Stops so far, bounded by `MaxCrashes`. |

Two starting points, chosen by `Scenario`: `kept` is a guest that ran on the
old build, and `first` is a guest that has never been up. `Dev` makes the
manifest a development tree's, under which `up` keeps whatever root it finds.

Not modelled: `--fresh`, which discards the root on purpose; the provisioning
script, whose retry is decided from the host's own copy; a guest that plants
a link in its root, which is refused before any step here runs; and the
state disk, which no step here touches.

## What is checked

| Property | Meaning |
|---|---|
| `WorkspacesKept` | The workspaces exist somewhere on disk in every state. |
| `BootedRight` | A guest boots only on a whole root that holds the workspaces, cloned from the manifest's export (or, under `Dev`, a whole old root). |
| `MovedIsReal` | An `srv/workspaces` in `root.next` is always the real one, which is what lets `root_step` read its presence as a finished move. |
| `Converges` | Once `up` stops being interrupted, the guest boots. No state is refused forever. |

The clean configurations are `RootUpgrade.cfg` and `KeptDev.cfg` (a kept
root under a release and a development manifest) and `FirstRun.cfg` and
`FirstRunDev.cfg` (a first run under each).

## The mutants

Each `Mutant*.cfg` turns one rule off and names, on its `expect-violation`
line, the property TLC must then violate. A mutant that passes means the
model no longer depends on that rule.

| Configuration | Rule removed | Violates |
|---|---|---|
| `MutantNoClearSlot` | The clone's own `srv/workspaces` is removed before the clone is used. | `WorkspacesKept` |
| `MutantCloneAsNext` | The upgrade's clone is made as `root.building`, not under the name `root.next`. | `WorkspacesKept` |
| `MutantRootBeforeMoved` | `root_step` reads a finished move before it reads a missing root. | `BootedRight` |
| `MutantRecordFirst` | The revision is recorded after the root it describes is in place. | `BootedRight` |
| `MutantMoveBeforeName` | The clone is named `root.next` before the workspaces move into it. | `Converges` |
| `MutantRefuseWithoutCopy` | A root that never received a workspace copy is replaced without a move. | `Converges` |
| `MutantCloneInPlace` | The first clone is made as `root.building` and renamed. | `BootedRight` |

The last two are the code as it stood before 2026-11-13. Writing the `first`
scenario is what found them: a first `up` stopped during the clone, or
between the clone and the workspace copy, left a root that every later `up`
refused to upgrade (and, under a development manifest, a partial root that
was booted). The first five are the two crash windows closed in #1166 and the
ordering rules the upgrade already had.

## Running it

`make model-check` runs every configuration. One by hand:

```bash
java -cp ~/tools/tla2tools.jar tlc2.TLC -config FirstRun.cfg RootUpgrade.tla
```
