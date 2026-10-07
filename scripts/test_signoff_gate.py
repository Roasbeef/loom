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
        for inherited in ("SSH_ORIGINAL_COMMAND", "GH_TOKEN", "SIGNOFF_PARALLEL", "LOOM_SIGNOFF_UNGATED"):
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

    def test_the_gate_fetches_with_the_state_directory_as_home(self):
        # The test's own HOME knows nothing of this URL, so the fetch can
        # succeed only if git reads the state directory's .gitconfig.
        url = "https://origin.example.invalid/loom.git"
        (self.state / ".gitconfig").write_text(f'[url "{self.origin}"]\n\tinsteadOf = {url}\n')
        git(self.state / "loom-signoff", "remote", "set-url", "origin", url)
        result = self.gate(f"signoff {self.pushed} --dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)

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

    def test_a_commit_from_a_deleted_branch_is_refused(self):
        # The checkout holds the commit, as it does after an earlier run,
        # so only the branch check can refuse it once the branch is gone.
        subprocess.run(["git", "-C", str(self.work), "checkout", "-q", "-b", "temp", self.pushed],
                       check=True, env=self.env, capture_output=True)
        subprocess.run(["git", "-C", str(self.work), "commit", "-q", "--allow-empty", "-m", "temporary"],
                       check=True, env=self.env)
        temporary = git(self.work, "rev-parse", "HEAD")
        git(self.work, "push", "-q", "origin", "temp")
        checkout = self.state / "loom-signoff"
        git(checkout, "fetch", "-q", "origin")
        self.assertEqual(git(checkout, "cat-file", "-t", temporary), "commit")
        self.assertEqual(self.gate(f"signoff {temporary} --dry-run").returncode, 0)

        git(self.work, "push", "-q", "origin", ":temp")
        self.record.unlink()
        result = self.gate(f"signoff {temporary} --dry-run")
        self.assertEqual(result.returncode, 2)
        self.assertIn("none of origin's branches", result.stderr)
        self.assertIsNone(self.recorded())

    def test_only_branches_are_fetched_whatever_the_config_says(self):
        git(self.state / "loom-signoff", "config", "--add", "remote.origin.fetch",
            "+refs/pull/*:refs/remotes/origin/pull/*")
        result = self.gate(f"signoff {self.unbranched}")
        self.assertEqual(result.returncode, 2)
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


STUB_DOCKER_SESSION = """#!/usr/bin/env bash
echo "$*" >>"$STUB_DIR/docker.log"
case $1 in
build)
	while [ $# -gt 0 ]; do
		if [ "$1" = --iidfile ]; then echo sha256:stub >"$2"; fi
		shift
	done
	;;
run)
	sleep "$STUB_RUN_SECONDS" &
	echo $! >"$STUB_DIR/run.pid"
	wait
	;;
kill) kill "$(cat "$STUB_DIR/run.pid")" ;;
esac
"""

STUB_GH = """#!/usr/bin/env bash
echo "$*" >>"$STUB_DIR/gh.log"
"""


class DriverSessionTest(Fixture):
    """The driver's run belongs to the session that asked for it."""

    def setUp(self):
        super().setUp()
        self.stubs = self.root / "stubs"
        self.stubs.mkdir()
        for name, text in (("docker", STUB_DOCKER_SESSION), ("gh", STUB_GH)):
            stub = self.stubs / name
            stub.write_text(text)
            stub.chmod(0o755)
        checkout = self.root / "checkout"
        subprocess.run(["git", "clone", "-q", str(self.origin), str(checkout)],
                       check=True, env=self.env, capture_output=True)
        self.env.update(
            PATH=f"{self.stubs}:{self.env['PATH']}", STUB_DIR=str(self.stubs),
            LOOM_DIR=str(checkout), LOOM_ORIGIN=str(self.origin), LOOM_SHA=self.pushed,
            LOOM_POST="yes", LOOM_URL="", LOOM_HEARTBEAT="1",
        )

    def log(self, name):
        path = self.stubs / f"{name}.log"
        return path.read_text() if path.exists() else ""

    def test_a_session_that_goes_away_cancels_the_run(self):
        driver = subprocess.Popen(
            ["bash", str(DRIVER)], env=dict(self.env, STUB_RUN_SECONDS="60"),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        self.addCleanup(lambda: driver.poll() is None and driver.kill())
        self.assertIn("== building", driver.stdout.readline().decode())

        # Closing the read end is what sshd does when the client's Ctrl-C
        # ends the session.
        driver.stdout.close()
        self.assertEqual(driver.wait(timeout=20), 130)
        self.assertRegex(self.log("docker"), r"(?m)^kill loom-signoff-[0-9a-f]{12}-[0-9]+$")
        self.assertEqual(self.log("gh"), "")

    def test_a_session_that_stays_gets_its_verdict(self):
        result = subprocess.run(
            ["bash", str(DRIVER)], env=dict(self.env, STUB_RUN_SECONDS="3"),
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("== running,", result.stdout)
        self.assertIn("GREEN", result.stdout)
        self.assertNotIn("kill", self.log("docker"))
        self.assertEqual(self.log("gh").strip(), f"signoff --commit {self.pushed} linux")


STUB_DOCKER_HOSTILE = """#!/usr/bin/env bash
# `build` writes the image ID file the driver asks for. `run` behaves as a
# hostile container: it replaces every file it can reach under the /logs
# mount with a symlink to the secret, including the names the driver reads.
case $1 in
build)
	while [ $# -gt 0 ]; do
		if [ "$1" = --iidfile ]; then echo sha256:stub >"$2"; fi
		shift
	done
	;;
run)
	while [ $# -gt 0 ]; do
		if [ "$1" = -v ]; then
			case $2 in
			*:/logs)
				dir=${2%:/logs}
				for name in signoff.log image-id image-build.log entrypoint.sh; do
					ln -sf "$STUB_SECRET" "$dir/$name"
				done
				;;
			esac
		fi
		shift
	done
	;;
esac
"""


class DriverTest(Fixture):
    """The driver, with docker replaced by a stub that attacks the mount."""

    def setUp(self):
        super().setUp()
        self.secret = self.root / "secret"
        self.secret.write_text("the-gh-token")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text(STUB_DOCKER_HOSTILE)
        docker.chmod(0o755)
        self.home = self.root / "state"
        self.home.mkdir()
        self.env.update(
            PATH=f"{bin_dir}:{self.env['PATH']}", HOME=str(self.home),
            STUB_SECRET=str(self.secret), LOOM_DIR=str(self.home / "loom-signoff"),
            LOOM_ORIGIN=str(self.origin), LOOM_SHA=self.pushed, LOOM_POST="no",
        )

    def test_a_planted_symlink_in_the_mount_is_not_printed(self):
        result = subprocess.run(["bash", str(DRIVER)], env=self.env, capture_output=True,
                                text=True, timeout=30, stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("the-gh-token", result.stdout + result.stderr)
        logs = self.home / "loom-signoff-container/logs" / self.pushed[:12]
        self.assertTrue((logs / "container/entrypoint.sh").is_symlink())
        self.assertFalse((logs / "signoff.log").is_symlink())
        self.assertFalse((logs / "image-id").is_symlink())


    def test_pruning_keeps_the_current_runs_logs(self):
        # An earlier run of this commit left its directory older than fifty
        # newer ones, which is the case where mtime ordering would prune it.
        parent = self.home / "loom-signoff-container/logs"
        current = parent / self.pushed[:12]
        current.mkdir(parents=True)
        os.utime(current, (1, 1))
        for n in range(55):
            other = parent / f"other{n}"
            other.mkdir()
            os.utime(other, (1000 + n, 1000 + n))
        result = subprocess.run(["bash", str(DRIVER)], env=self.env, capture_output=True,
                                text=True, timeout=30, stdin=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((current / "signoff.log").exists())
        self.assertEqual(len(list(parent.iterdir())), 50)


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
        result = self.remote("--dry-run", SIGNOFF_PARALLEL="4")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertEqual(seen["argv"], ["signoff-host", f"signoff {self.pushed} --dry-run --parallel 4"])
        self.assertEqual(seen["stdin"], "")

    def test_a_gate_takes_no_details_link(self):
        result = self.remote("--url", "https://example.invalid")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(self.recorded())

    def test_an_ungated_host_is_sent_the_driver(self):
        result = self.remote("--dry-run", LOOM_SIGNOFF_UNGATED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        seen = self.recorded()
        self.assertEqual(seen["stdin"], DRIVER.read_text())
        self.assertIn(f"LOOM_SHA={self.pushed}", seen["argv"][1])
        self.assertIn("LOOM_POST=no", seen["argv"][1])


if __name__ == "__main__":
    unittest.main()
