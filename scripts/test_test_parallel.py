"""Exercise the package runner's concurrency boundary with real EUnit modules."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class TestParallelRunner(unittest.TestCase):
    def test_module_limit_and_exclusive_serial_barrier(self):
        with tempfile.TemporaryDirectory(prefix="loom-parallel-runner-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ["test.sh", "with_timeout.py"]:
                shutil.copy2(ROOT / "scripts" / name, scripts / name)
            (scripts / "serial-tests").write_text(
                "host|probe_serial|The probe checks the exclusive serial barrier.\n"
            )
            package = root / "packages" / "host"
            tests = package / "test"
            tests.mkdir(parents=True)
            ebin = package / "build/dev/erlang/host/ebin"
            ebin.mkdir(parents=True)
            (tests / "probe_support.erl").write_text('''
-module(probe_support).
-export([start/2, stop/1, body/0, serial/0]).
start(_, _) ->
    persistent_term:put(probe_counter, atomics:new(2, [])),
    Coordinator = spawn_link(fun() -> pair(none) end),
    persistent_term:put(probe_coordinator, Coordinator),
    {ok, Coordinator}.
stop(_) -> ok.
pair(none) ->
    receive {ready, First} -> pair(First) end;
pair(First) ->
    receive {ready, Second} ->
        First ! release,
        Second ! release,
        pair(none)
    end.
body() ->
    Counter = persistent_term:get(probe_counter),
    Live = atomics:add_get(Counter, 1, 1),
    try
        io:format(standard_error, "PROBE_ENTER ~p~n", [Live]),
        true = Live =< 2,
        %% Pairing requires real overlap without assuming a module load time.
        persistent_term:get(probe_coordinator) ! {ready, self()},
        receive release -> ok after 2000 -> error(probe_pair_timeout) end,
        %% Keep the witnessed pair live briefly to expose extra nested bodies.
        receive finish -> ok after 20 -> ok end
    after
        atomics:sub(Counter, 1, 1),
        atomics:add(Counter, 2, 1)
    end.
serial() ->
    Counter = persistent_term:get(probe_counter),
    0 = atomics:get(Counter, 1),
    6 = atomics:get(Counter, 2),
    io:format(standard_error, "PROBE_SERIAL~n", []),
    ok.
''')
            for name in ["probe_a", "probe_b"]:
                (tests / f"{name}.erl").write_text(
                    f"-module({name}).\n-export([one_test/0, two_test/0, three_test/0]).\n"
                    "one_test() -> probe_support:body().\n"
                    "two_test() -> probe_support:body().\n"
                    "three_test() -> probe_support:body().\n"
                )
            (tests / "probe_serial.erl").write_text(
                "-module(probe_serial).\n-export([barrier_test/0]).\n"
                "barrier_test() -> probe_support:serial().\n"
            )
            subprocess.run(
                ["erlc", "-o", str(ebin), *map(str, tests.glob("*.erl"))],
                check=True, capture_output=True, text=True, timeout=20,
            )
            (ebin / "host.app").write_text(
                '{application,host,[{vsn,"1"},{modules,[probe_support]},'
                '{applications,[kernel,stdlib]},{mod,{probe_support,[]}}]}.\n'
            )

            # Compilation is already real above. Stub only Gleam's build so
            # this isolated runner fixture needs no package dependency tree.
            binaries = root / "bin"
            binaries.mkdir()
            gleam = binaries / "gleam"
            gleam.write_text("#!/bin/sh\nexit 0\n")
            gleam.chmod(0o755)
            environment = dict(
                os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                LOOM_TEST_PARALLEL="2", LOOM_TEST_TIMEOUT_SECONDS="10",
                LOOM_BUILD_TIMEOUT_SECONDS="10",
            )
            result = subprocess.run(
                ["bash", str(scripts / "test.sh"), "host"],
                env=environment, capture_output=True, text=True, timeout=20,
            )
            output = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, output)
            self.assertEqual(output.count("PROBE_ENTER"), 6, output)
            self.assertIn("PROBE_ENTER 2", output)
            self.assertEqual(output.count("PROBE_SERIAL"), 1, output)
            self.assertGreater(output.index("PROBE_SERIAL"), output.rindex("PROBE_ENTER"))


if __name__ == "__main__":
    unittest.main()
