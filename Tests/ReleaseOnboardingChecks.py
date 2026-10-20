#!/usr/bin/env python3
"""Verify release layout and Finder launcher without installing or downloading AI."""
import hashlib
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time
import unittest
import zipfile


PROJECT = Path(__file__).resolve().parent.parent
LAUNCHER = PROJECT / "scripts/release-onboarding/准备本地AI.command"


class ReleaseOnboardingChecks(unittest.TestCase):
    def launcher_case(self, exit_code=None):
        with tempfile.TemporaryDirectory(prefix="YingShu onboarding ") as temporary:
            root = Path(temporary) / "下载包 中文与空格"
            support = root / "安装支援"
            support.mkdir(parents=True)
            launcher = root / LAUNCHER.name
            shutil.copy2(LAUNCHER, launcher)
            if exit_code is not None:
                (support / "prepare-local-ai.sh").write_text(
                    "#!/bin/bash\n"
                    "printf 'TEST_RUNTIME_OVERRIDE=%s\\n' \"${YINGSHU_AI_RUNTIME_DIR-unset}\"\n"
                    "printf '%s\\n' 'TEST_STAGE: installer reached from another working directory'\n"
                    "printf '%s\\n' 'TEST_DETAIL: specific failure and log path remain visible'\n"
                    f"exit {exit_code}\n",
                    encoding="utf-8",
                )
            environment = dict(os.environ)
            environment["YINGSHU_AI_RUNTIME_DIR"] = str(root / "override-must-not-be-used")
            result = subprocess.run(
                ["/bin/bash", str(launcher)], cwd="/", input="\n",
                env=environment, capture_output=True, text=True, timeout=10,
            )
            self.assertIn("按回车键结束", result.stdout)
            return result

    def test_launcher_success_from_unrelated_directory(self):
        result = self.launcher_case(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TEST_STAGE", result.stdout)
        self.assertIn("本地 AI 准备完成", result.stdout)
        self.assertIn("重新打开", result.stdout)
        self.assertIn("云端整理设置没有被更改", result.stdout)

    def test_launcher_preserves_failure_code_and_details(self):
        result = self.launcher_case(37)
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertIn("TEST_DETAIL: specific failure", result.stdout)
        self.assertIn("尚未准备完成（退出码 37）", result.stdout)
        self.assertNotIn("本地 AI 准备完成。", result.stdout)

    def test_launcher_clears_test_runtime_override(self):
        result = self.launcher_case(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("TEST_RUNTIME_OVERRIDE=unset", result.stdout)
        self.assertNotIn("override-must-not-be-used", result.stdout)

    def test_launcher_reports_missing_support(self):
        result = self.launcher_case()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("请重新完整解压", result.stdout)
        self.assertNotIn("本地 AI 准备完成。", result.stdout)

    def test_launcher_preserves_cancellation_outcome(self):
        result = self.launcher_case(130)
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertIn("本次准备已取消", result.stdout)

    def test_launcher_waits_for_return_after_displaying_outcome(self):
        with tempfile.TemporaryDirectory(prefix="yingshu-launcher-wait-") as temporary:
            root = Path(temporary)
            (root / "安装支援").mkdir()
            (root / "安装支援/prepare-local-ai.sh").write_text("#!/bin/bash\nexit 0\n")
            launcher = root / LAUNCHER.name
            shutil.copy2(LAUNCHER, launcher)
            process = subprocess.Popen(
                [str(launcher)], cwd="/", stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            try:
                output = b""
                deadline = time.monotonic() + 10
                while "按回车键结束".encode() not in output:
                    ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
                    self.assertTrue(ready, "Launcher did not display its final prompt")
                    block = os.read(process.stdout.fileno(), 8192)
                    self.assertTrue(block, "Launcher exited before waiting for Return")
                    output += block
                self.assertIsNone(process.poll(), "Launcher did not wait for Return")
                process.communicate(b"\n", timeout=5)
                self.assertEqual(process.returncode, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_archive_allowlist_permissions_checksum_and_signing_calls(self):
        with tempfile.TemporaryDirectory(prefix="yingshu-package-check-") as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            scripts.mkdir()
            shutil.copy2(PROJECT / "scripts/package-release.sh", scripts)
            shutil.copy2(PROJECT / "scripts/prepare-local-ai.sh", scripts)
            shutil.copytree(PROJECT / "scripts/release-onboarding", scripts / "release-onboarding")
            (root / "Resources").mkdir()
            shutil.copy2(PROJECT / "Resources/ai_voice_worker.py", root / "Resources")
            # These unlisted files must never be swept into the release.
            (root / "private-project.json").write_text("not for distribution")
            (scripts / "unlisted-private-helper.sh").write_text("not for distribution")
            executable = root / "dist/映述.app/Contents/MacOS/YingShu"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"disposable test executable without build paths\n")
            executable.chmod(0o755)
            app_resources = root / "dist/映述.app/Contents/Resources"
            app_resources.mkdir()
            shutil.copy2(PROJECT / "Resources/ai_voice_worker.py", app_resources)
            fakebin = root / "fakebin"
            fakebin.mkdir()
            log = root / "tool-calls.txt"
            # The app is a disposable fixture. Only strip/sign commands are stubbed;
            # assertions below prove the release script retains both signing calls.
            for tool in ("codesign", "xcrun"):
                stub = fakebin / tool
                stub.write_text(
                    "#!/bin/bash\n"
                    f"printf '%s\\n' '{tool}' \"$*\" >> \"$YINGSHU_PACKAGING_TEST_LOG\"\n",
                    encoding="utf-8",
                )
                stub.chmod(0o755)
            # A tiny ditto substitute lets the packaging contract also be checked
            # on hosts without macOS tooling; production still uses real ditto.
            copy_stub = fakebin / "ditto"
            copy_stub.write_text(
                "#!/bin/bash\n"
                "previous=''; latest=''\n"
                "for item in \"$@\"; do previous=\"$latest\"; latest=\"$item\"; done\n"
                "/bin/cp -R \"$previous\" \"$latest\"\n",
                encoding="utf-8",
            )
            copy_stub.chmod(0o755)
            environment = dict(os.environ)
            environment["PATH"] = str(fakebin) + os.pathsep + environment.get("PATH", "")
            environment["YINGSHU_PACKAGING_TEST_LOG"] = str(log)
            result = subprocess.run(
                ["/bin/bash", str(scripts / "package-release.sh"), "--no-build"],
                cwd="/", env=environment, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            archive = root / "dist/release/YingShu-Mac.zip"
            with zipfile.ZipFile(archive) as contents:
                self.assertEqual(
                    {name.split("/")[0] for name in contents.namelist()},
                    {"映述.app", "准备本地AI.command", "首次使用说明.txt", "安装支援"},
                )
                self.assertEqual(contents.read("准备本地AI.command"), LAUNCHER.read_bytes())
                self.assertEqual(
                    contents.read("安装支援/prepare-local-ai.sh"),
                    (PROJECT / "scripts/prepare-local-ai.sh").read_bytes(),
                )
                self.assertEqual(
                    contents.read("安装支援/ai_voice_worker.py"),
                    (PROJECT / "Resources/ai_voice_worker.py").read_bytes(),
                )
                self.assertEqual(
                    contents.read("安装支援/ai_voice_worker.py"),
                    contents.read("映述.app/Contents/Resources/ai_voice_worker.py"),
                )
                self.assertEqual(
                    {name for name in contents.namelist() if name.startswith("安装支援/")},
                    {"安装支援/", "安装支援/prepare-local-ai.sh", "安装支援/ai_voice_worker.py"},
                )
                for name in ("准备本地AI.command", "安装支援/prepare-local-ai.sh", "映述.app/Contents/MacOS/YingShu"):
                    self.assertTrue(contents.getinfo(name).external_attr >> 16 & 0o111, name)
                self.assertNotIn("private-project.json", contents.namelist())
                self.assertFalse(any("unlisted-private" in name for name in contents.namelist()))
                instructions = contents.read("首次使用说明.txt").decode("utf-8")
                self.assertIn("无需 API Key", instructions)
                self.assertIn("无需克隆仓库", instructions)
                self.assertIn("替换旧版即可", instructions)
                self.assertIn("1.89 GB", instructions)
                self.assertIn("6 GB", instructions)
                self.assertIn("尚未经过 Apple 公证", instructions)
                self.assertIn("隐私与安全性", instructions)
                self.assertIn("仍要打开", instructions)
                self.assertIn("https://support.apple.com/zh-cn/102445", instructions)
            expected = hashlib.sha256(archive.read_bytes()).hexdigest() + "  YingShu-Mac.zip\n"
            self.assertEqual((archive.parent / "SHA256SUMS.txt").read_text(), expected)
            calls = log.read_text()
            self.assertIn("strip -S", calls)
            self.assertIn("--force --deep --sign -", calls)
            self.assertIn("--verify --deep --strict", calls)
            (app_resources / "ai_voice_worker.py").write_text("outdated worker fixture\n")
            mismatch = subprocess.run(
                ["/bin/bash", str(scripts / "package-release.sh"), "--no-build"],
                cwd="/", env=environment, capture_output=True, text=True, timeout=30,
            )
            self.assertNotEqual(mismatch.returncode, 0)
            self.assertIn("worker 与安装支援版本不一致", mismatch.stderr)
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest() + "  YingShu-Mac.zip\n", expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
