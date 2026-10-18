"""Check scripts/check_affected.sh: the git half of the affected-gate selector, and its runner.

The selection itself is Gleam (packages/lint, `lint/affected`) and is tested
there; what stays here is what needs git or a shell. `--changed` prints the
paths the selector is given, and the runner fixture stands a fake `gleam`
in for the selector so the skip census can be exercised on its own.
"""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


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

            # The script under test is part of the base commit, so only the
            # edits below count as changes.
            (repo / "scripts").mkdir()
            (repo / "scripts/check_affected.sh").write_bytes(
                (ROOT / "scripts/check_affected.sh").read_bytes())
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
            result = subprocess.run(
                ["bash", "scripts/check_affected.sh", "--changed", "main"], cwd=repo,
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(),
                             ["base.txt", "moved.txt", "new.txt", "renamed.txt"])


class RunnerSkipTest(unittest.TestCase):
    """The real runner must preserve declarations without hiding new skips."""

    def run_fixture(self, undeclared=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / ".github/scripts").mkdir(parents=True)
            for name in ("scripts/check_affected.sh", ".github/scripts/skip_census.sh"):
                (root / name).write_bytes((ROOT / name).read_bytes())
            census = root / ".github/scripts/skip_census.sh"
            census.chmod(0o755)
            retry = root / ".github/scripts/hex_retry.sh"
            retry.write_text('#!/usr/bin/env bash\nexec "$@"\n')
            retry.chmod(0o755)

            # A fake `gleam` answers the selector's two calls: the plan is
            # one static lane that runs the emitter, and the report is a
            # line. Both end with the status line the real selector prints.
            bin_directory = root / "bin"
            bin_directory.mkdir()
            fake = bin_directory / "gleam"
            fake.write_text(
                '#!/usr/bin/env bash\n'
                'case " $* " in\n'
                '*" lanes "*) echo "static python3 scripts/emit.py" ;;\n'
                '*) echo "mode affected" ;;\n'
                'esac\n'
                'echo "# ok"\n')
            fake.chmod(0o755)
            (root / "packages/lint").mkdir(parents=True)
            for args in (("init", "-q", "-b", "main"), ("add", "."),
                         ("-c", "user.name=test", "-c", "user.email=test@example.com",
                          "commit", "-q", "-m", "base")):
                subprocess.run(["git", "-C", str(root), *args], check=True,
                               capture_output=True)
            (root / ".github/declared-skips").write_text(
                "declared|any|permitted fixture|The fixture owns this skip.\n"
                "declared|any|another lane|This lane was not selected.\n")

            # A matching line near the start must not close the pipe while
            # its producer still has more than a pipe buffer left to write.
            log = "SKIP fixture: permitted fixture\n" * 50_000
            if undeclared:
                log += "SKIP fixture: unlisted fixture\n"
            (root / "scripts/emit.py").write_text(
                "import sys\nsys.stdout.write(" + repr(log) + ")\n")
            environment = dict(os.environ)
            environment["PATH"] = f"{bin_directory}:{environment['PATH']}"
            environment.pop("GITHUB_STEP_SUMMARY", None)
            return subprocess.run(
                ["bash", "scripts/check_affected.sh", "main"], cwd=root,
                env=environment, capture_output=True, text=True, timeout=30)

    def test_long_logs_keep_the_existing_declared_skip(self):
        result = self.run_fixture()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no undeclared skip", result.stdout)

    def test_an_undeclared_skip_still_fails_the_runner(self):
        result = self.run_fixture(undeclared=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("1 undeclared skip(s)", result.stdout)
        self.assertIn("SKIP fixture: unlisted fixture", result.stdout)


if __name__ == "__main__":
    unittest.main()
