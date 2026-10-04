#!/usr/bin/env python3
"""Check bounded ownership and metadata models with named negative witnesses.

The runner owns only this directory. It pins the official tools jar by release
and SHA-256, regenerates PlusCal in an isolated run directory, and rejects a
stale checked-in translation. Every TLC invocation has a heap and wall-clock
bound. Expected counterexamples require exit 12 and the intended invariant;
parse errors, unrelated invariant failures, and timeouts are failures.

Examples:
    python3 protocol/models/distributed-authority/run.py
    python3 protocol/models/distributed-authority/run.py --case MutantAdmission
    python3 protocol/models/distributed-authority/run.py --translate
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VERSION = "1.7.1"
JAR_SHA256 = "d532ba31aafe17afba1130f92410d9257454ff7393d1eb2fe032f0c07f352da5"
JAR_URL = f"https://github.com/tlaplus/tlaplus/releases/download/v{VERSION}/tla2tools.jar"

# Counterexamples for reachability are positive controls: the desired state
# must exist while all safety predicates still hold. Mutants select a safety
# invariant that exposes the actual defect, rather than an earlier symptom.
CASES = {
    'ChannelSafety': None,
    'ChannelSafetyQuota': None,
    'ChannelReachOutcome': 'NoCompleteStream',
    'ChannelReachHookResult': 'NoCompleteStream',
    'ChannelReachBidirectional': 'NoBidirectionalPending',
    'ChannelReachLateAck': 'NoLateConsumptionAck',
    'ChannelReachQuota': 'NoQuotaFailure',
    'ChannelReachCancel': 'NoCancelUnderPressure',
    'ChannelMutantNetworkAck': 'ConsumerBound',
    'ChannelMutantTimeout': 'ConsumerBound',
    'ChannelMutantRestart': 'ConsumerBound',
    'ChannelMutantQuota': 'LifetimeBytesBound',
    'ChannelMutantDroppedSuccess': 'NoSuccessAfterLoss',
    'ChannelMutantControl': 'ControlIndependent',

    "IngressSafety": None,
    "IngressSafetyOne": None,
    "IngressReachTimeout": "NoTimedOutRecovery",
    "IngressReachReuse": "NoReuseAfterTimeout",
    "IngressReachCrash": "NoCrashWithPending",
    "IngressMutantTimeout": "QueueBound",
    "IngressMutantRestart": "QueueBound",
    "Safety": None,
    "ReachHandoff": "NoSuccessfulHandoff",
    "ReachRecovery": "NoRecoveredHandoff",
    "ReachActivationReply": "NoRecoveredActivation",
    "ReachDelayed": "NoLateRejection",
    "ReachStaleRoute": "NoStaleRouteRejection",
    "ReachAbortRetry": "NoAbortRetry",
    "MutantDirectory": "OneEffectiveWriter",
    "MutantAdmission": "NoOverlappingAuthority",
    "MutantCut": "ActivationHasEvidence",
    "MetadataSafety": None,
    "MetadataSafetyCapacity": None,
    "MetadataReachUnknown": "NoUnknownCommit",
    "MetadataReachMissing": "NoMissingThenCommit",
    "MetadataReachReconcile": "NoLostReconciliation",
    "MetadataReachLate": "NoLateReply",
    "MetadataReachStale": "NoStaleRejection",
    "MetadataReachConflict": "NoDigestConflict",
    "MetadataReachCapacity": "NoCapacityRefusal",
    "MetadataReachMinority": "NoMinorityThenHeal",
    "MetadataReachCompacted": "NoCompactedReconciliation",
    "MetadataMutantTimeout": "NoFalseNoCommit",
    "MetadataMutantRetry": "OneLogicalCommit",
    "MetadataMutantMinority": "NoMinorityAck",
    "MetadataMutantABA": "MonotonicFence",
    "MetadataMutantReceipt": "ReceiptRetained",
}


def model_for_case(case: str) -> str:
    """Select the closed model family for a named control."""
    if case.startswith("Channel"):
        return "Channel"
    if case.startswith("Ingress"):
        return "Ingress"
    return "Metadata" if case.startswith("Metadata") else "Ownership"


def provision() -> Path:
    """Fetch and authenticate the pinned jar without installing global tools."""
    cache = ROOT / ".cache"
    cache.mkdir(exist_ok=True)
    jar = cache / f"tla2tools-{VERSION}.jar"
    if not jar.exists():
        candidate = cache / f"download-{time.time_ns()}.jar"
        command = ["curl", "--fail", "--location", "--max-time", "60",
                   "--output", str(candidate), JAR_URL]
        print("Download:", json.dumps(command), flush=True)
        subprocess.run(command, check=True, timeout=65)
        if hashlib.sha256(candidate.read_bytes()).hexdigest() != JAR_SHA256:
            raise RuntimeError(f"SHA-256 mismatch: {candidate}")
        candidate.replace(jar)

    # Authenticate cached jars too. A locally provisioned wrong version must
    # not attach its results to the checked-in translation or configurations.
    if hashlib.sha256(jar.read_bytes()).hexdigest() != JAR_SHA256:
        raise RuntimeError(f"SHA-256 mismatch: {jar}")
    return jar


def execute(command: list[str], cwd: Path, log: Path, timeout: int) -> dict:
    """Capture the process's own exit status and retain its complete output."""
    started = time.monotonic()
    print("Run:", json.dumps(command), flush=True)
    with log.open("w") as stream:
        try:
            result = subprocess.run(command, cwd=cwd, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=timeout)
            code = result.returncode
        except subprocess.TimeoutExpired:
            code = None
            stream.write(f"\nRunner timeout after {timeout} seconds.\n")

    return {"command": command, "exit_code": code,
            "seconds": round(time.monotonic() - started, 3),
            "log": str(log.relative_to(ROOT))}


def translate(java: str, jar: Path, run: Path, update: bool, model: str) -> dict:
    """Regenerate in isolation; ordinary checking never rewrites source files."""
    source = ROOT / f"{model}.tla"
    generated = run / source.name
    shutil.copyfile(source, generated)
    command = [java, "-Xmx512m", "-cp", str(jar), "pcal.trans", "-nocfg",
               "-unixEOL", str(generated)]
    result = execute(command, run, run / f"translation-{model}.log", 30)
    output = (run / f"translation-{model}.log").read_text()
    if result["exit_code"] != 0 or "Translation completed." not in output:
        raise RuntimeError(f"PlusCal translation failed: {result['log']}\n{output}")
    # The pinned translator emits trailing spaces on declarations. Normalize
    # those spaces only, so the checked-in generated artifact passes diff QA.
    generated.write_text("\n".join(line.rstrip() for line in
                                    generated.read_text().splitlines()) + "\n")
    if update:
        source.write_bytes(generated.read_bytes())
    elif source.read_bytes() != generated.read_bytes():
        raise RuntimeError("Stale PlusCal translation; run run.py --translate.")
    result["passed"] = True
    return result


def check(java: str, jar: Path, run: Path, case: str, timeout: int) -> dict:
    """Require exhaustive success or a counterexample to the expected predicate."""
    work = run / case
    work.mkdir()
    model = model_for_case(case)
    shutil.copyfile(run / f"{model}.tla", work / f"{model}.tla")
    shutil.copyfile(ROOT / f"{case}.cfg", work / f"{case}.cfg")
    command = [java, "-Xmx512m", "-XX:MaxDirectMemorySize=64m", "-cp", str(jar),
               "tlc2.TLC", "-workers", "1", "-seed", "1", "-fp", "0",
               "-metadir", str(work / "states"),
               "-config", f"{case}.cfg", f"{model}.tla"]
    result = execute(command, work, work / "tlc.log", timeout)
    output = (work / "tlc.log").read_text()
    expected = CASES[case]
    stats = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found"
                       r", ([\d,]+) states left on queue", output)
    if stats:
        result.update(zip(("generated_states", "distinct_states", "queued_states"),
                          (int(n.replace(",", "")) for n in stats[-1])))
    result["trace_states"] = len(re.findall(r"^State \d+:", output, re.MULTILINE))
    if expected is None:
        passed = (result["exit_code"] == 0 and result.get("queued_states") == 0
                  and "Model checking completed. No error has been found." in output)
    else:
        failures = re.findall(r"Error: Invariant (\w+) is violated\.", output)
        passed = (result["exit_code"] == 12 and failures == [expected]
                  and result["trace_states"] > 1 and bool(stats))
    result.update(case=case, model=model, expected_invariant=expected, passed=passed,
                  model_sha256=hashlib.sha256((work / f"{model}.tla").read_bytes()).hexdigest(),
                  config_sha256=hashlib.sha256((work / f"{case}.cfg").read_bytes()).hexdigest())
    print(f"{case}: {'PASS' if passed else 'FAIL'}, exit={result['exit_code']}, "
          f"distinct={result.get('distinct_states')}, "
          f"trace={result['trace_states']}, log={result['log']}", flush=True)
    if not passed:
        print(output[-6000:], file=sys.stderr)
    return result


def main() -> int:
    """Run the full suite by default and leave a machine-readable evidence record."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="/usr/bin/java",
                        help="Java executable; no global configuration changes.")
    parser.add_argument("--case", choices=CASES,
                        help="Run one control; omit to run the complete suite.")
    parser.add_argument("--timeout", type=int, default=60,
                        help="Seconds per TLC case (1..120; timeout fails the run).")
    parser.add_argument("--translate", action="store_true",
                        help="Regenerate all PlusCal models only; do not run TLC.")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 120:
        parser.error("--timeout must be between 1 and 120 seconds")
    run = ROOT / ".runs" / str(time.time_ns())
    run.mkdir(parents=True)
    summary = {"tools_version": VERSION, "jar_sha256": JAR_SHA256,
               "java": args.java, "timeout_seconds_per_case": args.timeout,
               "heap_mib": 512, "direct_memory_mib": 64, "workers": 1,
               "seed": 1, "fingerprint_index": 0,
               "model_sha256": hashlib.sha256((ROOT / "Ownership.tla").read_bytes()).hexdigest(),
               "results": []}
    try:
        jar = provision()
        models = ([model_for_case(args.case)]
                  if args.case and not args.translate
                  else ["Ownership", "Metadata", "Ingress", "Channel"])
        summary["translation"] = {model: translate(args.java, jar, run, args.translate, model)
                                  for model in models}
        summary["model_sha256"] = {model: hashlib.sha256((run / f"{model}.tla").read_bytes()).hexdigest()
                                   for model in models}
        if not args.translate:
            for case in ([args.case] if args.case else CASES):
                summary["results"].append(check(args.java, jar, run, case, args.timeout))
        summary["passed"] = all(r["passed"] for r in summary["results"])
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        summary.update(passed=False, error=str(error))
        print(error, file=sys.stderr)

    # Preserve evidence even for setup failures. An absent jar, parse error, or
    # sandbox denial remains a failed run with its exact diagnostic available.
    evidence = run / "summary.json"
    evidence.write_text(json.dumps(summary, indent=2) + "\n")
    print("Evidence:", evidence, flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
