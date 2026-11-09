"""Bare-metal orchestration in /tmp; pip, NVIDIA and native MediaPipe are fakes."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]


class BareMetalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="gesture-gpu-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.app = self.root / "app"
        self.venv = self.app / "libs/venv"
        shutil.copytree(ROOT / "scripts", self.source / "scripts")
        for directory in ("etc", "assets", "src/proto", "checkpoint", "wheels"):
            (self.source / directory).mkdir(parents=True)
        shutil.copy2(ROOT / "etc/config.yaml", self.source / "etc/config.yaml")
        for name in ("setup.py", "pyproject.toml", "MANIFEST.in", "README.md"):
            shutil.copy2(ROOT / name, self.source / name)
        (self.source / "src/proto/video.proto").write_text('syntax="proto3";')
        (self.source / "src/version.py").write_text("old code")
        (self.source / "checkpoint/gesture_recognizer.task").write_bytes(b"initial model")
        (self.source / "wheels/fake.whl").touch()
        # A source marker from a dev machine must never select the target server path.
        (self.source / ".app_dir").write_text("/dev-machine/path\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.script(self.bin / "nvidia-smi", "echo '0, NVIDIA L4, 610.57.04, 23034 MiB'")
        (self.venv / "bin").mkdir(parents=True)
        self.script(self.venv / "bin/python", '''
if [[ "$1" == -m && "$2" == pip ]]; then
    printf '%s\\n' "$*" >> "$TEST_PIP_LOG"
    if [[ "${3:-}" == --version && "${TEST_PIP_MISSING:-}" == 1 && ! -f "$TEST_PIP_LOG.bootstrapped" ]]; then exit 1; fi
    exit 0
fi
if [[ "$1" == -m && "$2" == ensurepip ]]; then
    printf '%s\\n' "$*" >> "$TEST_PIP_LOG"
    touch "$TEST_PIP_LOG.bootstrapped"
    exit 0
fi
exec "$TEST_PYTHON" "$@"
''')
        self.script(self.venv / "bin/mediapipe-gesture-server", '''
printf 'worker cwd=%s args=%s\\n' "$PWD" "$*"
exit "${TEST_WORKER_EXIT:-0}"
''')
        self.modules = self.root / "modules"
        self.modules.mkdir()
        package = self.modules / "mediapipe_gesture"
        package.mkdir()
        (package / "__init__.py").touch()
        shutil.copy2(ROOT / "src/config.py", package / "config.py")
        (package / "server.py").write_text('''import os
class Worker:
 def __init__(self,cfg): self.cfg=cfg
 def probe(self):
  if os.environ.get('TEST_PROBE_FAIL'): raise RuntimeError('GPU probe failed')
  print('fake native probe delegate='+self.cfg.gesture.delegate)
''')
        for name in ("grpc", "grpc_tools", "google", "google/protobuf", "mediapipe", "cv2", "numpy", "prometheus_client"):
            module = self.modules / name
            module.mkdir(exist_ok=True)
            (module / "__init__.py").write_text('__version__="test stub"\n')
        (self.modules / "ctypes.py").write_text("def CDLL(name): return None\n")
        self.pip_log = self.root / "pip.log"
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}",
                    "PYTHONPATH": str(self.modules), "PYTHONDONTWRITEBYTECODE": "1",
                    "TEST_PYTHON": sys.executable, "TEST_PIP_LOG": str(self.pip_log),
                    "PYTHON": sys.executable}

    def script(self, path, body):
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def call(self, script="setup-gpu-server", *args, expected=0, env=None):
        result = subprocess.run(["bash", str(self.source / "scripts" / f"{script}.sh"),
                                 "--app-dir", str(self.app), *map(str, args)],
                                env={**self.env, **(env or {})}, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_first_setup_and_repeat_preserve_runtime_and_update_code(self):
        output = self.call()
        self.assertIn("Installation validated", output)
        self.assertNotIn("fake native probe", output)
        config = self.app / "etc/config.yaml"
        cfg = yaml.safe_load(config.read_text())
        self.assertEqual(cfg["gesture"]["delegate"], "gpu")
        self.assertEqual(cfg["server"]["addr"], "127.0.0.1:50053")
        self.assertEqual(cfg["metrics"]["port"], 9102)
        self.assertEqual(Path(cfg["gesture"]["model"]), self.app / "models/gesture_recognizer.task")
        cfg["server"]["max_streams"] = 3
        cfg["gesture"]["delegate"] = "cpu"
        config.write_text(yaml.safe_dump(cfg))
        before = config.read_bytes()
        (self.source / "checkpoint/gesture_recognizer.task").write_bytes(b"new model")
        (self.source / "src/version.py").write_text("updated code")
        self.assertIn("Existing YAML uses CPU", self.call())
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual((self.app / "models/gesture_recognizer.task").read_bytes(), b"initial model")
        self.assertEqual((self.app / "src/version.py").read_text(), "updated code")
        self.assertEqual((self.app / ".app_venv").read_text().strip(), str(self.venv))
        self.assertEqual((self.source / ".app_dir").read_text(), "/dev-machine/path\n")
        self.assertTrue((self.app / "setup.py").is_file())
        self.assertTrue((self.app / "assets").is_dir())
        self.assertTrue((self.app / ".gpu-server-deployment").is_file())
        self.assertTrue((self.app / "start.sh").is_file())
        self.assertTrue((self.app / "stop.sh").is_file())
        self.assertIn("--no-index", self.pip_log.read_text())
        self.assertIn("--no-build-isolation", self.pip_log.read_text())
        self.assertIn("--no-deps", self.pip_log.read_text())
        self.assertIn("-m pip check", self.pip_log.read_text())
        self.assertIn(str(self.app), self.pip_log.read_text())
        self.assertNotIn(str(self.source) + "\n", self.pip_log.read_text())

    def test_dry_run_is_read_only_and_renders_unit(self):
        before = sorted(p.relative_to(self.app) for p in self.app.rglob("*"))
        output = self.call("setup-gpu-server", "--dry-run", "--systemd")
        self.assertEqual(before, sorted(p.relative_to(self.app) for p in self.app.rglob("*")))
        self.assertFalse(self.pip_log.exists())
        self.assertIn(f"WorkingDirectory={self.app}", output)
        self.assertIn("EnvironmentFile=-/etc/mediapipe-gesture/env", output)
        self.assertIn(f"ExecStart=/bin/bash {self.app}/scripts/run-gpu-server.sh", output)

    def test_setup_without_rsync_copies_code_and_preserves_runtime(self):
        bash_env = self.root / "without-rsync.sh"
        bash_env.write_text('''command() {
    if [[ "$1" == -v && "${2:-}" == rsync ]]; then return 1; fi
    builtin command "$@"
}
''')
        self.script(self.bin / "rsync", "echo 'rsync must not be called' >&2; exit 99")
        env = {"BASH_ENV": str(bash_env)}
        self.assertIn("rsync unavailable; using cp -r", self.call(env=env))
        config = self.app / "etc/config.yaml"
        before = config.read_bytes()
        (self.source / "src/version.py").write_text("updated without rsync")
        (self.app / "src/retained.py").write_text("retained by cp fallback")
        self.call(env=env)
        self.assertEqual((self.app / "src/version.py").read_text(), "updated without rsync")
        self.assertTrue((self.app / "src/retained.py").is_file())
        self.assertEqual(config.read_bytes(), before)
        self.assertEqual((self.app / "models/gesture_recognizer.task").read_bytes(), b"initial model")
        self.assertTrue((self.app / "scripts/run-gpu-server.sh").is_file())

    def test_nemotron_path_and_venv_rejected(self):
        output = self.call("setup-gpu-server", "--app-dir", "/u01/ims/ai-engine", expected=1)
        self.assertIn("belongs to Nemotron", output)
        output = self.call("setup-gpu-server", "--venv", "/opt/nemotron-venv", expected=1)
        self.assertIn("Nemotron venv", output)
        self.assertFalse(self.pip_log.exists())

    def test_running_instance_blocks_setup_before_sync(self):
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            state = self.app / "run"
            state.mkdir()
            token = Path(f"/proc/{proc.pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
            (state / "mediapipe-gesture.pid").write_text(str(proc.pid))
            (state / "mediapipe-gesture.start").write_text(token + "\n")
            (state / "mediapipe-gesture.addr").write_text("127.0.0.1:1\n")
            self.assertIn("stop it before setup", self.call(expected=1))
            self.assertFalse((self.app / "src").exists())
            self.assertFalse(self.pip_log.exists())
            self.assertIsNone(proc.poll())
        finally:
            proc.terminate()
            proc.wait()

    def test_native_probe_is_explicit_and_failure_propagates(self):
        # Like Nemotron, setup checks installation; actual model init is at start/probe.
        self.call(env={"TEST_PROBE_FAIL": "1"})
        result = subprocess.run(["bash", str(self.app / "scripts/check-gpu-server.sh")],
                                env={**self.env, "APP_DIR": str(self.app), "TEST_PROBE_FAIL": "1"},
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("GPU probe failed", result.stdout + result.stderr)

    def test_existing_venv_without_pip_bootstraps_offline(self):
        self.call(env={"TEST_PIP_MISSING": "1"})
        self.assertIn("-m ensurepip --upgrade", self.pip_log.read_text())
        install_lines = [line for line in self.pip_log.read_text().splitlines() if " pip install " in line]
        self.assertTrue(install_lines)
        self.assertTrue(all("--no-index" in line and "--no-deps" in line for line in install_lines))

    def test_setup_does_not_call_legacy_installer(self):
        self.script(self.source / "scripts/install.sh", "echo 'legacy installer must not run' >&2; exit 99")
        self.call()

    def test_legacy_commands_refuse_gpu_deployment(self):
        self.call()
        for command in ("install", "upgrade", "start", "stop", "restart", "status"):
            self.assertIn("This deployment uses setup-gpu-server.sh", self.call(command, expected=1))

    def test_foreground_lock_blocks_setup_and_second_launcher(self):
        self.call()
        self.script(self.venv / "bin/mediapipe-gesture-server", "exec sleep 60")
        proc = subprocess.Popen(["bash", str(self.app / "scripts/run-gpu-server.sh")],
                                env={**self.env, "APP_DIR": str(self.app)},
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(.3)
            self.assertIsNone(proc.poll())
            before = self.pip_log.read_bytes()
            self.assertIn("stop gesture before setup", self.call(expected=1))
            self.assertEqual(self.pip_log.read_bytes(), before)
            second = subprocess.run(["bash", str(self.app / "scripts/run-gpu-server.sh")],
                                    env={**self.env, "APP_DIR": str(self.app)}, capture_output=True, text=True, timeout=5)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("already running", second.stderr)
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_previous_foreground_without_lock_blocks_setup(self):
        self.call()
        worker = self.venv / "bin/mediapipe-gesture-server"
        worker.write_text("import time\ntime.sleep(60)\n")
        proc = subprocess.Popen([sys.executable, str(worker), "--config", str(self.app / "etc/config.yaml")])
        try:
            self.assertIn("stop it before setup", self.call(expected=1))
            self.assertIsNone(proc.poll())
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_generated_background_start_stop_and_reinstall(self):
        self.call()
        self.script(self.venv / "bin/mediapipe-gesture-server", "exec sleep 60")
        def control(action):
            result = subprocess.run(["bash", str(self.app / f"{action}.sh")], env=self.env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout
        try:
            self.assertIn("Started PID=", control("start"))
            self.assertTrue((self.app / "run.pid").exists())
            self.assertTrue((self.app / "run.start").exists())
            self.assertIn("Already running", control("start"))
            self.assertNotEqual(self.call(expected=1), "")
            self.assertIn("Stopped PID=", control("stop"))
            self.assertFalse((self.app / "run.pid").exists())
            self.assertIn("Setup complete", self.call())
        finally:
            control("stop")

    def test_generated_stop_does_not_signal_reused_pid(self):
        self.call()
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            (self.app / "run.pid").write_text(str(proc.pid) + "\n")
            (self.app / "run.start").write_text("0\n")
            result = subprocess.run(["bash", str(self.app / "stop.sh")], env=self.env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("no signal sent", result.stdout)
            self.assertIsNone(proc.poll())
            self.assertFalse((self.app / "run.pid").exists())
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    def test_copy_model_dry_run_preserve_and_explicit_replace(self):
        model = self.app / "models/gesture_recognizer.task"
        self.call("copy-models", "--dry-run")
        self.assertFalse(model.exists())
        self.call("copy-models")
        (self.source / "checkpoint/gesture_recognizer.task").write_bytes(b"replacement")
        self.call("copy-models")
        self.assertEqual(model.read_bytes(), b"initial model")
        self.call("copy-models", "--replace")
        self.assertEqual(model.read_bytes(), b"replacement")

    def test_foreground_launcher_uses_runtime_config_and_exit_code(self):
        self.call()
        result = subprocess.run(["bash", str(self.app / "scripts/run-gpu-server.sh")],
                                env={**self.env, "APP_DIR": str(self.app), "TEST_WORKER_EXIT": "7"},
                                cwd="/tmp", text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn(f"worker cwd={self.app} args=--config {self.app}/etc/config.yaml", result.stdout)
        self.assertFalse((self.app / "run/mediapipe-gesture.pid").exists())


if __name__ == "__main__":
    unittest.main()
