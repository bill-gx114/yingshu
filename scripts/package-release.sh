#!/bin/bash
# Package a distributable copy; never modify an installed or running application.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" != "--no-build" ]]; then bash scripts/build-app.sh; fi
release_stage="$(mktemp -d /tmp/yingshu-release.XXXXXX)"
trap 'rm -rf "$release_stage"' EXIT
release_app="$release_stage/映述.app"
release_output="$(pwd)/dist/release"
mkdir -p "$release_output"
ditto --norsrc --noextattr --noqtn "dist/映述.app" "$release_app"
xcrun strip -S "$release_app/Contents/MacOS/YingShu"
codesign --force --deep --sign - "$release_app"
codesign --verify --deep --strict "$release_app"
python3 - "$release_output" "$release_app" <<'PY'
import hashlib, pathlib, sys, zipfile
output = pathlib.Path(sys.argv[1])
app = pathlib.Path(sys.argv[2])
archive = output / '映述-Mac.zip'
# zipfile writes Unicode names with the UTF-8 flag and preserves executable mode.
# Only the curated app tree is included, without Finder resource forks or xattrs.
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as contents:
    for path in sorted(app.rglob('*')):
        contents.write(path, pathlib.Path(app.name) / path.relative_to(app))
with zipfile.ZipFile(archive) as contents:
    assert not any(x.startswith('__MACOSX/') for x in contents.namelist()), 'Unexpected resource forks'
    binary = contents.read('映述.app/Contents/MacOS/YingShu')
    assert b'/' + b'Users/' not in binary, 'Executable still contains a local build path'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
print(f'Release archive: {archive.name} ({archive.stat().st_size:,} bytes)')
print(f'SHA-256: {digest}')
PY
