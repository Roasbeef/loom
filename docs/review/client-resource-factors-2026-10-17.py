"""Bounded four-factor diagnostic; controls are not installable releases.

The retained resource trial owns the timed cold replacement and real composer.
Only its untimed fixture seed gains two observations, to separate application
startup from the first domain's loader hint and resource initialization.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import statistics
import time

REPO = Path(__file__).resolve().parents[2]
DRIVER = REPO / "build/startup/client_resource_compare.py"
spec = importlib.util.spec_from_file_location("resource_trial", DRIVER)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
VARIANTS_FILE = REPO / "build/startup/resource-factor-variants.json"
LABEL = "startup-resource-factors-1core"
OUT = REPO / "build/startup"
CUTS = {}
SEED = None


class SeedDaemon(r.b.Daemon):
    def __init__(self, *args, **kwargs):
        global SEED
        super().__init__(*args, **kwargs)
        SEED = self
        CUTS["seed_daemon_ready"] = r.proc_resources(self.proc.pid)
        CUTS["seed_daemon_ready_ms"] = self.ready_ms


class SeedControl(r.b.Control):
    def create_session_timed(self, *args, **kwargs):
        value = super().create_session_timed(*args, **kwargs)
        CUTS["seed_first_resident"] = r.proc_resources(SEED.proc.pid)
        CUTS["seed_create_timing"] = value
        return value


def tree_manifest(root):
    entries = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            value = [path.lstat().st_mode, "symlink", os.readlink(path)]
        elif path.is_file():
            value = [path.stat().st_mode, "file", hashlib.sha256(path.read_bytes()).hexdigest()]
        else:
            continue
        entries[str(path.relative_to(root))] = value
    return entries


def fingerprints(variants):
    return {name: {part: r.artifact_fingerprint(root / part)
                   for part in ["loom", "loom-client", "."]}
            for name, root in variants.items()}


def check_variants(variants):
    manifests = {name: tree_manifest(root) for name, root in variants.items()}
    reference = manifests["concurrent-hint"]
    serve = "loom/lib/client-0.3.2/ebin/client@serve.beam"
    launcher = "loom/bin/loomd"
    expected = {"concurrent-hint": set(), "concurrent-nohint": {serve},
                "serial-hint": {launcher}, "serial-nohint": {serve, launcher}}
    differences = {}
    support_differences = {}
    for name, manifest in manifests.items():
        diff = {path for path in set(reference) | set(manifest)
                if reference.get(path) != manifest.get(path)}
        runtime_diff = {path for path in diff if path.startswith(("loom/", "loom-client/"))}
        support_diff = diff - runtime_diff
        assert runtime_diff == expected[name], (name, sorted(runtime_diff))
        assert support_diff <= {"smoke-support/client@release_probe_test.beam", "smoke-support/release-smoke.toml"}, (name, sorted(support_diff))
        differences[name] = sorted(runtime_diff)
        support_differences[name] = {path: manifest.get(path) for path in sorted(support_diff)}
        beams = [path for path in manifest
                 if path.startswith("loom-client/") and path.endswith(".beam")]
        assert len(beams) == 827
        assert all(manifest[path] == reference[path] for path in beams)
    original = (variants["concurrent-hint"] / launcher).read_bytes()
    concurrent = b"application:ensure_all_started(client, temporary, concurrent)"
    assert original.count(concurrent) == 1
    assert b"smoke-support" not in original
    serial = original.replace(concurrent, b"application:ensure_all_started(client)")
    for name in ["serial-hint", "serial-nohint"]:
        assert (variants[name] / launcher).read_bytes() == serial
    assert manifests["serial-nohint"][serve] == manifests["concurrent-nohint"][serve]
    return {"differences": differences, "non_runtime_support_differences": support_differences, "identical_client_beams": 827,
            "serial_launcher": "exact one API-call replacement; all other bytes identical",
            "nohint_beam": "root-verified one-call removal; same BEAM in both nohint controls"}


def interrupted(signum, frame):
    raise TimeoutError("bounded factor experiment interrupted: %s" % signum)


def summarize(rows):
    metrics = {
        "composer_ms": lambda row: row["composer_ms"],
        "cgroup_cpu_ms": lambda row: row["cgroup_composer_cpu_ms"],
        "daemon_composer_hwm_kib": lambda row: row["daemon_at_composer"]["hwm_kib"],
        "combined_composer_rss_kib": lambda row: row["combined_composer_rss_kib"],
        "client_whole_peak_kib": lambda row: row["client_peak_rss_kib"],
        "seed_ready_rss_kib": lambda row: row["seed_daemon_ready"]["rss_kib"],
        "seed_ready_hwm_kib": lambda row: row["seed_daemon_ready"]["hwm_kib"],
        "seed_ready_cpu_ms": lambda row: row["seed_daemon_ready"]["cpu_with_waited_children_ms"],
        "seed_resident_rss_kib": lambda row: row["seed_first_resident"]["rss_kib"],
        "seed_resident_hwm_kib": lambda row: row["seed_first_resident"]["hwm_kib"],
    }
    return {name: {key: {"median": statistics.median(values), "range": [min(values), max(values)],
                         "values": values}
                   for key, get in metrics.items()
                   for values in [[get(row) for row in rows if row["mode"] == name and not row["warmup"]]]}
            for name in ["concurrent-hint", "concurrent-nohint", "serial-hint", "serial-nohint"]}


def main():
    global CUTS
    started = time.monotonic()
    signal.signal(signal.SIGALRM, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    signal.alarm(240)
    metadata = json.loads(VARIANTS_FILE.read_text())
    variants = {name: (REPO / path).resolve() for name, path in metadata["variants"].items()}
    driver_hash = hashlib.sha256(DRIVER.read_bytes()).hexdigest()
    audit = check_variants(variants)
    before = fingerprints(variants)
    allowed = sorted(os.sched_getaffinity(0))
    r.EXPECTED_AFFINITY = (allowed[0],)
    os.sched_setaffinity(0, r.EXPECTED_AFFINITY)
    r.RUN_LABEL = LABEL
    r.b.Daemon = SeedDaemon
    r.b.Control = SeedControl
    rows = []
    names = list(variants)
    schedule = [("warmup", names)] + [(block, names[block:] + names[:block]) for block in range(4)]
    for block, order in schedule:
        for name in order:
            CUTS = {}
            r.CURRENT = variants[name]
            row = r.trial(name, block, "smoke", "cold-autostart", block == "warmup")
            row.update(CUTS)
            rows.append(row)
            (OUT / (LABEL + "-partial.json")).write_text(json.dumps(rows, indent=2))
    assert before == fingerprints(variants)
    assert driver_hash == hashlib.sha256(DRIVER.read_bytes()).hexdigest()
    identities = {row[key]["pid"] for row in rows for key in ["seed_identity", "native_identity"]}
    remaining = [pid for pid in identities if Path("/proc/%d" % pid).exists()]
    assert not remaining, remaining
    summary = summarize(rows)
    result = {"provenance": {"variant_metadata": metadata, "audit": audit, "artifacts": before,
                              "trial_driver_sha256": driver_hash, "affinity": list(r.EXPECTED_AFFINITY),
                              "clock_ticks_per_second": r.CLOCK_TICKS,
                              "schedule": schedule, "elapsed_s": time.monotonic() - started,
                              "observations": "Extra seed readiness/residency observations are untimed. Retained cold replacement composer trial is unchanged. Derived controls have intentionally stale release checksum manifests and are not installable.",
                              "retired_native_identities": len(identities)},
              "rows": rows, "summary": summary}
    (OUT / (LABEL + "-results.json")).write_text(json.dumps(result, indent=2))
    signal.alarm(0)
    print(json.dumps({"summary": summary, "retired_native_identities": len(identities)}, indent=2))


if __name__ == "__main__":
    main()
