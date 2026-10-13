"""Keep Rebar's known native build plugin inside the relocatable seed.

Rebar links its production pc plugin to an absolute default-profile directory.
The seed crosses machines and jail roots, so that build-machine path cannot be
part of its runtime contract. Copy only this known in-seed plugin; unknown links
remain subject to the release archiver's existing refusal policy.
"""

from pathlib import Path
import shutil
import sys
import tempfile


def materialize(seed):
    """Make the native seed relocatable and reproducible."""
    seed = Path(seed).resolve(strict=True)
    native = seed / 'build/dev/erlang/esqlite/_build'
    drop_compile_caches(native)
    materialize_plugin(native)


def drop_compile_caches(native):
    """Remove rebar3's incremental-compile graphs from the native build.

    Rebar records absolute source paths and wall-clock modification times in
    each `.rebar3/rebar_compiler_erl/*.dag`, so two builds of identical sources
    never agree on those bytes. They only let a later rebar3 run skip work, and
    a code-mode build never runs rebar3 here: Gleam finds the compiled package
    already in place. A missing graph means a full recompile, which is correct.
    """
    for cache in native.glob('*/*/.rebar3/rebar_compiler_erl'):
        shutil.rmtree(cache)


def materialize_plugin(native):
    """Replace the reviewed pc link with its regular in-seed contents."""
    plugin = native / 'prod/plugins/pc'
    if not plugin.is_symlink():
        return

    target = native / 'default/plugins/pc'
    if (not target.is_dir() or target.resolve(strict=True) != target
            or plugin.resolve(strict=True) != target):
        raise ValueError('codemode seed: pc must name its regular in-seed default plugin')
    if any(path.is_symlink() for path in target.rglob('*')):
        raise ValueError('codemode seed: the pc plugin must contain only regular paths')

    # Finish copying before changing the link, preserving bytes, modes and times.
    # The seed is still under construction; no ready seed has been published.
    with tempfile.TemporaryDirectory(prefix='.pc-copy-', dir=plugin.parent) as temporary:
        copied = Path(temporary) / 'pc'
        shutil.copytree(target, copied)
        plugin.unlink()
        copied.rename(plugin)


if __name__ == '__main__':
    materialize(sys.argv[1])
