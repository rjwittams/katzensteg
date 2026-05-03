import importlib.util
import os
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

        self.assertTrue(
            {"tools", "pkg_config", "paths", "assets"}.issubset(doctor.keys()),
            project["name"],
        )
        self.assertIsInstance(doctor["tools"], list, project["name"])
        self.assertIsInstance(doctor["pkg_config"], list, project["name"])
        self.assertIsInstance(doctor["paths"], list, project["name"])
        self.assertIsInstance(doctor["assets"], list, project["name"])

        for tool_entry in doctor["tools"]:
            if isinstance(tool_entry, str):
                continue
            self.assertIsInstance(tool_entry, dict, project["name"])
            self.assertIn("name", tool_entry, project["name"])
            self.assertIsInstance(tool_entry["name"], str, project["name"])

        for module_entry in doctor["pkg_config"]:
            if isinstance(module_entry, str):
                continue
            self.assertIsInstance(module_entry, dict, project["name"])
            self.assertIn("name", module_entry, project["name"])
            self.assertIsInstance(module_entry["name"], str, project["name"])

        for path_entry in doctor["paths"]:
            self.assertIsInstance(path_entry, dict, project["name"])
            self.assertIn("kind", path_entry, project["name"])
            self.assertIn("path", path_entry, project["name"])
            self.assertIsInstance(path_entry["kind"], str, project["name"])
            self.assertIsInstance(path_entry["path"], str, project["name"])

        for asset_entry in doctor["assets"]:
            self.assertIsInstance(asset_entry, dict, project["name"])
            self.assertTrue("path" in asset_entry or "any_of" in asset_entry, project["name"])
            if "path" in asset_entry:
                self.assertIsInstance(asset_entry["path"], str, project["name"])
            if "any_of" in asset_entry:
                self.assertIsInstance(asset_entry["any_of"], list, project["name"])
                for path_value in asset_entry["any_of"]:
                    self.assertIsInstance(path_value, str, project["name"])

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
            "gamescope": "gamescope",
            "git": "git",
            "gl": "mesa",
            "make": "make",
            "opus": "opus",
            "patchelf": "patchelf",
            "pkg-config": "pkgconf",
            "qmake6": "qt6-base",
            "sdl2": "sdl2",
            "SDL2_ttf": "sdl2_ttf",
            "uv": "uv",
            "vulkan": "vulkan-headers vulkan-icd-loader",
            "zig": "zig",
        }
        expected_debian = {
            "cmake": "cmake",
            "ffplay": "ffmpeg",
            "gamescope": "gamescope",
            "git": "git",
            "gl": "libgl-dev",
            "make": "make",
            "opus": "libopus-dev",
            "patchelf": "patchelf",
            "pkg-config": "pkg-config",
            "qmake6": "qt6-base-dev",
            "sdl2": "libsdl2-dev",
            "SDL2_ttf": "libsdl2-ttf-dev",
            "vulkan": "libvulkan-dev",
            "zig": "zig",
        }
        expected_brew = {
            "cmake": "cmake",
            "ffplay": "ffmpeg",
            "git": "git",
            "opus": "opus",
            "patchelf": "patchelf",
            "pkg-config": "pkgconf",
            "qmake6": "qt",
            "sdl2": "sdl2",
            "SDL2_ttf": "sdl2_ttf",
            "uv": "uv",
            "zig": "zig",
        }

        self.assertIn("arch", package_hints)
        self.assertIn("brew", package_hints)
        self.assertIn("debian", package_hints)
        self.assertEqual(expected_arch, package_hints["arch"])
        self.assertEqual(expected_brew, package_hints["brew"])
        self.assertEqual(expected_debian, package_hints["debian"])

    def test_detect_distro_family_recognizes_arch(self):
        bootstrap = load_module()

        os_release_text = "\n".join(
            [
                'NAME="Arch Linux"',
                "ID=arch",
                'ID_LIKE="archlinux"',
            ]
        )

        self.assertEqual("arch", bootstrap.detect_distro_family(os_release_text, platform="linux"))

    def test_detect_distro_family_recognizes_debian_like(self):
        bootstrap = load_module()

        os_release_text = "\n".join(
            [
                'NAME="Ubuntu"',
                "ID=ubuntu",
                "ID_LIKE=debian",
            ]
        )

        self.assertEqual("debian", bootstrap.detect_distro_family(os_release_text, platform="linux"))

    def test_detect_distro_family_recognizes_macos(self):
        bootstrap = load_module()

        self.assertEqual("brew", bootstrap.detect_distro_family(None, platform="darwin"))

    def test_render_install_hint_lines_formats_arch_command(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        report_lines = bootstrap.render_install_hint_lines(manifest, ["ffplay"], distro_family="arch")

        self.assertEqual(["sudo pacman -S --needed ffmpeg"], report_lines)

    def test_render_install_hint_lines_formats_debian_command(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        report_lines = bootstrap.render_install_hint_lines(manifest, ["ffplay"], distro_family="debian")

        self.assertEqual(["sudo apt install ffmpeg"], report_lines)

    def test_render_install_hint_lines_formats_brew_command(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        report_lines = bootstrap.render_install_hint_lines(manifest, ["ffplay"], distro_family="brew")

        self.assertEqual(["brew install ffmpeg"], report_lines)

    def test_render_install_hint_lines_uses_unsupported_distro_fallback(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        report_lines = bootstrap.render_install_hint_lines(
            manifest,
            ["ffplay", "pkg-config"],
            distro_family="unknown",
        )

        self.assertEqual(
            [
                "No package hints available for distro family: unknown",
                "ffplay",
                "pkg-config",
            ],
            report_lines,
        )

    def test_render_install_hint_lines_does_not_guess_missing_package_mapping(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        report_lines = bootstrap.render_install_hint_lines(manifest, ["nonexistent-capability"], distro_family="debian")

        self.assertEqual(
            ["No package hint for capability: nonexistent-capability"],
            report_lines,
        )

    def test_manifest_records_doctor_metadata(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        repo_doctor = manifest["doctor"]
        retroarch = bootstrap.project_by_name(manifest, "retroarch")
        moonlight = bootstrap.project_by_name(manifest, "moonlight-qt")
        chiaki = bootstrap.project_by_name(manifest, "chiaki-ng")
        cannonball = bootstrap.project_by_name(manifest, "cannonball")
        scummvm = bootstrap.project_by_name(manifest, "scummvm")

        self.assertIn("zig", repo_doctor["tools"])
        self.assertIn("pkg-config", repo_doctor["tools"])
        self.assertIn({"name": "gamescope", "platforms": ["linux"]}, repo_doctor["tools"])
        self.assertIn("sdl2", repo_doctor["pkg_config"])
        self.assertIn({"name": "gl", "platforms": ["linux"]}, repo_doctor["pkg_config"])
        self.assertTrue(
            any(
                asset.get("label", "").startswith("RetroArch bsnes core")
                for asset in retroarch["doctor"]["assets"]
            )
        )
        self.assertEqual(["qmake6"], moonlight["doctor"]["tools"])
        self.assertIn("sdl2", moonlight["doctor"]["pkg_config"])
        self.assertIn("SDL2_ttf", moonlight["doctor"]["pkg_config"])
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
            {"kind": "config", "path": "build/config.xml"},
            cannonball["doctor"]["paths"],
        )
        self.assertIn({"path": "roms/epr-10381b.132"}, cannonball["doctor"]["assets"])
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

        with mock.patch.object(bootstrap.subprocess, "run") as run_mock, \
            mock.patch("builtins.print"):
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

        with mock.patch.object(bootstrap.subprocess, "run") as run_mock, \
            mock.patch("builtins.print"):
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

        with mock.patch.object(bootstrap.subprocess, "run") as run_mock, \
            mock.patch("builtins.print"):
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
        ) as run_mock, \
            mock.patch("builtins.print"):
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
        ) as run_mock, \
            mock.patch("builtins.print"):
            results = bootstrap.run_build_commands([failing, succeeding], dry_run=False)

        self.assertEqual(2, run_mock.call_count)
        self.assertEqual("failed", results[0].status)
        self.assertIsInstance(results[0].error, FileNotFoundError)
        self.assertEqual(["cmake -S . -B build"], results[0].printed_commands)
        self.assertEqual("succeeded", results[1].status)

    def test_run_doctor_classifies_missing_tools_packages_and_paths(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "cannonball",
                    "directory": "cannonball",
                    "doctor": {
                        "tools": ["missing-tool"],
                        "pkg_config": ["missing-module"],
                        "paths": [
                            {"kind": "output", "path": "build/cannonball"},
                            {"kind": "config", "path": "config.xml"},
                        ],
                        "assets": [
                            {"path": "$HOME/roms/game.bin"},
                        ],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            project_root = root / "cannonball"
            project_root.mkdir(parents=True)
            expected_config = str(project_root / "config.xml")
            expected_output = str(project_root / "build" / "cannonball")
            expected_asset = str(Path(temp_dir) / "roms" / "game.bin")

            with mock.patch.dict(os.environ, {"HOME": temp_dir}, clear=False), \
                mock.patch.object(bootstrap.shutil, "which", return_value=None) as which_mock, \
                mock.patch.object(
                    bootstrap.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=1),
                ) as run_mock:
                report = bootstrap.run_doctor(manifest, root, names=["cannonball"])

        self.assertEqual(["missing-tool"], report.missing_tools)
        self.assertEqual(["missing-module"], report.missing_packages)
        self.assertEqual([expected_output], report.missing_outputs)
        self.assertEqual([expected_config], report.missing_configs)
        self.assertEqual([expected_asset], report.missing_assets)
        self.assertIn("missing tools", report.summary)
        self.assertIn("missing pkg-config modules", report.summary)
        self.assertIn("missing outputs", report.summary)
        self.assertIn("missing configs", report.summary)
        self.assertIn("missing assets", report.summary)
        which_mock.assert_called_once_with("missing-tool")
        run_mock.assert_called_once_with(
            ["pkg-config", "--exists", "missing-module"],
            check=False,
            stdout=bootstrap.subprocess.DEVNULL,
            stderr=bootstrap.subprocess.DEVNULL,
        )

    def test_run_doctor_checks_repo_doctor_and_platform_filtered_entries(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "doctor": {
                "tools": ["repo-tool"],
                "pkg_config": [
                    {"name": "linux-module", "platforms": ["linux"]},
                    {"name": "macos-module", "platforms": ["macos"]},
                ],
                "paths": [],
                "assets": [],
            },
            "projects": [
                {
                    "name": "retroarch",
                    "directory": "retroarch",
                    "doctor": {
                        "tools": [],
                        "pkg_config": [],
                        "paths": [],
                        "assets": [
                            {
                                "label": "linux core",
                                "platforms": ["linux"],
                                "any_of": ["missing-core.so", "present-core.so"],
                            },
                            {
                                "label": "macos core",
                                "platforms": ["macos"],
                                "path": "missing-core.dylib",
                            },
                        ],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            project_root = root / "retroarch"
            project_root.mkdir(parents=True)
            (project_root / "present-core.so").write_text("core", encoding="utf-8")

            with mock.patch.object(bootstrap, "current_platform", return_value="linux"), \
                mock.patch.object(bootstrap.shutil, "which", return_value=None), \
                mock.patch.object(
                    bootstrap.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=1),
                ) as run_mock:
                report = bootstrap.run_doctor(manifest, root, names=["retroarch"])

        self.assertEqual(["repo-tool"], report.missing_tools)
        self.assertEqual(["linux-module"], report.missing_packages)
        self.assertEqual([], report.missing_assets)
        run_mock.assert_called_once()
        self.assertEqual("linux-module", run_mock.call_args.args[0][2])

    def test_run_doctor_reports_missing_any_of_asset_by_label(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "retroarch",
                    "directory": "retroarch",
                    "doctor": {
                        "tools": [],
                        "pkg_config": [],
                        "paths": [],
                        "assets": [
                            {
                                "label": "RetroArch bsnes core",
                                "any_of": ["missing-a.so", "missing-b.so"],
                            },
                        ],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            (root / "retroarch").mkdir(parents=True)
            report = bootstrap.run_doctor(manifest, root, names=["retroarch"])

        self.assertEqual(["RetroArch bsnes core"], report.missing_assets)

    def test_run_doctor_reports_execstack_libretro_assets(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "retroarch",
                    "directory": "retroarch",
                    "doctor": {
                        "tools": [],
                        "pkg_config": [],
                        "paths": [],
                        "assets": [
                            {
                                "label": "RetroArch melonDS core",
                                "platforms": ["linux"],
                                "path": "cores/melonds_libretro.so",
                                "elf_no_execstack": True,
                            },
                        ],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            core_path = root / "retroarch" / "cores" / "melonds_libretro.so"
            core_path.parent.mkdir(parents=True)
            core_path.write_bytes(b"not a real elf")

            with mock.patch.object(bootstrap, "current_platform", return_value="linux"), \
                mock.patch.object(bootstrap.shutil, "which", return_value="/usr/bin/patchelf"), \
                mock.patch.object(
                    bootstrap.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=0, stdout="execstack: X\n"),
                ) as run_mock:
                report = bootstrap.run_doctor(manifest, root, names=["retroarch"])

        self.assertEqual(
            [
                bootstrap.InvalidAsset(
                    label="RetroArch melonDS core",
                    path=core_path,
                    repair_command=("patchelf", "--clear-execstack", str(core_path)),
                )
            ],
            report.invalid_assets,
        )
        self.assertEqual(
            [f"RetroArch melonDS core requests executable stack: {core_path}"],
            [str(item) for item in report.invalid_assets],
        )
        self.assertIn("invalid assets", report.summary)
        run_mock.assert_called_once_with(
            ["patchelf", "--print-execstack", str(core_path)],
            check=False,
            stdout=bootstrap.subprocess.PIPE,
            stderr=bootstrap.subprocess.DEVNULL,
            text=True,
        )

    def test_format_doctor_detail_lines_includes_missing_items_and_install_hints(self):
        bootstrap = load_module()

        manifest = bootstrap.load_manifest(MANIFEST_PATH)
        report = bootstrap.DoctorReport(
            missing_tools=["zig"],
            missing_packages=["sdl2"],
            missing_outputs=[],
            missing_configs=["/tmp/config.xml"],
            missing_assets=["RetroArch bsnes core"],
            summary="missing tools: 1",
            invalid_assets=[
                bootstrap.InvalidAsset(
                    label="RetroArch melonDS core",
                    path=Path("/tmp/melonds_libretro.so"),
                    repair_command=("patchelf", "--clear-execstack", "/tmp/melonds_libretro.so"),
                )
            ],
        )

        lines = bootstrap.format_doctor_detail_lines(report, manifest, distro_family="arch")

        self.assertIn("Doctor details:", lines)
        self.assertIn("    zig", lines)
        self.assertIn("    sdl2", lines)
        self.assertIn("    /tmp/config.xml", lines)
        self.assertIn("    RetroArch bsnes core", lines)
        self.assertIn("    RetroArch melonDS core requests executable stack: /tmp/melonds_libretro.so", lines)
        self.assertIn("    patchelf --clear-execstack /tmp/melonds_libretro.so", lines)
        self.assertIn("    sudo pacman -S --needed zig sdl2", lines)

    def test_run_doctor_summary_is_ok_when_nothing_is_missing(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "ready-project",
                    "directory": "ready-project",
                    "doctor": {
                        "tools": ["present-tool"],
                        "pkg_config": ["present-module"],
                        "paths": [
                            {"kind": "output", "path": "build/output.bin"},
                            {"kind": "config", "path": "config.xml"},
                        ],
                        "assets": [
                            {"path": "$HOME/assets/ready.bin"},
                        ],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            project_root = root / "ready-project"
            (project_root / "build").mkdir(parents=True)
            project_root.mkdir(parents=True, exist_ok=True)
            (project_root / "build" / "output.bin").write_text("ok", encoding="utf-8")
            (project_root / "config.xml").write_text("<config />", encoding="utf-8")
            asset_path = Path(temp_dir) / "assets" / "ready.bin"
            asset_path.parent.mkdir(parents=True)
            asset_path.write_text("asset", encoding="utf-8")

            with mock.patch.dict(os.environ, {"HOME": temp_dir}, clear=False), \
                mock.patch.object(bootstrap.shutil, "which", return_value="/usr/bin/present-tool"), \
                mock.patch.object(
                    bootstrap.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=0),
                ):
                report = bootstrap.run_doctor(manifest, root, names=["ready-project"])

        self.assertEqual([], report.missing_tools)
        self.assertEqual([], report.missing_packages)
        self.assertEqual([], report.missing_outputs)
        self.assertEqual([], report.missing_configs)
        self.assertEqual([], report.missing_assets)
        self.assertEqual("doctor ok", report.summary)

    def test_run_doctor_treats_pkg_config_launch_failure_as_missing_tool(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "pkg-config-project",
                    "directory": "pkg-config-project",
                    "doctor": {
                        "tools": [],
                        "pkg_config": ["sdl2", "opus"],
                        "paths": [],
                        "assets": [],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            (root / "pkg-config-project").mkdir(parents=True)

            with mock.patch.object(
                bootstrap.subprocess,
                "run",
                side_effect=FileNotFoundError("pkg-config not found"),
            ) as run_mock:
                report = bootstrap.run_doctor(manifest, root, names=["pkg-config-project"])

        self.assertEqual(["pkg-config"], report.missing_tools)
        self.assertEqual([], report.missing_packages)
        self.assertIn("missing tools", report.summary)
        self.assertNotIn("missing pkg-config modules", report.summary)
        self.assertEqual(1, run_mock.call_count)

    def test_run_doctor_rejects_unknown_path_kind(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "broken-project",
                    "directory": "broken-project",
                    "doctor": {
                        "tools": [],
                        "pkg_config": [],
                        "paths": [
                            {"kind": "typo", "path": "somewhere"},
                        ],
                        "assets": [],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"

            with self.assertRaisesRegex(ValueError, "unknown doctor path kind.*typo.*broken-project"):
                bootstrap.run_doctor(manifest, root, names=["broken-project"])

    def test_run_doctor_rejects_unknown_path_kind_even_when_path_exists(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "broken-project",
                    "directory": "broken-project",
                    "doctor": {
                        "tools": [],
                        "pkg_config": [],
                        "paths": [
                            {"kind": "typo", "path": "existing-file"},
                        ],
                        "assets": [],
                    },
                }
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            project_root = root / "broken-project"
            project_root.mkdir(parents=True)
            (project_root / "existing-file").write_text("present", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "unknown doctor path kind.*typo.*broken-project"):
                bootstrap.run_doctor(manifest, root, names=["broken-project"])

    def test_run_doctor_continues_across_multiple_projects(self):
        bootstrap = load_module()

        manifest = {
            "schema_version": 1,
            "projects": [
                {
                    "name": "first-project",
                    "directory": "first-project",
                    "doctor": {
                        "tools": ["missing-tool"],
                        "pkg_config": [],
                        "paths": [],
                        "assets": [],
                    },
                },
                {
                    "name": "second-project",
                    "directory": "second-project",
                    "doctor": {
                        "tools": [],
                        "pkg_config": ["missing-module"],
                        "paths": [
                            {"kind": "config", "path": "config.xml"},
                        ],
                        "assets": [
                            {"path": "$HOME/assets/missing.bin"},
                        ],
                    },
                },
            ],
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir) / "dev"
            (root / "first-project").mkdir(parents=True)
            (root / "second-project").mkdir(parents=True)
            expected_config = str(root / "second-project" / "config.xml")
            expected_asset = str(Path(temp_dir) / "assets" / "missing.bin")

            with mock.patch.dict(os.environ, {"HOME": temp_dir}, clear=False), \
                mock.patch.object(bootstrap.shutil, "which", return_value=None), \
                mock.patch.object(
                    bootstrap.subprocess,
                    "run",
                    return_value=mock.Mock(returncode=1),
                ):
                report = bootstrap.run_doctor(manifest, root, names=["first-project", "second-project"])

        self.assertEqual(["missing-tool"], report.missing_tools)
        self.assertEqual(["missing-module"], report.missing_packages)
        self.assertEqual([expected_config], report.missing_configs)
        self.assertEqual([expected_asset], report.missing_assets)
        self.assertIn("missing tools", report.summary)
        self.assertIn("missing pkg-config modules", report.summary)
        self.assertIn("missing configs", report.summary)
        self.assertIn("missing assets", report.summary)

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
        ) as run_mock, \
            mock.patch("builtins.print"):
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
        ) as run_mock, \
            mock.patch("builtins.print"):
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
            mock.patch.object(bootstrap, "run_plan", return_value=[failed_result]), \
            mock.patch.object(bootstrap, "run_doctor", return_value=bootstrap.DoctorReport([], [], [], [], [], "doctor ok")), \
            mock.patch("builtins.print"):
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
            mock.patch.object(bootstrap, "run_plan", return_value=[failed_result]), \
            mock.patch.object(bootstrap, "run_doctor", return_value=bootstrap.DoctorReport([], [], [], [], [], "doctor ok")), \
            mock.patch("builtins.print"):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH)])

        self.assertEqual(1, exit_code)

    def test_main_default_runs_sync_build_then_doctor(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[["git", "clone", "https://example.invalid/demo.git"]],
            build_commands=["cmake -S . -B build"],
            profiles=["demo.profile"],
        )
        events = []

        def fake_sync(plan, dry_run):
            events.append(("sync", [item.name for item in plan], dry_run))
            return [
                bootstrap.CommandPhaseResult(
                    name=plan[0].name,
                    path=plan[0].path,
                    printed_commands=["git clone demo"],
                    status="succeeded",
                )
            ]

        def fake_build(plan, dry_run):
            events.append(("build", [item.name for item in plan], dry_run))
            return [
                bootstrap.CommandPhaseResult(
                    name=plan[0].name,
                    path=plan[0].path,
                    printed_commands=["cmake -S . -B build"],
                    status="succeeded",
                )
            ]

        def fake_doctor(manifest, root, names=None, include_non_default=False):
            events.append(("doctor", list(names), include_non_default, root))
            return bootstrap.DoctorReport([], [], [], [], [], "doctor ok")

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp/dev", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[planned]) as plan_projects_mock, \
            mock.patch.object(bootstrap, "run_sync_commands", side_effect=fake_sync), \
            mock.patch.object(bootstrap, "run_build_commands", side_effect=fake_build), \
            mock.patch.object(bootstrap, "run_doctor", side_effect=fake_doctor), \
            mock.patch("builtins.print"):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH), "demo.profile"])

        self.assertEqual(0, exit_code)
        self.assertEqual(
            [("sync", ["demo"], False), ("build", ["demo"], False), ("doctor", ["demo.profile"], False, Path("/tmp/dev"))],
            events,
        )
        plan_projects_mock.assert_called_once_with(
            {"default_root": "/tmp/dev", "projects": []},
            Path("/tmp/dev"),
            ["demo.profile"],
            False,
        )

    def test_main_build_only_skips_sync_but_runs_build_and_doctor(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[["git", "clone", "https://example.invalid/demo.git"]],
            build_commands=["cmake -S . -B build"],
            profiles=[],
        )
        recorded_sync_calls = []
        recorded_build_calls = []

        def fake_build(plan, dry_run):
            recorded_build_calls.append((plan, dry_run))
            return [
                bootstrap.CommandPhaseResult(
                    name=plan[0].name,
                    path=plan[0].path,
                    printed_commands=["cmake -S . -B build"],
                    status="succeeded",
                )
            ]

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp/dev", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[planned]), \
            mock.patch.object(bootstrap, "run_sync_commands", side_effect=lambda *args: recorded_sync_calls.append(args)), \
            mock.patch.object(bootstrap, "run_build_commands", side_effect=fake_build), \
            mock.patch.object(bootstrap, "run_doctor", return_value=bootstrap.DoctorReport([], [], [], [], [], "doctor ok")) as doctor_mock, \
            mock.patch("builtins.print"):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH), "--build-only"])

        self.assertEqual(0, exit_code)
        self.assertEqual([], recorded_sync_calls)
        self.assertEqual([([planned], False)], recorded_build_calls)
        doctor_mock.assert_called_once_with({"default_root": "/tmp/dev", "projects": []}, Path("/tmp/dev"), [], False)

    def test_main_doctor_only_skips_sync_and_build(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[["git", "clone", "https://example.invalid/demo.git"]],
            build_commands=["cmake -S . -B build"],
            profiles=[],
        )
        recorded_sync_calls = []
        recorded_build_calls = []

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp/dev", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[planned]), \
            mock.patch.object(bootstrap, "run_sync_commands", side_effect=lambda *args: recorded_sync_calls.append(args)), \
            mock.patch.object(bootstrap, "run_build_commands", side_effect=lambda *args: recorded_build_calls.append(args)), \
            mock.patch.object(
                bootstrap,
                "run_doctor",
                return_value=bootstrap.DoctorReport(["missing-tool"], [], [], [], [], "missing tools: 1"),
            ) as doctor_mock, \
            mock.patch("builtins.print"):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH), "--doctor-only", "demo"])

        self.assertEqual(1, exit_code)
        self.assertEqual([], recorded_sync_calls)
        self.assertEqual([], recorded_build_calls)
        doctor_mock.assert_called_once_with({"default_root": "/tmp/dev", "projects": []}, Path("/tmp/dev"), ["demo"], False)

    def test_main_dry_run_still_runs_doctor_and_summary(self):
        bootstrap = load_module()

        planned = bootstrap.PlannedProject(
            name="demo",
            path=Path("/tmp/demo-checkout"),
            commands=[["git", "clone", "https://example.invalid/demo.git"]],
            build_commands=["cmake -S . -B build"],
            profiles=[],
        )
        dry_run_values = []
        printed_lines = []

        def fake_sync(plan, dry_run):
            dry_run_values.append(("sync", dry_run))
            return [
                bootstrap.CommandPhaseResult(
                    name=plan[0].name,
                    path=plan[0].path,
                    printed_commands=["git clone demo"],
                    status="succeeded",
                )
            ]

        def fake_build(plan, dry_run):
            dry_run_values.append(("build", dry_run))
            return [
                bootstrap.CommandPhaseResult(
                    name=plan[0].name,
                    path=plan[0].path,
                    printed_commands=["cmake -S . -B build"],
                    status="succeeded",
                )
            ]

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp/dev", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[planned]), \
            mock.patch.object(bootstrap, "run_sync_commands", side_effect=fake_sync), \
            mock.patch.object(bootstrap, "run_build_commands", side_effect=fake_build), \
            mock.patch.object(bootstrap, "run_doctor", return_value=bootstrap.DoctorReport([], [], [], [], [], "doctor ok")) as doctor_mock, \
            mock.patch("builtins.print", side_effect=lambda line="": printed_lines.append(line)):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH), "--dry-run"])

        self.assertEqual(0, exit_code)
        self.assertEqual([("sync", True), ("build", True)], dry_run_values)
        doctor_mock.assert_called_once()
        self.assertTrue(any("Final summary" in line for line in printed_lines))
        self.assertTrue(any("doctor: doctor ok" in line for line in printed_lines))

    def test_main_returns_non_zero_on_doctor_failure(self):
        bootstrap = load_module()

        with mock.patch.object(bootstrap, "load_manifest", return_value={"default_root": "/tmp/dev", "projects": []}), \
            mock.patch.object(bootstrap, "plan_projects", return_value=[]), \
            mock.patch.object(bootstrap, "run_plan", return_value=[]), \
            mock.patch.object(
                bootstrap,
                "run_doctor",
                return_value=bootstrap.DoctorReport([], ["missing-module"], [], [], [], "missing pkg-config modules: 1"),
            ), \
            mock.patch("builtins.print"):
            exit_code = bootstrap.main(["--manifest", str(MANIFEST_PATH)])

        self.assertEqual(1, exit_code)


if __name__ == "__main__":
    unittest.main()
