"""Check startup benchmark endpoints and failure cleanup without releases."""

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from contextlib import redirect_stdout


SPEC = importlib.util.spec_from_file_location(
    "bench_startup_memory", Path(__file__).with_name("bench_startup_memory.py"))
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


class MaxRssTest(unittest.TestCase):
    def test_linux_wait4_already_reports_kib(self):
        with patch.object(bench.sys, "platform", "linux"):
            self.assertEqual(bench.maxrss_kib(65536), 65536.0)

    def test_darwin_wait4_bytes_are_converted_to_kib(self):
        with patch.object(bench.sys, "platform", "darwin"):
            self.assertEqual(bench.maxrss_kib(67108864), 65536.0)


class ForeignRetirementTest(unittest.TestCase):
    def test_zombie_with_parentheses_in_command_is_retired_without_waiting(self):
        with patch.object(bench.sys, "platform", "linux"), \
                patch("builtins.open", unittest.mock.mock_open(
                    read_data="123 (daemon (worker)) Z 1 123 123 0 -1 4227084 100 0 0 0 0 0 0 0 20 0 1 0")), \
                patch.object(bench.os, "kill") as kill, \
                patch.object(bench.time, "monotonic", side_effect=[0, 0, 2]), \
                patch.object(bench.time, "sleep") as sleep:
            bench.stop_foreign(123, grace_s=1)
        self.assertEqual(kill.call_args_list, [unittest.mock.call(123, bench.signal.SIGTERM),
                                               unittest.mock.call(123, 0)])
        sleep.assert_not_called()

    def test_live_process_still_waits_and_receives_kill_at_deadline(self):
        with patch.object(bench.sys, "platform", "linux"), \
                patch("builtins.open", unittest.mock.mock_open(
                    read_data="123 (daemon) S 1 123 123 0 -1 4227084 100 0 0 0 0 0 0 0 20 0 1 0")), \
                patch.object(bench.os, "kill") as kill, \
                patch.object(bench.time, "monotonic", side_effect=[0, 0, 2]), \
                patch.object(bench.time, "sleep") as sleep:
            bench.stop_foreign(123, grace_s=1)
        sleep.assert_called_once_with(0.02)
        self.assertEqual(kill.call_args_list[-1], unittest.mock.call(123, bench.signal.SIGKILL))

    def test_zombie_leader_with_other_threads_is_not_retirement_evidence(self):
        with patch.object(bench.sys, "platform", "linux"), \
                patch("builtins.open", unittest.mock.mock_open(
                    read_data="123 (daemon) Z 1 123 123 0 -1 4227084 100 0 0 0 0 0 0 0 20 0 2 0")):
            self.assertFalse(bench.linux_zombie(123))

    def test_unreadable_procfs_is_not_retirement_evidence(self):
        with patch.object(bench.sys, "platform", "linux"), \
                patch("builtins.open", side_effect=PermissionError("procfs unavailable")), \
                patch.object(bench.os, "kill") as kill, \
                patch.object(bench.time, "monotonic", side_effect=[0, 0, 2]), \
                patch.object(bench.time, "sleep") as sleep:
            bench.stop_foreign(123, grace_s=1)
        sleep.assert_called_once()
        self.assertEqual(kill.call_args_list[-1], unittest.mock.call(123, bench.signal.SIGKILL))

    def test_other_states_and_malformed_procfs_are_not_zombies(self):
        for stat in ("123 (daemon) S 1", "123 (daemon) R 1", "123 (daemon) T 1",
                     "124 (daemon) Z 1", "123 daemon Z 1", "123 (daemon)",
                     "123 (daemon)Z", "123 (daemon) Zgarbage", ""):
            with self.subTest(stat=stat), \
                    patch.object(bench.sys, "platform", "linux"), \
                    patch("builtins.open", unittest.mock.mock_open(read_data=stat)):
                self.assertFalse(bench.linux_zombie(123))

    def test_darwin_does_not_consult_procfs(self):
        with patch.object(bench.sys, "platform", "darwin"), \
                patch("builtins.open") as opened:
            self.assertFalse(bench.linux_zombie(123))
        opened.assert_not_called()


class ConfigurationTest(unittest.TestCase):
    def test_explicit_config_flows_to_client_and_persisted_provenance(self):
        # Exercise CLI parsing and the resulting JSON with actual input bytes;
        # only release processes and git discovery are replaced in this test.
        with tempfile.TemporaryDirectory(prefix="loom-bench-config-") as directory:
            root = Path(directory)
            config = root / "catalogue.toml"
            config.write_bytes(b"abc")
            private = root / "private"
            private.mkdir()
            build = SimpleNamespace(name="current", loomd="/release/loomd", check=Mock())

            def measured(key, builds, runs, db):
                args = bench.client_args(SimpleNamespace(root=str(private), state="/private", work="/work"), build)
                self.assertEqual(args[args.index("--config") + 1], str(config))
                self.assertEqual(args[args.index("--server") + 1], str(private / "loomd-best-effort"))
                return {"current": {"total": {"time_ms": [100], "rss_kib": []}}}, {"current": {}}

            with patch.object(bench.sys, "argv", ["bench", "--config", str(config),
                                                   "--only", "g", "--runs", "1", "--best-effort"]), \
                    patch.object(bench, "CONFIG", bench.CONFIG), \
                    patch.object(bench, "BEST_EFFORT", False), \
                    patch.object(bench, "OUT_DIR", str(root / "results")), \
                    patch.object(bench, "CURRENT", build), \
                    patch.object(bench, "warm_up"), \
                    patch.object(bench, "measure", side_effect=measured), \
                    patch.object(bench.subprocess, "run", return_value=SimpleNamespace(stdout="frozen\n")), \
                    redirect_stdout(io.StringIO()):
                bench.main()
            result = json.loads((root / "results/latest.json").read_text())
            self.assertEqual(result["configuration"], {
                "path": str(config), "size_bytes": 3,
                "sha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"})
            self.assertEqual(result["enforcement_demand"], "best-effort")
            self.assertIn("private launcher execs release", result["client_autostart"])
            self.assertIn("g", result["raw"])

    def test_non_file_config_is_rejected_before_measurement(self):
        with tempfile.TemporaryDirectory(prefix="loom-bench-config-") as directory:
            with self.assertRaisesRegex(bench.BenchError, "not a readable regular file"):
                bench.configuration_provenance(directory)
            with self.assertRaisesRegex(bench.BenchError, "not a readable regular file"):
                bench.configuration_provenance(str(Path(directory) / "missing.toml"))

    def test_actual_read_failure_is_not_treated_as_valid_provenance(self):
        with patch.object(bench.os.path, "isfile", return_value=True), \
                patch("builtins.open", side_effect=PermissionError("unreadable")):
            with self.assertRaisesRegex(bench.BenchError, "configuration is unreadable"):
                bench.configuration_provenance("catalogue.toml")


class EnforcementLaunchTest(unittest.TestCase):
    def test_default_client_uses_release_without_a_private_launcher(self):
        # No root is supplied: default argument generation must not need a
        # wrapper directory or perform wrapper filesystem operations.
        with patch.object(bench, "BEST_EFFORT", False):
            args = bench.client_args(SimpleNamespace(state="/state", work="/work"),
                                     SimpleNamespace(loomd="/release/loomd"))
        self.assertEqual(args[args.index("--server") + 1], "/release/loomd")
        self.assertNotIn("--best-effort", args)

    def test_opted_in_wrapper_preserves_literal_paths_helper_and_arguments(self):
        with tempfile.TemporaryDirectory(prefix="loom-bench-launch-") as directory:
            root = Path(directory)
            release = root / "release ' with $(unwanted)"
            release.mkdir()
            daemon = release / "loomd"
            daemon.write_text("#!" + bench.sys.executable + "\n"
                              "import json, sys\nprint(json.dumps(sys.argv[1:]))\n")
            daemon.chmod(0o700)
            helper = release / "loom-exec"
            helper.write_text("#!/bin/sh\nexit 0\n")
            helper.chmod(0o700)
            private = root / "private"
            private.mkdir()
            profile = SimpleNamespace(root=str(private), state="/state", work="/work")
            with patch.object(bench, "BEST_EFFORT", True):
                args = bench.client_args(profile, SimpleNamespace(loomd=str(daemon)))
            wrapper = args[args.index("--server") + 1]
            extra = ["--state-dir", "literal ' $(unwanted) path"]
            output = subprocess.check_output([wrapper, *extra], text=True, timeout=5)
            self.assertEqual(json.loads(output),
                             ["--best-effort", "--helper", str(helper), *extra])
            self.assertNotIn("--best-effort", args)

    def test_direct_daemon_gets_best_effort_only_after_opt_in(self):
        profile = SimpleNamespace(root="/private", state="/private/state",
                                  work="/private/work", env={})
        for enabled in (False, True):
            proc = Mock(pid=987654, returncode=None)
            with self.subTest(best_effort=enabled), \
                    patch.object(bench, "BEST_EFFORT", enabled), \
                    patch("builtins.open", unittest.mock.mock_open()), \
                    patch.object(bench.subprocess, "Popen", return_value=proc) as popen, \
                    patch.object(bench.Daemon, "_await_ready", return_value=1), \
                    patch.object(bench.Daemon, "_port", return_value=1234):
                bench.Daemon(profile, SimpleNamespace(loomd="/release/loomd"))
            self.assertEqual("--best-effort" in popen.call_args.args[0], enabled)
            bench.LIVE.discard(proc.pid)


class CreationTimingTest(unittest.TestCase):
    def test_reply_and_resident_are_distinct_endpoints(self):
        control = object.__new__(bench.Control)
        control.request = Mock(side_effect=[
            {"session_id": "session-one"},
            {"status": {"state": "opening"}},
            {"status": {"state": "resident"}},
        ])
        with patch.object(bench, "now_ms", side_effect=[100, 112, 150]), \
                patch.object(bench.time, "sleep"):
            timed = control.create_session_timed(SimpleNamespace(work="/work"), "key")
        self.assertEqual(timed, {"session_id": "session-one",
                                 "create_reply_ms": 12, "resident_ms": 50})
        self.assertEqual([call.args[0] for call in control.request.call_args_list],
                         ["sessions.create", "sessions.get", "sessions.get"])
        for call in control.request.call_args_list:
            self.assertGreater(call.kwargs["within_s"], 0)
            self.assertLessEqual(call.kwargs["within_s"], 30)

    def test_create_time_spends_the_residency_deadline(self):
        control = object.__new__(bench.Control)
        control.request = Mock(return_value={"session_id": "slow-session"})
        # The create reply consumes the entire one-second shared deadline.
        with patch.object(bench, "now_ms", side_effect=[0, 1100]), \
                patch.object(bench.time, "monotonic", side_effect=[0, 0, 1.1]):
            with self.assertRaisesRegex(bench.BenchError, "slow-session never became resident"):
                control.create_session_timed(SimpleNamespace(work="/work"), "key", within_s=1)
        control.request.assert_called_once()

    def test_refused_status_is_not_reported_as_ready(self):
        control = object.__new__(bench.Control)
        control.request = Mock(side_effect=[
            {"session_id": "session-one"}, bench.BenchError("sessions.get refused")])
        with self.assertRaisesRegex(bench.BenchError, "sessions.get refused"):
            control.create_session_timed(SimpleNamespace(work="/work"), "key")


class ControlDeadlineTest(unittest.TestCase):
    def test_continuous_unrelated_frames_cannot_extend_rpc(self):
        clock = [0.0]
        payload = json.dumps({"event": "notice"}).encode()
        frame = bytes([0x81, len(payload)]) + payload
        data = bytearray(frame * 100)
        sock = Mock()

        def receive(count):
            clock[0] += 0.03
            chunk = bytes(data[:count])
            del data[:count]
            return chunk

        sock.recv.side_effect = receive
        control = object.__new__(bench.Control)
        control.sock, control.next_id = sock, 1
        with patch.object(bench.time, "monotonic", side_effect=lambda: clock[0]):
            with self.assertRaisesRegex(bench.BenchError, "sessions.get: control request deadline"):
                control.request("sessions.get", {}, within_s=0.1)
        self.assertLess(clock[0], 0.2)
        remaining = [call.args[0] for call in sock.settimeout.call_args_list]
        self.assertGreater(len(remaining), 2)
        self.assertEqual(remaining, sorted(remaining, reverse=True))

    def test_upgrade_eof_closes_socket(self):
        sock = Mock()
        sock.recv.return_value = b""
        with patch("builtins.open", unittest.mock.mock_open(read_data="token")), \
                patch.object(bench.socket, "create_connection", return_value=sock):
            with self.assertRaisesRegex(bench.BenchError, "control socket closed"):
                bench.Control(SimpleNamespace(state="/private"), 1234)
        sock.close.assert_called_once()


class LaunchCleanupTest(unittest.TestCase):
    def test_daemon_readiness_failure_retires_live_process(self):
        proc = Mock(pid=987654, returncode=None)
        profile = SimpleNamespace(root="/private", state="/private/state",
                                  work="/private/work", env={})
        with patch("builtins.open", unittest.mock.mock_open()), \
                patch.object(bench.subprocess, "Popen", return_value=proc), \
                patch.object(bench.Daemon, "_await_ready", side_effect=bench.BenchError("not ready")), \
                patch.object(bench, "terminate") as terminate:
            with self.assertRaisesRegex(bench.BenchError, "not ready"):
                bench.Daemon(profile, SimpleNamespace(loomd="/release/loomd"))
        terminate.assert_called_once_with(proc.pid)
        bench.LIVE.discard(proc.pid)

    def test_daemon_early_exit_keeps_original_error_after_poll_reaps_it(self):
        proc = Mock(pid=987654, returncode=1)
        profile = SimpleNamespace(root="/private", state="/private/state",
                                  work="/private/work", env={})
        with patch("builtins.open", unittest.mock.mock_open()), \
                patch.object(bench.subprocess, "Popen", return_value=proc), \
                patch.object(bench.Daemon, "_await_ready", side_effect=bench.BenchError("early exit")), \
                patch.object(bench, "terminate") as terminate:
            with self.assertRaisesRegex(bench.BenchError, "early exit"):
                bench.Daemon(profile, SimpleNamespace(loomd="/release/loomd"))
        terminate.assert_not_called()
        self.assertNotIn(proc.pid, bench.LIVE)

    def test_client_terminal_setup_failure_retires_child(self):
        with patch.object(bench.pty, "fork", return_value=(987654, 123)), \
                patch.object(bench.fcntl, "ioctl", side_effect=OSError("terminal setup")), \
                patch.object(bench.Client, "stop") as stop:
            with self.assertRaisesRegex(OSError, "terminal setup"):
                bench.Client(SimpleNamespace(env={}), SimpleNamespace(loom="/release/loom"), [])
        stop.assert_called_once()
        bench.LIVE.discard(987654)


class ScenarioTest(unittest.TestCase):
    def setUp(self):
        self.profile = Mock(state="/private/state", work="/private/work")
        self.daemon = Mock(started=100, ready_ms=40, port=1234)
        self.daemon.stop.return_value = 200
        self.daemon.rss_kib.side_effect = [100, 190]
        self.control = Mock()
        self.control.create_session_timed.return_value = {
            "session_id": "fresh-id", "create_reply_ms": 5, "resident_ms": 55}
        self.client = Mock(started=200)
        self.client.await_first_frame.return_value = 20
        self.client.await_text.return_value = 70
        self.client.stop.return_value = 300
        for name, instance in (("Profile", self.profile), ("Daemon", self.daemon),
                               ("Control", self.control), ("Client", self.client)):
            mocked = self.enterContext(patch.object(bench, name, return_value=instance))
            setattr(self, name + "Factory", mocked)
        self.enterContext(patch.object(bench.time, "sleep"))
        self.build = SimpleNamespace(name="current", loomd="/release/loomd")

    def assert_cleaned(self, client=True):
        if client:
            self.client.stop.assert_called_once()
        self.control.close.assert_called_once()
        self.daemon.stop.assert_called_once()
        self.profile.remove.assert_called_once()

    def test_g_total_uses_daemon_launch_and_attached_composer(self):
        rows = bench.once_g(self.build, "current-0", None)
        self.assertEqual(rows["daemon ready"], ([40], [200]))
        self.assertEqual(rows["create reply"], ([5], []))
        self.assertEqual(rows["resident"], ([55], []))
        self.assertEqual(rows["client first frame"], ([20], [300]))
        self.assertEqual(rows["attached composer"], ([70], []))
        self.assertEqual(rows["total"], ([170], []))
        self.client.await_text.assert_called_once_with(bench.ATTACHED)
        self.assertIn("fresh-id", self.ClientFactory.call_args.args[2])
        self.assert_cleaned()

    def test_g_failure_at_create_cleans_daemon_and_control(self):
        self.control.create_session_timed.side_effect = bench.BenchError("create failed")
        with self.assertRaisesRegex(bench.BenchError, "create failed"):
            bench.once_g(self.build, "current-0", None)
        self.ClientFactory.assert_not_called()
        self.assert_cleaned(client=False)

    def test_g_failure_at_composer_cleans_every_resource(self):
        self.client.await_text.side_effect = bench.BenchError("composer missing")
        with self.assertRaisesRegex(bench.BenchError, "composer missing"):
            bench.once_g(self.build, "current-0", None)
        self.assert_cleaned()

    def test_g_failure_at_first_frame_cleans_every_resource(self):
        self.client.await_first_frame.side_effect = bench.BenchError("first frame missing")
        with self.assertRaisesRegex(bench.BenchError, "first frame missing"):
            bench.once_g(self.build, "current-0", None)
        self.client.await_text.assert_not_called()
        self.assert_cleaned()

    def test_g_census_uses_same_attached_witness_and_profiles_both(self):
        with patch.object(bench, "census", side_effect=[{"total": 1}, {"total": 2}]), \
                patch.object(bench, "client_attach", return_value="attach"):
            self.assertEqual(bench.census_g(self.build, None),
                             {"client": {"total": 1}, "daemon": {"total": 2}})
        self.assertTrue(self.DaemonFactory.call_args.kwargs["profiled"])
        self.assertIn("--profile", self.ClientFactory.call_args.args[2])
        self.client.await_text.assert_called_once_with(bench.ATTACHED)
        self.assert_cleaned()

    def test_e_preserves_old_row_and_distinguishes_first_domain(self):
        self.control.create_session_timed.side_effect = [
            {"session_id": str(k), "create_reply_ms": k + 1, "resident_ms": k + 20}
            for k in range(10)]
        rows = bench.once_e(self.build, "current-0", None)
        self.assertEqual(rows["daemon"], (list(range(20, 30)), [200]))
        self.assertEqual(rows["first create reply"], ([1], []))
        self.assertEqual(rows["first resident"], ([20], []))
        self.assertEqual(rows["later create reply"], (list(range(2, 11)), []))
        self.assertEqual(rows["later resident"], (list(range(21, 30)), []))
        self.assertEqual(rows["per_session"], ([], [10]))
        self.assert_cleaned(client=False)

    def test_e_failure_cleans_resources_and_returns_no_partial_result(self):
        self.control.create_session_timed.side_effect = bench.BenchError("resident failed")
        with self.assertRaisesRegex(bench.BenchError, "resident failed"):
            bench.once_e(self.build, "current-0", None)
        self.assert_cleaned(client=False)


class ComparisonTest(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(tempfile.TemporaryDirectory(prefix="loom-bench-compare-"))
        self.path = Path(directory) / "baseline.json"
        self.configuration = {"path": "/current/catalogue.toml", "sha256": "a" * 64, "size_bytes": 10}
        self.enterContext(patch.object(bench.sys, "platform", "linux"))

    def saved(self, **changes):
        result = {"platform": "linux", "rss_unit": "KiB", "configuration": dict(self.configuration),
                  "enforcement_demand": "platform", "rows": {"g total": {"time_median_ms": 123}}}
        result.update(changes)
        self.path.write_text(json.dumps(result))
        return result

    def test_matching_saved_provenance_accepts_same_bytes_at_another_path(self):
        previous = dict(self.configuration, path="/old/catalogue.toml")
        saved = self.saved(configuration=previous)
        self.assertEqual(bench.comparison_rows(str(self.path), self.configuration, "platform"), saved["rows"])

    def test_legacy_missing_unknown_or_cross_platform_rss_is_refused(self):
        fixtures = [{"rows": {}}, {"platform": "linux", "rss_unit": "bytes"},
                    {"platform": "darwin", "rss_unit": "KiB"},
                    {"platform": "unknown", "rss_unit": "KiB"}]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                self.path.write_text(json.dumps(fixture))
                with self.assertRaisesRegex(bench.BenchError, "RSS provenance.*--against"):
                    bench.comparison_rows(str(self.path), self.configuration, "platform")

    def test_missing_or_different_configuration_is_refused(self):
        for configuration in (None, {}, dict(self.configuration, sha256="b" * 64),
                              dict(self.configuration, size_bytes=11)):
            with self.subTest(configuration=configuration):
                self.saved(configuration=configuration)
                with self.assertRaisesRegex(bench.BenchError, "configuration provenance"):
                    bench.comparison_rows(str(self.path), self.configuration, "platform")

    def test_missing_unknown_or_different_enforcement_is_refused(self):
        for demand in (None, "unknown", "best-effort"):
            with self.subTest(demand=demand):
                self.saved(enforcement_demand=demand)
                with self.assertRaisesRegex(bench.BenchError, "enforcement demand"):
                    bench.comparison_rows(str(self.path), self.configuration, "platform")

    def test_cli_refuses_legacy_comparison_before_release_checks_or_measurement(self):
        config = self.path.with_name("catalogue.toml")
        config.write_bytes(b"abc")
        self.path.write_text(json.dumps({"rows": {}}))
        build = SimpleNamespace(check=Mock())
        with patch.object(bench.sys, "argv", ["bench", "--only", "g", "--config", str(config),
                                               "--compare", str(self.path)]), \
                patch.object(bench, "CONFIG", bench.CONFIG), \
                patch.object(bench, "BEST_EFFORT", False), \
                patch.object(bench, "CURRENT", build), \
                patch.object(bench, "warm_up") as warm, \
                patch.object(bench, "measure") as measure, \
                patch.object(bench.subprocess, "run") as subprocess_run:
            with self.assertRaisesRegex(bench.BenchError, "RSS provenance"):
                bench.main()
        build.check.assert_not_called()
        warm.assert_not_called()
        measure.assert_not_called()
        subprocess_run.assert_not_called()

    def test_g_alternates_builds_and_retains_raw_endpoints(self):
        builds = [SimpleNamespace(name="against"), SimpleNamespace(name="current")]
        calls = []

        def once(build, tag, db):
            calls.append((build.name, tag))
            return {"create reply": ([5], []), "resident": ([55], []),
                    "attached composer": ([70], []), "total": ([170], [])}

        with patch.dict(bench.SCENARIOS, {"g": ("pipeline", once, lambda build, db: {})}):
            measured, memory = bench.measure("g", builds, 2, None)
        self.assertEqual(calls, [("against", "against-0"), ("current", "current-0"),
                                 ("current", "current-1"), ("against", "against-1")])
        self.assertEqual(measured["current"]["resident"]["time_ms"], [55, 55])
        self.assertEqual(measured["against"]["total"]["time_ms"], [170, 170])
        summary = bench.summarise({"g": (measured, memory)}, "current")
        self.assertEqual(summary["g total"]["time_median_ms"], 170)


if __name__ == "__main__":
    unittest.main()
