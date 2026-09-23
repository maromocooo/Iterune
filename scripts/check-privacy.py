#!/usr/bin/env python3
"""Heuristic release check. Never prints matched secrets, only file paths and rule names."""
import argparse
import pathlib
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--directory', type=pathlib.Path, help='Check an exported tree instead of Git-tracked files')
args = parser.parse_args()
root = args.directory.resolve() if args.directory else pathlib.Path(__file__).resolve().parent.parent
if args.directory:
    paths = [p.relative_to(root) for p in root.rglob('*') if p.is_file()]
else:
    paths = [pathlib.Path(p.decode()) for p in subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).split(b'\0') if p]
rules = {
    'personal home path': re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'provider token': re.compile(rb'\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,})\b'),
    'personal email': re.compile(rb'[A-Za-z0-9._%+-]+@(?!example\.(?:com|org)\b|localhost\b|(?:[A-Za-z0-9.-]+\.)?noreply\.github\.com\b)[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    'local conversation id': re.compile(rb'codex resume [0-9a-f]{8}-[0-9a-f-]{27,}'),
}
forbidden_parts = {'.git', '.build', '.swiftpm', '.codex', '.agents', 'work', 'node_modules'}
failures = []
for relative in paths:
    if (root / relative).is_symlink() or set(relative.parts) & forbidden_parts or relative.name in {'auth.json', 'credentials.json', '.DS_Store'} or relative.name.startswith('.env') and relative.name != '.env.example' or relative.suffix in {'.sqlite', '.skillstudio', '.pem', '.p12', '.key'} or '.sqlite-' in relative.name:
        failures.append((str(relative), 'private/generated file')); continue
    data = (root / relative).read_bytes()
    for name, pattern in rules.items():
        if pattern.search(data): failures.append((str(relative), name))
for path, rule in failures:
    print(f'{path}: {rule}', file=sys.stderr)
print(f'Privacy check: {len(paths)} files, {len(failures)} findings. This heuristic does not inspect Git history or guarantee absence of personal data.')
sys.exit(bool(failures))
