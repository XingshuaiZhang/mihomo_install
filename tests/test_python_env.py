import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))
import residential as r


class PythonEnvironmentTests(unittest.TestCase):
    def test_existing_python_needs_no_install(self):
        with tempfile.TemporaryDirectory() as directory:
            env = {**os.environ, "MIHOMO_PYTHON": sys.executable, "XDG_DATA_HOME": directory}
            result = subprocess.run(["bash", str(PROJECT / "setup_python.sh")], env=env,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("无需安装", result.stdout)
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_explicit_invalid_python_does_not_silently_use_another(self):
        env = {**os.environ, "MIHOMO_PYTHON": "/not-an-interpreter"}
        result = subprocess.run(["bash", str(PROJECT / "residential.sh"), "--help"],
                                env=env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("setup_python.sh", result.stderr)

    def test_user_environment_is_found_without_activation(self):
        with tempfile.TemporaryDirectory() as directory:
            venv = Path(directory) / "mihomo_install/venv"
            subprocess.run([sys.executable, "-m", "venv", "--without-pip", "--system-site-packages", str(venv)],
                           check=True, capture_output=True, timeout=20)
            env = {**os.environ, "XDG_DATA_HOME": directory}
            env.pop("MIHOMO_PYTHON", None)
            result = subprocess.run(["bash", "-c", 'source "$1"; mihomo_python', "_", str(PROJECT / "python_env.sh")],
                                    env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(venv / "bin/python"))

    def test_cron_launcher_uses_working_python_and_preserves_arguments(self):
        with tempfile.TemporaryDirectory(prefix="mihomo cron ") as directory:
            root = Path(directory)
            r.copy_runtime_tool(root)
            (root / "residential.py").write_text("import json, sys; print(json.dumps([sys.executable, sys.argv[1:]]))")
            result = subprocess.run(["/bin/bash", str(root / "residential-refresh.sh"),
                                     "--subscription-file", "/path with spaces/sub.yaml"],
                                    env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            executable, args = json.loads(result.stdout)
            self.assertEqual(executable, sys.executable)
            self.assertEqual(args, ["--install-dir", str(root), "refresh", "--subscription-file", "/path with spaces/sub.yaml"])
            self.assertEqual((root / "residential-refresh.sh").stat().st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
