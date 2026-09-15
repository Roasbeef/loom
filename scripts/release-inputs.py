#!/usr/bin/env python3
"""Record the immutable builder identity and the actual tool bytes it used."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def output(*command):
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT).strip()


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def tree_digest(root):
    digest = hashlib.sha256()
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root).as_posix().encode()
        if path.is_symlink():
            value = b'link:' + os.readlink(path).encode()
        elif path.is_file():
            value = sha(path).encode()
        else:
            continue
        digest.update(relative + b'\0' + value + b'\0')
    return digest.hexdigest()


record = {'builder': os.environ['LOOM_BUILDER_ID'], 'source_prefix': str(Path.cwd().resolve()), 'tools': {}}
for name, arguments in [('gleam', ['--version']), ('rebar3', ['--version']), ('go', ['version']),
                        ('cc', ['--version']), ('python3', ['--version'])]:
    path = Path(shutil.which(name) or name).resolve(strict=True)
    record['tools'][name] = {'version': output(str(path), *arguments), 'sha256': sha(path)}
otp = Path(output('erl', '-noshell', '-eval', 'io:format("~s", [code:root_dir()]), halt().'))
golang = Path(output('go', 'env', 'GOROOT'))
record['tools']['otp_tree'] = {'sha256': tree_digest(otp)}
record['tools']['go_tree'] = {'sha256': tree_digest(golang)}
print(json.dumps(record, sort_keys=True, indent=2))
