import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import CalledProcessError
from unittest import mock


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

    def test_plan_project_selects_build_commands_for_current_platform(self):
        bootstrap = load_module()

        project = {
            "name": "demo",
            "directory": "demo",
            "primary_remote": "origin",
            "remotes": {"origin": "https://example.invalid/demo.git"},
            "checkout": "main",
            "build": {
                "linux": ["cmake -S . -B build", "cmake --build build"],
                "macos": ["xcodebuild -project Demo.xcodeproj"],
            },
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            with mock.patch.object(bootstrap, "current_platform", return_value="linux"):
                planned = bootstrap.plan_project(project, Path(temp_dir))

        self.assertEqual(
            ["cmake -S . -B build", "cmake --build build"],
            planned.build_commands,
        )

    def test_run_build_commands_executes_from_checkout_directory(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[],
            build_commands=["cmake -S . -B build", "cmake --build build"],
            profiles=[],
        )

        with mock.patch.object(bootstrap.subprocess, "run") as run_mock:
            results = bootstrap.run_build_commands([planned], dry_run=False)

        self.assertEqual(2, run_mock.call_count)
        self.assertEqual([planned.path, planned.path], [call.kwargs["cwd"] for call in run_mock.call_args_list])
        self.assertEqual(
            ["cmake -S . -B build", "cmake --build build"],
            results[0].printed_commands,
        )
        self.assertEqual("succeeded", results[0].status)

    def test_run_build_commands_dry_run_prints_without_running(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[],
            build_commands=["cmake -S . -B build"],
            profiles=[],
        )

        with mock.patch.object(bootstrap.subprocess, "run") as run_mock:
            results = bootstrap.run_build_commands([planned], dry_run=True)

        self.assertEqual([], run_mock.call_args_list)
        self.assertEqual(["cmake -S . -B build"], results[0].printed_commands)
        self.assertEqual("succeeded", results[0].status)

    def test_run_build_commands_reports_empty_build_list(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[],
            build_commands=[],
            profiles=[],
        )

        with mock.patch.object(bootstrap.subprocess, "run") as run_mock:
            results = bootstrap.run_build_commands([planned], dry_run=False)

        self.assertEqual([], run_mock.call_args_list)
        self.assertEqual([], results[0].printed_commands)
        self.assertEqual("succeeded", results[0].status)

    def test_run_build_commands_marks_failures_and_continues(self):
        bootstrap = load_module()

        failing = bootstrap.PlannedProject(
            name="failing",
            path=Path("/tmp/failing-checkout"),
            commands=[],
            build_commands=["cmake -S . -B build", "cmake --build build"],
            profiles=[],
        )
        succeeding = bootstrap.PlannedProject(
            name="succeeding",
            path=Path("/tmp/succeeding-checkout"),
            commands=[],
            build_commands=["make -j4"],
            profiles=[],
        )

        with mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=[
                CalledProcessError(1, "cmake -S . -B build"),
                None,
            ],
        ) as run_mock:
            results = bootstrap.run_build_commands([failing, succeeding], dry_run=False)

        self.assertEqual(2, run_mock.call_count)
        self.assertEqual(["cmake -S . -B build", "make -j4"], [call.args[0] for call in run_mock.call_args_list])
        self.assertEqual("failed", results[0].status)
        self.assertIsInstance(results[0].error, CalledProcessError)
        self.assertEqual(["cmake -S . -B build"], results[0].printed_commands)
        self.assertEqual("succeeded", results[1].status)
        self.assertEqual(["make -j4"], results[1].printed_commands)

    def test_run_build_commands_contains_runtime_launch_failures(self):
        bootstrap = load_module()

        failing = bootstrap.PlannedProject(
            name="failing",
            path=Path("/tmp/missing-checkout"),
            commands=[],
            build_commands=["cmake -S . -B build"],
            profiles=[],
        )
        succeeding = bootstrap.PlannedProject(
            name="succeeding",
            path=Path("/tmp/succeeding-checkout"),
            commands=[],
            build_commands=["make -j4"],
            profiles=[],
        )

        with mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=[
                FileNotFoundError("missing build tool"),
                None,
            ],
        ) as run_mock:
            results = bootstrap.run_build_commands([failing, succeeding], dry_run=False)

        self.assertEqual(2, run_mock.call_count)
        self.assertEqual("failed", results[0].status)
        self.assertIsInstance(results[0].error, FileNotFoundError)
        self.assertEqual(["cmake -S . -B build"], results[0].printed_commands)
        self.assertEqual("succeeded", results[1].status)

    def test_run_sync_commands_contains_runtime_launch_failures(self):
        bootstrap = load_module()

        failing = bootstrap.PlannedProject(
            name="failing",
            path=Path("/tmp/failing-checkout"),
            commands=[["git", "clone", "https://example.invalid/failing.git"]],
            build_commands=[],
            profiles=[],
        )
        succeeding = bootstrap.PlannedProject(
            name="succeeding",
            path=Path("/tmp/succeeding-checkout"),
            commands=[["git", "clone", "https://example.invalid/succeeding.git"]],
            build_commands=[],
            profiles=[],
        )

        with mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=[
                FileNotFoundError("git not found"),
                None,
            ],
        ) as run_mock:
            results = bootstrap.run_sync_commands([failing, succeeding], dry_run=False)

        self.assertEqual(2, run_mock.call_count)
        self.assertEqual("failed", results[0].status)
        self.assertIsInstance(results[0].error, FileNotFoundError)
        self.assertEqual("succeeded", results[1].status)

    def test_run_plan_skips_build_after_sync_failure(self):
        bootstrap = load_module()

        failing = bootstrap.PlannedProject(
            name="failing",
            path=Path("/tmp/failing-checkout"),
            commands=[["git", "clone", "https://example.invalid/failing.git"]],
            build_commands=["cmake -S . -B build"],
            profiles=[],
        )
        succeeding = bootstrap.PlannedProject(
            name="succeeding",
            path=Path("/tmp/succeeding-checkout"),
            commands=[],
            build_commands=["make -j4"],
            profiles=[],
        )

        with mock.patch.object(
            bootstrap.subprocess,
            "run",
            side_effect=[
                CalledProcessError(1, ["git", "clone", "https://example.invalid/failing.git"]),
                None,
            ],
        ) as run_mock:
            results = bootstrap.run_plan([failing, succeeding], dry_run=False)

        self.assertEqual(2, run_mock.call_count)
        self.assertEqual(
            [["git", "clone", "https://example.invalid/failing.git"], "make -j4"],
            [call.args[0] for call in run_mock.call_args_list],
        )
        self.assertEqual("failed", results[0].sync.status)
        self.assertEqual([], results[0].build.printed_commands)
        self.assertEqual("skipped", results[0].build.status)
        self.assertEqual("succeeded", results[1].build.status)

    def test_main_returns_non_zero_on_sync_failure(self):
        bootstrap = load_module()

        failed_result = bootstrap.ProjectExecutionResult(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            sync=bootstrap.CommandPhaseResult(
                name="demo",
                path=Path("/tmp/demo-checkout"),
                printed_commands=["git clone demo"],
                status="failed",
                error=CalledProcessError(1, ["git", "clone", "demo"]),
            ),
            build=bootstrap.CommandPhaseResult(
                name="demo",
                path=Path("/tmp/demo-checkout"),
                printed_commands=[],
                status="skipped",
            ),
        )

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[]), \
            mock.patch.object(bootstrap, "run_plan", return_value=[failed_result]):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH)])

        self.assertEqual(1, exit_code)

    def test_main_returns_non_zero_on_build_failure(self):
        bootstrap = load_module()

        failed_result = bootstrap.ProjectExecutionResult(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            sync=bootstrap.CommandPhaseResult(
                name="demo",
                path=Path("/tmp/demo-checkout"),
                printed_commands=["git clone demo"],
                status="succeeded",
            ),
            build=bootstrap.CommandPhaseResult(
                name="demo",
                path=Path("/tmp/demo-checkout"),
                printed_commands=["cmake -S . -B build"],
                status="failed",
                error=CalledProcessError(1, "cmake -S . -B build"),
            ),
        )

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[]), \
            mock.patch.object(bootstrap, "run_plan", return_value=[failed_result]):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH)])

        self.assertEqual(1, exit_code)


if __name__ == "__main__":
    unittest.main()
