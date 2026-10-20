#!/usr/bin/env python3
"""Offline installer orchestration checks; these do NOT validate real AI inference.

Only a disposable copy of prepare-local-ai.sh is executed. Its system inspection
and download tools point to local fixtures and its fixed uv archive digest is
replaced with the digest of a tiny generated archive. The shell/Python installer
logic itself is retained. Fake uv creates a controlled Python launcher, fake Hub
metadata serves deterministic local bytes, and a fake worker speaks JSONL ready.
No model, package, user Python environment, microphone or network is accessed.
"""
from __future__ import annotations

import ast
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PREPARER = ROOT / "scripts/prepare-local-ai.sh"


def executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o700)


class InstallerFixture:
    """Each run has a private HOME, runtime, package and immutable fake toolchain."""

    def __init__(self, directory: Path):
        self.root = directory
        self.package = directory / "downloaded preparation package"
        self.tools = directory / "mock-tools"
        self.fixture = directory / "fixtures"
        self.runtime = directory / "Runtime with spaces"
        self.home = directory / "home"
        self.temp = directory / "tmp"
        for path in (self.package / "scripts", self.package / "Resources", self.tools, self.fixture, self.home, self.temp):
            path.mkdir(parents=True, exist_ok=True)
        self.state = self.fixture / "state.json"
        self.events_file = self.fixture / "events.jsonl"
        self.config: dict[str, object] = {"arch": "arm64", "os": "14.0", "translated": "0", "free_kib": 20 * 1024 * 1024}
        self.configure()
        self._write_mocks()
        self.archive = self.fixture / "uv-aarch64-apple-darwin.tar.gz"
        uv = self._launcher(self.fixture / "fake_uv.py").encode()
        with tarfile.open(self.archive, "w:gz") as output:
            entry = tarfile.TarInfo("uv-aarch64-apple-darwin/uv")
            entry.mode = 0o700; entry.size = len(uv)
            output.addfile(entry, io.BytesIO(uv))
        self.archive_digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.script = self.package / "scripts/prepare-local-ai.sh"
        self.source = PREPARER.read_text(encoding="utf-8")
        patched = self.source
        self.tool_replacements: dict[str, str] = {}
        for original in ("/usr/bin/curl", "/usr/sbin/sysctl", "/usr/bin/sw_vers", "/bin/df", "/usr/bin/df",
                         "/usr/bin/tar", "/usr/bin/shasum", "/usr/bin/uname", "/bin/uname", "/usr/bin/arch", "/usr/bin/id"):
            replacement = shlex.quote(str(self.tools / Path(original).name))
            if original in patched:
                patched = re.sub(r"([\"']?)" + re.escape(original) + r"\1", lambda _: replacement, patched)
                self.tool_replacements[original] = replacement
        digest_pattern = re.compile(r"(?mi)^([^\n#]*(?:uv)[^\n]*(?:sha)[^\n]*?)([0-9a-f]{64})([^\n]*)$")
        patched, self.digest_replacements = digest_pattern.subn(lambda m: m[1] + self.archive_digest + m[3], patched)
        executable(self.script, patched)
        (self.package / "Resources/ai_voice_worker.py").write_text(self.worker, encoding="utf-8")
        self.environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.home), "TMPDIR": str(self.temp),
                            "LANG": "en_US.UTF-8", "YINGSHU_AI_RUNTIME_DIR": str(self.runtime)}

    def configure(self, **values: object) -> None:
        self.config.update(values)
        self.state.write_text(json.dumps(self.config), encoding="utf-8")

    def _launcher(self, script: Path) -> str:
        # The host test interpreter is explicit and isolated. Production never gets
        # a hook to choose an executable; only the mock archive contains this path.
        return "#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -I -B " + shlex.quote(str(script)) + ' "$@"\n'

    def events(self) -> list[dict]:
        if not self.events_file.exists():
            return []
        return [json.loads(line) for line in self.events_file.read_text().splitlines()]

    def run(self, timeout: float = 20) -> subprocess.CompletedProcess:
        process = self.start()
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try: stdout, stderr = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); stdout, stderr = process.communicate()
            raise AssertionError('Disposable setup exceeded its deadline:\n' + stdout + stderr)
        return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)

    def start(self) -> subprocess.Popen:
        return subprocess.Popen(["/bin/bash", str(self.script)], cwd=self.package, env=self.environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace", start_new_session=True)

    def _write_mocks(self) -> None:
        fixture_import = "import sys\nsys.path.insert(0, " + repr(str(self.fixture)) + ")\n"
        common = f"""import json, os, pathlib, sys, time
FIXTURE = pathlib.Path({str(self.fixture)!r})
STATE = FIXTURE / 'state.json'
def config(): return json.loads(STATE.read_text())
def event(tool, **fields):
    with (FIXTURE / 'events.jsonl').open('a') as out:
        out.write(json.dumps(dict(tool=tool, **fields)) + '\\n')
"""
        (self.fixture / "mock_common.py").write_text(common)
        tool = """from mock_common import *
import hashlib, shutil
name = pathlib.Path(sys.argv[1]).name
args = sys.argv[2:]
event(name, args=args)
settings = config()
if name == 'uname': print(('x86_64' if settings.get('translated') == '1' else settings['arch']) if any(x in args for x in ('-m', '-p')) else 'Darwin')
elif name == 'arch': print(settings['arch'])
elif name == 'id': print(settings.get('uid', '501'))
elif name == 'sysctl':
    key = args[-1]
    print(settings['translated'] if key == 'sysctl.proc_translated' else ('1' if settings['arch'] == 'arm64' else '0'))
elif name == 'sw_vers': print(settings['os'])
elif name == 'df':
    print('Filesystem 1024-blocks Used Available Capacity Mounted on')
    print('fixture 41943040 1024 %s 1%% /' % settings['free_kib'])
elif name == 'curl':
    destinations = [args[i+1] for i, x in enumerate(args[:-1]) if x in ('-o', '--output')]
    urls = [x for x in args if x.startswith('https://')]
    if not destinations or len(urls) != 1 or 'github.com/astral-sh/uv/releases/download/0.13.1/' not in urls[0]:
        raise SystemExit('Mock refuses any unexpected network command: ' + repr(args))
    if settings.get('download_failure'): raise SystemExit(22)
    output = pathlib.Path(destinations[0]); output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(b'invalid archive' if settings.get('bad_checksum') else (FIXTURE / 'uv-aarch64-apple-darwin.tar.gz').read_bytes())
elif name == 'shasum':
    if '-c' in args or '--check' in args:
        for line in sys.stdin:
            expected, filename = line.strip().split(None, 1)
            filename = filename.lstrip('*')
            if hashlib.sha256(pathlib.Path(filename).read_bytes()).hexdigest() != expected: raise SystemExit(1)
            print(filename + ': OK')
    else:
        filename = args[-1]
        print(hashlib.sha256(pathlib.Path(filename).read_bytes()).hexdigest() + '  ' + filename)
elif name == 'tar':
    import subprocess
    raise SystemExit(subprocess.run(['/usr/bin/tar', *args]).returncode)
else: raise SystemExit('Unexpected mock tool ' + name)
"""
        (self.fixture / "system_tool.py").write_text(fixture_import + tool)
        for name in ("curl", "sysctl", "sw_vers", "df", "tar", "shasum", "uname", "arch", "id"):
            executable(self.tools / name, "#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -I -B " +
                       shlex.quote(str(self.fixture / "system_tool.py")) + " " + shlex.quote(name) + ' "$@"\n')
        launcher = self._launcher(self.fixture / "managed_python.py")
        (self.fixture / "python_launcher.txt").write_text(launcher)
        (self.fixture / "fake_uv.py").write_text(fixture_import + """from mock_common import *
args = sys.argv[1:]
event('uv', args=args)
if args == ['--version']: print('uv 0.13.1'); raise SystemExit(0)
if config().get('pause_uv'):
    event('gate', stage='uv')
    deadline = time.monotonic() + 30
    while not (FIXTURE / 'release-gate').exists() and time.monotonic() < deadline: time.sleep(.02)
def python_at(path):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text((FIXTURE / 'python_launcher.txt').read_text()); path.chmod(0o700)
base = pathlib.Path(os.environ['UV_PYTHON_INSTALL_DIR']) / 'cpython-3.12.14-macos-aarch64-none/bin/python3.12'
if args[:2] == ['python', 'install']: python_at(base)
elif args[:2] == ['python', 'find']: print(base)
elif args[:1] == ['venv']:
    python_at(pathlib.Path(args[-1]) / 'bin/python')
elif args[:2] == ['pip', 'install']:
    if config().get('install_failure'): raise SystemExit(53)
elif args[:2] == ['pip', 'freeze']: print('mlx==0.32.4\\nmlx-audio==0.5.9\\nmlx-lm==0.32.2')
elif args[:2] == ['pip', 'check']: print('All installed packages are compatible')
else: raise SystemExit('Unexpected fake uv command: ' + repr(args))
""")
        (self.fixture / "managed_python.py").write_text(fixture_import + """from mock_common import *
import collections, importlib.metadata, platform, runpy, types
event('python', args=sys.argv[1:])
platform.machine = lambda: 'arm64'
platform.python_version = lambda: '3.12.14'
sys.version_info = collections.namedtuple('VersionInfo', 'major minor micro releaselevel serial')(3, 12, 14, 'final', 0)
def pinned_versions():
    requirements = pathlib.Path(os.environ['UV_PYTHON_INSTALL_DIR']).parent / 'requirements.pinned.txt'
    return dict(line.split('==', 1) for line in requirements.read_text().splitlines() if '==' in line) if requirements.exists() else {}
importlib.metadata.distributions = lambda: [types.SimpleNamespace(metadata={'Name':name}, version=version) for name, version in pinned_versions().items()]
importlib.metadata.version = lambda name: pinned_versions().get(name, 'fixture')
sys.path.insert(0, str(FIXTURE))
args = sys.argv[1:]
while args and args[0] in ('-B', '-I', '-u', '-s', '-E'): args.pop(0)
if args[:1] == ['--version']: print('Python 3.12.14'); raise SystemExit(0)
if args[:1] == ['-c']:
    sys.argv = ['-c', *args[2:]]
    exec(compile(args[1], '<installer-check>', 'exec'), dict(__name__='__main__'))
elif args[:1] == ['-']:
    source = sys.stdin.read(); sys.argv = ['-', *args[1:]]
    exec(compile(source, '<installer-inline>', 'exec'), dict(__name__='__main__'))
elif args:
    sys.argv = args
    runpy.run_path(args[0], run_name='__main__')
else: raise SystemExit('Unexpected empty Python invocation')
""")
        (self.fixture / "huggingface_hub.py").write_text("""from mock_common import *
import hashlib, types
def resources(repo):
    kind = 'qwen3_asr' if 'ASR' in repo else 'qwen2'
    return {'config.json':json.dumps({'model_type':kind}).encode(), 'tokenizer_config.json':b'{}',
            'model.safetensors':('tiny-fake-weights:' + repo).encode(), 'LICENSE':b'Apache-2.0', 'README.md':b'Installer fixture only'}
class HfApi:
    def __init__(self, *args, **kwargs): pass
    def model_info(self, repo, revision=None, **kwargs):
        event('hub-metadata', repo=repo, revision=revision)
        records=[]
        for name, data in resources(repo).items():
            lfs=types.SimpleNamespace(sha256=hashlib.sha256(data).hexdigest()) if name.endswith('.safetensors') else None
            records.append(types.SimpleNamespace(rfilename=name, size=len(data), lfs=lfs,
                blob_id=hashlib.sha1(('blob %s\\0'%len(data)).encode()+data).hexdigest()))
        return types.SimpleNamespace(sha=revision, card_data={'license':'apache-2.0'}, siblings=records)
def hf_hub_download(repo, filename, *args, **kwargs):
    event('hub-file', repo=repo, filename=filename, local=bool(kwargs.get('local_files_only')))
    if kwargs.get('local_files_only'): raise FileNotFoundError('Fixture cache starts empty')
    target=pathlib.Path(kwargs['local_dir'])/filename; target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(resources(repo)[filename]); return str(target)
""")
        mlx = self.fixture / "mlx"; mlx.mkdir()
        (mlx / "__init__.py").write_text("from . import core\n")
        (mlx / "core.py").write_text("""class Array:
    def __init__(self, value): self.value=value
    def sum(self): return Array(sum(self.value))
    def item(self): return self.value
    def tolist(self): return self.value
array=Array
def eval(*args): pass
def synchronize(): pass
def default_device(): return 'gpu'
class Metal:
    def is_available(self): return True
metal=Metal()
""")
        for module in ("mlx_audio", "mlx_lm", "numpy", "transformers"):
            (self.fixture / (module + ".py")).write_text("__version__ = 'fixture'\n")

    @property
    def worker(self) -> str:
        return f"""#!/usr/bin/env python3
# FAKE JSONL WORKER: proves preparation orchestration only, never real AI.
import json, pathlib, sys
sys.path.insert(0, {str(self.fixture)!r})
from mock_common import *
event('worker', args=sys.argv[1:])
if config().get('probe_failure'):
    print(json.dumps({{'status':'error','error':'fixture startup failure'}}), flush=True)
    raise SystemExit(23)
print(json.dumps({{'status':'ready','asr_model_id':'mlx-community/Qwen3-ASR-0.6B-8bit',
    'cleanup_model_id':'mlx-community/Qwen2.5-1.5B-Instruct-4bit'}}), flush=True)
for line in sys.stdin:
    request=json.loads(line)
    print(json.dumps({{'id':request.get('id'),'ok':True,'text':request.get('text','fixture'),
        'original_text':request.get('text','fixture'),'cleanup_applied':False,'metrics':{{}}}}), flush=True)
"""


class AISetupChecks(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="yingshu-ai-setup-check-")
        self.addCleanup(self.temporary.cleanup)
        self.fixture = InstallerFixture(Path(self.temporary.name))

    def assertFailed(self, result: subprocess.CompletedProcess, detail: str = "") -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr + detail)

    def assertSucceeded(self, result: subprocess.CompletedProcess) -> None:
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_source_has_no_system_python_bootstrap_and_complete_syntax(self) -> None:
        source = self.fixture.source
        self.assertNotIn("/usr/bin/python3", source)
        self.assertNotRegex(source, r"\bpython3\s+-m\s+pip\b")
        self.assertIn("--only-binary", source)
        self.assertEqual(self.fixture.digest_replacements, 1, "Exactly the uv archive digest may be replaced")
        subprocess.run(["/bin/bash", "-n", str(PREPARER)], check=True, capture_output=True)
        for name, body in re.findall(r"<<[\"']?([A-Z][A-Z0-9_]*)[\"']?\s*\n(.*?)\n\1(?:\n|$)", source, re.S):
            if re.search(r"(?m)^(?:import |from |def |class )", body): ast.parse(body, filename="inline-" + name)

    def test_wrong_architecture_rejected_before_download(self) -> None:
        self.fixture.configure(arch="x86_64")
        self.assertFailed(self.fixture.run())
        self.assertFalse(any(x['tool'] in ('curl', 'uv') for x in self.fixture.events()))
        self.assertFalse((self.fixture.runtime / 'manifest.json').exists())

    def test_old_system_rejected_before_download(self) -> None:
        self.fixture.configure(os="13.6")
        result = self.fixture.run()
        self.assertFailed(result)
        self.assertIn("macOS 14", result.stdout + result.stderr, "Old-system rejection must explain the actual minimum version")
        self.assertNotIn("unbound variable", result.stdout + result.stderr)
        self.assertFalse(any(x['tool'] in ('curl', 'uv') for x in self.fixture.events()))

    def test_rosetta_rejected_before_download(self) -> None:
        self.fixture.configure(translated="1")
        self.assertFailed(self.fixture.run())
        self.assertFalse(any(x['tool'] in ('curl', 'uv') for x in self.fixture.events()))

    def test_low_space_rejected_before_download(self) -> None:
        self.fixture.configure(free_kib=128 * 1024)
        self.assertFailed(self.fixture.run())
        self.assertFalse(any(x['tool'] in ('curl', 'uv') for x in self.fixture.events()))

    def test_archive_checksum_rejected_before_execution(self) -> None:
        self.fixture.configure(bad_checksum=True)
        self.assertFailed(self.fixture.run())
        self.assertTrue(any(x['tool'] == 'curl' for x in self.fixture.events()))
        self.assertFalse(any(x['tool'] == 'uv' for x in self.fixture.events()))
        self.assertFalse((self.fixture.runtime / 'manifest.json').exists())

    def _previous_manifest(self) -> bytes:
        self.fixture.runtime.mkdir(parents=True, exist_ok=True)
        data = b'{"previous_runtime":"must remain byte-for-byte intact"}\n'
        (self.fixture.runtime / 'manifest.json').write_bytes(data)
        return data

    def test_dependency_failure_preserves_previous_manifest_and_logs(self) -> None:
        before = self._previous_manifest()
        self.fixture.configure(install_failure=True)
        self.assertFailed(self.fixture.run())
        self.assertEqual((self.fixture.runtime / 'manifest.json').read_bytes(), before)
        self.assertTrue(list((self.fixture.runtime / 'setup-logs').glob('prepare-*.log')))

    def test_final_probe_failure_preserves_previous_manifest(self) -> None:
        before = self._previous_manifest()
        self.fixture.configure(probe_failure=True)
        self.assertFailed(self.fixture.run())
        self.assertTrue(any(x['tool'] == 'worker' for x in self.fixture.events()), "Must reach the actual final worker probe")
        self.assertEqual((self.fixture.runtime / 'manifest.json').read_bytes(), before)

    def test_success_then_rerun_reuses_verified_resources(self) -> None:
        self.assertSucceeded(self.fixture.run())
        manifest = json.loads((self.fixture.runtime / 'manifest.json').read_text())
        self.assertTrue(manifest['offline'])
        self.assertTrue(Path(manifest['python_path']).is_file())
        self.assertTrue(any(x['tool'] == 'worker' for x in self.fixture.events()))
        downloads = sum(x['tool'] in ('curl', 'hub-file') and not x.get('local') for x in self.fixture.events())
        environments = sum(x['tool'] == 'uv' and x['args'][:1] == ['venv'] for x in self.fixture.events())
        installations = sum(x['tool'] == 'uv' and x['args'][:2] == ['pip', 'install'] for x in self.fixture.events())
        self.assertSucceeded(self.fixture.run())
        self.assertEqual(sum(x['tool'] in ('curl', 'hub-file') and not x.get('local') for x in self.fixture.events()), downloads,
                         "A rerun must reuse the verified archive/models instead of downloading them again")
        restored = json.loads((self.fixture.runtime / 'manifest.json').read_text())
        self.assertEqual(Path(restored['python_path']).resolve(), Path(manifest['python_path']).resolve(),
                         "Rerun must keep the verified versioned environment, including a stable alias to it")
        self.assertEqual(sum(x['tool'] == 'uv' and x['args'][:1] == ['venv'] for x in self.fixture.events()), environments)
        self.assertEqual(sum(x['tool'] == 'uv' and x['args'][:2] == ['pip', 'install'] for x in self.fixture.events()), installations)
        for model in manifest['models'].values():
            for record in model['files']:
                path = Path(manifest['asr_model_path'] if model['id'] == manifest['asr_model_id'] else manifest['cleanup_model_path']) / record['name']
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), record['sha256'])

    def test_concurrent_preparation_is_rejected_without_clobbering_first(self) -> None:
        self.fixture.configure(pause_uv=True)
        first = self.fixture.start()
        try:
            deadline = time.monotonic() + 15
            while not any(x['tool'] == 'gate' for x in self.fixture.events()) and time.monotonic() < deadline:
                if first.poll() is not None: self.fail(first.communicate()[0])
                time.sleep(.02)
            self.assertTrue(any(x['tool'] == 'gate' for x in self.fixture.events()), "First setup did not reach the controlled gate")
            before = len([x for x in self.fixture.events() if x['tool'] == 'uv'])
            self.assertFailed(self.fixture.run(timeout=4))
            self.assertEqual(len([x for x in self.fixture.events() if x['tool'] == 'uv']), before,
                             "A competing preparation must stop before running its own installer")
        finally:
            (self.fixture.fixture / 'release-gate').touch()
            try:
                stdout, stderr = first.communicate(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(first.pid, signal.SIGKILL); stdout, stderr = first.communicate()
            self.assertEqual(first.returncode, 0, stdout + stderr)


if __name__ == '__main__':
    print('Offline setup harness: fake downloads, packages and worker; no real AI model acceptance.', flush=True)
    unittest.main(verbosity=2)
