"""Keep compiler caches reusable without restoring prior test sessions."""
import io
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def compiled_cache_paths():
    """Read the scalar or literal-list paths from the real cache step."""
    lines = (ROOT / '.github/actions/setup-toolchain/action.yml').read_text().splitlines()
    step = lines.index('    - name: Cache compiled Gleam artifacts')
    path = next(i for i in range(step, len(lines))
                if lines[i].startswith('        path: '))
    value = lines[path].split(': ', 1)[1]
    if value != '|':
        return [value]
    paths = []
    for line in lines[path + 1:]:
        if not line.startswith('          '):
            break
        paths.append(line.strip())
    return paths


class CompiledCacheTest(unittest.TestCase):
    def test_archive_keeps_compiler_state_without_session_workspaces(self):
        compiler = {
            'packages/client/build/dev/erlang/loom_client/ebin/client.beam',
            'packages/client/build/prod/erlang/loom_client/ebin/client.beam',
            'packages/web_client/build/dev/javascript/loom_web_client/client.mjs',
            'packages/client/build/packages/gleam_stdlib/src/gleam/list.gleam',
            'packages/client/build/packages/packages.toml',
        }
        sessions = {
            'packages/client/build/tui-pair-123/session.db',
            'packages/runtime/build/test_db/session.db',
            'packages/client/build/shipped-remote-123/state/session.db',
            'packages/tui/build/erlang-shipment/erl',
        }
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for name in compiler | sessions:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(name)

            # Archive the configured roots recursively, as the cache action
            # does, rather than comparing their spelling with an allow-list.
            with tarfile.open(fileobj=io.BytesIO(), mode='w') as archive:
                for pattern in compiled_cache_paths():
                    for path in root.glob(pattern):
                        archive.add(path, arcname=str(path.relative_to(root)))
                names = set(archive.getnames())
            self.assertTrue(compiler <= names, compiler - names)
            self.assertFalse(sessions & names, sessions & names)


if __name__ == '__main__':
    unittest.main()
