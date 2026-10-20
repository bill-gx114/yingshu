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
# Keep this allowlist explicit. No checkout, user configuration or prepared model
# directory belongs in the download; the setup script prepares those on its own.
mkdir -p "$release_stage/安装支援"
cp scripts/prepare-local-ai.sh "$release_stage/安装支援/prepare-local-ai.sh"
cp Resources/ai_voice_worker.py "$release_stage/安装支援/ai_voice_worker.py"
cp scripts/release-onboarding/准备本地AI.command "$release_stage/准备本地AI.command"
cp scripts/release-onboarding/首次使用说明.txt "$release_stage/首次使用说明.txt"
chmod 755 "$release_stage/准备本地AI.command" "$release_stage/安装支援/prepare-local-ai.sh"
if ! cmp -s "$release_app/Contents/Resources/ai_voice_worker.py" "$release_stage/安装支援/ai_voice_worker.py"; then
    printf '%s\n' 'App 内的本地 AI worker 与安装支援版本不一致。请重新运行默认打包流程构建应用，不要使用 --no-build。' >&2
    exit 1
fi
xcrun strip -S "$release_app/Contents/MacOS/YingShu"
codesign --force --deep --sign - "$release_app"
codesign --verify --deep --strict "$release_app"
python3 - "$release_output" "$release_stage" <<'PY'
import hashlib, pathlib, sys, zipfile
output = pathlib.Path(sys.argv[1])
stage = pathlib.Path(sys.argv[2])
archive = output / 'YingShu-Mac.zip'
# zipfile writes Unicode names with the UTF-8 flag and preserves executable mode.
# Only the app and the three allowlisted onboarding items are included.
items = [stage / name for name in ('映述.app', '准备本地AI.command', '首次使用说明.txt', '安装支援')]
with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as contents:
    for item in items:
        contents.write(item, item.relative_to(stage))
        if item.is_dir():
            for path in sorted(item.rglob('*')):
                contents.write(path, path.relative_to(stage))
with zipfile.ZipFile(archive) as contents:
    assert not any(x.startswith('__MACOSX/') for x in contents.namelist()), 'Unexpected resource forks'
    assert {x.split('/')[0] for x in contents.namelist()} == {item.name for item in items}, 'Unexpected release items'
    assert {x for x in contents.namelist() if x.startswith('安装支援/')} == {
        '安装支援/', '安装支援/prepare-local-ai.sh', '安装支援/ai_voice_worker.py'
    }, 'Unexpected installer files'
    for name in ('准备本地AI.command', '安装支援/prepare-local-ai.sh'):
        assert contents.getinfo(name).external_attr >> 16 & 0o111, f'Not executable: {name}'
        assert contents.read(name) == (stage / name).read_bytes(), f'Installer differs: {name}'
    assert contents.read('安装支援/ai_voice_worker.py') == (stage / '安装支援/ai_voice_worker.py').read_bytes(), 'Worker differs'
    binary = contents.read('映述.app/Contents/MacOS/YingShu')
    assert b'/' + b'Users/' not in binary, 'Executable still contains a local build path'
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
(output / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
print(f'Release archive: {archive.name} ({archive.stat().st_size:,} bytes)')
print(f'SHA-256: {digest}')
PY
