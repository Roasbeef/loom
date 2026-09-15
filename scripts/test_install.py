"""Exercise release publication without building or starting a real daemon."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class InstallTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        shutil.copy(Path(__file__).with_name("install.sh"), self.repo / "scripts/install.sh")
        self.prefix = self.root / "prefix space $cash 'quote"
        self.lib = self.prefix / "lib/loom"
        self.env = dict(os.environ, PREFIX=str(self.prefix), HOME=str(self.root / "home"))
        self.server = self.repo / "build/release/loom"
        self.client = self.repo / "build/release/loom-client"
        self.slim = self.repo / "build/tui-erlang-shipment"
        for tree in (self.server, self.client, self.slim):
            (tree / "bin").mkdir(parents=True)
            (tree / "marker").write_text("first\n")
            for name in ("loomd", "loom-exec", "loom", "loom-profile"):
                executable = tree / "bin" / name
                executable.write_text(
                    '#!/bin/sh\nset -eu\n'
                    'root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)\n'
                    'printf "%s\\n" "$root" "${LOOM_EXECUTABLE-unset}"\n'
                    'cat "$root/marker"\n'
                    'printf "%s\\n" "$@"\n'
                )
                executable.chmod(0o755)
        (self.server / "share/codemode-seed").mkdir(parents=True)

    def install(self, shape="bundled", success=True, **environment):
        result = subprocess.run(
            ["bash", str(self.repo / "scripts/install.sh")],
            env=dict(self.env, LOOM_CLIENT=shape, **environment),
            capture_output=True, text=True, timeout=10,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def launch(self, name):
        return subprocess.check_output(
            [str(self.prefix / "bin" / name), "argument with spaces"],
            env=self.env, text=True, timeout=5,
        ).splitlines()

    def test_repeated_install_retains_every_tree_and_publishes_new_contents(self):
        self.install()
        old_server = (self.lib / "server").resolve()
        old_client = (self.lib / "client").resolve()
        old_wrapper = (self.prefix / "bin/loom").read_bytes()
        # A running process can load another module long after its launch.
        reader = subprocess.Popen(
            ["sh", "-c", 'read ignored; cat "$1/marker"', "sh", str(old_server)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        self.addCleanup(lambda: reader.poll() is None and reader.kill())
        for value in ("second", "third", "fourth"):
            for tree in (self.server, self.client):
                (tree / "marker").write_text(value + "\n")
            self.install()
            self.assertEqual(self.launch("loomd")[2], value)
            self.assertEqual(self.launch("loom")[2:], [value, "argument with spaces"])
        self.assertEqual(reader.communicate("load\n", timeout=5)[0], "first\n")
        self.assertEqual(reader.returncode, 0)
        self.assertEqual((old_client / "marker").read_text(), "first\n")
        self.assertEqual(len(list(self.lib.glob("server.*"))), 4)
        self.assertEqual(len(list(self.lib.glob("client.*"))), 4)
        self.assertNotEqual(old_server, (self.lib / "server").resolve())
        self.assertEqual(self.launch("loom")[1], str((self.prefix / "bin/loom").resolve()))
        self.assertEqual((self.prefix / "bin/loom").read_bytes(), old_wrapper)

    def test_shape_switch_and_link_rollback_preserve_old_readers(self):
        self.install()
        old = (self.lib / "server").resolve()
        client = (self.lib / "client").resolve()
        (self.server / "marker").write_text("second\n")
        self.install("slim")
        self.assertEqual(self.launch("loom")[0], str((self.lib / "tui").resolve()))
        self.assertEqual(self.launch("loom-profile")[0], str((self.lib / "tui").resolve()))
        self.assertEqual((self.lib / "client").resolve(), client)
        rollback = self.lib / "rollback"
        rollback.symlink_to(old)
        os.replace(rollback, self.lib / "server")
        self.assertEqual(self.launch("loomd")[2], "first")

    def test_legacy_layout_is_refused_before_publication(self):
        self.install()
        previous = (self.lib / "server").resolve()
        legacy = self.lib / "tui"
        legacy.mkdir()
        (legacy / "marker").write_text("legacy")
        result = self.install(success=False)
        self.assertIn("migrated offline", result.stderr)
        self.assertEqual((legacy / "marker").read_text(), "legacy")
        self.assertEqual((self.lib / "server").resolve(), previous)
        self.assertEqual(len(list(self.lib.glob("server.*"))), 1)

    def test_failed_copy_does_not_change_links_or_wrappers(self):
        self.install()
        previous = (self.lib / "server").resolve()
        wrapper = (self.prefix / "bin/loom").read_bytes()
        fake_bin = self.root / "fake-bin"
        fake_bin.mkdir()
        cp = fake_bin / "cp"
        cp.write_text("#!/bin/sh\nexit 17\n")
        cp.chmod(0o755)
        self.install(success=False, PATH=str(fake_bin) + os.pathsep + self.env["PATH"])
        self.assertEqual((self.lib / "server").resolve(), previous)
        self.assertEqual((self.prefix / "bin/loom").read_bytes(), wrapper)
        self.assertEqual(self.launch("loomd")[2], "first")


if __name__ == "__main__":
    unittest.main()
