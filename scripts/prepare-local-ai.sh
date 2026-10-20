#!/bin/bash
# Explicit first-run setup. No system Python, pip, Git, Homebrew, or compiler required.
set -euo pipefail
umask 077

stage="启动准备器"
log_file=""
lock_owned=0
lock_dir=""
finish() {
  local result="$?"
  if [[ "$lock_owned" == 1 ]]; then
    /bin/unlink "$lock_dir/pid" 2>/dev/null || true
    /bin/rmdir "$lock_dir" 2>/dev/null || true
  fi
  if [[ "$result" != 0 ]]; then
    printf '\n本地 AI 尚未准备完成（阶段：%s，退出码：%s）。\n' "$stage" "$result" >&2
    printf '已完成的下载会保留；确认网络与空间后，重新运行同一个准备器即可。\n' >&2
    if [[ -n "$log_file" ]]; then printf '准备日志：%s\n' "$log_file" >&2; fi
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
fail() { printf '\n%s\n' "$*" >&2; exit 1; }

stage="检查 Mac"
printf '\n映述 · 本地 AI 首次准备\n模型约 1.89 GB，另需运行环境、下载缓存和解压空间。\n公开下载来源：GitHub / PyPI / Hugging Face（含其文件分发服务）。\n不需要 API Key、管理员密码，也不会读取你的照片、项目或录音。\n\n[1/5] 检查 Mac 与可用空间\n'
[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail "此准备器仅适用于 Apple Silicon Mac。"
[[ "$(/usr/bin/uname -m)" == arm64 ]] || fail "需要以原生模式运行的 Apple Silicon Mac。Intel Mac 不支持；若使用 Rosetta 终端，请换用未勾选‘使用 Rosetta 打开’的终端再试。"
macos_version="$(/usr/bin/sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
[[ "$macos_major" =~ ^[0-9]+$ ]] && [[ "$macos_major" -ge 14 ]] || fail "需要 macOS 14 或更新系统，当前为 ${macos_version}。"
[[ "$(/usr/bin/id -u)" != 0 ]] || fail "请用自己的普通 Mac 账户双击准备器，不要使用 sudo 或 root。"

script_dir="$(cd "$(dirname "$0")" && pwd)"
worker_path="$script_dir/ai_voice_worker.py"
if [[ ! -f "$worker_path" ]]; then worker_path="$script_dir/../Resources/ai_voice_worker.py"; fi
[[ -f "$worker_path" ]] || fail "缺少安装支援/ai_voice_worker.py。请重新解压完整下载包，保留‘安装支援’文件夹后重试。"
runtime_dir="${YINGSHU_AI_RUNTIME_DIR:-$HOME/Library/Application Support/YingShu/AI Runtime}"
if [[ -n "${YINGSHU_AI_RUNTIME_DIR:-}" ]]; then
  printf '验证用自定义目录：%s（正式应用只识别标准 Application Support 目录）。\n' "$runtime_dir"
fi
mkdir -p "$runtime_dir/setup-logs" || fail "无法写入本机 AI 目录，请使用自己的普通 Mac 账户运行。"
log_file="$runtime_dir/setup-logs/prepare-$(/bin/date -u +%Y%m%d-%H%M%S)-$$.log"
exec > >(/usr/bin/tee -a "$log_file") 2>&1
printf '安装目录：%s\n日志：%s\n' "$runtime_dir" "$log_file"
lock_dir="$runtime_dir/.setup.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  old_pid="$(/bin/cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    fail "已有一个本地 AI 准备任务正在运行，请等待它完成，不要同时启动两个准备器。"
  fi
  # Only the lock's PID file and empty directory are removed; no recursive deletion.
  /bin/unlink "$lock_dir/pid" 2>/dev/null || true
  /bin/rmdir "$lock_dir" 2>/dev/null || fail "上次准备锁无法清理，请查看安装目录的 .setup.lock。"
  mkdir "$lock_dir" || fail "无法取得准备锁，请稍后重试。"
fi
lock_owned=1
printf '%s\n' "$$" > "$lock_dir/pid"
free_kb="$(/bin/df -Pk "$runtime_dir" | /usr/bin/awk 'END {print $4}')"
[[ "$free_kb" =~ ^[0-9]+$ ]] && [[ "$free_kb" -ge 6291456 ]] || fail "请先为准备过程留出至少 6 GB 可用磁盘空间（包括运行环境、缓存与解压，并非模型本体大小）。"

# Do not inherit custom package indexes, system Python state, or account credentials.
for setup_variable in $(compgen -v UV_); do unset "$setup_variable"; done
unset PYTHONPATH PYTHONHOME PYTHONUSERBASE PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_TRUSTED_HOST PIP_CONFIG_FILE
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN HF_ENDPOINT HF_HUB_OFFLINE TRANSFORMERS_OFFLINE
export UV_NO_CONFIG=1 UV_PYTHON_PREFERENCE=only-managed UV_PYTHON_DOWNLOADS=automatic
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_HUB_DISABLE_TELEMETRY=1
export HF_HOME="$runtime_dir/download-cache/huggingface"
export UV_CACHE_DIR="$runtime_dir/download-cache/uv"
export UV_PYTHON_INSTALL_DIR="$runtime_dir/python"

stage="准备独立 Python 运行环境"
printf '\n[2/5] 准备独立运行环境（不会修改系统 Python 或其他项目）\n'
uv_version=0.13.1
uv_archive_sha=cfe454573412ff7380d15fc7dae5997ab53ffce72fce0a78e91ddbc84001acd2
uv_archive="$runtime_dir/download-cache/uv-aarch64-apple-darwin-$uv_version.tar.gz"
mkdir -p "$runtime_dir/download-cache" "$runtime_dir/bootstrap/uv-$uv_version"
archive_matches() {
  [[ -f "$1" ]] && [[ "$(/usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}')" == "$uv_archive_sha" ]]
}
if ! archive_matches "$uv_archive"; then
  printf '下载官方 uv %s（约 14 MB），完成后核对固定 SHA-256。\n' "$uv_version"
  pending_archive="$uv_archive.pending-$$"
  if ! /usr/bin/curl --disable --proto '=https' --tlsv1.2 --fail --location --retry 2 --connect-timeout 20 --max-time 900 \
      --output "$pending_archive" "https://releases.astral.sh/github/uv/releases/download/$uv_version/uv-aarch64-apple-darwin.tar.gz"; then
    printf '官方分发地址暂时无法连接，改用同一版本的官方 GitHub 下载地址。\n'
    /usr/bin/curl --disable --proto '=https' --tlsv1.2 --fail --location --retry 2 --connect-timeout 20 --max-time 900 \
      --output "$pending_archive" "https://github.com/astral-sh/uv/releases/download/$uv_version/uv-aarch64-apple-darwin.tar.gz"
  fi
  archive_matches "$pending_archive" || fail "uv 下载校验失败，未运行下载内容。请检查网络后重新运行准备器。"
  /bin/mv "$pending_archive" "$uv_archive"
else
  printf '复用已校验的 uv 下载。\n'
fi
bootstrap_stage="$runtime_dir/bootstrap/extract-$$"
mkdir -p "$bootstrap_stage"
/usr/bin/tar -xzf "$uv_archive" -C "$bootstrap_stage" uv-aarch64-apple-darwin/uv
uv_bin="$runtime_dir/bootstrap/uv-$uv_version/uv"
/bin/mv "$bootstrap_stage/uv-aarch64-apple-darwin/uv" "$uv_bin"
/bin/rmdir "$bootstrap_stage/uv-aarch64-apple-darwin" "$bootstrap_stage"
[[ "$("$uv_bin" --version)" == "uv $uv_version"* ]] || fail "独立安装工具版本不符，请重新运行准备器。"
"$uv_bin" python install --no-bin 3.12.14
python_base="$runtime_dir/python/cpython-3.12.14-macos-aarch64-none/bin/python3.12"
[[ -x "$python_base" ]] || fail "独立 Python 尚未准备完整，请重新运行。"
"$python_base" -I -B -c 'import platform,sys; assert sys.version_info[:3] == (3,12,14) and platform.machine() == "arm64", "Python版本或架构不符"'

stage="安装固定版本的本地 AI 依赖"
printf '\n[3/5] 安装固定版本的 AI 依赖（仅使用预编译包，不调用本机编译器）\n'
cat > "$runtime_dir/requirements.pinned.txt" <<'REQUIREMENTS'
annotated-doc==0.0.5
anyio==4.15.1
cffi==2.1.1
click==8.5.0
filelock==4.2.2
fsspec==2026.9.0
h11==0.16.0
hf-xet==1.7.0
httpcore2==2.14.0
httpx2==2.14.0
huggingface-hub==2.2.0
idna==3.20
jinja2==3.1.6
markdown-it-py==4.2.0
markupsafe==3.0.4
mdurl==0.1.2
miniaudio==1.71
mlx==0.32.4
mlx-audio==0.5.9
mlx-lm==0.32.2
mlx-metal==0.32.4
numpy==2.5.4
packaging==26.3
protobuf==7.36.2
pycparser==3.11
pygments==2.21.0
pyyaml==6.0.3
regex==2026.9.29
rich==15.0.0
safetensors==0.8.0
scipy==1.18.1
sentencepiece==0.2.1
shellingham==1.5.4
sounddevice==0.5.6
soundfile==0.13.1
tokenizers==0.23.3
tqdm==4.70.1
transformers==5.20.1
truststore==0.10.5
typer==0.27.3
typing-extensions==4.16.0
REQUIREMENTS
requirements_sha="$(/usr/bin/shasum -a 256 "$runtime_dir/requirements.pinned.txt" | /usr/bin/awk '{print $1}')"
environment_base="$runtime_dir/environments/qwen-v1-py3.12.14-${requirements_sha:0:12}"
cached_environment="$("$python_base" -I -B - "$runtime_dir" "$environment_base" "$requirements_sha" <<'PY_ENV'
import json, pathlib, sys
root, base, expected = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
try:
    previous = json.loads((root / "manifest.json").read_text())
    candidate = pathlib.Path(previous["python_path"]).parent.parent.resolve()
    if (candidate.parent == (root / "environments").resolve()
            and candidate.name.startswith(base.name + "-attempt-")
            and (candidate / ".prepared-requirements").read_text().strip() == expected):
        print(candidate)
except (OSError, ValueError, KeyError, TypeError):
    pass
PY_ENV
)"
environment_dir="${cached_environment:-$environment_base}"
python_bin="$environment_dir/bin/python"
if [[ -x "$python_bin" && -f "$environment_dir/.prepared-requirements" ]] && \
   [[ "$(/bin/cat "$environment_dir/.prepared-requirements")" == "$requirements_sha" ]] && \
   "$uv_bin" pip check --python "$python_bin" && \
   "$python_bin" -I -B -c 'import platform,sys,importlib.metadata; from pathlib import Path; import mlx.core,mlx_audio,mlx_lm,huggingface_hub; assert sys.version_info[:3] == (3,12,14) and platform.machine() == "arm64"; assert all(importlib.metadata.version(n)==v for n,v in (row.split("==") for row in Path(sys.argv[1]).read_text().splitlines() if row.strip()))' "$runtime_dir/requirements.pinned.txt"; then
  printf '复用已验证的独立 AI 环境。\n'
else
  # Never repair an active environment in place. The old manifest remains usable
  # until the new environment and both real models have passed their offline probe.
  environment_dir="$environment_base-attempt-$(/bin/date -u +%Y%m%d-%H%M%S)-$$"
  "$uv_bin" venv --python "$python_base" "$environment_dir"
  python_bin="$environment_dir/bin/python"
  "$uv_bin" pip install --python "$python_bin" --index-url https://pypi.org/simple --only-binary :all: \
    -r "$runtime_dir/requirements.pinned.txt"
  "$uv_bin" pip check --python "$python_bin"
  "$python_bin" -I -B -c 'import platform,sys; import mlx.core,mlx_audio,mlx_lm,huggingface_hub; assert sys.version_info[:3] == (3,12,14) and platform.machine() == "arm64"'
fi
"$uv_bin" pip freeze --python "$python_bin" > "$environment_dir/requirements.lock"

stage="下载校验模型与离线启动检查"
printf '\n[4/5] 下载并校验语音与文字模型（合计约 1.89 GB）\n文件下载可能等待较久，可看当前文件与下载进度；中断后重新运行会复用已完成文件。\n'
"$python_bin" -I -B - "$runtime_dir" "$python_bin" "$worker_path" "$environment_dir" "$requirements_sha" <<'PY_SETUP'
import hashlib, importlib.metadata, json, os, pathlib, platform, selectors, subprocess, sys, time, uuid
from huggingface_hub import HfApi, hf_hub_download

root = pathlib.Path(sys.argv[1]).expanduser().resolve()
python_path, worker_path, environment_dir, requirements_sha = sys.argv[2:]
specs = {
    "asr": ("mlx-community/Qwen3-ASR-0.6B-8bit", "89e96d92ba34aca20b3e29fb10cc284097d1219f"),
    "cleanup": ("mlx-community/Qwen2.5-1.5B-Instruct-4bit", "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"),
}
manifest = {"schema_version": 1, "python_path": python_path,
            "python_version": platform.python_version(), "prepared_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "versions": {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()},
            "models": {}, "offline": True}
api = HfApi(endpoint="https://huggingface.co", token=False)

def hashes(path):
    sha = hashlib.sha256()
    git_hash = hashlib.sha1(f"blob {path.stat().st_size}\0".encode())
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            sha.update(block); git_hash.update(block)
    return sha.hexdigest(), git_hash.hexdigest()

def verified(entry, digest):
    lfs = entry.lfs
    expected = (lfs.get("sha256") if isinstance(lfs, dict) else getattr(lfs, "sha256", None)) if lfs else None
    return digest[0] == expected if expected else digest[1] == entry.blob_id

for role, (model_id, revision) in specs.items():
    info = api.model_info(model_id, revision=revision, files_metadata=True, token=False)
    if info.sha != revision or (info.card_data or {}).get("license") != "apache-2.0":
        raise RuntimeError(f"{role}: 模型版本或许可核验失败，未启用此模型。")
    files = [x for x in info.siblings if x.rfilename in {"README.md", "LICENSE", "LICENSE.txt"}
             or x.rfilename.endswith((".json", ".txt", ".safetensors"))]
    if any("/" in x.rfilename or x.rfilename.endswith(".py") for x in files):
        raise RuntimeError(f"{role}: 模型文件清单不符合预期。")
    if sum(x.size or 0 for x in files) > 1_500_000_000:
        raise RuntimeError(f"{role}: 模型大小超过每组 1.5 GB 的准备上限。")
    dest = root / "models" / model_id.replace("/", "--") / revision
    dest.mkdir(parents=True, exist_ok=True)
    records = []
    print(f"\n{'语音识别' if role == 'asr' else '文字整理'}：{model_id}", flush=True)
    for index, entry in enumerate(files, 1):
        target = dest / entry.rfilename
        print(f"  {index}/{len(files)}  {entry.rfilename}  ({(entry.size or 0) / 1_000_000:.1f} MB)", flush=True)
        digest = hashes(target) if target.is_file() else None
        if digest and not verified(entry, digest):
            # Keep the exact corrupt file for diagnosis; replace only this app-owned model entry.
            target.rename(target.with_name(target.name + ".invalid-" + uuid.uuid4().hex[:8]))
            digest = None
        if digest is None:
            hf_hub_download(model_id, entry.rfilename, revision=revision, token=False,
                            endpoint="https://huggingface.co", local_dir=dest, force_download=False)
            digest = hashes(target)
        if not verified(entry, digest):
            raise RuntimeError(f"{role}: {entry.rfilename} 完整性核验失败。请重新运行准备器，不能使用未核验文件。")
        records.append({"name": entry.rfilename, "bytes": target.stat().st_size, "sha256": digest[0]})
    if not {"config.json", "model.safetensors", "tokenizer_config.json"}.issubset({x["name"] for x in records}):
        raise RuntimeError(f"{role}: 缺少权重或必要配置。")
    manifest[f"{role}_model_path"] = str(dest)
    manifest[f"{role}_model_id"] = model_id
    manifest[f"{role}_model_revision"] = revision
    manifest["models"][role] = {"id": model_id, "revision": revision, "license": "apache-2.0",
                                "source": f"https://huggingface.co/{model_id}/tree/{revision}", "files": records}

print("\n[5/5] 离线启动检查：实际加载语音与文字模型，请等待检查结果。", flush=True)
candidate = root / ("manifest.preparing-" + uuid.uuid4().hex + ".json")
candidate.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
env = os.environ.copy()
env.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "TOKENIZERS_PARALLELISM": "false", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"})
probe_log = root / "setup-logs" / ("model-startup-" + uuid.uuid4().hex[:12] + ".log")
process = None
try:
    with probe_log.open("wb") as stderr:
        process = subprocess.Popen([python_path, "-I", "-B", worker_path, "--manifest", str(candidate)],
                                   cwd=root, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=stderr)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        buffer = b""; ready = False; deadline = time.monotonic() + 240
        while time.monotonic() < deadline and not ready:
            for key, _ in selector.select(timeout=0.25):
                part = os.read(key.fileobj.fileno(), 8192)
                if not part:
                    raise RuntimeError("模型启动进程提前退出，请查看模型启动日志。")
                buffer += part
                if len(buffer) > 1024 * 1024:
                    raise RuntimeError("模型启动结果超出预期大小。")
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try: message = json.loads(line)
                    except (ValueError, UnicodeError): continue
                    if message.get("status") == "ready":
                        ready = True; break
                    if message.get("status") == "error":
                        raise RuntimeError("模型启动检查失败：" + str(message.get("error", "未知错误")))
            if process.poll() is not None and not ready:
                raise RuntimeError("模型启动进程已结束，尚未就绪。")
        selector.close()
        if not ready:
            raise RuntimeError("模型启动检查超过 240 秒；本机环境未切换，请查看日志后重试。")
    pathlib.Path(environment_dir, ".prepared-requirements").write_text(requirements_sha + "\n")
    os.replace(candidate, root / "manifest.json")
    print("语音与文字模型已离线加载通过。", flush=True)
except BaseException:
    print("模型启动日志：" + str(probe_log), flush=True)
    raise
finally:
    if process is not None:
        if process.stdin: process.stdin.close()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
    if candidate.exists(): candidate.unlink()
PY_SETUP
printf '\n本地 AI 准备完成\n请正常退出并重新打开“映述”，在“口述选项 → 语音与整理设置”选择“AI识别与整理”。\n已有项目会保留原识别模式，请检查该选项。首次口述需授权麦克风，模型首次加载仍可能稍等。\n可以先打开内置示例，再按 R 说一句、再按 R 结束，检查文字是否留在同一画面。\n本次准备日志：%s\n' "$log_file"
