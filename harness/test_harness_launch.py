"""Exercise server launch arguments in a disposable tree with a fake JVM."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class HarnessLaunchTests(unittest.TestCase):
    def test_both_servers_allow_resume(self):
        harness = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "harness").mkdir()
            for name in ("run-one.sh", "worldline.toml"):
                shutil.copy2(harness / name, root / "harness" / name)
            (root / "harness/.built-revisions").write_text("proxy=fixture\nserver=fixture\n")
            libs = root / "server/paper-server/build/libs"
            libs.mkdir(parents=True)
            (libs / "paper-bundler-fixture.jar").touch()
            tools = root / "tools"
            tools.mkdir()
            for name, script in {
                "git": '#!/bin/sh\nprintf "fixture\\n"\n',
                "java": '#!/bin/sh\nprintf "%s\\n" "$@" > "$HARNESS_CAPTURE"\n',
            }.items():
                path = tools / name
                path.write_text(script)
                path.chmod(0o755)
            for server, port, control, partition in (
                ("server-a", "25566", "25576", "west"),
                ("server-b", "25567", "25577", "east"),
            ):
                with self.subTest(server=server):
                    run = root / "server/run" / server
                    run.mkdir(parents=True)
                    (run / "eula.txt").write_text("eula=false\n")
                    (run / "server.properties").write_text("enforce-secure-profile=false\n")
                    capture = root / f"{server}.args"
                    env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", HARNESS_CAPTURE=str(capture))
                    result = subprocess.run(["bash", str(root / "harness/run-one.sh"), server],
                                            env=env, capture_output=True, text=True)
                    self.assertEqual(0, result.returncode, result.stderr)
                    args = capture.read_text().splitlines()
                    for expected in ("-Dworldline.resume=true", f"-Dworldline.server-id={server}",
                                     f"-Dworldline.control-port={control}", f"-Dworldline.partition-id={partition}"):
                        self.assertIn(expected, args)
                    self.assertEqual(port, args[args.index("--port") + 1])
                    self.assertEqual("eula=false\n", (run / "eula.txt").read_text())


if __name__ == "__main__":
    unittest.main()
