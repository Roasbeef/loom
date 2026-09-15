#!/usr/bin/env python3
"""Compare both native builds and stage only artifacts bound to this release."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil

spec = importlib.util.spec_from_file_location('release_compare', Path(__file__).with_name('release-compare.py'))
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)


def stage(candidates, destination, tag, commit):
    if not re.fullmatch('[0-9a-f]{40}', commit):
        raise ValueError('expected full commit hash')
    reports = {}
    selected = []
    for platform, prefix in [('linux-x86_64', 'release'), ('macos-arm64', 'release-macos')]:
        first = candidates / f'{prefix}-first'
        reports[platform] = compare.compare(first, candidates / f'{prefix}-second')
        manifest_name = f'manifest-{platform}.json'
        document = json.loads((first / manifest_name).read_text())
        for key, value in [('tag', tag), ('commit', commit), ('platform', platform), ('version', tag[1:])]:
            if document.get(key) != value:
                raise ValueError(f'{platform}: manifest {key} does not match requested release')
        names = [manifest_name, *(artifact['name'] for artifact in document['artifacts'])]
        if len(set(names)) != 4 or set(reports[platform]['artifacts']) != {*names, 'SHA256SUMS'}:
            raise ValueError('unexpected or duplicate release artifacts')
        selected.extend(first / name for name in names)
    if len({path.name for path in selected}) != len(selected):
        raise ValueError('release asset names collide across platforms')
    # Validate every input before creating the directory handed to gh release.
    destination.mkdir()
    for source in selected:
        shutil.copyfile(source, destination / source.name)
    (destination / 'reproduction.json').write_text(json.dumps(reports, indent=2, sort_keys=True) + '\n')
    sums = [f'{compare.digest(path)}  {path.name}\n' for path in sorted(destination.iterdir())]
    (destination / 'SHA256SUMS').write_text(''.join(sums))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidates', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--commit', required=True)
    args = parser.parse_args()
    try:
        stage(args.candidates, args.destination, args.tag, args.commit)
    except (ValueError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
