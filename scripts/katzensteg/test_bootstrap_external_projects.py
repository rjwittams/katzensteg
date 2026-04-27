import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).with_name("bootstrap_external_projects.py")
MANIFEST_PATH = Path(__file__).resolve().parents[2] / "profiles" / "external-projects.json"


def load_module():
    spec = importlib.util.spec_from_file_location("bootstrap_external_projects", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class BootstrapExternalProjectsTest(unittest.TestCase):
    def test_manifest_records_retroarch_pushed_branch(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        retroarch = bootstrap.project_by_name(manifest, "retroarch")

        self.assertEqual("RetroArch", retroarch["directory"])
        self.assertEqual("rjwittams", retroarch["primary_remote"])
        self.assertEqual("macos-sdl2-window-contexts", retroarch["checkout"])
        self.assertIn("jsr", retroarch["profiles"])

    def test_absent_checkout_plans_branch_clone(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        with tempfile.TemporaryDirectory() as temp_dir:
            plan = bootstrap.plan_projects(manifest, Path(temp_dir), names=["retroarch"])

        self.assertEqual(1, len(plan))
        command = plan[0].commands[0]
        self.assertEqual("git", command[0])
        self.assertIn("clone", command)
        self.assertIn("--origin", command)
        self.assertIn("rjwittams", command)
        self.assertIn("--branch", command)
        self.assertIn("macos-sdl2-window-contexts", command)

    def test_selection_accepts_launcher_profile_names(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        selected = bootstrap.select_projects(manifest, names=["chiaki.sdl", "cannonball"])

        self.assertEqual(["cannonball", "chiaki-ng"], [project["name"] for project in selected])


if __name__ == "__main__":
    unittest.main()
