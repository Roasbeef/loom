"""Check the affected-gate selector against the real tree and a scratch repository."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import affected  # noqa: E402


# The graph is read once from the checkout under test, so the expectations
# below are about the dependency edges the tree declares today. A test that
# fails after a gleam.toml edit is reporting a changed closure, which is
# what the selector exists to follow.
GRAPH = affected.load_graph(affected.ROOT, affected.tracked_files(affected.ROOT))


def packages(paths):
    return set(affected.select(paths, GRAPH).packages)


class SelectTest(unittest.TestCase):
    def test_docs_only_runs_static_gates(self):
        selection = affected.select(["docs/next.md", "README.md", "protocol-change/001-x.md",
                                     "packages/tui/CLAUDE.md"], GRAPH)
        self.assertEqual(selection.mode, "affected")
        self.assertEqual(selection.packages, {})
        self.assertEqual(selection.gates, [])
        self.assertEqual(selection.signoff, [])
        self.assertEqual(affected.lanes(selection),
                         [("static", ["make", *affected.STATIC_GATES])])
        self.assertEqual(affected.prep(selection), [])

    def test_tui_selects_its_dev_dependents_and_stops(self):
        selection = affected.select(["packages/tui/src/tui.gleam"], GRAPH)
        self.assertEqual(selection.mode, "affected")

        # client takes tui as a dev dependency; conformance depends on
        # client but never compiles client's tests, so it is not reached.
        self.assertEqual(set(selection.packages), {"tui", "client"})
        self.assertEqual(selection.packages["client"], "dev-depends on tui")
        self.assertEqual(selection.signoff, [])
        self.assertEqual(affected.lanes(selection)[1:],
                         [("client", ["bash", "scripts/check.sh", "client", "tui"])])

        # client's code-mode fixtures need the seed, and both packages'
        # shipped fixtures need bin/loomd.
        self.assertEqual(affected.prep(selection),
                         ["codemode-seed", "binaries", "server-shipment"])

    def test_session_view_reaches_both_hosts(self):
        self.assertEqual(packages(["packages/session_view/src/session_view/inbox.gleam"]),
                         {"session_view", "tui", "web_view", "client", "conformance"})

    def test_leaf_change_selects_only_itself(self):
        selection = affected.select(["packages/lint/src/lint/rule.gleam"], GRAPH)
        self.assertEqual(selection.mode, "affected")
        self.assertEqual(set(selection.packages), {"lint"})
        self.assertEqual(affected.prep(selection), ["binaries"])
        self.assertEqual(affected.lanes(selection)[1:],
                         [("fast", ["bash", "scripts/check.sh", "lint"])])

    def test_core_change_escalates_to_full_check(self):
        selection = affected.select(["packages/core/src/core/json.gleam"], GRAPH)
        self.assertEqual(selection.mode, "full")
        self.assertIn("Gleam packages are affected", selection.reasons[0])
        self.assertIn("the full check was selected", selection.signoff)
        self.assertEqual(affected.lanes(selection)[-1], ("full", ["bash", "scripts/check.sh"]))

    def test_makefile_change_escalates_to_full_check(self):
        selection = affected.select(["Makefile"], GRAPH)
        self.assertEqual(selection.mode, "full")
        self.assertEqual(selection.reasons, ["Makefile is build or CI machinery"])

    def test_machinery_and_manifests_escalate(self):
        for path in ("scripts/check.sh", ".github/workflows/ci.yml", "Dockerfile",
                     "packages/tui/gleam.toml", "packages/tui/manifest.toml",
                     "protocol/msgpack-fixtures/bin-empty.bin", "unheard-of/file"):
            with self.subTest(path=path):
                self.assertEqual(affected.select([path], GRAPH).mode, "full")

    def test_sandbox_selects_the_real_helper_suites_and_the_signoff(self):
        selection = affected.select(["packages/sandbox/internal/policy/policy.go"], GRAPH)
        self.assertEqual(selection.mode, "affected")
        self.assertTrue({"sandbox", "broker", "tools", "codemode", "client"}
                        <= set(selection.packages))
        self.assertIn("touches the sandbox helper", selection.signoff)

        # The self-test runs the helper `binaries` built rather than
        # rebuilding it beside the package lanes.
        self.assertIn(("selftest", ["./packages/sandbox/loom-exec", "--self-test"]),
                      affected.lanes(selection))

    def test_daemon_change_keeps_the_signoff(self):
        selection = affected.select(["packages/client/src/client.gleam"], GRAPH)
        self.assertEqual(set(selection.packages), {"client", "conformance"})
        self.assertEqual(selection.signoff,
                         ["touches the daemon (packages/client, which loomd is built from)"])

    def test_daemon_is_what_loomd_is_built_from(self):
        # client's [dependencies] closure, less the two view packages the
        # owner exempted.
        self.assertEqual(affected.daemon_packages(GRAPH), {
            "client", "host", "core", "storage", "session", "machine", "prompt",
            "events", "runtime", "broker", "provider", "tools", "codemode", "mcp",
            "lsp", "telemetry", "executor"})
        for package in ("runtime", "session", "storage", "events", "broker",
                        "provider", "mcp", "lsp", "host", "tools", "executor"):
            with self.subTest(package=package):
                selection = affected.select([f"packages/{package}/src/x.gleam"], GRAPH)
                self.assertTrue(any("touches the daemon" in note for note in selection.signoff))
        for path in ("packages/tui/src/x.gleam", "packages/session_view/src/session_view/x.gleam",
                     "packages/web_view/src/x.gleam", "packages/web_client/src/x.gleam",
                     "packages/lint/src/x.gleam", "packages/runtime/CLAUDE.md", "docs/next.md"):
            with self.subTest(path=path):
                self.assertEqual(affected.select([path], GRAPH).signoff, [])

    def test_session_view_wire_files_keep_the_signoff(self):
        selection = affected.select(
            ["packages/session_view/src/session_view/session_wire.gleam"], GRAPH)
        self.assertEqual(selection.signoff, ["touches the client wire codec"])

    def test_example_read_by_a_test_selects_its_reader(self):
        self.assertEqual(packages(["docs/examples/stale_symbol_sweep.gleam"]), {"codemode"})

    def test_model_change_selects_the_model_check(self):
        selection = affected.select(["protocol/models/terminal-attachment/PSrc/Channel.p"], GRAPH)
        self.assertEqual(selection.packages, {})
        self.assertEqual([gate for gate, _ in selection.gates], ["model-check"])
        self.assertEqual(affected.prep(selection), [])


class ClosureTest(unittest.TestCase):
    """The closure rule on a graph small enough to read."""

    def graph(self):
        # a <- b <- c, and d takes c as a dev dependency while e takes d
        # as a regular one.
        return affected.Graph(
            packages=["a", "b", "c", "d", "e"], gleam=["a", "b", "c", "d", "e"],
            deps={"a": set(), "b": {"a"}, "c": {"b"}, "d": set(), "e": {"d"}},
            dev={"a": set(), "b": set(), "c": set(), "d": {"c"}, "e": set()})

    def test_regular_edges_are_transitive_and_dev_edges_are_not(self):
        closure = affected.affected_closure({"a": "changed"}, self.graph())
        self.assertEqual(closure, {"a": "changed", "b": "depends on a",
                                   "c": "depends on b", "d": "dev-depends on c"})

    def test_half_the_packages_escalates(self):
        selection = affected.select(["packages/a/src/a.gleam"], self.graph())
        self.assertEqual(selection.mode, "full")
        selection = affected.select(["packages/c/src/c.gleam"], self.graph())
        self.assertEqual(selection.mode, "affected")


class ChangedPathsTest(unittest.TestCase):
    def test_diff_counts_commits_edits_and_untracked_files_since_the_merge_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)

            def git(*args):
                subprocess.run(["git", "-C", str(repo), *args], check=True,
                               capture_output=True)

            git("init", "-q", "-b", "main")
            git("config", "user.name", "test")
            git("config", "user.email", "test@example.com")
            (repo / "base.txt").write_text("base\n")
            (repo / "moved.txt").write_text("moved\n")
            git("add", ".")
            git("commit", "-q", "-m", "base")
            git("checkout", "-q", "-b", "topic")
            git("mv", "moved.txt", "renamed.txt")
            git("commit", "-q", "-m", "topic")

            # A commit on main after the branch point is not the topic's
            # change and must not appear.
            git("checkout", "-q", "main")
            (repo / "main-only.txt").write_text("main\n")
            git("add", ".")
            git("commit", "-q", "-m", "main")
            git("checkout", "-q", "topic")
            (repo / "base.txt").write_text("edited\n")
            (repo / "new.txt").write_text("new\n")
            self.assertEqual(affected.changed_paths(repo, "main"),
                             ["base.txt", "moved.txt", "new.txt", "renamed.txt"])


if __name__ == "__main__":
    unittest.main()
