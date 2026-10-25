"""Turn Harbor's `provider/model` string into a minimal `loom.toml`.

Loom refuses to start a session without a model catalogue, and the catalogue
needs facts Harbor does not carry: the wire dialect, the variable that holds
the API key, and the model's context window. This module owns that mapping and
nothing else. It does no I/O, so the same inputs always render the same file.

Two rules shape it, both from `docs/configuration.md`:

* An API key is never written to the file. `api_key_env` names an environment
  variable that the daemon reads when it dispatches a request, so the adapter
  only has to put that variable in the daemon's environment.
* The decoder is strict: an unknown key, a wrong type or a dangling role name
  refuses the file. Everything rendered here is therefore a key the decoder
  documents, and `render_loom_toml` validates each value before it writes it
  so that a typo fails on the host rather than inside the container.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, replace

# The catalogue entry every trial uses. The name becomes part of the durable
# `{provider, model_id}` identity a session stores, so it is fixed and says
# where the run came from.
ENTRY_NAME = "harbor"

# Conservative figures for a model whose real ones the caller did not supply.
# `context_window` drives overflow detection, so a figure smaller than the
# truth only makes Loom compact earlier, while a larger one would let a
# request overflow. That is the direction worth erring in.
DEFAULT_CONTEXT_WINDOW = 200_000
DEFAULT_MAX_OUTPUT_TOKENS = 32_000

# Dialects the catalogue accepts that this adapter can drive with an API key.
# `codex-subscription` is excluded: it needs an interactive native sign-in.
DIALECTS = ("anthropic", "openai", "openai-responses", "gemini")

THINKING_LEVELS = ("off", "low", "medium", "high")

# Harbor's `reasoning_effort` vocabulary onto Loom's four levels. A word that
# is not here is refused, not guessed at.
_EFFORT_TO_THINKING = {
    "none": "off",
    "off": "off",
    "minimal": "low",
    "low": "low",
    "medium": "medium",
    "high": "high",
    "xhigh": "high",
    "max": "high",
}

# The providers Harbor names that Loom speaks natively. The tuple is the
# dialect and then the API-key variables in preference order.
_NATIVE_PROVIDERS = {
    "anthropic": ("anthropic", ("ANTHROPIC_API_KEY",)),
    "openai": ("openai-responses", ("OPENAI_API_KEY",)),
    "gemini": ("gemini", ("GEMINI_API_KEY", "GOOGLE_API_KEY")),
    "google": ("gemini", ("GEMINI_API_KEY", "GOOGLE_API_KEY")),
}

_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_ABSOLUTE_PATH = re.compile(r"^/[A-Za-z0-9._+@~/-]*$")


class CatalogueError(ValueError):
    """The model cannot be expressed as a Loom catalogue entry."""


@dataclass(frozen=True)
class Pricing:
    """Dollars per million tokens, the unit providers publish.

    `input` and `output` are required once a pricing table exists. The two
    cache rates are optional and default to `input` inside Loom, which can only
    over-report spend.
    """

    input: float
    output: float
    cache_read: float | None = None
    cache_write: float | None = None


@dataclass(frozen=True)
class ModelSpec:
    """Everything one `[models.harbor]` table needs."""

    provider: str
    model_id: str
    dialect: str
    api_key_envs: tuple[str, ...]
    base_url: str | None = None
    context_window: int = DEFAULT_CONTEXT_WINDOW
    max_output_tokens: int = DEFAULT_MAX_OUTPUT_TOKENS
    thinking: str = "off"
    pricing: Pricing | None = None
    # Which of `api_key_envs` the host actually set; filled in by the agent
    # once it has looked, because only the agent can see the environment.
    api_key_env: str = field(default="")


def split_model_name(model_name: str) -> tuple[str, str]:
    """Split Harbor's `provider/model` on the first slash only.

    A model id may itself contain slashes (`openrouter/anthropic/claude-x`),
    and Loom wants the id verbatim, so only the first segment is a provider.
    """
    provider, sep, model_id = model_name.partition("/")
    if not sep or not provider or not model_id:
        raise CatalogueError(
            f"model name {model_name!r} must be in the form provider/model "
            "(for example anthropic/claude-opus-4-5)"
        )
    return provider.lower(), model_id


def thinking_from_effort(effort: str | None) -> str:
    """Map Harbor's `reasoning_effort` onto Loom's `thinking` level."""
    if effort is None:
        return "off"
    try:
        return _EFFORT_TO_THINKING[effort.strip().lower()]
    except KeyError:
        known = ", ".join(sorted(_EFFORT_TO_THINKING))
        raise CatalogueError(
            f"reasoning_effort {effort!r} has no Loom equivalent; use one of: {known}"
        ) from None


def resolve_model(
    model_name: str,
    *,
    dialect: str | None = None,
    api_key_env: str | None = None,
    base_url: str | None = None,
    context_window: int | None = None,
    max_output_tokens: int | None = None,
    reasoning_effort: str | None = None,
    openai_api: str = "responses",
    pricing: Pricing | None = None,
) -> ModelSpec:
    """Choose the dialect, key variable and limits for a Harbor model name.

    The native providers (`anthropic`, `openai`, `gemini`) need nothing else.
    Any other provider is an OpenAI-compatible endpoint Loom has no built-in
    address for, so the caller must name `base_url`; the adapter will not
    invent one, because a wrong guess sends the bearer key to the wrong host.
    """
    provider, model_id = split_model_name(model_name)
    native = _NATIVE_PROVIDERS.get(provider)

    if dialect is not None and dialect not in DIALECTS:
        raise CatalogueError(
            f"dialect {dialect!r} is not one the adapter can drive; "
            f"use one of: {', '.join(DIALECTS)}"
        )
    if openai_api not in ("responses", "chat"):
        raise CatalogueError("openai_api must be 'responses' or 'chat'")

    if native is not None:
        chosen, key_envs = native
        if provider == "openai" and openai_api == "chat":
            chosen = "openai"
        chosen = dialect or chosen
    else:
        if base_url is None:
            raise CatalogueError(
                f"provider {provider!r} is not one Loom speaks natively; pass "
                "base_url (an OpenAI-compatible endpoint root) and, if the key "
                f"is not {provider.upper().replace('-', '_')}_API_KEY, api_key_env"
            )
        chosen = dialect or "openai"
        key_envs = (f"{provider.upper().replace('-', '_')}_API_KEY",)

    if api_key_env is not None:
        key_envs = (api_key_env,)
    for name in key_envs:
        if not _ENV_NAME.match(name):
            raise CatalogueError(f"api key variable name {name!r} is not valid")

    window = DEFAULT_CONTEXT_WINDOW if context_window is None else context_window
    ceiling = DEFAULT_MAX_OUTPUT_TOKENS if max_output_tokens is None else max_output_tokens
    for label, value in (("context_window", window), ("max_output_tokens", ceiling)):
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise CatalogueError(f"{label} must be a positive integer")

    return ModelSpec(
        provider=provider,
        model_id=model_id,
        dialect=chosen,
        api_key_envs=key_envs,
        base_url=base_url.rstrip("/") if base_url else None,
        context_window=window,
        max_output_tokens=ceiling,
        thinking=thinking_from_effort(reasoning_effort),
        pricing=pricing,
    )


def with_api_key_env(spec: ModelSpec, chosen: str) -> ModelSpec:
    """Record which candidate key variable the host had set."""
    if chosen not in spec.api_key_envs:
        raise CatalogueError(f"{chosen} is not a candidate key variable for {spec.provider}")
    return replace(spec, api_key_env=chosen)


def _string(value: str) -> str:
    """A TOML basic string. JSON escaping is a valid subset of TOML's."""
    return json.dumps(value)


def _number(value: float) -> str:
    if value < 0 or value != value or value in (float("inf"), float("-inf")):
        raise CatalogueError(f"price {value!r} must be a finite number of zero or more")
    return repr(float(value))


def render_loom_toml(
    spec: ModelSpec,
    *,
    network: str = "full",
    rw_mounts: tuple[str, ...] = (),
) -> str:
    """Render the whole catalogue for one trial.

    `network` and `rw_mounts` are the two workspace facts a Terminal-Bench task
    most often needs changed. A task that installs packages needs `full`
    network, which is also Loom's default; a task whose solution lives outside
    the working directory needs a writable mount, because Loom's jail
    otherwise confines writes to the workspace.
    """
    if not spec.api_key_env:
        raise CatalogueError("no API key variable was selected for the model")
    if network not in ("full", "off"):
        raise CatalogueError("network must be 'full' or 'off'")
    for path in rw_mounts:
        if path == "/" or not _ABSOLUTE_PATH.match(path) or ".." in path.split("/"):
            raise CatalogueError(
                f"writable mount {path!r} must be an absolute path without '..' "
                "and may not be the filesystem root"
            )

    lines = [
        "# Generated by loom_harbor for one Harbor trial. It names the variable",
        "# that holds the API key; it never contains the key itself.",
        "",
        f"[models.{ENTRY_NAME}]",
        f"dialect = {_string(spec.dialect)}",
    ]
    if spec.dialect == "openai-responses":
        # Responses requires an explicit authentication selection.
        lines.append('auth = "api-key"')
    if spec.base_url:
        lines.append(f"base_url = {_string(spec.base_url)}")
    lines += [
        f"api_key_env = {_string(spec.api_key_env)}",
        f"model_id = {_string(spec.model_id)}",
        f"context_window = {spec.context_window}",
        f"max_output_tokens = {spec.max_output_tokens}",
        f"thinking = {_string(spec.thinking)}",
    ]

    if spec.pricing is not None:
        lines += ["", f"[models.{ENTRY_NAME}.pricing]"]
        lines.append(f"input = {_number(spec.pricing.input)}")
        lines.append(f"output = {_number(spec.pricing.output)}")
        if spec.pricing.cache_read is not None:
            lines.append(f"cache_read = {_number(spec.pricing.cache_read)}")
        if spec.pricing.cache_write is not None:
            lines.append(f"cache_write = {_number(spec.pricing.cache_write)}")

    lines += ["", "[roles]", f"main = [{_string(ENTRY_NAME)}]", "", "[tools]"]
    lines.append(f"network = {_string(network)}")

    if rw_mounts:
        lines += ["", "[workspace]", "mounts = ["]
        lines += [f"  {{ path = {_string(path)}, access = \"rw\" }}," for path in rw_mounts]
        lines.append("]")

    return "\n".join(lines) + "\n"
