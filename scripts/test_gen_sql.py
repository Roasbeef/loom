"""SQL generation must distinguish a printed Parrot failure from success."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class GenerationStatusTest(unittest.TestCase):
    def run_generator(self, output, status):
        with tempfile.TemporaryDirectory(prefix="loom-gen-sql-test-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            for name in ("gen-sql.sh", "embed-sql-schema.py"):
                shutil.copyfile(ROOT / "scripts" / name, root / "scripts" / name)
            for package in ("storage", "executor"):
                shutil.copytree(ROOT / "packages" / package / "sql",
                                root / "packages" / package / "sql")
                (root / "packages" / package / "src" / package).mkdir(parents=True)
            # Only the child status protocol is simulated. The real wrapper,
            # pipeline and schema-embedding path execute inside this fixture.
            for name, source in {
                "sqlite3": "#!/bin/sh\ncat >/dev/null\n",
                "gleam": '''#!/bin/sh
if [ "$1" = run ]; then
  printf '%s\\n' "$GEN_SQL_TEST_OUTPUT"
  exit "$GEN_SQL_TEST_STATUS"
fi
exit 0
''',
            }.items():
                path = root / "bin" / name
                path.write_text(source)
                path.chmod(0o755)
            env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                       GEN_SQL_TEST_OUTPUT=output, GEN_SQL_TEST_STATUS=str(status))
            return subprocess.run(["bash", "scripts/gen-sql.sh", "executor"],
                                  cwd=root, env=env, capture_output=True, text=True,
                                  timeout=10)

    def test_printed_error_with_zero_status_refuses_stale_bindings(self):
        result = self.run_generator("Error: could not call sqlc generate", 0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generation did not complete successfully", result.stderr)
        self.assertNotIn("generated SQL modules are up to date", result.stdout)

    def test_nonzero_child_status_is_not_hidden_by_tee_or_success_text(self):
        result = self.run_generator("SQL successfully generated!", 7)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("generated SQL modules are up to date", result.stdout)

    def test_success_status_and_marker_allow_schema_generation(self):
        result = self.run_generator("\x1b[32mSQL successfully generated!\x1b[0m", 0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("generated SQL modules are up to date", result.stdout)


if __name__ == "__main__":
    unittest.main()
