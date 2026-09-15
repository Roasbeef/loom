#!/usr/bin/env python3
"""Require identical complete release artifacts from two independent builders."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import sys
import tarfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def members(path):
    result = {}
    with tarfile.open(path, 'r:gz') as archive:
        for item in archive:
            stream = archive.extractfile(item) if item.isfile() else None
            result[item.name] = (item.type.decode(), item.mode, item.uid, item.gid,
                                 item.mtime, item.linkname,
                                 hashlib.file_digest(stream, 'sha256').hexdigest() if stream else '')
    return result


def validate_candidate(directory, files):
    manifests = [path for name, path in files.items()
                 if name.startswith('manifest-') and name.endswith('.json')]
    if not manifests:
        raise ValueError('builder supplied no release manifest')
    for path in manifests:
        document = json.loads(path.read_text())
        if document.get('schema') != 1 or document.get('repository') != 'Roasbeef/loom':
            raise ValueError('builder supplied an invalid release manifest')
        if not re.fullmatch('[0-9a-f]{40}', document.get('commit', '')):
            raise ValueError('release manifest lacks a full source commit')
        artifacts = document.get('artifacts', [])
        if len(artifacts) != 3 or {a.get('component') for a in artifacts} != {'server', 'client', 'slim'}:
            raise ValueError('release manifest must bind server, client and slim artifacts')
        for artifact in artifacts:
            name = artifact.get('name', '')
            if name not in files or Path(name).name != name:
                raise ValueError('release artifact is missing from builder output')
            archive = directory / name
            if archive.stat().st_size != artifact.get('size') or digest(archive) != artifact.get('sha256'):
                raise ValueError('release artifact does not match its manifest')


def compare(left, right):
    left_files = {path.name: path for path in left.iterdir() if path.is_file()}
    right_files = {path.name: path for path in right.iterdir() if path.is_file()}
    if left_files.keys() != right_files.keys():
        raise ValueError('builders produced different artifact sets')
    validate_candidate(left, left_files)
    validate_candidate(right, right_files)
    different = []
    for name in sorted(left_files):
        if digest(left_files[name]) == digest(right_files[name]):
            continue
        different.append(name)
        print(f'DIFF {name}', file=sys.stderr)
        if name.endswith('.tar.gz'):
            first, second = members(left_files[name]), members(right_files[name])
            for entry in sorted(first.keys() | second.keys()):
                if first.get(entry) != second.get(entry):
                    print(f'  {entry}', file=sys.stderr)
    if different:
        raise ValueError(f'{len(different)} artifacts differ; no reproducibility attestation produced')
    return {'result': 'identical', 'artifacts': {name: digest(left_files[name]) for name in sorted(left_files)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first', type=Path)
    parser.add_argument('second', type=Path)
    args = parser.parse_args()
    try:
        print(json.dumps(compare(args.first, args.second), indent=2, sort_keys=True))
    except (ValueError, OSError, tarfile.TarError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
