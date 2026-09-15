#!/usr/bin/env python3
"""Write canonical release archives and the updater's per-platform manifest.

Canonical packaging removes filesystem metadata from the artifact identity. It
cannot make different compiler/runtime inputs equivalent; reproducibility checks
must compare independent builds before claiming that stronger property.
"""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import tarfile


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], text=True).strip()


def archive(source, destination, stem, epoch):
    """Preserve file bytes and executable intent with stable tar/gzip metadata."""
    entries = [source, *sorted(source.rglob('*'), key=lambda p: p.relative_to(source).as_posix())]
    with destination.open('wb') as output:
        with gzip.GzipFile(filename='', mode='wb', fileobj=output, mtime=0, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as tar:
                for path in entries:
                    relative = path.relative_to(source)
                    name = stem if path == source else f'{stem}/{relative.as_posix()}'
                    info = tar.gettarinfo(str(path), arcname=name)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    info.mtime = epoch
                    info.pax_headers = {}
                    if info.isdir():
                        info.mode = 0o755
                    elif info.issym():
                        # Release assembly uses sibling executable aliases. Do not
                        # publish archive links which can redirect later writes.
                        target = PurePosixPath(info.linkname)
                        if target.is_absolute() or len(target.parts) != 1 or info.linkname in ('', '.', '..'):
                            raise ValueError(f'unsupported release symlink: {name}')
                        if not (path.parent / info.linkname).is_file() or (path.parent / info.linkname).is_symlink():
                            raise ValueError(f'release symlink does not name a regular sibling: {name}')
                        info.mode = 0o777
                    elif info.isreg() or info.islnk():
                        # Hard-link identity is build-machine metadata. Ship every
                        # regular file's bytes, even when the source shares inodes.
                        info.type = tarfile.REGTYPE
                        info.linkname = ''
                        info.size = path.stat().st_size
                        info.mode = 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644
                    else:
                        raise ValueError(f'unsupported release entry: {name}')
                    if info.isreg():
                        with path.open('rb') as contents:
                            tar.addfile(info, contents)
                    else:
                        tar.addfile(info)


def manifest(root, output, platform, version, epoch, artifacts):
    commit = git(root, 'rev-parse', 'HEAD')
    tag = os.environ.get('LOOM_RELEASE_TAG', f'commit-{commit}')
    if '/' in tag or '\\' in tag or not tag or any(ord(c) < 33 for c in tag):
        raise ValueError('LOOM_RELEASE_TAG must be a single printable tag')
    # Lockfiles and build scripts identify the recipe. The builder must also
    # preserve its toolchain inventory beside these inputs for reproduction.
    inputs = sorted({*root.glob('packages/*/manifest.toml'), *root.glob('packages/*/go.sum'),
                     *root.glob('packages/*/gleam.toml'), *root.glob('packages/*/go.mod'),
                     *root.glob('scripts/release*.sh'), *root.glob('scripts/release*.py'),
                     root / 'scripts/go-build.sh', root / 'scripts/platform.sh',
                     root / 'scripts/codemode_seed.sh', root / 'scripts/codemode-seed-manifest.toml',
                     root / 'scripts/dist.sh',
                     root / 'Makefile', root / 'packages/tui/priv/install.sh'})
    document = {
        'schema': 1, 'repository': 'Roasbeef/loom', 'tag': tag,
        'version': version, 'commit': commit, 'platform': platform,
        'source_date_epoch': epoch,
        'build_inputs': [{'name': p.relative_to(root).as_posix(), 'sha256': digest(p)} for p in inputs],
        'artifacts': sorted(artifacts, key=lambda artifact: artifact['component']),
    }
    inventory = root / 'build/release-inputs.json'
    if inventory.exists():
        document['toolchain'] = json.loads(inventory.read_text())
    else:
        document['toolchain'] = {'builder': 'unrecorded-development-build'}
    path = output / f'manifest-{platform}.json'
    path.write_text(json.dumps(document, sort_keys=True, indent=2) + '\n')
    sums = [f'{digest(p)}  {p.name}\n' for p in sorted(output.iterdir()) if p.is_file() and p.name != 'SHA256SUMS']
    (output / 'SHA256SUMS').write_text(''.join(sums))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--platform', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--server', type=Path, required=True)
    parser.add_argument('--client', type=Path, required=True)
    parser.add_argument('--slim', type=Path, required=True)
    args = parser.parse_args()
    if git(args.root, 'status', '--porcelain'):
        parser.error('release manifests require a clean committed source tree')
    epoch = int(os.environ.get('SOURCE_DATE_EPOCH', git(args.root, 'show', '-s', '--format=%ct', 'HEAD')))
    if not 0 <= epoch <= 0xffffffff:
        parser.error('SOURCE_DATE_EPOCH must fit an unsigned 32-bit timestamp')
    args.output.mkdir(parents=True, exist_ok=True)
    artifacts = []
    for component, source, stem in [
        ('server', args.server, f'loomd-{args.version}-{args.platform}'),
        ('client', args.client, f'loom-{args.version}-{args.platform}'),
        ('slim', args.slim, f'loom-slim-{args.version}-{args.platform}'),
    ]:
        destination = args.output / f'{stem}.tar.gz'
        archive(source, destination, stem, epoch)
        artifacts.append({'component': component, 'name': destination.name, 'root': stem,
                          'size': destination.stat().st_size, 'sha256': digest(destination)})
    manifest(args.root, args.output, args.platform, args.version, epoch, artifacts)


if __name__ == '__main__':
    main()
