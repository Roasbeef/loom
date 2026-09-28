#!/usr/bin/env python3
"""Select the gates a change can affect.

Usage: scripts/affected.py [--base REV] [--format text|lanes] [PATH...]

The full gate (`make check`, and the signoff built from it) runs every
package's suite whatever a change touched. This script reads what a change
touched and prints the subset of gates that can observe it: the packages
whose build or tests include a changed file, plus a fixed set of cheap
whole-tree static gates. `scripts/check_affected.sh` runs the subset, and
`make check-affected` is its entry point.

What changed is the difference between the merge base of BASE (default
`origin/main`) and HEAD, taken against the working tree so that
uncommitted edits and untracked files count too. Paths given on the
command line replace the diff, which is how the tests drive it.

A package is affected in three ways, each derived from the tree rather
than written down here:

1. Its own files changed.
2. It depends on an affected package. The edges come from the path
   dependencies in every `packages/*/gleam.toml`. A `[dependencies]` edge
   is transitive: whatever builds against `session_view` builds against
   `tui` if `tui` depends on it. A `[dev-dependencies]` edge is not,
   because Gleam compiles a package's dev dependencies only when that
   package is the root of the build: `client` takes `tui` as a dev
   dependency, so a `tui` change affects `client`'s tests, but it does not
   reach `conformance`, which depends on `client` and never compiles
   `client`'s tests.
3. Its sources or tests name a file outside the package by a relative
   path literal, such as `"../../protocol/msgpack-fixtures/"` in `core`'s
   tests or `"/../sandbox/loom-exec"` in the real-helper suites. Those are
   read at test time rather than compiled, so the edge covers the package
   itself and not its dependents.

Some changes are not decided by the graph. Build and CI machinery
(`scripts/`, the `Makefile`, `.github/`, the image, and any package's
`gleam.toml` or `manifest.toml`) can change what every gate does, so they
select the full `make check`. So does a change whose affected packages
are more than half of the Gleam packages, since the subset would then
save little and `core` is the only package that reaches that far today.
A path the script does not recognise also selects the full check; an
unknown file is not evidence that nothing is affected.

The script says, separately from the gates, whether the change still needs
the full signoff before it merges. That is the owner's rule of 2026-09-28
in docs/execution.md section 4: a change touching the daemon, the sandbox,
or the wire, or one crossing many packages, keeps the signoff.
"""

import argparse
from dataclasses import dataclass, field
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib


ROOT = Path(__file__).resolve().parent.parent

# The static gates are whole-tree and take about ten seconds together, so
# they always run rather than being selected by their inputs. Tracking the
# inputs of the prelude digest (`packages/cap`) and the web asset digest
# (`packages/web_client` and the `web_view` sources its stylesheet scans)
# would save two seconds and add a second copy of what those scripts
# already know. `make lint` runs over every package, not only the affected
# ones: its gating rules are per file, but a whole-tree run costs seconds
# and needs no argument about which rules are cross-module.
STATIC_GATES = ("fmt-check", "lint", "doc-check", "prelude-check", "client-check")

# Package lanes, taken from scripts/signoff.sh so that the packages which
# run concurrently here are the ones already proven to run concurrently
# there. Packages in no named lane go to `fast`. `client` and `tui` share
# a lane in the signoff because the bootstrap fixtures follow them there;
# keeping them together here costs nothing when only one is selected.
LANES = (
    ("client", ("client", "tui")),
    ("mid", ("runtime", "storage", "session", "events")),
    ("conformance", ("conformance",)),
)

# The Go sandbox helper is a package directory without a gleam.toml.
# scripts/check.sh accepts it by name and runs its Go vet, build and tests.
GO_PACKAGES = ("sandbox",)

# Machinery that can change what any gate does. A change here runs the
# full check, because no smaller set of gates is known to observe it.
ESCALATE_PREFIXES = ("scripts/", ".github/")
ESCALATE_FILES = ("Makefile", "Dockerfile", ".dockerignore")
ESCALATE_PACKAGE_FILES = ("gleam.toml", "manifest.toml")

# The wire's golden msgpack fixtures. The Go sandbox's tests read them
# through `filepath.Join`, which no literal scan sees, and they are the
# wire contract, so a change here runs the full check.
WIRE_PREFIX = "protocol/msgpack-fixtures/"

# Prose and agent configuration: covered by the static gates alone.
DOC_PREFIXES = ("docs/", "protocol-change/", "skills/", ".claude/")
DOC_ROOT_FILES = (".gitignore",)

# The P protocol models, checked by `make model-check`.
MODEL_PREFIX = "protocol/models/"

# The daemon, for the signoff rule, is the package loomd is exported from
# (`make server-shipment` runs `gleam export erlang-shipment` in
# packages/client) together with every package it reaches through
# `[dependencies]` path edges, read from the graph. Two of those are
# exempt by the owner's ruling of 2026-09-28: `session_view` and
# `web_view` are the views the terminal and the browser drive, and a
# change to them is judged by their own gates. The wire files inside
# `session_view` are still listed below.
DAEMON_ROOT = "client"
DAEMON_EXEMPT = ("session_view", "web_view")

# Other paths whose change keeps the full signoff even when the selected
# gates pass: the kernel sandbox and its helper, and the wire the terminal
# and the daemon speak. `core` holds the codecs; it is also a daemon
# package, and a `core` change selects the full check anyway.
SIGNOFF_PREFIXES = (
    ("packages/sandbox/", "the sandbox helper"),
    ("protocol/msgpack-fixtures/", "the wire's msgpack fixtures"),
    ("packages/session_view/src/session_view/protocol.gleam", "the client wire protocol"),
    ("packages/session_view/src/session_view/session_wire.gleam", "the client wire codec"),
)

# More packages changed directly than this counts as crossing many.
SIGNOFF_PACKAGE_LIMIT = 2

# Source extensions scanned for relative path literals.
SCANNED_SUFFIXES = (".gleam", ".erl", ".mjs", ".js", ".css", ".go")
PATH_LITERAL = re.compile(r'"/?((?:\.\./)+[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)')

# A literal the tests append to the repository root they computed, as in
# `repo <> "/docs/examples/strand_map.gleam"`. The base is not always the
# repository (`workspace <> "/.claude/skills"` names a scratch workspace),
# so such a literal counts only when it names a tracked file or a package,
# never a bare directory, and fixture strings such as `"/etc/passwd"` fall
# out with the rest.
ROOTED_LITERAL = re.compile(r'"/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*)')


@dataclass
class Graph:
    """The package graph read from the tree.

    `deps` and `dev` map each Gleam package to the packages it names as
    path dependencies in `[dependencies]` and `[dev-dependencies]`.
    `reads` maps a repository path prefix to the packages whose sources
    name it by a relative literal, with the literal kept for the reason.
    """

    packages: list
    gleam: list
    deps: dict
    dev: dict
    reads: dict = field(default_factory=dict)


@dataclass
class Selection:
    """What a change selects.

    `mode` is `full` when the full check runs and `affected` otherwise.
    `packages` maps each selected package to the reason it was selected.
    `gates` lists the non-package gates with their reasons, and `signoff`
    the reasons the change still needs the full signoff, empty when it
    does not.
    """

    mode: str = "affected"
    reasons: list = field(default_factory=list)
    packages: dict = field(default_factory=dict)
    gates: list = field(default_factory=list)
    signoff: list = field(default_factory=list)


def path_deps(table):
    """Return the names in a dependency table that are path dependencies.

    ## Examples

        >>> sorted(path_deps({"core": {"path": "../core"}, "x": ">= 1.0.0"}))
        ['core']
    """
    return {name for name, spec in (table or {}).items()
            if isinstance(spec, dict) and "path" in spec}


def load_graph(root, tracked):
    """Read every package's manifest and relative path literals.

    ## Examples

        graph = load_graph(ROOT, tracked_files(ROOT))
        graph.deps["tui"]  # {"host", "core", "machine", "session_view"}
    """
    packages = sorted(p.name for p in (root / "packages").iterdir()
                      if p.is_dir() and ((p / "gleam.toml").exists() or p.name in GO_PACKAGES))
    gleam = [p for p in packages if (root / "packages" / p / "gleam.toml").exists()]
    deps, dev = {}, {}
    for package in gleam:
        manifest = tomllib.loads((root / "packages" / package / "gleam.toml").read_text())

        # Gleam accepts both spellings of the dev table; the tree uses the
        # underscore one today.
        deps[package] = path_deps(manifest.get("dependencies"))
        dev[package] = (path_deps(manifest.get("dev-dependencies"))
                        | path_deps(manifest.get("dev_dependencies")))
    graph = Graph(packages, gleam, deps, dev)
    graph.reads = scan_reads(root, tracked, packages)
    return graph


def daemon_packages(graph):
    """Return the packages the daemon is built from, less the exempt views.

    ## Examples

        sorted(daemon_packages(graph))
        # ["broker", "client", "codemode", "core", "events", "host", ...]
    """
    found = set()
    frontier = [DAEMON_ROOT] if DAEMON_ROOT in graph.gleam else []
    while frontier:
        package = frontier.pop()
        if package not in found:
            found.add(package)
            frontier.extend(graph.deps.get(package, ()))
    return found - set(DAEMON_EXEMPT)


def scan_reads(root, tracked, packages):
    """Map repository path prefixes to the packages that read them.

    A literal is resolved against both the package root, where the test
    runner's working directory is, and the directory of the file holding
    it, where an asset tool resolves it. A resolution counts only when it
    names a package, or a tracked file or directory outside `packages/`;
    that discards the literals which are inputs to path-escape tests
    (`"../etc/passwd"`) and build outputs such as `bin/`. A literal naming
    another package's file counts as a read of that whole package, because
    the helper binary the real-helper suites run is built from all of it.

    ## Examples

        reads = scan_reads(ROOT, tracked_files(ROOT), ["broker", "core"])
        reads["protocol/msgpack-fixtures"]  # {"broker": '"../../protocol/..."', ...}
    """
    directories = set()
    for path in tracked:
        parts = path.split("/")
        for i in range(1, len(parts)):
            directories.add("/".join(parts[:i]))
    reads = {}
    for path in tracked:
        parts = path.split("/")
        if len(parts) < 3 or parts[0] != "packages" or parts[1] not in packages:
            continue
        if not path.endswith(SCANNED_SUFFIXES):
            continue
        reader = parts[1]
        try:
            text = (root / path).read_text(errors="replace")
        except OSError:
            continue
        candidates = [(literal, os.path.normpath(os.path.join(base, literal)))
                      for literal in PATH_LITERAL.findall(text)
                      for base in (f"packages/{reader}", os.path.dirname(path))]
        candidates += [("/" + literal, literal) for literal in ROOTED_LITERAL.findall(text)
                       if literal in tracked or literal.startswith("packages/")]
        for literal, target in candidates:
            prefix = read_prefix(target, reader, packages, tracked, directories)
            if prefix:
                reads.setdefault(prefix, {}).setdefault(reader, literal)
    return reads


def read_prefix(target, reader, packages, tracked, directories):
    """Return the prefix a resolved literal reads, or None.

    ## Examples

        read_prefix("packages/sandbox/loom-exec", "broker", ["sandbox"], set(), set())
        # "packages/sandbox"
    """
    parts = target.split("/")
    if target.startswith("..") or target in (".", "packages"):
        return None
    if parts[0] == "packages":
        if len(parts) >= 2 and parts[1] in packages and parts[1] != reader:
            return f"packages/{parts[1]}"
        return None
    if target in tracked or target in directories:
        return target
    return None


def under(path, prefix):
    """Report whether `path` is `prefix` or lies beneath it.

    ## Examples

        >>> under("docs/examples/a.gleam", "docs/examples")
        True
        >>> under("docs/examplesX", "docs/examples")
        False
    """
    prefix = prefix.rstrip("/")
    return path == prefix or path.startswith(prefix + "/")


def affected_closure(changed, graph):
    """Return every package whose build includes a changed package.

    Regular dependency edges are followed transitively; a dev-dependency
    edge adds the package that declares it and stops there.

    ## Examples

        affected_closure({"tui": "changed"}, graph)
        # {"tui": "changed", "client": "dev-depends on tui"}
    """
    selected = dict(changed)
    frontier = list(changed)
    while frontier:
        package = frontier.pop()
        for other in graph.gleam:
            if package in graph.deps.get(other, ()) and other not in selected:
                selected[other] = f"depends on {package}"
                frontier.append(other)
    for other in graph.gleam:
        if other in selected:
            continue
        for package in sorted(graph.dev.get(other, ())):
            if package in selected:
                selected[other] = f"dev-depends on {package}"
                break
    return selected


def classify(path, graph):
    """Name the kind of change a path is.

    The kinds are `machinery` (selects the full check), `manifest` (a
    package's gleam.toml or manifest.toml, also the full check),
    `wire` (the golden msgpack fixtures, also the full check),
    `package` (a package's own files), `package-doc` (Markdown at a
    package's root, which no build reads), `model` (a P protocol model),
    `doc` (prose and agent configuration), `read` (a file outside
    `packages/` that some package's tests read, and nothing more), and
    `unknown`.

    ## Examples

        classify("packages/tui/src/tui.gleam", graph)  # "package"
        classify("packages/tui/CLAUDE.md", graph)      # "package-doc"
        classify("Makefile", graph)                    # "machinery"
    """
    parts = path.split("/")
    if path.startswith(ESCALATE_PREFIXES) or path in ESCALATE_FILES:
        return "machinery"
    if path.startswith(WIRE_PREFIX):
        return "wire"
    if parts[0] == "packages" and len(parts) >= 3 and parts[1] in graph.packages:
        if len(parts) == 3 and parts[2] in ESCALATE_PACKAGE_FILES:
            return "manifest"
        if len(parts) == 3 and parts[2].endswith(".md"):
            return "package-doc"
        return "package"
    if path.startswith(MODEL_PREFIX):
        return "model"
    if path.startswith(DOC_PREFIXES) or path in DOC_ROOT_FILES or (
            len(parts) == 1 and path.endswith(".md")):
        return "doc"
    if any(under(path, prefix) for prefix in graph.reads):
        return "read"
    return "unknown"


def select(paths, graph):
    """Decide the gates for a list of changed repository paths.

    ## Examples

        select(["docs/next.md"], graph).packages  # {}
        select(["Makefile"], graph).mode          # "full"
    """
    selection = Selection()
    changed = {}
    readers = {}
    daemon = daemon_packages(graph)
    for path in sorted(set(paths)):
        kind = classify(path, graph)
        if kind == "machinery":
            selection.mode = "full"
            selection.reasons.append(f"{path} is build or CI machinery")
        elif kind == "wire":
            selection.mode = "full"
            selection.reasons.append(f"{path} is a wire fixture the Go sandbox also reads")
        elif kind == "manifest":
            selection.mode = "full"
            selection.reasons.append(f"{path} changes the dependency graph")
        elif kind == "package":
            changed[path.split("/")[1]] = "changed"
        elif kind == "model":
            add_gate(selection, "model-check", f"{MODEL_PREFIX} changed")
        elif kind == "unknown":
            selection.mode = "full"
            selection.reasons.append(f"{path} is not a path this script classifies")

        # Package Markdown is read by no build, so neither the signoff
        # rule nor a test that reads the package's files applies to it.
        if kind == "package-doc":
            continue
        notes = [f"touches {what}" for prefix, what in SIGNOFF_PREFIXES
                 if under(path, prefix)]
        if kind in ("package", "manifest") and path.split("/")[1] in daemon:
            notes.append(f"touches the daemon (packages/{path.split('/')[1]}, "
                         "which loomd is built from)")
        for note in notes:
            if note not in selection.signoff:
                selection.signoff.append(note)

        # A file some package's tests read by relative path selects that
        # package, whatever kind of file it is otherwise; `docs/examples`
        # is prose and a codemode fixture at once.
        for prefix, reading in graph.reads.items():
            if under(path, prefix):
                for reader, literal in sorted(reading.items()):
                    readers.setdefault(reader, f'reads {prefix} ("{literal}")')

    # The dependency closure's reasons win over a read, since a package
    # that changed or builds against a change is selected for that first.
    selection.packages = dict(readers)
    selection.packages.update(affected_closure(changed, graph))
    if "sandbox" in selection.packages:
        add_gate(selection, "selftest", "the sandbox helper changed; probe its enforcement layers")

    reached = [p for p in selection.packages if p in graph.gleam]
    if 2 * len(reached) > len(graph.gleam):
        selection.mode = "full"
        selection.reasons.append(
            f"{len(reached)} of {len(graph.gleam)} Gleam packages are affected")
    if len(changed) > SIGNOFF_PACKAGE_LIMIT:
        selection.signoff.append(f"changes {len(changed)} packages directly")
    if selection.mode == "full":
        selection.signoff.insert(0, "the full check was selected")
    return selection


def add_gate(selection, gate, reason):
    """Record a non-package gate once, with the first reason seen."""
    if gate not in (name for name, _ in selection.gates):
        selection.gates.append((gate, reason))


# Packages whose suites feature-detect a prerequisite and print SKIP
# without it, mapped to the make targets that provide it, as
# scripts/signoff.sh's preparation provides them all. The code-mode seed
# backs the code-mode suites and the client's live code-mode fixtures;
# the server shipment is bin/loomd, which the client's shipped fixtures
# and the tui's real-server lifecycle test run against.
SEED_PACKAGES = ("codemode", "tools", "cap", "client")
SHIPMENT_PACKAGES = ("client", "tui")


def prep(selection):
    """Return the make targets to build before the lanes start.

    `binaries` builds the helper that the real-helper suites and the
    self-test run, and the tui shipment; `make check-<pkg>` depends on it.
    The full check prepares everything, as the signoff does.

    ## Examples

        prep(select(["packages/tui/src/tui.gleam"], graph))
        # ["binaries", "server-shipment"]
    """
    if selection.mode == "full":
        return ["codemode-seed", "binaries", "server-shipment"]
    targets = []
    selected = set(selection.packages)
    if selected & set(SEED_PACKAGES):
        targets.append("codemode-seed")
    if selected or any(gate == "selftest" for gate, _ in selection.gates):
        targets.append("binaries")
    if selected & set(SHIPMENT_PACKAGES):
        targets.append("server-shipment")
    return targets


# The command for each non-package gate. The self-test runs the helper
# `binaries` already built, as scripts/signoff.sh's enforcement lane does;
# `make selftest` would rebuild it while the package lanes run it.
GATE_COMMANDS = {
    "selftest": ["./packages/sandbox/loom-exec", "--self-test"],
    "model-check": ["make", "model-check"],
}


def lanes(selection):
    """Return the lanes to run, as (name, command words) pairs.

    The static lane comes first and `scripts/check_affected.sh` runs it
    alone before the others, because `make lint` builds `packages/lint`
    and a `lint` package lane would build the same tree at the same time.

    ## Examples

        lanes(select(["docs/next.md"], graph))
        # [("static", ["make", "fmt-check", ...])]
    """
    result = [("static", ["make", *STATIC_GATES])]
    for gate, _ in selection.gates:
        result.append((gate, GATE_COMMANDS[gate]))
    if selection.mode == "full":
        result.append(("full", ["bash", "scripts/check.sh"]))
        return result
    remaining = [p for p in CHECK_ORDER if p in selection.packages]
    for name, members in LANES:
        chosen = [p for p in members if p in remaining]
        if chosen:
            result.append((name, ["bash", "scripts/check.sh", *chosen]))
    rest = [p for p in remaining if not any(p in m for _, m in LANES)]
    if rest:
        result.append(("fast", ["bash", "scripts/check.sh", *rest]))
    return result


# The package order scripts/check.sh uses, so a lane runs its packages in
# the order the full check does. Packages missing from it (a new one not
# yet added there) run last, in name order.
CHECK_ORDER = ("host core storage session machine prompt session_view web_view "
               "web_client telemetry runtime provider broker mcp tools cap ext "
               "codemode events client tui conformance lint sandbox").split()


def render(selection):
    """Return the human-readable report: one line per gate with its reason.

    Each line is `<kind> <name>  <reason>`, where kind is `mode`, `gate`
    or `signoff`, so the output is both readable and parseable by field.
    """
    lines = [f"mode {selection.mode}"]
    for reason in selection.reasons:
        lines.append(f"escalate  {reason}")
    for gate in STATIC_GATES:
        lines.append(f"gate {gate}  static: always runs over the whole tree")
    for gate, reason in selection.gates:
        lines.append(f"gate {gate}  {reason}")
    if selection.mode == "full":
        lines.append("gate check  every package (make check)")
    else:
        for package in [p for p in CHECK_ORDER if p in selection.packages] + sorted(
                p for p in selection.packages if p not in CHECK_ORDER):
            lines.append(f"gate check-{package}  {selection.packages[package]}")
    if selection.signoff:
        for reason in selection.signoff:
            lines.append(f"signoff required  {reason}")
    else:
        lines.append("signoff not-required  affected gates suffice with a dispositioned review")
    return "\n".join(lines)


def git(root, *args):
    """Run git in `root` and return its stdout, raising on failure."""
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          capture_output=True, text=True).stdout


def tracked_files(root):
    """Return the set of paths git tracks under `root`."""
    return set(git(root, "ls-files").splitlines())


def changed_paths(root, base):
    """Return the paths changed since the merge base of `base` and HEAD.

    The diff is against the working tree, so staged, unstaged and
    untracked files count as well as commits. Renames are split into a
    deletion and an addition so that both packages are seen.
    """
    merge_base = git(root, "merge-base", base, "HEAD").strip()
    diffed = git(root, "diff", "--name-only", "--no-renames", merge_base).splitlines()
    untracked = git(root, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(set(diffed) | set(untracked))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--format", choices=("text", "lanes"), default="text")
    parser.add_argument("--root", default=str(ROOT))
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args(argv)
    root = Path(args.root)
    graph = load_graph(root, tracked_files(root))
    paths = args.paths or changed_paths(root, args.base)
    selection = select(paths, graph)
    if args.format == "lanes":
        targets = prep(selection)
        if targets:
            print("prep", "make", *targets)
        for name, words in lanes(selection):
            print(name, *words)
    else:
        print(render(selection))
    return 0


if __name__ == "__main__":
    sys.exit(main())
