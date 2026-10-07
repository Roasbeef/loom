#!/usr/bin/env python3
"""Prepare private, explicitly named protocol-077 launch bundles.

The operator plan is a local packaging inventory, not a runtime authority format.
Owner deployments use the approved TOML contract. Executor templates retain the
runtime's physical declarations verbatim; its strict decoder must validate them.
Nothing here grants activation, effect admission, retirement, or sandbox proof.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import shutil
import subprocess
import sys
import tomllib
from typing import Any

LIMIT = 8 * 1024 * 1024
MEMBER = "/etc/loom-distributed/member"
ROLE_ENTRYPOINT = "/opt/loom/bin/loom-distributed-role"


class Refused(ValueError):
    """A bounded configuration or lifecycle operation was refused."""


def bounded_read(path: Path) -> bytes:
    with path.open("rb") as stream:
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise Refused(f"file exceeds 8 MiB: {path}")
    return data


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refused(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def keys(value: Any, required: set[str], optional: set[str] = frozenset()) -> dict:
    if not isinstance(value, dict) or set(value) - required - optional or required - set(value):
        raise Refused(f"expected fields {sorted(required)}, optional {sorted(optional)}")
    return value


def text(value: Any, pattern: str, maximum: int = 128) -> str:
    if not isinstance(value, str) or len(value.encode()) > maximum or not re.fullmatch(pattern, value):
        raise Refused("invalid bounded administrative value")
    return value


def label(value: Any) -> str:
    return text(value, r"[A-Za-z0-9._-]+")


def epoch(value: Any) -> int:
    if type(value) is not int or not 1 <= value <= 2147483647:
        raise Refused("epoch/generation must be a positive signed-32-bit integer")
    return value


def workspace_target(value: Any) -> str:
    target = absolute(value)
    # Container targets use POSIX spelling on every coordinator platform. Refuse
    # aliases before ancestry comparisons so readback and export retain one form.
    components = PurePosixPath(target)
    if target.startswith("//") or ".." in components.parts or components.as_posix() != target:
        raise Refused("workspace target must have canonical POSIX absolute spelling")
    protected = [MEMBER, "/var/lib/loom", "/opt/loom"]
    if target in {"/", "/work", "/etc", "/var", "/var/lib"} or any(target == root or target.startswith(root + "/") or root.startswith(target + "/") for root in protected):
        raise Refused("workspace mount overlaps membership, state or packaged runtime")
    return target


def array(value: Any, low: int, high: int) -> list:
    if not isinstance(value, list) or not low <= len(value) <= high:
        raise Refused(f"expected {low}..{high} entries")
    return value


def absolute(value: Any) -> str:
    if not isinstance(value, str) or not value.startswith("/") or len(value.encode()) > 4096 or any(ord(c) < 32 for c in value):
        raise Refused("expected bounded absolute path")
    return value


@dataclass(frozen=True)
class Workspace:
    executor: str
    workspace: str
    peer: str
    workspace_epoch: int
    session_epoch: int
    first_generation: int
    descriptor_sha256: str


@dataclass(frozen=True)
class Instance:
    name: str
    role: str
    node: str
    peers: tuple[str, ...]
    transport: str
    image: str | None
    template: Path | None
    workspaces: tuple[Workspace, ...]
    mounts: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class Plan:
    project: str
    instances: tuple[Instance, ...]


def load_plan(path: Path) -> Plan:
    raw = keys(json.loads(bounded_read(path), object_pairs_hook=unique_object), {"schema", "project", "instances"})
    if type(raw["schema"]) is not int or raw["schema"] != 1:
        raise Refused("operator plan schema must be 1")
    project = text(raw["project"], r"[a-z0-9][a-z0-9_-]*", 48)
    instances = []
    for row in array(raw["instances"], 2, 33):
        row = keys(row, {"name", "role", "node", "peers", "transport"}, {"image", "executor_template", "workspaces", "mounts"})
        name = text(row["name"], r"[a-z0-9][a-z0-9_-]*", 48)
        role = text(row["role"], r"owner|executor")
        node = text(row["node"], r"[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+", 255)
        peers = tuple(label(p) for p in array(row["peers"], 1, 32))
        if len(set(peers)) != len(peers) or name in peers:
            raise Refused("peers must be distinct other instance names")
        transport = text(row["transport"], r"native|docker")
        image = row.get("image")
        if transport == "docker":
            image = text(image, r"[A-Za-z0-9][A-Za-z0-9./_:@-]*", 512)
        elif image is not None:
            raise Refused("native instance cannot select an image")
        template = row.get("executor_template")
        if role == "executor":
            if not isinstance(template, str):
                raise Refused("executor requires an explicit deployment template")
            template = (path.parent / template).resolve(strict=True)
            if "workspaces" in row:
                raise Refused("executor physical workspaces belong in its deployment template")
        elif template is not None:
            raise Refused("owner cannot select executor_template")
        workspaces = []
        for item in array(row.get("workspaces", []), 0 if role == "executor" else 1, 32):
            item = keys(item, {"executor", "workspace", "peer", "workspace_epoch", "session_epoch", "first_generation", "descriptor_sha256"})
            workspaces.append(Workspace(label(item["executor"]), label(item["workspace"]), label(item["peer"]), epoch(item["workspace_epoch"]), epoch(item["session_epoch"]), epoch(item["first_generation"]), text(item["descriptor_sha256"], r"[0-9a-f]{64}", 64)))
        if len({(w.executor, w.workspace) for w in workspaces}) != len(workspaces):
            raise Refused("duplicate workspace selector")
        mounts = []
        for item in array(row.get("mounts", []), 0, 16):
            item = keys(item, {"source", "target"})
            source = absolute(item["source"])
            if ".." in Path(source).parts:
                raise Refused("workspace source must have a normalized absolute spelling")
            target = workspace_target(item["target"])
            mounts.append((source, target))
        if transport == "native" and mounts:
            raise Refused("native physical paths belong in executor deployment, not Docker mounts")
        if len({t for _, t in mounts}) != len(mounts) or any(a != b and (a.startswith(b + "/") or b.startswith(a + "/")) for _, a in mounts for _, b in mounts):
            raise Refused("overlapping workspace mount targets")
        instances.append(Instance(name, role, node, peers, transport, image, template, tuple(workspaces), tuple(mounts)))
    names = {i.name: i for i in instances}
    if len(names) != len(instances) or len({i.node for i in instances}) != len(instances):
        raise Refused("every instance requires a unique name and full node identity")
    if not any(i.role == "owner" for i in instances) or not any(i.role == "executor" for i in instances):
        raise Refused("plan must contain owners and executors")
    for instance in instances:
        for peer in instance.peers:
            if peer not in names or instance.name not in names[peer].peers:
                raise Refused("membership must name installed, reciprocal peers")
        for workspace in instance.workspaces:
            if workspace.peer not in instance.peers or names[workspace.peer].role != "executor" or workspace.executor != names[workspace.peer].name:
                raise Refused("workspace must select its named enrolled executor peer")
    return Plan(project, tuple(instances))


def write_private(path: Path, data: str | bytes) -> None:
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data.encode() if isinstance(data, str) else data)


def run(argv: list[str], *, capture: bool = False) -> subprocess.CompletedProcess:
    # Arguments never pass through a shell; credential contents never enter argv.
    return subprocess.run(argv, check=True, capture_output=capture)


def certificates(root: Path, plan: Plan) -> dict[str, str]:
    if not shutil.which("openssl"):
        raise Refused("prepare needs openssl on PATH")
    authority = root / "authority"
    authority.mkdir(mode=0o700)
    ca = authority / "ca.pem"
    key = authority / "ca.key"
    run(["openssl", "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "365", "-sha256", "-subj", "/CN=Loom-private-membership", "-keyout", str(key), "-out", str(ca)], capture=True)
    os.chmod(key, 0o600)
    os.chmod(ca, 0o600)
    cookie = secrets.token_hex(32)
    pins = {}
    for instance in plan.instances:
        member = root / instance.name / "member"
        member.mkdir(parents=True, mode=0o700)
        member.parent.chmod(0o700)
        (member.parent / "state").mkdir(mode=0o700)
        csr = member / "request.csr"
        leaf = member / "cert.pem"
        leaf_key = member / "key.pem"
        extensions = member / "extensions.cnf"
        write_private(extensions, "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:" + instance.node.split("@")[1] + "\n")
        run(["openssl", "req", "-new", "-newkey", "rsa:3072", "-nodes", "-sha256", "-subj", "/CN=" + instance.node, "-keyout", str(leaf_key), "-out", str(csr)], capture=True)
        leaf_key.chmod(0o600)
        run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(ca), "-CAkey", str(key), "-set_serial", str(secrets.randbits(128) or 1), "-days", "365", "-sha256", "-extfile", str(extensions), "-out", str(leaf)], capture=True)
        leaf.chmod(0o600)
        der = run(["openssl", "x509", "-in", str(leaf), "-outform", "DER"], capture=True).stdout
        pins[instance.name] = hashlib.sha256(der).hexdigest()
        write_private(member / "ca.pem", ca.read_bytes())
        write_private(member / ".erlang.cookie", cookie)
        csr.unlink()
        extensions.unlink()
    if len(set(pins.values())) != len(pins):
        raise Refused("duplicate certificate identity")
    return pins


def membership(instance: Instance, root: Path) -> dict[str, str]:
    base = MEMBER if instance.transport == "docker" else str(root / instance.name / "member")
    return {"ca": base + "/ca.pem", "certificate": base + "/cert.pem", "key": base + "/key.pem", "cookie": base + "/.erlang.cookie", "options": base + "/tls.options"}


def quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def deployment(instance: Instance, plan: Plan, root: Path, pins: dict[str, str]) -> str:
    members = membership(instance, root)
    by_name = {i.name: i for i in plan.instances}
    peers = [{"node": by_name[p].node, "leaf_sha256": pins[p]} for p in instance.peers]
    if instance.role == "owner":
        lines = ['schema = 1', 'endpoint_lifetime = "retired_slots_v1"', 'owner = ' + quote(instance.name), 'local_node = ' + quote(instance.node), '', '[membership]']
        lines.extend(key + " = " + quote(value) for key, value in members.items())
        for peer in peers:
            lines.extend(['', '[[peers]]', 'node = ' + quote(peer["node"]), 'leaf_sha256 = ' + quote(peer["leaf_sha256"])])
        for workspace in instance.workspaces:
            lines.extend(['', '[[workspaces]]', 'executor = ' + quote(workspace.executor), 'workspace = ' + quote(workspace.workspace), 'peer = ' + quote(by_name[workspace.peer].node)])
            lines.extend(key + " = " + str(getattr(workspace, key)) for key in ["workspace_epoch", "session_epoch", "first_generation"])
            lines.extend(['generation_policy = "clean_successor"', 'descriptor_sha256 = ' + quote(workspace.descriptor_sha256)])
        return "\n".join(lines) + "\n"
    source = bounded_read(instance.template).decode("utf-8")
    # Substitute only closed string tokens. Unknown physical declarations remain
    # the executor decoder's responsibility; no weak replacement decoder exists.
    substitutions = {"LOCAL_NODE": instance.node, "STATE_ROOT": "/var/lib/loom" if instance.transport == "docker" else str(root / instance.name / "state"), **{k.upper(): v for k, v in members.items()}, **{"PIN:" + k: v for k, v in pins.items()}}
    for token, value in substitutions.items():
        source = source.replace(quote("@LOOM:" + token + "@"), quote(value))
    if "@LOOM:" in source:
        raise Refused("executor template contains an unknown/unresolved token")
    parsed = tomllib.loads(source)
    if type(parsed.get("schema")) is not int or parsed["schema"] != 1 or parsed.get("endpoint_lifetime") != "retired_slots_v1" or parsed.get("local_node") != instance.node or parsed.get("membership") != members or parsed.get("peers") != peers:
        raise Refused("executor template common membership differs from inventory")
    return source


def compose(plan: Plan, root: Path) -> dict:
    services = {}
    for i in plan.instances:
        if i.transport != "docker":
            continue
        member = root / i.name / "member"
        command = [i.role, "--deployment", MEMBER + "/deployment.toml"]
        if i.role == "owner":
            command.extend(["--state-dir", "/var/lib/loom"])
        services[i.name] = {"image": i.image, "platform": "linux/amd64", "entrypoint": ["tini", "--", ROLE_ENTRYPOINT], "command": command, "network_mode": "host", "restart": "no", "working_dir": "/work", "volumes": [{"type": "bind", "source": str(member), "target": MEMBER}, {"type": "bind", "source": str(root / i.name / "state"), "target": "/var/lib/loom"}] + [{"type": "bind", "source": source, "target": target} for source, target in i.mounts]}
    return {"name": plan.project, "services": services}


def prepare(path: Path, root: Path) -> None:
    plan = load_plan(path)
    root = root.resolve()
    # Requiring an absent output prevents silently replacing retained identities.
    for instance in plan.instances:
        for source, _ in instance.mounts:
            if root.is_relative_to(Path(source)) or Path(source).is_relative_to(root):
                raise Refused("workspace bind overlaps the private launch bundle")
    root.mkdir(mode=0o700)
    root = root.resolve(strict=True)
    pins = certificates(root, plan)
    for instance in plan.instances:
        write_private(root / instance.name / "member" / "deployment.toml", deployment(instance, plan, root, pins))
        write_private(root / instance.name / "member" / "leaf.sha256", pins[instance.name] + "\n")
    write_private(root / "compose.json", json.dumps(compose(plan, root), indent=2) + "\n")
    inventory = {"schema": 1, "placement": "coordinator", "project": plan.project, "root": str(root), "instances": [{"name": i.name, "role": i.role, "node": i.node, "transport": i.transport, "image": i.image, "leaf_sha256": pins[i.name], "runtime_validation": "pending", "mounts": [{"source": source, "target": target} for source, target in i.mounts]} for i in plan.instances]}
    files = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file()}
    inventory["files"] = files
    write_private(root / "bundle.json", json.dumps(inventory, indent=2) + "\n")


def inspect_bundle(root: Path) -> dict:
    root = root.resolve(strict=True)
    if root.stat().st_mode & 0o077 or (root / "bundle.json").is_symlink() or (root / "bundle.json").stat().st_mode & 0o077:
        raise Refused("bundle root and inventory must remain private")
    bundle = keys(json.loads(bounded_read(root / "bundle.json"), object_pairs_hook=unique_object), {"schema", "placement", "project", "root", "instances", "files"})
    if type(bundle["schema"]) is not int or bundle["schema"] != 1 or bundle["root"] != str(root):
        raise Refused("bundle identity/location changed; prepare a new bundle")
    text(bundle["placement"], r"coordinator|host")
    text(bundle["project"], r"[a-z0-9][a-z0-9_-]*", 48)
    names, nodes, pins = set(), set(), set()
    for item in array(bundle["instances"], 1, 33):
        keys(item, {"name", "role", "node", "transport", "image", "leaf_sha256", "runtime_validation", "mounts"})
        name = text(item["name"], r"[a-z0-9][a-z0-9_-]*", 48)
        node = text(item["node"], r"[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+", 255)
        pin = text(item["leaf_sha256"], r"[0-9a-f]{64}", 64)
        text(item["role"], r"owner|executor")
        transport = text(item["transport"], r"native|docker")
        if item["runtime_validation"] != "pending" or name in names or node in nodes or pin in pins:
            raise Refused("duplicate/invalid retained identity")
        if transport == "docker":
            text(item["image"], r"[A-Za-z0-9][A-Za-z0-9./_:@-]*", 512)
        elif item["image"] is not None:
            raise Refused("native bundle image")
        names.add(name)
        nodes.add(node)
        pins.add(pin)
    if not isinstance(bundle["files"], dict) or len(bundle["files"]) > 512:
        raise Refused("invalid file inventory")
    required = {"compose.json", "authority/ca.pem"}
    required.update(name + "/member/" + leaf for name in names for leaf in ["deployment.toml", "leaf.sha256", "ca.pem", "cert.pem", "key.pem", ".erlang.cookie"])
    if not required <= set(bundle["files"]):
        raise Refused("incomplete bundle file inventory")
    for name in names:
        member = root / name / "member"
        if member.is_symlink() or member.stat().st_mode & 0o077:
            raise Refused("membership directories must remain distinct and private")
    for relative, digest in bundle["files"].items():
        target = root / relative
        if Path(relative).is_absolute() or ".." in Path(relative).parts or target.is_symlink() or target.resolve(strict=True).is_relative_to(root) is False:
            raise Refused("bundle file escapes retained root")
        if target.stat().st_mode & 0o077 or hashlib.sha256(bounded_read(target)).hexdigest() != text(digest, r"[0-9a-f]{64}", 64):
            raise Refused("private bundle file changed or permissions widened: " + relative)
    states = [root / name / "state" for name in names]
    if any(p.is_symlink() or not p.is_dir() or p.stat().st_mode & 0o077 for p in states) or len({(p.stat().st_dev, p.stat().st_ino) for p in states}) != len(states):
        raise Refused("state directories must retain distinct physical identities")
    document = json.loads(bounded_read(root / "compose.json"), object_pairs_hook=unique_object)
    expected_services = {}
    for item in bundle["instances"]:
        if item["transport"] == "native":
            if item["mounts"]:
                raise Refused("native bundle cannot carry Docker mounts")
            continue
        mounts = []
        for mount in array(item["mounts"], 0, 16):
            keys(mount, {"source", "target"})
            source, target = absolute(mount["source"]), workspace_target(mount["target"])
            mounts.append({"type": "bind", "source": source, "target": target})
        command = [item["role"], "--deployment", MEMBER + "/deployment.toml"]
        if item["role"] == "owner":
            command.extend(["--state-dir", "/var/lib/loom"])
        name = item["name"]
        expected_services[name] = {"image": item["image"], "platform": "linux/amd64", "entrypoint": ["tini", "--", ROLE_ENTRYPOINT], "command": command, "network_mode": "host", "restart": "no", "working_dir": "/work", "volumes": [{"type": "bind", "source": str(root / name / "member"), "target": MEMBER}, {"type": "bind", "source": str(root / name / "state"), "target": "/var/lib/loom"}] + mounts}
    if document != {"name": bundle["project"], "services": expected_services}:
        raise Refused("Compose identities/targets differ from retained inventory")
    return bundle


def export_bundle(source: Path, output: Path, names: list[str]) -> None:
    bundle = inspect_bundle(source)
    if bundle["placement"] != "coordinator":
        raise Refused("host identity cannot be exported again")
    source = source.resolve()
    selected = {i["name"]: i for i in bundle["instances"]}
    if not names or len(names) != len(set(names)) or any(n not in selected for n in names):
        raise Refused("export requires explicit distinct installed names")
    output = output.absolute()
    if output.is_relative_to(source) or source.is_relative_to(output):
        raise Refused("host bundle must be separate from coordinator bundle")
    for name in names:
        if any((source / name / "state").iterdir()) or (source / name / "member/tls.options").exists():
            raise Refused("export is only for unbooted empty state; never relocate retained runtime state")
        if (source / ("exported-" + name + ".json")).exists():
            raise Refused("role already exported; retain its original host identity")
    output.mkdir(mode=0o700)
    output = output.resolve()
    # Reserve export before copying. A failed export stays reserved so an unknown
    # outcome cannot silently produce a second original host identity.
    for name in names:
        write_private(source / ("exported-" + name + ".json"), json.dumps({"root": str(output)}))
    (output / "authority").mkdir(mode=0o700)
    write_private(output / "authority/ca.pem", bounded_read(source / "authority/ca.pem"))
    local_instances = [selected[n] for n in names]
    for instance in local_instances:
        name = instance["name"]
        member = output / name / "member"
        member.mkdir(parents=True, mode=0o700)
        member.parent.chmod(0o700)
        (member.parent / "state").mkdir(mode=0o700)
        for leaf in ["ca.pem", "cert.pem", "key.pem", ".erlang.cookie", "leaf.sha256", "deployment.toml"]:
            data = bounded_read(source / name / "member" / leaf)
            if leaf == "deployment.toml" and instance["transport"] == "native":
                rendered = data.decode()
                for suffix in ["/member/ca.pem", "/member/cert.pem", "/member/key.pem", "/member/.erlang.cookie", "/member/tls.options", "/state"]:
                    rendered = rendered.replace(quote(str(source / name) + suffix), quote(str(output / name) + suffix))
                data = rendered.encode()
            write_private(member / leaf, data)
    document = json.loads(bounded_read(source / "compose.json"))
    services = {name: document["services"][name] for name in names if selected[name]["transport"] == "docker"}
    for name, service in services.items():
        for mount in service["volumes"][:2]:
            mount["source"] = str(output / name / ("member" if mount["target"] == MEMBER else "state"))
    write_private(output / "compose.json", json.dumps({"name": bundle["project"], "services": services}, indent=2) + "\n")
    files = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest() for p in output.rglob("*") if p.is_file()}
    write_private(output / "bundle.json", json.dumps({**bundle, "placement": "host", "root": str(output), "instances": local_instances, "files": files}, indent=2) + "\n")
    inspect_bundle(output)


def docker_directories_owned(root: Path, name: str) -> None:
    for directory in [root / name / "member", root / name / "state"]:
        if directory.stat().st_uid != 10000:
            raise Refused("Docker private directories must be owned by image uid 10000: " + str(directory))


def lifecycle(root: Path, action: str, names: list[str]) -> None:
    bundle = inspect_bundle(root)
    if bundle["placement"] != "host":
        raise Refused("export selected roles into a host bundle before lifecycle commands")
    selected = {i["name"]: i for i in bundle["instances"] if i["transport"] == "docker"}
    if not names or len(names) != len(set(names)) or any(n not in selected for n in names):
        raise Refused("select explicit, distinct Docker instance names")
    if sys.platform != "linux":
        raise Refused("Compose host networking requires a Linux Docker host; use native previews on macOS")
    root = root.resolve()
    if action == "start":
        for name in names:
            instance = selected[name]
            docker_directories_owned(root, name)
            for mount in instance["mounts"]:
                physical = Path(mount["source"]).resolve(strict=True)
                if not physical.is_dir() or physical.is_relative_to(root) or root.is_relative_to(physical):
                    raise Refused("workspace source is missing or overlaps private host bundle")
            labels = json.loads(run(["docker", "image", "inspect", "--format", "{{json .Config.Labels}}", instance["image"]], capture=True).stdout or b"{}") or {}
            if labels.get("org.loom.distributed.protocol") != "077" or instance["role"] not in labels.get("org.loom.distributed.roles", "").split(","):
                raise Refused("image does not advertise the registered role contract")
            # This transient help-only process proves preliminary flag compatibility,
            # not deployment decoding, readiness, activation or effects.
            run(["docker", "run", "--rm", "--network", "none", "--read-only", "--entrypoint", ROLE_ENTRYPOINT, instance["image"], instance["role"], "--check-role"], capture=True)
    prefix = ["docker", "compose", "--project-name", bundle["project"], "--file", str(root / "compose.json")]
    suffix = {"start": ["up", "--detach", "--no-deps", "--pull", "never"], "stop": ["stop"], "logs": ["logs", "--tail", "200"]}[action]
    run(prefix + suffix + names)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    create = commands.add_parser("prepare", help="create a new private identity bundle; existing output refuses")
    create.add_argument("plan", type=Path)
    create.add_argument("output", type=Path)
    export = commands.add_parser("export", help="reserve and copy explicit unbooted roles to a new host bundle")
    export.add_argument("bundle", type=Path)
    export.add_argument("output", type=Path)
    export.add_argument("names", nargs="+")
    for name in ["inspect", "render", "start", "stop", "logs"]:
        command = commands.add_parser(name)
        command.add_argument("bundle", type=Path)
        if name in {"start", "stop", "logs"}:
            command.add_argument("names", nargs="+")
    args = parser.parse_args(argv)
    try:
        if args.action == "prepare":
            prepare(args.plan, args.output)
            print("prepared private bundle; runtime validation pending")
        elif args.action == "export":
            export_bundle(args.bundle, args.output, args.names)
            print("reserved host bundle; transfer only this private bundle to its declared absolute path")
        elif args.action in {"start", "stop", "logs"}:
            lifecycle(args.bundle, args.action, args.names)
        else:
            bundle = inspect_bundle(args.bundle)
            if args.action == "render":
                print(bounded_read(args.bundle / "compose.json").decode(), end="")
            else:
                for instance in bundle["instances"]:
                    command = ["loomd" if instance["role"] == "owner" else "loom-executor", "--deployment", str(args.bundle.resolve() / instance["name"] / "member" / "deployment.toml")]
                    if instance["role"] == "owner":
                        command.extend(["--state-dir", str(args.bundle.resolve() / instance["name"] / "state")])
                    print(json.dumps({**instance, "native_command": command if instance["transport"] == "native" and bundle["placement"] == "host" else None}))
        return 0
    except (Refused, OSError, ValueError, subprocess.CalledProcessError) as error:
        # OpenSSL/help output can contain private diagnostics. Report only the
        # command's program and status, never its captured stderr or credential argv.
        detail = f"{error.cmd[0]} exited {error.returncode}" if isinstance(error, subprocess.CalledProcessError) else str(error)
        print("distributed-launch: " + detail, file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
