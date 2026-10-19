#!/usr/bin/env python3
"""Check only Git-tracked publication files. Never read machine-local state."""
import pathlib
import re
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET

root = pathlib.Path(__file__).resolve().parents[1]
tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).split(b'\0')
paths = [pathlib.Path(p.decode()) for p in tracked if p]
if not paths:
    sys.exit('No tracked files; stage the intended publication files first.')

patterns = [
    ('API credential', re.compile(rb'\bsk-[A-Za-z0-9]{24,}\b')),
    ('GitHub credential', re.compile(rb'\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{24,}\b')),
    ('private home path', re.compile(b'/' + b'Users/' + rb'[^/\s]+/')),
]
failures = []
for relative in paths:
    parts = relative.parts
    name = relative.name
    if (parts[0] in {'.build', 'dist', '.venv', 'node_modules', 'models', 'private', 'recordings'}
            or parts[:2] == ('Tests', 'output') or name.startswith('.env')
            or '.yingshu' in name or relative.as_posix() == 'docs/验证记录.md'
            or relative.suffix.lower() in {'.pem', '.key', '.p12', '.pfx', '.safetensors', '.zip', '.dmg'}):
        failures.append((str(relative), 'machine-local or credential file'))
        continue
    data = (root / relative).read_bytes()
    for label, pattern in patterns:
        if pattern.search(data):
            failures.append((str(relative), label))
    if b'-----BEGIN ' + b'PRIVATE KEY-----' in data or b'-----BEGIN ' + b'RSA PRIVATE KEY-----' in data:
        failures.append((str(relative), 'private key material'))
    if relative.suffix == '.svg':
        try:
            ET.fromstring(data)
        except ET.ParseError:
            failures.append((str(relative), 'invalid SVG XML'))

# Validate local links in the main entry documents, including HTML img elements.
for relative in [pathlib.Path('README.md'), pathlib.Path('docs/项目介绍.md'), pathlib.Path('docs/开发与验证.md')]:
    source = root / relative
    if not source.exists():
        failures.append((str(relative), 'missing entry document'))
        continue
    content = source.read_text()
    links = re.findall(r'\]\(([^\s)]+)\)', content) + re.findall(r'(?:src|href)="([^"]+)"', content)
    for target in links:
        if urllib.parse.urlsplit(target).scheme or target.startswith('#'):
            continue
        target_path = urllib.parse.unquote(target.split('#', 1)[0])
        if target_path and not (source.parent / target_path).exists():
            failures.append((str(relative), 'broken local link: ' + target_path))

if failures:
    for filename, reason in failures:
        print(f'FAIL {filename}: {reason}')  # Never print matched credential values.
    sys.exit(1)
print(f'PASS {len(paths)} tracked files: publication boundaries, credential patterns, SVG XML and entry links')
