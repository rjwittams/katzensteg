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
    def assertDoctorShape(self, project):
        doctor = project["doctor"]

        self.assertEqual(
            {"tools", "pkg_config", "paths", "assets"},
            set(doctor.keys()),
            project["name"],
        )
        self.assertIsInstance(doctor["tools"], list, project["name"])
        self.assertIsInstance(doctor["pkg_config"], list, project["name"])
        self.assertIsInstance(doctor["paths"], list, project["name"])
        self.assertIsInstance(doctor["assets"], list, project["name"])

        for tool_name in doctor["tools"]:
            self.assertIsInstance(tool_name, str, project["name"])

        for module_name in doctor["pkg_config"]:
            self.assertIsInstance(module_name, str, project["name"])

        for path_entry in doctor["paths"]:
            self.assertIsInstance(path_entry, dict, project["name"])
            self.assertIn("kind", path_entry, project["name"])
            self.assertIn("path", path_entry, project["name"])
            self.assertIsInstance(path_entry["kind"], str, project["name"])
            self.assertIsInstance(path_entry["path"], str, project["name"])

        for asset_entry in doctor["assets"]:
            self.assertIsInstance(asset_entry, dict, project["name"])
            self.assertIn("path", asset_entry, project["name"])
            self.assertIsInstance(asset_entry["path"], str, project["name"])

    def test_manifest_records_retroarch_pushed_branch(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        retroarch = bootstrap.project_by_name(manifest, "retroarch")

        self.assertEqual("RetroArch", retroarch["directory"])
        self.assertEqual("rjwittams", retroarch["primary_remote"])
        self.assertEqual("macos-sdl2-window-contexts", retroarch["checkout"])
        self.assertIn("jsr", retroarch["profiles"])

    def test_manifest_records_package_hints(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        package_hints = manifest["package_hints"]
        expected_arch = {
            "cmake": "cmake",
            "ffplay": "ffmpeg",
            "git": "git",
            "opus": "opus",
            "pkg-config": "pkgconf",
            "qmake6": "qt6-base",
            "sdl2": "sdl2",
        }
        expected_debian = {
            "cmake": "cmake",
            "ffplay": "ffmpeg",
            "git": "git",
            "opus": "libopus-dev",
            "pkg-config": "pkg-config",
            "qmake6": "qt6-base-dev",
            "sdl2": "libsdl2-dev",
        }

        self.assertEqual({"arch", "debian"}, set(package_hints))
        self.assertEqual(expected_arch, package_hints["arch"])
        self.assertEqual(expected_debian, package_hints["debian"])

    def test_manifest_records_doctor_metadata(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        moonlight = bootstrap.project_by_name(manifest, "moonlight-qt")
        chiaki = bootstrap.project_by_name(manifest, "chiaki-ng")
        cannonball = bootstrap.project_by_name(manifest, "cannonball")
        scummvm = bootstrap.project_by_name(manifest, "scummvm")

        self.assertEqual(["qmake6"], moonlight["doctor"]["tools"])
        self.assertIn("sdl2", moonlight["doctor"]["pkg_config"])
        self.assertIn(
            {"kind": "output", "path": "app/release"},
            moonlight["doctor"]["paths"],
        )

        self.assertEqual(["uv", "cmake"], chiaki["doctor"]["tools"])
        self.assertIn("opus", chiaki["doctor"]["pkg_config"])
        self.assertIn(
            {"kind": "output", "path": ".codex-tmp/build-sdl-prototype"},
            chiaki["doctor"]["paths"],
        )

        self.assertIn(
            {"kind": "config", "path": "config.xml"},
            cannonball["doctor"]["paths"],
        )
        self.assertIn({"path": "$HOME/roms/mi2"}, scummvm["doctor"]["assets"])

    def test_manifest_records_doctor_shape_for_every_project(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)

        for project in manifest["projects"]:
            self.assertIn("doctor", project, project["name"])
            self.assertDoctorShape(project)

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
