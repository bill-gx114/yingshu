#!/bin/bash
# Explicit, one-time public downloads. The worker itself never downloads anything.
set -euo pipefail
umask 077
unset UV_INDEX_URL UV_EXTRA_INDEX_URL UV_INDEX PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_TRUSTED_HOST
export UV_NO_CONFIG=1

runtime_dir="${YINGSHU_AI_RUNTIME_DIR:-$HOME/Library/Application Support/YingShu/AI Runtime}"
mkdir -p "$runtime_dir/bootstrap"
uv_bin="$runtime_dir/bootstrap/bin/uv"
if [[ ! -x "$uv_bin" ]]; then
  /usr/bin/python3 -m pip --isolated install --disable-pip-version-check --no-warn-script-location --no-deps \
    --index-url https://pypi.org/simple --target "$runtime_dir/bootstrap" 'uv==0.13.1'
fi
export UV_CACHE_DIR="$runtime_dir/download-cache/uv"
export UV_PYTHON_INSTALL_DIR="$runtime_dir/python"
"$uv_bin" python install --no-bin 3.12.14
python_base="$runtime_dir/python/cpython-3.12.14-macos-aarch64-none/bin/python3.12"
if [[ ! -x "$runtime_dir/.venv/bin/python" ]]; then
  "$uv_bin" venv --python "$python_base" "$runtime_dir/.venv"
fi
python_bin="$runtime_dir/.venv/bin/python"
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
"$uv_bin" pip install --python "$python_bin" --index-url https://pypi.org/simple \
  -r "$runtime_dir/requirements.pinned.txt"
"$uv_bin" pip freeze --python "$python_bin" > "$runtime_dir/requirements.lock"

# Do not consume a user's Hugging Face token or follow a private mirror.
export HF_HUB_DISABLE_IMPLICIT_TOKEN=1 HF_HUB_DISABLE_TELEMETRY=1
unset HF_TOKEN HUGGING_FACE_HUB_TOKEN HF_ENDPOINT HF_HUB_OFFLINE TRANSFORMERS_OFFLINE
"$python_bin" -B - "$runtime_dir" <<'PY'
import hashlib, importlib.metadata, json, os, pathlib, platform, shutil, sys, time
from huggingface_hub import HfApi, hf_hub_download

root = pathlib.Path(sys.argv[1]).expanduser().resolve()
specs = {
    "asr": ("mlx-community/Qwen3-ASR-0.6B-8bit", "89e96d92ba34aca20b3e29fb10cc284097d1219f"),
    "cleanup": ("mlx-community/Qwen2.5-1.5B-Instruct-4bit", "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"),
}
manifest = {"schema_version": 1, "python_path": str(root / ".venv/bin/python"),
            "python_version": platform.python_version(), "prepared_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "versions": {d.metadata["Name"]: d.version for d in importlib.metadata.distributions()},
            "models": {}, "offline": True}
api = HfApi(endpoint="https://huggingface.co", token=False)
for role, (model_id, revision) in specs.items():
    info = api.model_info(model_id, revision=revision, files_metadata=True, token=False)
    if info.sha != revision or (info.card_data or {}).get("license") != "apache-2.0":
        raise RuntimeError(f"{role}: revision/license verification failed")
    files = [x for x in info.siblings if x.rfilename in {"README.md", "LICENSE", "LICENSE.txt"}
             or x.rfilename.endswith((".json", ".txt", ".safetensors"))]
    if any("/" in x.rfilename or x.rfilename.endswith(".py") for x in files):
        raise RuntimeError(f"{role}: unexpected model files")
    if sum(x.size or 0 for x in files) > 1_500_000_000:
        raise RuntimeError(f"{role}: public download exceeds 1.5 GB limit")
    dest = root / "models" / model_id.replace("/", "--") / revision
    dest.mkdir(parents=True, exist_ok=True)
    records = []
    print(f"Preparing {role}: {model_id} @ {revision}", flush=True)
    for entry in files:
        target = dest / entry.rfilename
        if not target.is_file():
            try:
                cached = pathlib.Path(hf_hub_download(model_id, entry.rfilename, revision=revision,
                                                     token=False, local_files_only=True))
                try:
                    os.link(cached.resolve(), target)
                except OSError:
                    shutil.copyfile(cached, target)
            except Exception:
                hf_hub_download(model_id, entry.rfilename, revision=revision, token=False,
                                endpoint="https://huggingface.co", local_dir=dest)
        sha = hashlib.sha256()
        git_hash = hashlib.sha1(f"blob {target.stat().st_size}\0".encode())
        with target.open("rb") as stream:
            for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                sha.update(block)
                git_hash.update(block)
        expected_lfs = getattr(entry.lfs, "sha256", None) if entry.lfs else None
        if expected_lfs:
            verified = sha.hexdigest() == expected_lfs
        else:
            verified = git_hash.hexdigest() == entry.blob_id
        if not verified:
            raise RuntimeError(f"{role}: integrity check failed for {entry.rfilename}; remove only that file and retry")
        records.append({"name": entry.rfilename, "bytes": target.stat().st_size, "sha256": sha.hexdigest()})
    if not {"config.json", "model.safetensors", "tokenizer_config.json"}.issubset({x["name"] for x in records}):
        raise RuntimeError(f"{role}: missing required weights/config")
    manifest[f"{role}_model_path"] = str(dest)
    manifest[f"{role}_model_id"] = model_id
    manifest[f"{role}_model_revision"] = revision
    manifest["models"][role] = {"id": model_id, "revision": revision, "license": "apache-2.0",
                                "source": f"https://huggingface.co/{model_id}/tree/{revision}", "files": records}
tmp = root / "manifest.json.preparing"
tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
os.replace(tmp, root / "manifest.json")
print("Verified local models and wrote " + str(root / "manifest.json"), flush=True)
PY
