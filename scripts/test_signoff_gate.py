"""Exercise the gated signoff path without ssh, sudo, docker or GitHub.

scripts/signoff/gate.sh is the only thing a pinned signoff key can run, so
what it refuses matters as much as what it runs: each refusal below is a
request that must never reach the driver. The driver is replaced by a stub
that records the environment it was handed, and origin is a local bare
repository, so a test can put a commit on a branch, or off every branch,
and see which the gate lets through. scripts/signoff_remote.sh's gate mode
is driven the same way, with `ssh` replaced by a stub that records its
arguments and its stdin.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
GATE = SCRIPTS / "signoff/gate.sh"
REMOTE = SCRIPTS / "signoff_remote.sh"
DRIVER = SCRIPTS / "signoff/driver.sh"

STUB_DRIVER = """#!/usr/bin/env bash
python3 -c 'import json, os, sys; json.dump(dict(os.environ), open(sys.argv[1], "w"))' "$STUB_RECORD"
"""

STUB_SSH = """#!/usr/bin/env bash
python3 -c 'import json, sys; json.dump({"argv": sys.argv[2:], "stdin": sys.stdin.read()}, open(sys.argv[1], "w"))' "$STUB_RECORD" "$@"
"""


def git(cwd, *args):
    return subprocess.run(
        ["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True,
    ).stdout.strip()


class Fixture(unittest.TestCase):
    """A bare origin with one commit on a branch and one on no branch."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.record = self.root / "record.json"
        self.env = dict(
            os.environ,
            HOME=str(self.root / "home"),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
            STUB_RECORD=str(self.record),
        )
        (self.root / "home").mkdir()
        for inherited in ("SSH_ORIGINAL_COMMAND", "GH_TOKEN", "SIGNOFF_PARALLEL", "LOOM_SIGNOFF_GATE"):
            self.env.pop(inherited, None)

        self.origin = self.root / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(self.origin)], check=True, env=self.env)
        work = self.root / "work"
        subprocess.run(["git", "clone", "-q", str(self.origin), str(work)],
                       check=True, env=self.env, capture_output=True)
        subprocess.run(["git", "-C", str(work), "commit", "-q", "--allow-empty", "-m", "on a branch"],
                       check=True, env=self.env)
        subprocess.run(["git", "-C", str(work), "push", "-q", "origin", "HEAD:refs/heads/main"],
                       check=True, env=self.env, capture_output=True)
        self.pushed = git(work, "rev-parse", "HEAD")

        # A commit origin holds under a ref that is not a branch, the way
        # GitHub holds a fork's pull request head: fetchable by SHA, and
        # pushed by nobody with access to this repository.
        subprocess.run(["git", "-C", str(work), "commit", "-q", "--allow-empty", "-m", "off every branch"],
                       check=True, env=self.env)
        subprocess.run(["git", "-C", str(work), "push", "-q", "origin", "HEAD:refs/pull/1/head"],
                       check=True, env=self.env, capture_output=True)
        self.unbranched = git(work, "rev-parse", "HEAD")
        self.work = work

    def recorded(self):
        return json.loads(self.record.read_text()) if self.record.exists() else None


class GateTest(Fixture):
    def setUp(self):
        super().setUp()
        self.state = self.root / "state"
        self.state.mkdir()
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.state / "loom-signoff")],
                       check=True, env=self.env, capture_output=True)
        (self.state / "gh-token").write_text("token-for-statuses")
        driver = self.root / "driver.sh"
        driver.write_text(STUB_DRIVER)
        driver.chmod(0o755)
        self.env.update(LOOM_SIGNOFF_STATE=str(self.state), LOOM_SIGNOFF_DRIVER=str(driver))

    def gate(self, request, via="argument"):
        env = dict(self.env)
        args = ["bash", str(GATE)]
        if via == "argument":
            args.append(request)
        else:
            env["SSH_ORIGINAL_COMMAND"] = request
        return subprocess.run(args, env=env, capture_output=True, text=True,
                              timeout=30, stdin=subprocess.DEVNULL)

    def test_a_pushed_commit_reaches_the_driver(self):
        result = self.gate(f"signoff {self.pushed}")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertEqual(seen["LOOM_SHA"], self.pushed)
        self.assertEqual(seen["LOOM_POST"], "yes")
        self.assertEqual(seen["GH_TOKEN"], "token-for-statuses")
        self.assertEqual(seen["HOME"], str(self.state))
        self.assertEqual(seen["LOOM_DIR"], str(self.state / "loom-signoff"))
        self.assertEqual(seen["LOOM_ORIGIN"], str(self.origin))
        self.assertEqual(seen["LOOM_PARALLEL"], "")

    def test_the_request_may_come_from_ssh(self):
        result = self.gate(f"signoff {self.pushed} --dry-run", via="ssh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.recorded()["LOOM_POST"], "no")

    def test_a_dry_run_never_holds_the_token(self):
        result = self.gate(f"signoff {self.pushed} --dry-run --parallel 4")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertNotIn("GH_TOKEN", seen)
        self.assertEqual(seen["LOOM_PARALLEL"], "4")

    def test_the_config_sets_the_ceilings(self):
        (self.state / "config").write_text("LOOM_CPUS=8\nLOOM_MEMORY=12g\n")
        result = self.gate(f"signoff {self.pushed} --dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertEqual((seen["LOOM_CPUS"], seen["LOOM_MEMORY"]), ("8", "12g"))

    def test_a_commit_on_no_branch_is_refused(self):
        result = self.gate(f"signoff {self.unbranched}")
        self.assertEqual(result.returncode, 2)
        self.assertIn("none of origin's branches", result.stderr)
        self.assertIsNone(self.recorded())

    def test_requests_outside_the_grammar_never_reach_the_driver(self):
        sha = self.pushed
        for request in [
            "",
            "id",
            "signoff",
            f"bash -lc 'exec bash -s' {sha}",
            f"env LOOM_SHA={sha} bash -lc 'exec bash -s'",
            f"signoff {sha[:12]}",
            f"signoff {sha.upper()}",
            f"signoff {sha};id",
            f"signoff {sha} ; id",
            f"signoff $(id) {sha}",
            f"signoff {sha} --url https://example.invalid",
            f"signoff {sha} --parallel",
            f"signoff {sha} --parallel 0",
            f"signoff {sha} --parallel 65",
            f"signoff {sha} --parallel 4x",
            f"signoff {sha} --parallel 08",
            f"signoff {sha}\nid",
        ]:
            with self.subTest(request=request):
                result = self.gate(request)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertIsNone(self.recorded())

    def test_no_checkout_is_refused_before_anything_runs(self):
        subprocess.run(["rm", "-rf", str(self.state / "loom-signoff")], check=True)
        result = self.gate(f"signoff {self.pushed}")
        self.assertEqual(result.returncode, 3)
        self.assertIsNone(self.recorded())


class RemoteGateModeTest(Fixture):
    """signoff_remote.sh's side: what it sends, and to a gate, nothing else."""

    def setUp(self):
        super().setUp()
        (self.work / "scripts/signoff").mkdir(parents=True)
        for script in (REMOTE, DRIVER):
            target = self.work / script.relative_to(SCRIPTS.parent)
            target.write_bytes(script.read_bytes())
            target.chmod(0o755)
        git(self.work, "checkout", "-q", self.pushed)
        git(self.work, "fetch", "-q", "origin")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        ssh = bin_dir / "ssh"
        ssh.write_text(STUB_SSH)
        ssh.chmod(0o755)
        self.env.update(PATH=f"{bin_dir}:{self.env['PATH']}", LOOM_SIGNOFF_HOST="signoff-host")

    def remote(self, *args, **environment):
        return subprocess.run(
            ["bash", str(self.work / "scripts/signoff_remote.sh"), *args],
            env=dict(self.env, **environment), capture_output=True, text=True, timeout=30,
        )

    def test_a_gate_is_sent_the_request_and_no_script(self):
        result = self.remote("--dry-run", LOOM_SIGNOFF_GATE="1", SIGNOFF_PARALLEL="4")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertEqual(seen["argv"], ["signoff-host", f"signoff {self.pushed} --dry-run --parallel 4"])
        self.assertEqual(seen["stdin"], "")

    def test_a_gate_takes_no_details_link(self):
        result = self.remote("--url", "https://example.invalid", LOOM_SIGNOFF_GATE="1")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(self.recorded())

    def test_an_ungated_host_is_sent_the_driver(self):
        result = self.remote("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertEqual(seen["stdin"], DRIVER.read_text())
        self.assertIn(f"LOOM_SHA={self.pushed}", seen["argv"][1])
        self.assertIn("LOOM_POST=no", seen["argv"][1])


if __name__ == "__main__":
    unittest.main()
