"""`LoomAgent`: Loom as a Harbor installed agent.

Harbor loads an agent by import path, `module.path:ClassName`
(`harbor.utils.import_path`, reached from `AgentFactory.create_agent_from_config`),
so the class below is the whole interface:

    harbor run -d terminal-bench@2.0 \\
        --agent loom_harbor.agent:LoomAgent -m anthropic/claude-opus-4-5

A trial moves through three Harbor calls, and each does one job here.

`install` puts a Loom release into the task container: the `loomd` server
archive and the self-contained `loom` client archive, verified against the
release's `SHA256SUMS`, or two local archives for an offline run. It runs once
per container, as root, and is idempotent.

`run` writes a one-model `loom.toml` and the instruction into the container,
starts `loomd` under the chosen isolation posture, drives it with
`loom run -p`, stops it, and copies the session database into `/logs/agent`,
where Harbor collects it. It deliberately does not touch the `AgentContext`:
Harbor calls `populate_context_post_run` only when the context is still empty,
and that hook is the one that runs after a timeout too, so it owns the
context and the trajectory.

`populate_context_post_run` runs on the host after Harbor has synced the logs
back. It reads `loom-run.json` for the verdict, usage and isolation label,
fills the context, and converts the session database into `trajectory.json`
(ATIF) with `loom_harbor.trajectory`.

Isolation is an explicit choice, never a silent default. See `LoomAgentOptions.jail`.
"""

from __future__ import annotations

import json
import re
import shlex
from pathlib import Path
from types import SimpleNamespace
from typing import Any, ClassVar, Literal, override

from harbor.agents.capabilities import AgentCapabilities
from harbor.agents.installed.base import (
    BaseInstalledAgent,
    NonZeroAgentExitCodeError,
    PackageSpec,
    with_prompt_template,
)
from harbor.agents.options import InstalledAgentOptions
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext
from pydantic import Field, field_validator

from loom_harbor import catalogue, runreport, scripts, trajectory

RELEASES_URL = "https://github.com/Roasbeef/loom/releases"

# Linux caps a single argument at 131072 bytes (MAX_ARG_STRLEN) and `loom run`
# takes the instruction as one. Stay clear of the cap rather than learn it from
# an "Argument list too long" in the middle of a trial.
MAX_INSTRUCTION_BYTES = 128 * 1024 - 1072

# Where the adapter keeps its own files in the container. `/installed-agent`
# is created by Harbor's `setup` before `install` runs.
REMOTE_DIR = "/installed-agent"
REMOTE_CONFIG = f"{REMOTE_DIR}/loom.toml"
REMOTE_PROMPT = f"{REMOTE_DIR}/loom-prompt.txt"
REMOTE_SERVER_TARBALL = f"{REMOTE_DIR}/loom-server.tar.gz"
REMOTE_CLIENT_TARBALL = f"{REMOTE_DIR}/loom-client.tar.gz"

# `loomd` flag per isolation posture. An empty flag is Loom's own default,
# `PlatformEnforcement`, which refuses a helper that cannot confine a run.
JAIL_FLAGS = {"platform": "", "container": "--best-effort"}

_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_INSTALL_DIR = re.compile(r"^/[A-Za-z0-9._+@~/-]*$")
_VERSION_WORD = re.compile(r"\d+\.\d+\.\d+[\w.+-]*")
_COMMIT_LINE = re.compile(r"^commit\s+([0-9a-f]{7,40})\s*$", re.MULTILINE)


class LoomAgentOptions(InstalledAgentOptions):
    """Everything `--agent-kwarg key=value` may set on `LoomAgent`.

    Harbor's own `version`, `prompt_template_path`, `base_url` and
    `reasoning_effort` keep their meaning: `version` selects the release,
    `base_url` is the model endpoint, `reasoning_effort` maps to Loom's
    `thinking` level.
    """

    release: str | None = Field(
        default=None,
        description=(
            "Release tag to install (v0.3.2, or commit-<sha> for a nightly). "
            "Defaults to `version`, then the latest published release."
        ),
    )
    release_base_url: str | None = Field(
        default=None,
        description=(
            "Directory URL that holds SHA256SUMS and the platform archives, "
            "for a mirror. Overrides `release`."
        ),
    )
    server_tarball: str | None = Field(
        default=None,
        description="Host path of loomd-<version>-<platform>.tar.gz, for an offline run.",
    )
    client_tarball: str | None = Field(
        default=None,
        description="Host path of loom-<version>-<platform>.tar.gz, for an offline run.",
    )
    jail: Literal["platform", "container"] = Field(
        default="container",
        description=(
            "Isolation posture. `container`: the task container is the "
            "boundary and loomd runs with --best-effort. `platform`: Loom's "
            "own kernel jail must come up fully, and the trial is refused if "
            "it does not."
        ),
    )
    timeout_sec: int = Field(
        default=1800,
        gt=0,
        description=(
            "Wall-clock limit passed to `loom run`. Harbor does not tell an "
            "agent its timeout, so set this a minute or two below the task's."
        ),
    )
    endpoint_url: str | None = Field(
        default=None,
        description=(
            "Model endpoint root for an OpenAI-compatible provider Loom has no "
            "built-in address for (together/..., openrouter/...). Harbor's own "
            "--base-url is not available: it needs a model-connection spec this "
            "adapter does not declare."
        ),
    )
    dialect: str | None = Field(default=None, description="Override the Loom dialect.")
    api_key_env: str | None = Field(
        default=None, description="Name of the host variable that holds the API key."
    )
    context_window: int | None = Field(default=None, gt=0)
    max_output_tokens: int | None = Field(default=None, gt=0)
    openai_api: Literal["responses", "chat"] = Field(
        default="responses",
        description="Which OpenAI wire dialect `openai/...` models use.",
    )
    network: Literal["full", "off"] = Field(
        default="full", description="Network posture of Loom's jailed tool shells."
    )
    rw_mounts: list[str] | str | None = Field(
        default=None,
        description=(
            "Absolute paths outside the working directory that tools may "
            "write (comma-separated, or a JSON list)."
        ),
    )
    price_input: float | None = Field(default=None, ge=0, description="USD per million tokens.")
    price_output: float | None = Field(default=None, ge=0, description="USD per million tokens.")
    price_cache_read: float | None = Field(default=None, ge=0)
    price_cache_write: float | None = Field(default=None, ge=0)
    state_dir: str | None = Field(
        default=None, description="Daemon state directory in the container (default ~/.loom-harbor)."
    )
    install_dir: str = Field(default="/opt/loom-harbor", description="Where the release is unpacked.")
    bwrap: Literal["auto", "keep"] = Field(
        default="auto",
        description=(
            "`container` jail only. `auto`: if the container has a bubblewrap "
            "that cannot create the namespaces Loom asks for, move it aside "
            "so Loom degrades honestly instead of failing every tool call. "
            "`keep`: never touch it."
        ),
    )

    @field_validator("install_dir")
    @classmethod
    def _safe_install_dir(cls, value: str) -> str:
        if value == "/" or not _INSTALL_DIR.match(value) or ".." in value.split("/"):
            raise ValueError("install_dir must be an absolute path of letters, digits and . _ + @ ~ -")
        return value.rstrip("/")

    @field_validator("rw_mounts", mode="before")
    @classmethod
    def _split_mounts(cls, value: Any) -> Any:
        if isinstance(value, str):
            return [part.strip() for part in value.split(",") if part.strip()]
        return value


def normalise_release(release: str | None) -> str | None:
    """Turn `0.3.2` into the tag `v0.3.2`; `latest` and empty mean no tag."""
    if release is None or release.strip() in ("", "latest"):
        return None
    release = release.strip()
    if release[0].isdigit():
        release = f"v{release}"
    if not _TAG.match(release):
        raise ValueError(f"release {release!r} is not a valid tag name")
    return release


def base_url_for(release: str | None) -> str:
    """The directory that holds `SHA256SUMS` and the archives for a release."""
    tag = normalise_release(release)
    return f"{RELEASES_URL}/latest/download" if tag is None else f"{RELEASES_URL}/download/{tag}"


class LoomAgent(BaseInstalledAgent):
    """Runs a Loom release on a Harbor task and reports it as ATIF."""

    capabilities = AgentCapabilities(atif=True, reasoning_effort=True)
    options_model = LoomAgentOptions
    options: LoomAgentOptions

    # Harbor's table has no bubblewrap entry, and Loom's namespace layer needs it.
    SYSTEM_PACKAGES: ClassVar[dict[str, PackageSpec]] = {
        **BaseInstalledAgent.SYSTEM_PACKAGES,
        "bubblewrap": PackageSpec(
            commands=("bwrap",),
            packages={
                "apt-get": ("bubblewrap",),
                "dnf": ("bubblewrap",),
                "yum": ("bubblewrap",),
                "apk": ("bubblewrap",),
            },
        ),
    }

    @staticmethod
    @override
    def name() -> str:
        return "loom"

    # ------------------------------------------------------------ configuration

    def _env(self, name: str) -> str | None:
        """An adapter setting from `--agent-env` or the host environment."""
        return self._get_env(name)

    def release_tag(self) -> str | None:
        """The release to install, or `None` for the latest published one."""
        chosen = self.options.release or self.options.version or self._env("LOOM_RELEASE")
        return normalise_release(chosen)

    def release_base_url(self) -> str:
        explicit = self.options.release_base_url or self._env("LOOM_RELEASE_BASE_URL")
        return explicit.rstrip("/") if explicit else base_url_for(self.release_tag())

    def local_tarballs(self) -> tuple[Path, Path] | None:
        """Both local archives, or `None` for a network install."""
        server = self.options.server_tarball or self._env("LOOM_SERVER_TARBALL")
        client = self.options.client_tarball or self._env("LOOM_CLIENT_TARBALL")
        if not server and not client:
            return None
        if not (server and client):
            raise ValueError(
                "an offline install needs both server_tarball and client_tarball "
                "(loomd-<version>-<platform>.tar.gz and loom-<version>-<platform>.tar.gz)"
            )
        paths = (Path(server).expanduser(), Path(client).expanduser())
        for path in paths:
            if not path.is_file():
                raise FileNotFoundError(f"Loom archive not found on the host: {path}")
        return paths

    def model_spec(self) -> catalogue.ModelSpec:
        """The catalogue entry for Harbor's `-m provider/model`, with its key variable chosen."""
        if not self.model_name:
            raise ValueError("LoomAgent needs a model: pass -m provider/model")
        options = self.options
        pricing = None
        if options.price_input is not None or options.price_output is not None:
            if options.price_input is None or options.price_output is None:
                raise ValueError("price_input and price_output must be given together")
            pricing = catalogue.Pricing(
                input=options.price_input,
                output=options.price_output,
                cache_read=options.price_cache_read,
                cache_write=options.price_cache_write,
            )
        spec = catalogue.resolve_model(
            self.model_name,
            dialect=options.dialect,
            api_key_env=options.api_key_env,
            base_url=options.endpoint_url,
            context_window=options.context_window,
            max_output_tokens=options.max_output_tokens,
            reasoning_effort=options.reasoning_effort,
            openai_api=options.openai_api,
            pricing=pricing,
        )
        found = self._resolve_env(*spec.api_key_envs)
        # The variable's name is chosen even when it is unset, so the error
        # below can name it; the value is read again at run time.
        return catalogue.with_api_key_env(spec, found[0] if found else spec.api_key_envs[0])

    def api_key(self) -> tuple[str, str]:
        """The key variable's name and value, or a loud refusal naming the variable."""
        spec = self.model_spec()
        found = self._resolve_env(*spec.api_key_envs)
        if not found or not found[1]:
            wanted = " or ".join(spec.api_key_envs)
            raise ValueError(
                f"no API key for {self.model_name}: set {wanted} in the host "
                "environment, or pass it with --agent-env"
            )
        return found

    def jail_flag(self) -> str:
        return JAIL_FLAGS[self.options.jail]

    def state_dir(self) -> str | None:
        return self.options.state_dir

    def rw_mounts(self) -> tuple[str, ...]:
        mounts = self.options.rw_mounts
        return tuple(mounts) if isinstance(mounts, list) else ()

    def render_catalogue(self) -> str:
        return catalogue.render_loom_toml(
            self.model_spec(), network=self.options.network, rw_mounts=self.rw_mounts()
        )

    def install_env(self) -> dict[str, str]:
        """Variables for the install script. None of them is a credential."""
        env = {"LOOM_PREFIX": self.options.install_dir}
        if self.local_tarballs() is None:
            env["LOOM_BASE_URL"] = self.release_base_url()
        else:
            env["LOOM_SERVER_TARBALL"] = REMOTE_SERVER_TARBALL
            env["LOOM_CLIENT_TARBALL"] = REMOTE_CLIENT_TARBALL
        return env

    def run_env(self, key_name: str, key_value: str) -> dict[str, str]:
        """Variables for the run script; the API key travels here and nowhere else."""
        env = {
            "LOOM_PREFIX": self.options.install_dir,
            "LOOM_OUT": str(self.environment_logs_dir),
            "LOOM_CONFIG": REMOTE_CONFIG,
            "LOOM_PROMPT_FILE": REMOTE_PROMPT,
            "LOOM_RUN_TIMEOUT_SEC": str(self.options.timeout_sec),
            "LOOM_JAIL_FLAG": self.jail_flag(),
            key_name: key_value,
        }
        if self.state_dir():
            env["LOOM_STATE_DIR"] = self.state_dir() or ""
        return env

    # ------------------------------------------------------------------ install

    @override
    def get_version_command(self) -> str | None:
        return f"{shlex.quote(self.options.install_dir)}/client/bin/loom version"

    @override
    def parse_version(self, stdout: str) -> str:
        """`loom version` prints `loom <version>`, `commit <sha>` and `platform <p>`.

        Nightly releases share a version and differ by commit, so the first
        twelve characters of the commit are appended: two runs that report the
        same agent version ran the same bytes.
        """
        found = _VERSION_WORD.search(stdout)
        if not found:
            return (stdout.strip().splitlines() or ["unknown"])[0]
        commit = _COMMIT_LINE.search(stdout)
        return found.group(0) + (f"+{commit.group(1)[:12]}" if commit else "")

    @override
    async def install(self, environment: BaseEnvironment) -> None:
        # Credentials and the model are checked before anything is downloaded,
        # so a typo costs seconds and not an install.
        self.api_key()
        self.render_catalogue()
        local = self.local_tarballs()

        await self.ensure_system_dependencies(environment, ("curl", "tar", "bash", "ca_certificates"))
        # Bubblewrap is Loom's namespace layer. Platform mode cannot run without
        # it. Container mode does not install it: a fresh one would meet the
        # same refused user namespaces that `run` probes for below.
        wanted = ("git", "ripgrep") + (("bubblewrap",) if self.options.jail == "platform" else ())
        for dependency in wanted:
            try:
                await self.ensure_system_dependencies(environment, (dependency,))
            except Exception as exc:
                # Without bubblewrap the platform posture cannot come up, so
                # that is fatal there; every other helper is a convenience.
                if dependency == "bubblewrap" and self.options.jail == "platform":
                    raise
                self.logger.warning("could not install %s (continuing): %s", dependency, exc)

        if local is not None:
            await environment.upload_file(local[0], REMOTE_SERVER_TARBALL)
            await environment.upload_file(local[1], REMOTE_CLIENT_TARBALL)

        await self.exec_as_root(
            environment,
            command=scripts.bash_command(scripts.INSTALL_SCRIPT),
            env=self.install_env(),
        )

    # ---------------------------------------------------------------------- run

    async def _preflight_platform(self, environment: BaseEnvironment) -> runreport.SelfTest:
        """Refuse a `platform` trial whose jail would not fully come up.

        `loomd` without `--best-effort` already refuses to run a tool call under
        a degraded helper, so skipping this check would not run anything
        unconfined. It would, however, spend a model's tokens on a session
        whose every tool call is refused. The self-test is the same one `loom
        run` uses to label the run, run as the same user.
        """
        helper = shlex.quote(f"{self.options.install_dir}/server/bin/loom-exec")
        result = await environment.exec(command=f"{helper} --self-test 2>&1")
        output = f"{result.stdout or ''}{result.stderr or ''}"
        selftest = runreport.parse_self_test(result.return_code, output)
        if selftest.posture != "enforced":
            tail = "\n".join(output.strip().splitlines()[-25:])
            raise RuntimeError(
                f"jail=platform needs Loom's kernel jail, but its self-test in this "
                f"container is {selftest.posture} (enforced {selftest.enforced}, "
                f"skipped {selftest.skipped}, failed {selftest.failed}). Run the "
                "container with the flags docs/docker.md calls full isolation, or use "
                "jail=container to accept the container as the boundary.\n" + tail
            )
        return selftest

    async def _prepare_namespace_layer(self, environment: BaseEnvironment) -> str:
        """Find out whether bubblewrap works here, and degrade honestly if it cannot.

        Returns `absent`, `usable`, `unusable` or `disabled` (it was unusable
        and has been moved aside). Whatever it returns lands in the metadata,
        next to the label `loom run` measures afterwards.
        """
        probe = await environment.exec(command=scripts.bash_command(scripts.BWRAP_PROBE))
        state = (probe.stdout or "").strip().splitlines()[-1:] or [""]
        if state[0] not in ("absent", "usable", "unusable"):
            raise RuntimeError(f"bubblewrap probe gave an unexpected answer: {probe.stdout!r} {probe.stderr!r}")
        if state[0] != "unusable":
            return state[0]
        if self.options.bwrap == "keep":
            self.logger.warning(
                "bubblewrap is present but cannot create namespaces here and bwrap=keep: "
                "Loom's tool calls will fail. Use a container that permits user namespaces, "
                "or bwrap=auto."
            )
            return "unusable"
        self.logger.warning(
            "bubblewrap cannot create namespaces in this container; moving it aside so "
            "Loom runs degraded (the task container is the isolation boundary)"
        )
        await self.exec_as_root(environment, command=scripts.bash_command(scripts.BWRAP_DISABLE))
        return "disabled"

    @with_prompt_template
    @override
    async def run(
        self, instruction: str, environment: BaseEnvironment, context: AgentContext
    ) -> None:
        key_name, key_value = self.api_key()
        config_text = self.render_catalogue()
        if len(instruction.encode()) > MAX_INSTRUCTION_BYTES:
            raise ValueError(
                f"the instruction is {len(instruction.encode())} bytes; `loom run -p` takes it as one "
                f"argument and the kernel limits one argument to {MAX_INSTRUCTION_BYTES + 1072} bytes"
            )
        self._selftest: runreport.SelfTest | None = None
        self._bwrap: str | None = None
        if self.options.jail == "platform":
            self._selftest = await self._preflight_platform(environment)
        else:
            self._bwrap = await self._prepare_namespace_layer(environment)

        # The catalogue is provenance and holds no secret, so keep a copy beside the logs.
        self.logs_dir.mkdir(parents=True, exist_ok=True)
        (self.logs_dir / "loom.toml").write_text(config_text)

        await self._upload_config_text(
            environment, content=config_text, remote_path=REMOTE_CONFIG, filename="loom.toml"
        )
        await self._upload_config_text(
            environment, content=instruction, remote_path=REMOTE_PROMPT, filename="prompt.txt"
        )

        self._stdout = ""
        try:
            result = await self.exec_as_agent(
                environment,
                command=scripts.bash_command(scripts.RUN_SCRIPT),
                env=self.run_env(key_name, key_value),
                timeout_sec=self.options.timeout_sec + 300,
            )
            self._stdout = result.stdout or ""
        finally:
            await self._salvage(environment)

        self._raise_for_unusable_or_api_failure()

    async def _salvage(self, environment: BaseEnvironment) -> None:
        """Copy the session out and stop the daemon, even after a timeout.

        The run script does this itself when it finishes. This second pass is
        for when it did not: Harbor cancelled `run` at the task's agent
        timeout, so the script was cut off with the daemon still running and
        the database still in the state directory.
        """
        env: dict[str, str] = {"LOOM_OUT": str(self.environment_logs_dir)}
        if self.state_dir():
            env["LOOM_STATE_DIR"] = self.state_dir() or ""
        try:
            await environment.exec(
                command=scripts.bash_command(scripts.COLLECT_SCRIPT), env=env, timeout_sec=90
            )
        except Exception as exc:  # best effort; the evidence is a bonus, not the verdict
            self.logger.warning("could not collect the Loom session: %s", exc)

    def _raise_for_unusable_or_api_failure(self) -> None:
        """Turn the report into Harbor's error taxonomy where it applies.

        A model that failed the task is a result, not an error, so `failed`,
        `aborted` and `timeout` return normally and the verifier decides. Two
        things are errors: a report the adapter cannot read, and a `failed`
        run whose reason Harbor's own classifier recognises as a provider
        problem (rate limit, auth, overload), because those are what
        `--retry-include` exists for.
        """
        try:
            report = runreport.parse_run_output(self._stdout)
        except runreport.RunReportError as exc:
            raise NonZeroAgentExitCodeError(f"unusable loom run report: {exc}") from exc
        if report.outcome != "failed" or not report.reason:
            return
        classified = self._classify_exec_error(
            "loom run", SimpleNamespace(return_code=1, stdout=report.reason, stderr="")
        )
        if type(classified) is not NonZeroAgentExitCodeError:
            raise classified

    # ------------------------------------------------------------- after the run

    def _read_report(self) -> runreport.RunReport | None:
        """The report from the synced log, or from the run's own stdout."""
        candidates = []
        synced = self.logs_dir / "loom-run.json"
        if synced.is_file():
            candidates.append(synced.read_text())
        candidates.append(getattr(self, "_stdout", ""))
        for text in candidates:
            try:
                return runreport.parse_run_output(text)
            except runreport.RunReportError:
                continue
        return None

    def _session_database(self, report: runreport.RunReport | None) -> Path | None:
        directory = self.logs_dir / "loom-session"
        if report is not None:
            named = directory / f"{report.session_id}.db"
            if named.is_file():
                return named
        databases = sorted(directory.glob("*.db"), key=lambda path: path.stat().st_mtime)
        return databases[-1] if databases else None

    def jail_record(self, report: runreport.RunReport | None) -> dict[str, Any]:
        """The isolation posture, as requested and as Loom measured it."""
        record: dict[str, Any] = {
            "requested": self.options.jail,
            "loomd_flag": self.jail_flag() or None,
            "boundary": (
                "Harbor task container; Loom's kernel jail is best-effort inside it"
                if self.options.jail == "container"
                else "Loom kernel jail; the trial is refused unless every layer enforces"
            ),
        }
        if report is not None:
            record["label"] = report.jail.posture
            record["selftest_enforced"] = report.jail.enforced
            record["selftest_skipped"] = report.jail.skipped
            if report.jail.reason:
                record["selftest_reason"] = report.jail.reason
        preflight = getattr(self, "_selftest", None)
        if preflight is not None:
            record["preflight"] = preflight.posture
        if getattr(self, "_bwrap", None) is not None:
            record["bubblewrap"] = self._bwrap
        return record

    def _secrets(self) -> tuple[str, ...]:
        try:
            return (self.api_key()[1],)
        except ValueError:
            return ()

    @override
    def populate_context_post_run(self, context: AgentContext) -> None:
        report = self._read_report()
        metadata: dict[str, Any] = {"jail": self.jail_record(report), "release": self.release_tag() or "latest"}

        if report is not None:
            metadata.update(
                session_id=report.session_id,
                outcome=report.outcome,
                turns=report.turns,
                elapsed_ms=report.elapsed_ms,
            )
            if report.reason:
                metadata["reason"] = report.reason
            if report.model:
                metadata["model"] = report.model
            usage = report.usage
            if usage is not None:
                metadata["usage_evidence"] = {
                    "tokens": usage.token_coverage,
                    "cost": usage.cost_kind,
                }
                # Zeros from an unreported run are "unknown", not "none used".
                if usage.tokens_reported:
                    context.n_input_tokens = usage.prompt_tokens
                    context.n_cache_tokens = usage.cache_read
                    context.n_output_tokens = usage.output
                if usage.cost_reported:
                    context.cost_usd = usage.cost_total
        else:
            metadata["outcome"] = "no-report"

        written = self._write_trajectory(report, metadata)
        metadata["trajectory"] = "trajectory.json" if written else None
        context.metadata = {"loom": metadata}

    def _write_trajectory(
        self, report: runreport.RunReport | None, metadata: dict[str, Any]
    ) -> bool:
        database = self._session_database(report)
        if database is None:
            self.logger.warning("no Loom session database was synced; no trajectory written")
            return False
        run_summary = {
            key: metadata[key]
            for key in ("outcome", "turns", "elapsed_ms", "reason")
            if key in metadata
        }
        try:
            document = trajectory.from_session_db(
                database,
                session_id=report.session_id if report else database.stem,
                agent_version=self.version() or "unknown",
                model_name=self.model_name,
                secrets=self._secrets(),
                extra={"loom_run": run_summary},
                agent_extra={"jail": self.jail_record(report), "release": self.release_tag() or "latest"},
            )
        except (trajectory.SessionDatabaseError, OSError) as exc:
            self.logger.warning("could not convert the Loom session to ATIF: %s", exc)
            return False
        if document is None:
            self.logger.warning("the Loom session holds no conversation; no trajectory written")
            return False
        (self.logs_dir / "trajectory.json").write_text(
            json.dumps(document.to_json_dict(), indent=2, ensure_ascii=False)
        )
        return True
