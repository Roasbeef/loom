#!/usr/bin/env python3
"""Validate a release and, with --push, atomically push main and its new tag."""
import argparse
from pathlib import Path
import re
import shlex
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parent.parent


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def validate_tag(tag):
    if not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(?:alpha|beta|rc)\.[1-9][0-9]*)?', tag):
        raise ValueError('expected vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N (also alpha/beta)')
    for package in ('client', 'tui'):
        version = tomllib.loads((ROOT / f'packages/{package}/gleam.toml').read_text())['version']
        if version != tag[1:]:
            raise ValueError(f'{package} version {version} must match {tag[1:]} before tagging')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--remote', default='origin')
    parser.add_argument('--push', action='store_true', help='create the annotated tag and push; default only prints the plan')
    parser.add_argument('--check', action='store_true', help='only validate tag/version agreement (used by CI)')
    args = parser.parse_args()
    try:
        validate_tag(args.tag)
        if args.check:
            return
        if args.remote.startswith('-'):
            raise ValueError('remote must not start with a dash')
        if git('status', '--porcelain'):
            raise ValueError('release requires a clean committed checkout')
        if git('tag', '--list', args.tag):
            raise ValueError('tag already exists locally; do not move release tags')
        commit = git('rev-parse', 'HEAD')
        commands = [
            ['git', 'tag', '-a', args.tag, commit, '-m', f'Loom {args.tag}'],
            ['git', 'push', '--atomic', args.remote, f'{commit}:refs/heads/main', f'refs/tags/{args.tag}'],
        ]
        print(f'Release {args.tag} from {commit}; CI builds both platforms and creates a draft.', flush=True)
        for command in commands:
            print(shlex.join(command), flush=True)
        if not args.push:
            print('Preview only. Pass --push to execute.')
            return
        # Fetch the actual branch before checking ancestry; an atomic push also
        # rejects a concurrent main advance without publishing a stranded tag.
        git('fetch', '--no-tags', args.remote, 'refs/heads/main')
        git('merge-base', '--is-ancestor', 'FETCH_HEAD', commit)
        if git('ls-remote', '--tags', args.remote, f'refs/tags/{args.tag}'):
            raise ValueError('tag already exists remotely; do not move release tags')
        for command in commands:
            subprocess.run(command, cwd=ROOT, check=True)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'release-tag: {error}\n')


if __name__ == '__main__':
    main()
