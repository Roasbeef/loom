#!/usr/bin/env python3
"""Invariant tests for offline identity preparation and targeted lifecycle calls."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).parent / "distributed" / "launch.py"
SPEC = importlib.util.spec_from_file_location("distributed_launch", SOURCE)
launch = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = launch
SPEC.loader.exec_module(launch)


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.template = self.root / "executor.toml"
        self.template.write_text('''schema = 1
endpoint_lifetime = "retired_slots_v1"
local_node = "@LOOM:LOCAL_NODE@"
# Physical provisioning fields await the actual strict runtime decoder.
[membership]
ca = "@LOOM:CA@"
certificate = "@LOOM:CERTIFICATE@"
key = "@LOOM:KEY@"
cookie = "@LOOM:COOKIE@"
options = "@LOOM:OPTIONS@"
[[peers]]
node = "brain@brain.example.invalid"
leaf_sha256 = "@LOOM:PIN:brain@"
''')
        self.inventory = {"schema": 1, "project": "demo", "instances": [
            {"name": "brain", "role": "owner", "node": "brain@brain.example.invalid", "peers": ["hands"], "transport": "native", "workspaces": [{"executor": "hands", "workspace": "project", "peer": "hands", "workspace_epoch": 1, "session_epoch": 1, "first_generation": 1, "descriptor_sha256": "2" * 64}]},
            {"name": "hands", "role": "executor", "node": "hands@hands.example.invalid", "peers": ["brain"], "transport": "docker", "image": "loom-roles:test", "executor_template": "executor.toml"}]}
        self.path = self.root / "plan.json"
        self.bundle = self.root / "bundle"
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        self.path.write_text(json.dumps(self.inventory))

    def fake_certificates(self, root, plan):
        (root / "authority").mkdir(mode=0o700)
        for leaf in ["ca.pem", "ca.key"]:
            launch.write_private(root / "authority" / leaf, "fixture " + leaf)
        pins = {}
        for instance in plan.instances:
            member = root / instance.name / "member"
            member.mkdir(parents=True, mode=0o700)
            (member.parent / "state").mkdir(mode=0o700)
            for leaf in ["ca.pem", "cert.pem", "key.pem", ".erlang.cookie"]:
                launch.write_private(member / leaf, "fixture " + instance.name + leaf)
            pins[instance.name] = hashlib.sha256(instance.node.encode()).hexdigest()
        return pins

    def prepare(self):
        with patch.object(launch, "certificates", side_effect=self.fake_certificates):
            launch.prepare(self.path, self.bundle)
        return launch.inspect_bundle(self.bundle)

    def test_exact_owner_contract_and_private_unique_identities(self):
        bundle = self.prepare()
        owner = tomllib.loads((self.bundle / "brain/member/deployment.toml").read_text())
        self.assertEqual(set(owner), {"schema", "endpoint_lifetime", "owner", "local_node", "membership", "peers", "workspaces"})
        self.assertEqual(owner["workspaces"][0]["peer"], "hands@hands.example.invalid")
        self.assertEqual(owner["workspaces"][0]["generation_policy"], "clean_successor")
        self.assertEqual(owner["peers"][0]["leaf_sha256"], bundle["instances"][1]["leaf_sha256"])
        self.assertNotEqual((self.bundle / "brain/state").stat().st_ino, (self.bundle / "hands/state").stat().st_ino)
        self.assertTrue(all((self.bundle / p).stat().st_mode & 0o077 == 0 for p in bundle["files"]))
        self.assertTrue(all(i["runtime_validation"] == "pending" for i in bundle["instances"]))

    def test_executor_template_preserves_physical_declarations(self):
        self.template.write_text(self.template.read_text() + '\n[unfrozen_physical_fixture]\nvalue = "retained exactly"\n')
        self.prepare()
        rendered = (self.bundle / "hands/member/deployment.toml").read_text()
        self.assertIn('value = "retained exactly"', rendered)
        self.assertNotIn("@LOOM:", rendered)
        self.assertEqual(tomllib.loads(rendered)["membership"]["options"], launch.MEMBER + "/tls.options")
        self.assertFalse((self.bundle / "hands/member/tls.options").exists())

    def test_duplicate_names_and_nodes_refuse_before_output(self):
        for field in ["name", "node"]:
            with self.subTest(field=field):
                changed = copy.deepcopy(self.inventory)
                changed["instances"][1][field] = changed["instances"][0][field]
                self.path.write_text(json.dumps(changed))
                with self.assertRaises(launch.Refused):
                    launch.prepare(self.path, self.bundle)
                self.assertFalse(self.bundle.exists())

    def test_strict_unknown_duplicate_boolean_and_bounds(self):
        mutations = [lambda p: p.update(extra=1), lambda p: p["instances"][0]["workspaces"][0].update(workspace_epoch=True), lambda p: p["instances"][0]["workspaces"][0].update(first_generation=2147483648), lambda p: p["instances"][0].update(peers=["hands", "hands"]), lambda p: p["instances"][1].update(peers=["missing"])]
        for mutation in mutations:
            changed = copy.deepcopy(self.inventory)
            mutation(changed)
            self.path.write_text(json.dumps(changed))
            with self.assertRaises(launch.Refused):
                launch.load_plan(self.path)
        self.path.write_text('{"schema":1,"schema":1,"project":"x","instances":[]}')
        with self.assertRaises(launch.Refused):
            launch.load_plan(self.path)
        self.path.write_bytes(b" " * (launch.LIMIT + 1))
        with self.assertRaises(launch.Refused):
            launch.load_plan(self.path)

    def test_remote_mount_source_is_deferred_but_private_targets_refuse(self):
        self.inventory["instances"][1]["mounts"] = [{"source": "/srv/remote-only/project", "target": "/work/project"}]
        self.save()
        plan = launch.load_plan(self.path)
        self.assertEqual(plan.instances[1].mounts, (("/srv/remote-only/project", "/work/project"),))
        for target in ["/etc/loom-distributed", launch.MEMBER, "/var/lib/loom", "/opt/loom", "/opt/loom/bin"]:
            self.inventory["instances"][1]["mounts"][0]["target"] = target
            self.save()
            with self.assertRaises(launch.Refused):
                launch.load_plan(self.path)

    def test_container_targets_require_canonical_posix_spelling_at_input(self):
        self.assertEqual(launch.workspace_target("/work/project-a"), "/work/project-a")
        for target in ["/work/./project", "/work//project", "/work/project/", "/work/project/../other", "//work/project", "/etc/loom-distributed/"]:
            with self.subTest(target=target):
                self.inventory["instances"][1]["mounts"] = [{"source": "/srv/remote-only/project", "target": target}]
                self.save()
                with self.assertRaisesRegex(launch.Refused, "canonical POSIX"):
                    launch.load_plan(self.path)
        self.inventory["instances"][1]["mounts"] = [{"source": "/srv/remote-only/project", "target": "/work/project"}, {"source": "/srv/remote-only/other", "target": "/work/project//nested"}]
        self.save()
        with self.assertRaisesRegex(launch.Refused, "canonical POSIX"):
            launch.load_plan(self.path)

    def test_noncanonical_target_refuses_readback_and_export_even_rehashed(self):
        self.inventory["instances"][1]["mounts"] = [{"source": "/srv/remote-only/project", "target": "/work/project"}]
        self.save()
        self.prepare()
        original_bundle = json.loads((self.bundle / "bundle.json").read_bytes())
        original_compose = json.loads((self.bundle / "compose.json").read_bytes())
        for target in ["/work/./project", "/work//project", "/work/project/", "/work/project/../other", "//work/project", "/etc/loom-distributed/"]:
            with self.subTest(target=target):
                bundle = copy.deepcopy(original_bundle)
                compose = copy.deepcopy(original_compose)
                bundle["instances"][1]["mounts"][0]["target"] = target
                compose["services"]["hands"]["volumes"][2]["target"] = target
                encoded = json.dumps(compose).encode()
                (self.bundle / "compose.json").write_bytes(encoded)
                bundle["files"]["compose.json"] = hashlib.sha256(encoded).hexdigest()
                (self.bundle / "bundle.json").write_text(json.dumps(bundle))
                with self.assertRaisesRegex(launch.Refused, "canonical POSIX"):
                    launch.inspect_bundle(self.bundle)
                output = self.root / "refused-host"
                with self.assertRaisesRegex(launch.Refused, "canonical POSIX"):
                    launch.export_bundle(self.bundle, output, ["hands"])
                self.assertFalse(output.exists())
                self.assertFalse((self.bundle / "exported-hands.json").exists())

    def test_actual_shipped_executor_fragment_renders_common_membership(self):
        folder = SOURCE.parent
        example = json.loads((folder / "plan.example.json").read_bytes())
        example["instances"][1]["executor_template"] = str(folder / "executor-membership.template.toml")
        self.path.write_text(json.dumps(example))
        plan = launch.load_plan(self.path)
        pins = {instance.name: hashlib.sha256(instance.node.encode()).hexdigest() for instance in plan.instances}
        executor = plan.instances[1]
        rendered = launch.deployment(executor, plan, self.root.resolve(), pins)
        common = tomllib.loads(rendered)
        self.assertNotIn("@LOOM:", rendered)
        self.assertEqual(common["local_node"], executor.node)
        self.assertEqual(common["membership"], launch.membership(executor, self.root.resolve()))
        self.assertEqual(common["peers"], [{"node": plan.instances[0].node, "leaf_sha256": pins["brain-a"]}])
        self.assertNotIn("executor", common)
        self.assertNotIn("workspaces", common)

    def test_bundle_and_state_directories_must_remain_private(self):
        self.prepare()
        state = self.bundle / "hands/state"
        state.chmod(0o755)
        with self.assertRaises(launch.Refused):
            launch.inspect_bundle(self.bundle)
        state.chmod(0o700)
        self.bundle.chmod(0o755)
        with self.assertRaises(launch.Refused):
            launch.inspect_bundle(self.bundle)

    def test_template_wrong_pin_or_node_and_unknown_token_refuse(self):
        original = self.template.read_text()
        for bad in [original.replace("@LOOM:LOCAL_NODE@", "another@host"), original.replace("@LOOM:PIN:brain@", "0" * 64), original + '\nunknown = "@LOOM:UNDEFINED@"\n']:
            self.template.write_text(bad)
            with patch.object(launch, "certificates", side_effect=self.fake_certificates):
                with self.assertRaises(launch.Refused):
                    launch.prepare(self.path, self.root / ("bad-" + str(len(list(self.root.iterdir())))))

    def test_existing_bundle_cannot_regenerate_identity(self):
        self.prepare()
        before = (self.bundle / "bundle.json").read_bytes()
        with self.assertRaises(FileExistsError):
            launch.prepare(self.path, self.bundle)
        self.assertEqual(before, (self.bundle / "bundle.json").read_bytes())

    def test_manifest_corruption_permissions_and_shared_state_refuse(self):
        self.prepare()
        leaf = self.bundle / "hands/member/key.pem"
        leaf.chmod(0o644)
        with self.assertRaises(launch.Refused):
            launch.inspect_bundle(self.bundle)
        leaf.chmod(0o600)
        leaf.write_text("changed")
        with self.assertRaises(launch.Refused):
            launch.inspect_bundle(self.bundle)
        leaf.write_text("fixture handskey.pem")
        state = self.bundle / "hands/state"
        state.rmdir()
        state.symlink_to(self.bundle / "brain/state", target_is_directory=True)
        with self.assertRaises(launch.Refused):
            launch.inspect_bundle(self.bundle)

    def test_compose_has_distinct_named_state_no_scale_or_relaxations(self):
        self.prepare()
        document = json.loads((self.bundle / "compose.json").read_bytes())
        service = document["services"]["hands"]
        self.assertEqual(set(document["services"]), {"hands"})
        self.assertEqual(service["network_mode"], "host")
        self.assertEqual(service["volumes"][1]["source"], str(self.bundle.resolve() / "hands/state"))
        self.assertNotIn("privileged", service)
        self.assertNotIn("security_opt", service)
        self.assertNotIn("deploy", service)
        self.assertNotIn("healthcheck", service)

    def test_changed_compose_identity_refuses_even_rehashed_manifest(self):
        self.prepare()
        compose = self.bundle / "compose.json"
        changed = json.loads(compose.read_bytes())
        changed["services"]["hands"]["volumes"][1]["source"] = str(self.bundle / "brain/state")
        compose.write_text(json.dumps(changed))
        manifest = self.bundle / "bundle.json"
        data = json.loads(manifest.read_bytes())
        data["files"]["compose.json"] = hashlib.sha256(compose.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(data))
        with self.assertRaises(launch.Refused):
            launch.inspect_bundle(self.bundle)

    def host_bundle(self):
        self.prepare()
        target = self.root / "linux-host"
        launch.export_bundle(self.bundle, target, ["hands"])
        self.bundle = target

    def test_lifecycle_targets_only_selected_names(self):
        self.host_bundle()
        with patch.object(launch.sys, "platform", "linux"), patch.object(launch, "run") as run:
            launch.lifecycle(self.bundle, "stop", ["hands"])
            self.assertEqual(run.call_args.args[0][-2:], ["stop", "hands"])
            self.assertNotIn("down", run.call_args.args[0])
            launch.lifecycle(self.bundle, "logs", ["hands"])
            self.assertEqual(run.call_args.args[0][-4:], ["logs", "--tail", "200", "hands"])
            for names in [["brain"], ["hands", "hands"], ["missing"], []]:
                with self.assertRaises(launch.Refused):
                    launch.lifecycle(self.bundle, "stop", names)

    def test_start_missing_contract_or_failed_help_never_calls_compose(self):
        self.host_bundle()
        with patch.object(launch.sys, "platform", "linux"), patch.object(launch, "docker_directories_owned"):
            with patch.object(launch, "run", return_value=subprocess.CompletedProcess([], 0, b"{}")) as run:
                with self.assertRaises(launch.Refused):
                    launch.lifecycle(self.bundle, "start", ["hands"])
                self.assertEqual(run.call_count, 1)
            labels = b'{"org.loom.distributed.protocol":"077","org.loom.distributed.roles":"owner,executor"}'
            with patch.object(launch, "run", side_effect=[subprocess.CompletedProcess([], 0, labels), subprocess.CalledProcessError(69, ["docker"])]) as run:
                with self.assertRaises(subprocess.CalledProcessError):
                    launch.lifecycle(self.bundle, "start", ["hands"])
                self.assertEqual(run.call_count, 2)

    def test_start_preflights_then_propagates_actual_start_failure(self):
        self.host_bundle()
        labels = b'{"org.loom.distributed.protocol":"077","org.loom.distributed.roles":"executor"}'
        with patch.object(launch.sys, "platform", "linux"), patch.object(launch, "docker_directories_owned"), patch.object(launch, "run", side_effect=[subprocess.CompletedProcess([], 0, labels), subprocess.CompletedProcess([], 0), subprocess.CalledProcessError(7, ["docker"])]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                launch.lifecycle(self.bundle, "start", ["hands"])
            self.assertEqual(run.call_args.args[0][-6:], ["up", "--detach", "--no-deps", "--pull", "never", "hands"])
            self.assertIn("--rm", run.call_args_list[1].args[0])
            self.assertIn("--network", run.call_args_list[1].args[0])

    def test_mac_compose_refuses_without_docker_calls(self):
        self.host_bundle()
        with patch.object(launch.sys, "platform", "darwin"), patch.object(launch, "run") as run:
            with self.assertRaises(launch.Refused):
                launch.lifecycle(self.bundle, "start", ["hands"])
            run.assert_not_called()

    def test_many_hands_use_explicit_unique_services_and_state(self):
        second = copy.deepcopy(self.inventory["instances"][1])
        second.update(name="hands-two", node="hands2@hands.example.invalid")
        self.inventory["instances"].append(second)
        self.inventory["instances"][0]["peers"].append("hands-two")
        workspace = copy.deepcopy(self.inventory["instances"][0]["workspaces"][0])
        workspace.update(executor="hands-two", peer="hands-two", workspace="project-two")
        self.inventory["instances"][0]["workspaces"].append(workspace)
        self.save()
        self.prepare()
        services = json.loads((self.bundle / "compose.json").read_bytes())["services"]
        self.assertEqual(set(services), {"hands", "hands-two"})
        self.assertNotEqual(services["hands"]["volumes"][1]["source"], services["hands-two"]["volumes"][1]["source"])

    def test_export_retains_identity_only_selected_credentials_and_paths(self):
        original = self.prepare()
        target = self.root / "mac-host"
        launch.export_bundle(self.bundle, target, ["brain"])
        exported = launch.inspect_bundle(target)
        self.assertEqual(exported["instances"], [original["instances"][0]])
        self.assertFalse((target / "authority/ca.key").exists())
        self.assertFalse((target / "hands").exists())
        self.assertEqual((target / "brain/member/key.pem").read_bytes(), (self.bundle / "brain/member/key.pem").read_bytes())
        owner = tomllib.loads((target / "brain/member/deployment.toml").read_text())
        self.assertEqual(owner["membership"]["key"], str(target.resolve() / "brain/member/key.pem"))
        with self.assertRaises(launch.Refused):
            launch.export_bundle(self.bundle, self.root / "duplicate-host", ["brain"])
        with self.assertRaises(launch.Refused):
            launch.export_bundle(target, self.root / "re-exported", ["brain"])

    def test_export_nonempty_state_refuses(self):
        self.prepare()
        (self.bundle / "hands/state/retained.sqlite").write_text("retained")
        with self.assertRaises(launch.Refused):
            launch.export_bundle(self.bundle, self.root / "host", ["hands"])

    def test_real_local_openssl_unique_leaf_pins_cookie_and_modes(self):
        launch.prepare(self.path, self.bundle)
        bundle = launch.inspect_bundle(self.bundle)
        self.assertNotEqual(bundle["instances"][0]["leaf_sha256"], bundle["instances"][1]["leaf_sha256"])
        cookies = [(self.bundle / name / "member/.erlang.cookie").read_bytes() for name in ["brain", "hands"]]
        self.assertEqual(cookies[0], cookies[1])
        self.assertEqual(len(cookies[0]), 64)
        self.assertNotIn(b"\n", cookies[0])
        for name in ["brain", "hands"]:
            leaf = self.bundle / name / "member/cert.pem"
            der = subprocess.run(["openssl", "x509", "-in", str(leaf), "-outform", "DER"], check=True, capture_output=True).stdout
            recorded = (self.bundle / name / "member/leaf.sha256").read_text().strip()
            self.assertEqual(hashlib.sha256(der).hexdigest(), recorded)
            subprocess.run(["openssl", "verify", "-CAfile", str(self.bundle / name / "member/ca.pem"), str(leaf)], check=True, capture_output=True)


class EntrypointTests(unittest.TestCase):
    def test_missing_role_deployment_support_and_exact_argument_forwarding(self):
        wrapper = SOURCE.parents[2] / "docker/distributed/role-entrypoint.sh"
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "loom-executor"
            binary.write_text('#!/bin/sh\n[ "${1:-}" = --help ] && { echo local-only; exit 0; }\nexit 9\n')
            binary.chmod(0o755)
            environment = {**os.environ, "PATH": directory + ":" + os.environ["PATH"]}
            refused = subprocess.run(["sh", str(wrapper), "executor", "--check-role"], env=environment, capture_output=True)
            self.assertEqual(refused.returncode, 69)
            binary.write_text('#!/bin/sh\n[ "${1:-}" = --help ] && { echo --deployment; exit 0; }\nprintf "%s\\n" "$@"\nexit 9\n')
            supported = subprocess.run(["sh", str(wrapper), "executor", "--check-role"], env=environment, capture_output=True)
            self.assertEqual(supported.returncode, 0)
            started = subprocess.run(["sh", str(wrapper), "executor", "--deployment", "/private/path with spaces.toml"], env=environment, capture_output=True)
            self.assertEqual(started.returncode, 9)
            self.assertEqual(started.stdout.decode().splitlines(), ["--deployment", "/private/path with spaces.toml"])
            self.assertEqual(subprocess.run(["sh", str(wrapper), "unknown"], capture_output=True).returncode, 64)
            self.assertEqual(subprocess.run(["sh", str(wrapper), "executor"], env=environment, capture_output=True).returncode, 64)


if __name__ == "__main__":
    unittest.main()
