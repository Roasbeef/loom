"""Keep prerequisite skips visible to the strict CI census under EUnit."""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CENSUS = ROOT / ".github/scripts/skip_census.sh"
STDOUT_SKIP = re.compile(r'\bio\.println\s*\((?:\s|//[^\n]*)*"SKIP(?:\s|")')
QUOTED_OR_COMMENT = re.compile(r'//[^\n]*|"(?:\\.|[^"\\])*"', re.DOTALL)


def stdout_skip_sites(source):
    # A call written in a Gleam string or // comment is documentation, not an
    # emitter. Token spans also keep // inside a quoted URL from hiding code.
    excluded = [match.span() for match in QUOTED_OR_COMMENT.finditer(source)]
    return [match for match in STDOUT_SKIP.finditer(source)
            if not any(start <= match.start() < end for start, end in excluded)]


class SkipReportingTest(unittest.TestCase):
    def test_skip_emitter_guard_recognizes_multiline_and_shared_helpers(self):
        for source in ['io.println("SKIP example: absent")',
                       'io.println(\n  "SKIP " <> name <> ": " <> reason,\n)',
                       'io.println( // Prerequisite absent.\n "SKIP example")']:
            with self.subTest(source=source):
                self.assertEqual(len(stdout_skip_sites(source)), 1)
        for source in ['io.println_error("SKIP example")',
                       'io.println("ordinary output mentioning SKIP")',
                       '// io.println("SKIP example")',
                       'let x = 1 // io.println("SKIP example")',
                       'let example = "io.println(\\"SKIP example\\")"']:
            with self.subTest(source=source):
                self.assertEqual(stdout_skip_sites(source), [])
        self.assertEqual(len(stdout_skip_sites(
            'let url = "https://example.invalid"\nio.println("SKIP example")'
        )), 1)

    def test_gleam_prerequisite_skips_bypass_captured_stdout(self):
        # Existing suites use a leading SKIP literal, including shared helpers.
        # Keep that convention on stderr: EUnit hides successful stdout even
        # with verbose progress, so a green census could otherwise miss a skip.
        hidden = []
        for path in sorted((ROOT / "packages").glob("*/test/**/*.gleam")):
            source = path.read_text()
            for match in stdout_skip_sites(source):
                line = source.count("\n", 0, match.start()) + 1
                hidden.append(f"{path.relative_to(ROOT)}:{line}")
        self.assertEqual(hidden, [], "Use io.println_error for SKIP diagnostics")

    def test_passing_eunit_skip_reaches_the_census(self):
        # Run stock EUnit rather than fabricating a log. Its stdout control
        # demonstrates the capture behavior that made the declaration appear
        # stale; the stderr diagnostic is the path all real skips must use.
        expression = '''
          Result = eunit:test([fun() ->
            io:format("SKIP stdout_probe: captured prerequisite~n", []),
            io:format(standard_error,
                      "SKIP stderr_probe: visible prerequisite~n", [])
          end], [verbose]),
          case Result of ok -> erlang:halt(0); _ -> erlang:halt(1) end.
        '''
        result = subprocess.run(
            ["erl", "+S", "2:2", "-noshell", "-eval", expression],
            capture_output=True, text=True, timeout=10,
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        self.assertNotIn("SKIP stdout_probe", output)
        self.assertEqual(output.count("SKIP stderr_probe"), 1)

        with tempfile.TemporaryDirectory(prefix="loom-skip-reporting-") as root:
            log = Path(root) / "gate.log"
            declarations = Path(root) / "declared-skips"
            log.write_text(output)
            declarations.write_text("")
            environment = dict(os.environ, LOOM_DECLARED_SKIPS=str(declarations))
            environment.pop("GITHUB_STEP_SUMMARY", None)

            def census():
                return subprocess.run(
                    ["bash", str(CENSUS), "reporting regression", str(log)],
                    env=environment, capture_output=True, text=True, timeout=5,
                )

            undeclared = census()
            self.assertEqual(undeclared.returncode, 1, undeclared.stderr)
            self.assertIn("1 undeclared skip", undeclared.stdout)

            declarations.write_text(
                "declared|any|visible prerequisite|deliberate regression fixture\n"
            )
            declared = census()
            self.assertEqual(declared.returncode, 0, declared.stderr)
            self.assertIn("declared skips", declared.stdout)

            log.write_text("")
            stale = census()
            self.assertEqual(stale.returncode, 1, stale.stderr)
            self.assertIn("Stale declaration", stale.stdout)


if __name__ == "__main__":
    unittest.main()
