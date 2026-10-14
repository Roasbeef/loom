"""Exercise the package runner's concurrency boundary with real EUnit modules."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
from collections import Counter


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
                LOOM_BUILD_TIMEOUT_SECONDS="10", LOOM_TEST_SHARD="1/1",
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

    def test_shards_partition_modules_and_keep_serial_exclusive(self):
        with tempfile.TemporaryDirectory(prefix="loom-shard-runner-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            for name in ["test.sh", "with_timeout.py"]:
                shutil.copy2(ROOT / "scripts" / name, scripts / name)
            serial_file = scripts / "serial-tests"
            serial_file.write_text(
                "host|probe_e|The probe checks the exclusive serial barrier.\n"
                "host|probe_f|The probe checks the exclusive serial barrier.\n"
            )
            package = root / "packages/host"
            tests = package / "test"
            tests.mkdir(parents=True)
            ebin = package / "build/dev/erlang/host/ebin"
            ebin.mkdir(parents=True)
            (tests / "probe_support.erl").write_text('''
-module(probe_support).
-export([start/2, stop/1, body/1, serial/1]).
start(_, _) ->
    persistent_term:put(probe_counter, atomics:new(2, [])),
    {ok, spawn_link(fun() -> receive stop -> ok end end)}.
stop(_) -> ok.
body(Name) ->
    Counter = persistent_term:get(probe_counter),
    Live = atomics:add_get(Counter, 1, 1),
    try
        true = Live =< 2,
        io:format(standard_error, "PROBE_BODY ~s~n", [Name]),
        receive finish -> ok after 20 -> ok end
    after
        atomics:sub(Counter, 1, 1),
        atomics:add(Counter, 2, 1)
    end.
serial(Name) ->
    Counter = persistent_term:get(probe_counter),
    0 = atomics:get(Counter, 1),
    Expected = list_to_integer(os:getenv("PROBE_EXPECTED_COMPLETED")),
    Expected = atomics:get(Counter, 2),
    io:format(standard_error, "PROBE_SERIAL ~s~n", [Name]),
    ok.
''')
            names = [f"probe_{letter}" for letter in "abcdef"]
            for name in names:
                function = "serial" if name in ["probe_e", "probe_f"] else "body"
                (tests / f"{name}.erl").write_text(
                    f"-module({name}).\n-export([runs_test/0]).\n"
                    f'runs_test() -> probe_support:{function}("{name}").\n'
                )
            subprocess.run(
                ["erlc", "-o", str(ebin), *map(str, tests.glob("*.erl"))],
                check=True, capture_output=True, text=True, timeout=20,
            )
            (ebin / "host.app").write_text(
                '{application,host,[{vsn,"1"},{modules,[probe_support]},'
                '{applications,[kernel,stdlib]},{mod,{probe_support,[]}}]}.\n'
            )
            binaries = root / "bin"
            binaries.mkdir()
            gleam = binaries / "gleam"
            gleam.write_text("#!/bin/sh\necho PROBE_BUILD\n")
            gleam.chmod(0o755)
            environment = dict(
                os.environ, PATH=str(binaries) + os.pathsep + os.environ["PATH"],
                LOOM_TEST_PARALLEL="2", LOOM_TEST_TIMEOUT_SECONDS="10",
                LOOM_BUILD_TIMEOUT_SECONDS="10", PROBE_EXPECTED_COMPLETED="0",
            )

            def run(shard, *arguments):
                return subprocess.run(
                    ["bash", str(scripts / "test.sh"), "host", *arguments],
                    env=dict(environment, LOOM_TEST_SHARD=shard),
                    capture_output=True, text=True, timeout=20,
                )

            # Include the support module in the inventory, just as the real
            # runner does. It exports no tests but still owns one shard slot.
            inventory = sorted(names + ["probe_support"])
            observed = []
            for index in range(1, 4):
                expected = inventory[index - 1::3]
                environment["PROBE_EXPECTED_COMPLETED"] = str(
                    sum(name in "probe_a probe_b probe_c probe_d".split()
                        for name in expected)
                )
                result = run(f"{index}/3")
                output = result.stdout + result.stderr
                self.assertEqual(result.returncode, 0, output)
                markers = [line.split()[1] for line in result.stderr.splitlines()
                           if line.startswith(("PROBE_BODY ", "PROBE_SERIAL "))]
                self.assertCountEqual(markers, [name for name in expected if name in names])
                observed.extend(markers)
                if "PROBE_SERIAL " in result.stderr and "PROBE_BODY " in result.stderr:
                    self.assertGreater(result.stderr.index("PROBE_SERIAL "),
                                       result.stderr.rindex("PROBE_BODY "))
            self.assertEqual(Counter(observed), Counter(names))

            # A declaration on another shard is valid; a missing module is not.
            with serial_file.open("a") as declarations:
                declarations.write("host|probe_missing|A stale declaration must fail.\n")
            stale = run("1/3")
            self.assertEqual(stale.returncode, 2, stale.stdout + stale.stderr)
            self.assertIn("declares modules absent", stale.stderr)
            serial_file.write_text("")

            empty = run("8/8")
            self.assertEqual(empty.returncode, 2, empty.stdout + empty.stderr)
            self.assertIn("No tests matched", empty.stderr)
            focused = run("1/1", "--match", "probe_a:runs_test")
            self.assertEqual(focused.returncode, 0, focused.stdout + focused.stderr)
            self.assertEqual(focused.stderr.count("PROBE_BODY"), 1)

            for shard in ["0/2", "1/0", "3/2", "1", "a/2", "1/2/3",
                          "999999999999999999999999/2"]:
                with self.subTest(shard=shard):
                    invalid = run(shard)
                    self.assertEqual(invalid.returncode, 2, invalid.stdout + invalid.stderr)
                    self.assertNotIn("PROBE_BUILD", invalid.stdout)
            ambiguous = run("1/2", "--match", "probe_a:runs_test")
            self.assertEqual(ambiguous.returncode, 2)
            self.assertNotIn("PROBE_BUILD", ambiguous.stdout)


if __name__ == "__main__":
    unittest.main()
