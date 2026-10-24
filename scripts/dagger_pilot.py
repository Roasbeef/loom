#!/usr/bin/env python3
"""Opt-in Dagger beta pilot for Loom's five portable Erlang package gates.

Only declared, tracked source inputs enter the engine. Existing CI and signoff
remain authoritative. Run with --plan to inspect dependency closures without
starting an engine; see docs/dagger-pilot.md for setup and cache limitations.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
import urllib.request

VERSION = "1.0.0-beta.19"
ENGINE = f"image+docker://registry.dagger.io/engine:v{VERSION}"
PACKAGES = ("core", "machine", "prompt", "statem", "session_view")
SCRIPTS = ("scripts/check.sh", "scripts/test.sh", "scripts/with_timeout.py",
           "scripts/serial-tests", "scripts/dagger_pilot.py")


def closure(root, package, seen=None):
    """Follow native path dependencies, refusing expansion outside this pilot."""
    seen = set() if seen is None else seen
    if package in seen:
        return seen
    if package not in PACKAGES:
        raise ValueError(f"dependency outside pilot: {package}")
    seen.add(package)
    folder = root / "packages" / package
    config = tomllib.loads((folder / "gleam.toml").read_text())
    for section in ("dependencies", "dev_dependencies"):
        for dependency in config.get(section, {}).values():
            if isinstance(dependency, dict) and "path" in dependency:
                target = (folder / dependency["path"]).resolve()
                if target.parent != (root / "packages").resolve():
                    raise ValueError(f"dependency outside packages: {target}")
                closure(root, target.name, seen)
    return seen


def package_input(path, packages):
    """Select source, fixtures and native configuration, never host build trees."""
    parts = Path(path).parts
    return (len(parts) >= 3 and parts[0] == "packages"
            and parts[1] in packages
            and (parts[2] in ("src", "test", "dev", "priv")
                 or parts[2:] in (("gleam.toml",), ("manifest.toml",))))


def input_files(root, packages):
    """Fail rather than silently omit a new, untracked source or test file."""
    paths = [f"packages/{package}/{part}" for package in sorted(packages)
             for part in ("src", "test", "dev", "priv", "gleam.toml", "manifest.toml")]

    def listing(*args):
        return subprocess.check_output(
            ["git", "ls-files", "-z", *args, "--", *paths], cwd=root).decode().split("\0")

    untracked = [p for p in listing("--others")
                 if p and package_input(p, packages)]
    if untracked:
        raise ValueError("stage new pilot inputs with git add first: "
                         + ", ".join(untracked))
    files = {p for p in listing("--cached") if package_input(p, packages)}
    files.update(SCRIPTS)
    selected = []
    for name in sorted(files):
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"symlink input is not supported: {name}")
        if path.is_file():
            selected.append(name)
        elif name in SCRIPTS or name.endswith(("/gleam.toml", "/manifest.toml")):
            raise ValueError(f"required input missing: {name}")
    return selected


def snapshot(root, destination, files):
    """Copy working-tree bytes, including edits and deletions, into a clean tree."""
    for name in files:
        source = root / name
        if any(root.joinpath(*Path(name).parts[:n]).is_symlink()
               for n in range(1, len(Path(name).parts) + 1)):
            raise ValueError(f"symlink input is not supported: {name}")
        if not source.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"input outside root: {name}")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, target)
        target.chmod(0o755 if os.access(root / name, os.X_OK) else 0o644)


def query(dagger, engine, document, env):
    """Keep GraphQL errors and nonzero command exits distinct from a pass."""
    port = int(env["DAGGER_SESSION_PORT"])
    token = base64.b64encode((env["DAGGER_SESSION_TOKEN"] + ":").encode()).decode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/query",
        data=json.dumps({"query": document}).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Basic " + token})
    # Session credentials are for loopback only, never an ambient HTTP proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=1800) as result:
        response = json.load(result)
    if response.get("errors"):
        raise RuntimeError(json.dumps(response["errors"]))
    return response.get("data", response), ""


def gate_query(toolchain, source, package, fresh=""):
    """Describe one isolated gate; package inputs determine its cache key."""
    quote = json.dumps
    commands = ["bash", "scripts/check.sh", package]
    body = (f"withDirectory(path: \"/work\", source: {quote(source)}) {{ "
            "withWorkdir(path: \"/work\") { "
            "withEnvVariable(name: \"ERL_FLAGS\", value: \"+S 2:2\") { "
            f"withExec(args: {quote(commands)}) {{ stdout }} }} }} }}")
    if fresh:
        body = ("withEnvVariable(name: \"LOOM_DAGGER_FRESH\", value: "
                + quote(fresh) + ") { " + body + " }")
    return "{ node(id: " + quote(toolchain) + ") { ... on Container { " + body + " } } }"


def find_stdout(value):
    """Extract the single requested output without depending on chain depth."""
    while isinstance(value, dict) and "stdout" not in value:
        if len(value) != 1:
            raise ValueError("unexpected Dagger gate response")
        value = next(iter(value.values()))
    return value["stdout"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", nargs="*", choices=PACKAGES)
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--session", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--dagger", default="dagger")
    parser.add_argument("--engine", default=ENGINE)
    parser.add_argument("--fresh", action="store_true", help="rerun gates without deleting engine caches")
    parser.add_argument("--output", type=Path, default=Path("build/dagger-pilot"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    packages = args.packages or list(PACKAGES)
    output = args.output.resolve()
    if not args.plan and not args.session:
        output.mkdir(parents=True, exist_ok=True)
        (output / "summary.json").write_text(json.dumps({"status": "running", "packages": packages}) + "\n")
    plans = {p: input_files(root, closure(root, p)) for p in packages}
    if args.plan:
        print(json.dumps(plans, indent=2))
        return 0
    # This trial never selects a managed engine, even through ambient settings.
    if not args.engine.startswith(("image+docker://", "container+docker://")):
        raise ValueError("pilot supports only explicit local/self-hosted Docker engines")
    env = dict(os.environ) if args.session else {
        k: v for k, v in os.environ.items()
        if not k.startswith(("DAGGER_", "_EXPERIMENTAL_DAGGER"))}
    env["DAGGER_NO_NAG"] = "1"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if not args.session:
        with tempfile.TemporaryDirectory(prefix="loom-dagger-auth-") as auth:
            env.update(HOME=auth, XDG_CONFIG_HOME=auth + "/config",
                       XDG_CACHE_HOME=auth + "/cache")
            version = subprocess.check_output([args.dagger, "version"], text=True, env=env)
            if not re.search(r"\bv" + re.escape(VERSION) + r"\b", version):
                raise ValueError(f"install Dagger {VERSION}; got {version.strip()}")
            (output / "summary.json").write_text(json.dumps({"status": "running", "packages": packages}) + "\n")
            with (output / "engine.log").open("w") as trace:
                completed = subprocess.run([args.dagger, "--engine=" + args.engine,
                    "--progress=plain", "run", "--", sys.executable, str(Path(__file__).resolve()),
                    *sys.argv[1:], "--session"], env=env, stderr=trace, timeout=1800)
            if completed.returncode:
                raise RuntimeError(f"gate failed; see {output / 'engine.log'}")
            return 0
    run_started = time.monotonic()
    fresh = str(uuid.uuid4()) if args.fresh else ""
    summary = []
    # Sequential gates bound resource use on a shared developer engine. Each gate
    # is still independently cacheable; parallel scheduling is not this trial.
    with tempfile.TemporaryDirectory(prefix="loom-dagger-") as temp:
        toolchain_path = Path(temp) / "toolchain"
        new_toolchain = subprocess.check_output(
            ["git", "ls-files", "--others",
             "scripts/signoff/Dockerfile", "scripts/toolchain/gleam",
             ".github/scripts/install_rust_analyzer.sh"], cwd=root, text=True).splitlines()
        if new_toolchain:
            raise ValueError("stage new toolchain inputs first: " + ", ".join(new_toolchain))
        toolchain_files = subprocess.check_output(
            ["git", "ls-files", "scripts/signoff/Dockerfile",
             "scripts/toolchain/gleam", ".github/scripts/install_rust_analyzer.sh"],
            cwd=root, text=True).splitlines()
        snapshot(root, toolchain_path, toolchain_files)
        build_source, trace = query(args.dagger, args.engine,
            "{ host { directory(path: " + json.dumps(str(toolchain_path)) + ") { dockerBuild(dockerfile: \"scripts/signoff/Dockerfile\", platform: \"linux/amd64\") { id } } } }", env)
        toolchain = build_source["host"]["directory"]["dockerBuild"]["id"]
        for package, files in plans.items():
            source_path = Path(temp) / package
            snapshot(root, source_path, files)
            started = time.monotonic()
            source, trace = query(args.dagger, args.engine,
                                  "{ host { directory(path: " + json.dumps(str(source_path)) + ") { id } } }", env)
            source = source["host"]["directory"]["id"]
            try:
                result, gate_trace = query(args.dagger, args.engine,
                    gate_query(toolchain, source, package, fresh), env)
            except RuntimeError as error:
                (output / f"{package}.log").write_text(str(error))
                raise
            text = find_stdout(result)
            (output / f"{package}.log").write_text(text)
            elapsed = round(time.monotonic() - started, 3)
            counts = re.findall(r"(?:All \d+ tests passed|Test passed|\d+ tests? passed)", text)
            row = {"package": package, "seconds": elapsed, "result": "pass",
                   "tests": counts, "fresh": bool(fresh)}
            summary.append(row)
            print(json.dumps(row), flush=True)
    (output / "summary.json").write_text(json.dumps({"status": "passed",
        "seconds": round(time.monotonic() - run_started, 3),
        "gates": summary}, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"dagger pilot failed: {error}", file=sys.stderr)
        sys.exit(1)
