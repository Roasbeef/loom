"""Exercise release publication without building or starting a real daemon."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
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
        (self.repo / "packages/tui/priv").mkdir(parents=True)
        shutil.copy(Path(__file__).resolve().parent.parent / "packages/tui/priv/install.sh",
                    self.repo / "packages/tui/priv/install.sh")
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

    def test_repeated_install_keeps_current_previous_and_in_use_trees(self):
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
        # The reader held the first server tree open, so it survives pruning
        # beside the current and previous trees. Nothing held the first client.
        self.assertEqual(len(list(self.lib.glob("server.*"))), 3)
        self.assertEqual(len(list(self.lib.glob("client.*"))), 2)
        self.assertFalse(old_client.exists())
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

    def trees(self, stem):
        """Names of the real directories the installer treats as release trees."""
        return sorted(p.name for p in self.lib.glob(stem + ".*")
                      if p.is_dir() and not p.is_symlink()
                      and re.fullmatch(r"[A-Za-z0-9]{8}", p.name.split(".", 1)[1]))

    def fake_tree(self, name):
        # The installer works in physical paths, and so must the processes
        # these tests start from a tree (macOS temp dirs sit behind a symlink).
        tree = self.lib.resolve() / name
        tree.mkdir(parents=True)
        (tree / "marker").write_text("old\n")
        return tree

    def hold(self, argv, **kwargs):
        process = subprocess.Popen(argv, **kwargs)
        self.addCleanup(lambda: (process.kill(), process.wait()))
        return process

    def test_prune_removes_unused_trees_and_only_those(self):
        self.install()
        previous = (self.lib / "server").resolve()
        old = [self.fake_tree("server.OLDOLD%02d" % i) for i in range(3)]
        old += [self.fake_tree("client.OLDOLD%02d" % i) for i in range(2)]
        keep = [self.fake_tree(n) for n in (
            "legacy-backup.12345678", "server.short", "server.TOOLONG123",
            "server.bad-char", "serverX.ABCDEFGH", "tui.ABCDEFGH", "other.ABCDEFGH",
        )]
        (self.lib / "update.lock").write_text("")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "marker").write_text("outside\n")
        link = self.lib.resolve() / "server.LINKLINK"
        link.symlink_to(outside)
        regular = self.lib.resolve() / "client.FILEFILE"
        regular.write_text("a regular file\n")
        result = self.install()
        for tree in old:
            self.assertFalse(tree.exists(), tree)
            self.assertIn("removed: " + str(tree), result.stdout)
        self.assertIn("pruned 5 old release trees", result.stdout)
        # The first install's trees were the previous ones, the new ones current.
        self.assertEqual(len(self.trees("server")), 2)
        self.assertEqual(len(self.trees("client")), 2)
        self.assertTrue(previous.is_dir())
        self.assertNotEqual((self.lib / "server").resolve(), previous)
        self.assertEqual(self.launch("loomd")[2], "first")
        for path in keep:
            self.assertTrue(path.is_dir(), path)
        self.assertTrue(link.is_symlink())
        self.assertEqual((outside / "marker").read_text(), "outside\n")
        self.assertTrue(regular.is_file())
        self.assertTrue((self.lib / "update.lock").exists())

    def test_prune_keeps_trees_a_live_process_uses(self):
        self.install()
        named = self.fake_tree("server.HELDHELD")
        free = self.fake_tree("server.FREEFREE")
        self.hold([sys.executable, "-c", "import time; time.sleep(60)", str(named)])
        working = self.fake_tree("client.HELDHELD")
        if shutil.which("lsof"):
            self.hold([sys.executable, "-c", "import time; time.sleep(60)"], cwd=working)
        result = self.install()
        self.assertTrue(named.is_dir())
        self.assertFalse(free.exists())
        self.assertIn("kept (in use): " + str(named), result.stdout)
        if shutil.which("lsof"):
            self.assertTrue(working.is_dir())
            self.assertIn("kept (in use): " + str(working), result.stdout)
        else:
            self.assertFalse(working.exists())

    def test_prune_deletes_nothing_without_a_usable_in_use_check(self):
        self.install()
        old = self.fake_tree("server.OLDOLD01")
        for broken in ("ps", "lsof"):
            if not shutil.which(broken):
                continue
            fake_bin = self.root / ("fake-" + broken)
            fake_bin.mkdir()
            script = fake_bin / broken
            script.write_text("#!/bin/sh\nexit 3\n")
            script.chmod(0o755)
            result = self.install(PATH=str(fake_bin) + os.pathsep + self.env["PATH"])
            self.assertTrue(old.is_dir(), broken)
            self.assertIn("no old release trees pruned", result.stdout)
        result = self.install(LOOM_KEEP_OLD_TREES="1")
        self.assertTrue(old.is_dir())
        self.assertIn("old release trees kept", result.stdout)

    def test_prune_after_a_slim_install_covers_tui_but_not_client_trees(self):
        self.install()
        client = self.fake_tree("client.OLDOLD01")
        tui = self.fake_tree("tui.OLDOLD01")
        self.install("slim")
        self.assertTrue(client.is_dir())
        self.assertFalse(tui.exists())

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
