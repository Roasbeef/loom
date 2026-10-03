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
    """Replace the reviewed pc link with its regular in-seed contents."""
    seed = Path(seed).resolve(strict=True)
    native = seed / 'build/dev/erlang/esqlite/_build'
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
