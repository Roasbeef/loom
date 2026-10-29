"""Keep prerequisite skips visible to the strict CI census under EUnit.

The guard against stdout skip emitters in Gleam test sources is lint rule R19;
this file proves the EUnit behaviour that rule protects against. The Darwin
policy regression also rejects a return to silently waived verifier skips.
"""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CENSUS = ROOT / ".github/scripts/skip_census.sh"


class SkipReportingTest(unittest.TestCase):
    # The static half of this contract -- no `io.println("SKIP ...")` in any
    # test source -- is lint rule R19 (packages/lint, lint/skip_stdout), which
    # `make lint` runs over every package's test/ directory. What a lint rule
    # cannot show is the premise it rests on, that EUnit really discards a
    # passing test's stdout, so that is what remains here.
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

    def test_darwin_refusal_coverage_needs_no_verifier_skip_waiver(self):
        # Main's Darwin verifier tests execute refusal assertions. Reintroducing
        # the old waiver both rejects those logs as stale and excuses a future
        # verifier skip. Exercise the real configured census on either host.
        historical_refusal = (
            "the jail refused: this host cannot jail a verifier: the verifier ran "
            "without a required enforcement layer: skip:rlimit-address-space: "
            "invalid argument; mem_bytes was NOT applied; "
            "skip:darwin-process-lifecycle: macOS has no PID namespace, subreaper, "
            "or stable process handle; rapid reparenting can evade sampled cleanup "
            "and PID reuse remains racy while the Seatbelt profile persists"
        )
        configured = ROOT / ".github/declared-skips"
        prerequisites = []
        for line in configured.read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            kind, platform, marker, _ = line.split("|", 3)
            if (
                kind == "declared"
                and platform in ("any", "darwin")
                and "this host cannot jail a verifier" not in marker
            ):
                prerequisites.append("SKIP existing_prerequisite: " + marker)

        with tempfile.TemporaryDirectory(prefix="loom-darwin-census-") as root:
            directory = Path(root)
            shim = directory / "bin"
            shim.mkdir()
            uname = shim / "uname"
            uname.write_text("#!/bin/sh\nprintf '%s\\n' Darwin\n")
            uname.chmod(0o700)
            log = directory / "gate.log"
            baseline = "\n".join(prerequisites) + "\n"
            environment = dict(
                os.environ,
                PATH=str(shim) + os.pathsep + os.environ["PATH"],
                LOOM_DECLARED_SKIPS=str(configured),
            )
            environment.pop("GITHUB_STEP_SUMMARY", None)

            def census(output):
                log.write_text(output)
                return subprocess.run(
                    ["bash", str(CENSUS), "Darwin verifier coverage", str(log)],
                    env=environment, capture_output=True, text=True, timeout=5,
                )

            refusal_coverage = census(baseline)
            self.assertEqual(refusal_coverage.returncode, 0,
                             refusal_coverage.stdout + refusal_coverage.stderr)
            skipped_verifier = census(
                baseline + "SKIP verifier: " + historical_refusal + "\n"
            )
            self.assertEqual(skipped_verifier.returncode, 1,
                             skipped_verifier.stdout + skipped_verifier.stderr)
            self.assertIn("1 undeclared skip", skipped_verifier.stdout)
            self.assertNotIn("Stale declaration", skipped_verifier.stdout)


if __name__ == "__main__":
    unittest.main()
