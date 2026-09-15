#!/usr/bin/env python3
"""Compare cold Gleam cache builds at a fixed source path and timestamp."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', default='gleam')
parser.add_argument('--runs', type=int, default=12)
args = parser.parse_args()
compiler = shutil.which(args.compiler)
if compiler is None:
    parser.error('compiler executable was not found')
if args.runs < 2:
    parser.error('--runs must be at least 2')
root = Path(tempfile.mkdtemp(prefix='gleam-cache-repro-'))
fixtures = {
    'parameters': '''pub fn guard(when condition: Bool, return consequence: a,
      otherwise alternative: fn() -> a) -> a {
      case condition { True -> consequence False -> alternative() }
    }
''',
    'labels': '''pub type Thing { Thing(first: Int, second: Int, third: Int) }
    pub fn guard(value: Thing) -> Thing {
      case value { Thing(a, b, c) -> Thing(a, b, c) }
    }
''',
}
failed = False
print(subprocess.check_output([compiler, '--version'], text=True).strip())
print(f'Artifacts: {root}')
for name, source in fixtures.items():
    project = root / name
    (project / 'src' / 'gleam').mkdir(parents=True)
    (project / 'gleam.toml').write_text('name = "gleam_stdlib"\nversion = "1.0.0"\n')
    (project / 'src' / 'gleam' / 'bool.gleam').write_text(source)
    for path in project.rglob('*'):
        if path.is_file():
            os.utime(path, (1700000000, 1700000000))
    seen = {}
    for run in range(args.runs):
        shutil.rmtree(project / 'build', ignore_errors=True)
        result = subprocess.run([compiler, 'build'], cwd=project,
                                env=dict(os.environ, ERL_COMPILER_OPTIONS='[deterministic]'),
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(result.stdout)
        caches = list((project / 'build').rglob('gleam@bool.cache'))
        if len(caches) != 1:
            raise RuntimeError(f'Expected one bool cache, found {caches}')
        cache = caches[0].read_bytes()
        digest = hashlib.sha256(cache).hexdigest()
        seen[digest] = seen.get(digest, 0) + 1
        (project / f'cache-{run}.bin').write_bytes(cache)
    print(f'{name}: {len(seen)} distinct hashes in {args.runs} cold builds')
    for digest, count in sorted(seen.items()):
        print(f'  {digest} ({count} builds)')
    failed |= len(seen) != 1
raise SystemExit(1 if failed else 0)
