#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Literal


DEFAULT_MANIFEST = Path(__file__).resolve().parents[2] / "profiles" / "external-projects.json"
OS_RELEASE_PATH = Path("/etc/os-release")


@dataclass
class PlannedProject:
    name: str
    path: Path
    commands: list[list[str]]
    build_commands: list[str]
    profiles: list[str]


PhaseStatus = Literal["succeeded", "failed", "skipped"]


@dataclass
class CommandPhaseResult:
    name: str
    path: Path
    printed_commands: list[str]
    status: PhaseStatus
    error: Exception | None = None


@dataclass
class ProjectExecutionResult:
    name: str
    path: Path
    sync: CommandPhaseResult
    build: CommandPhaseResult


@dataclass
class DoctorReport:
    missing_tools: list[str]
    missing_packages: list[str]
    missing_outputs: list[str]
    missing_configs: list[str]
    missing_assets: list[str]
    summary: str


def load_manifest(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("schema_version") != 1:
        raise ValueError(f"unsupported manifest schema: {manifest.get('schema_version')!r}")
    if not isinstance(manifest.get("projects"), list):
        raise ValueError("manifest must contain a projects array")
    return manifest


def project_by_name(manifest: dict, name: str) -> dict:
    for project in manifest["projects"]:
        if project["name"] == name:
            return project
    raise KeyError(name)


def parse_os_release(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value.strip().strip("'\"")
    return values


def read_os_release(path: Path = OS_RELEASE_PATH) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return None


def detect_distro_family(os_release_text: str | None = None, platform: str | None = None) -> str:
    normalized_platform = platform or sys.platform
    if normalized_platform == "darwin":
        return "brew"
    if not normalized_platform.startswith("linux"):
        return "unknown"
    if os_release_text is None:
        os_release_text = read_os_release()
    if not os_release_text:
        return "unknown"

    os_release = parse_os_release(os_release_text)
    identities = {
        value.lower()
        for value in (
            os_release.get("ID", ""),
            *os_release.get("ID_LIKE", "").split(),
            os_release.get("NAME", ""),
        )
        if value
    }
    if "arch" in identities or "archlinux" in identities:
        return "arch"
    if {"debian", "ubuntu"} & identities:
        return "debian"
    return "unknown"


def resolve_package_names(manifest: dict, capabilities: Iterable[str], distro_family: str) -> tuple[list[str], list[str]]:
    package_hints = manifest.get("package_hints", {})
    distro_hints = package_hints.get(distro_family)
    if distro_hints is None:
        return [], list(capabilities)

    packages: list[str] = []
    missing: list[str] = []
    for capability in capabilities:
        package_name = distro_hints.get(capability)
        if package_name is None:
            missing.append(capability)
            continue
        packages.append(package_name)
    return packages, missing


def format_install_command(distro_family: str, package_names: Iterable[str]) -> str | None:
    packages = list(dict.fromkeys(package_names))
    if not packages:
        return None
    if distro_family == "arch":
        return "sudo pacman -S --needed " + " ".join(packages)
    if distro_family == "debian":
        return "sudo apt install " + " ".join(packages)
    if distro_family == "brew":
        return "brew install " + " ".join(packages)
    return None


def render_install_hint_lines(manifest: dict, capabilities: Iterable[str], distro_family: str | None = None) -> list[str]:
    resolved_distro_family = distro_family or detect_distro_family()
    if resolved_distro_family not in manifest.get("package_hints", {}):
        return [
            f"No package hints available for distro family: {resolved_distro_family}",
            *list(capabilities),
        ]

    package_names, missing_capabilities = resolve_package_names(manifest, capabilities, resolved_distro_family)
    command = format_install_command(resolved_distro_family, package_names)
    lines: list[str] = []
    if command is not None:
        lines.append(command)
    for capability in missing_capabilities:
        lines.append(f"No package hint for capability: {capability}")
    return lines


def select_projects(manifest: dict, names: Iterable[str] | None = None, include_non_default: bool = False) -> list[dict]:
    requested = list(names or [])
    if not requested:
        return [project for project in manifest["projects"] if include_non_default or project.get("default", True)]

    selected = [
        project
        for project in manifest["projects"]
        if any(name == project["name"] or name in project.get("profiles", []) for name in requested)
    ]
    matched_names = {
        name
        for project in selected
        for name in [project["name"], *project.get("profiles", [])]
        if name in requested
    }
    unknown = [name for name in requested if name not in matched_names]
    if unknown:
        raise ValueError("unknown project/profile: " + ", ".join(unknown))
    return selected


def expand_path(path: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(path)))


def doctor_project_root(root: Path, project: dict) -> Path:
    return root / project["directory"]


def doctor_path(project_root: Path, path_value: str) -> Path:
    candidate = expand_path(path_value)
    if candidate.is_absolute():
        return candidate
    return project_root / candidate


def doctor_entry_applies(entry: str | dict, platform: str | None = None) -> bool:
    if not isinstance(entry, dict):
        return True
    platforms = entry.get("platforms")
    if platforms is None:
        return True
    return (platform or current_platform()) in platforms


def doctor_entry_name(entry: str | dict) -> str:
    if isinstance(entry, str):
        return entry
    return entry["name"]


def iter_doctor_names(entries: Iterable[str | dict], platform: str | None = None) -> Iterable[str]:
    for entry in entries:
        if doctor_entry_applies(entry, platform):
            yield doctor_entry_name(entry)


def resolve_asset_paths(project_root: Path, asset_entry: dict) -> list[Path]:
    if "path" in asset_entry:
        return [doctor_path(project_root, asset_entry["path"])]
    if "any_of" in asset_entry:
        return [doctor_path(project_root, path_value) for path_value in asset_entry["any_of"]]
    raise ValueError(f"doctor asset entry must contain path or any_of: {asset_entry!r}")


def missing_asset_label(asset_entry: dict, resolved_paths: list[Path]) -> str:
    if label := asset_entry.get("label"):
        return str(label)
    if len(resolved_paths) == 1:
        return str(resolved_paths[0])
    return "one of: " + ", ".join(str(path) for path in resolved_paths)


PkgConfigStatus = Literal["present", "missing_module", "missing_tool"]


def run_pkg_config_exists(module_name: str) -> PkgConfigStatus:
    try:
        result = subprocess.run(
            ["pkg-config", "--exists", module_name],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return "missing_tool"
    if result.returncode == 0:
        return "present"
    return "missing_module"


def format_doctor_summary(report: DoctorReport) -> str:
    categories = [
        ("missing tools", report.missing_tools),
        ("missing pkg-config modules", report.missing_packages),
        ("missing outputs", report.missing_outputs),
        ("missing configs", report.missing_configs),
        ("missing assets", report.missing_assets),
    ]
    parts = [f"{label}: {len(items)}" for label, items in categories if items]
    if not parts:
        return "doctor ok"
    return ", ".join(parts)


def run_doctor(
    manifest: dict,
    root: Path,
    names: Iterable[str] | None = None,
    include_non_default: bool = False,
) -> DoctorReport:
    missing_tools: list[str] = []
    missing_packages: list[str] = []
    missing_outputs: list[str] = []
    missing_configs: list[str] = []
    missing_assets: list[str] = []

    doctor_sections: list[tuple[dict, Path, str]] = []
    if repo_doctor := manifest.get("doctor"):
        doctor_sections.append((repo_doctor, DEFAULT_MANIFEST.parents[1], "katzensteg"))
    for project in select_projects(manifest, names, include_non_default):
        doctor = project.get("doctor", {})
        doctor_sections.append((doctor, doctor_project_root(root, project), project["name"]))

    for doctor, project_root, section_name in doctor_sections:
        for tool_name in iter_doctor_names(doctor.get("tools", [])):
            if shutil.which(tool_name) is None:
                missing_tools.append(tool_name)

        pkg_config_available = True
        for module_name in iter_doctor_names(doctor.get("pkg_config", [])):
            if not pkg_config_available:
                continue
            status = run_pkg_config_exists(module_name)
            if status == "present":
                continue
            if status == "missing_tool":
                missing_tools.append("pkg-config")
                pkg_config_available = False
                continue
            if status == "missing_module":
                missing_packages.append(module_name)

        for path_entry in doctor.get("paths", []):
            if not doctor_entry_applies(path_entry):
                continue
            path_kind = path_entry["kind"]
            if path_kind not in {"output", "config"}:
                raise ValueError(
                    f"unknown doctor path kind {path_kind!r} for project {section_name}"
                )
            resolved_path = doctor_path(project_root, path_entry["path"])
            if resolved_path.exists():
                continue
            if path_kind == "output":
                missing_outputs.append(str(resolved_path))
            elif path_kind == "config":
                missing_configs.append(str(resolved_path))

        for asset_entry in doctor.get("assets", []):
            if not doctor_entry_applies(asset_entry):
                continue
            resolved_paths = resolve_asset_paths(project_root, asset_entry)
            if not any(path.exists() for path in resolved_paths):
                missing_assets.append(missing_asset_label(asset_entry, resolved_paths))

    report = DoctorReport(
        missing_tools=list(dict.fromkeys(missing_tools)),
        missing_packages=list(dict.fromkeys(missing_packages)),
        missing_outputs=list(dict.fromkeys(missing_outputs)),
        missing_configs=list(dict.fromkeys(missing_configs)),
        missing_assets=list(dict.fromkeys(missing_assets)),
        summary="",
    )
    report.summary = format_doctor_summary(report)
    return report


def format_doctor_detail_lines(
    report: DoctorReport,
    manifest: dict,
    distro_family: str | None = None,
) -> list[str]:
    if not doctor_has_failures(report):
        return []

    lines: list[str] = ["Doctor details:"]
    if report.missing_tools:
        lines.append("  missing tools:")
        lines.extend(f"    {item}" for item in report.missing_tools)
    if report.missing_packages:
        lines.append("  missing pkg-config modules:")
        lines.extend(f"    {item}" for item in report.missing_packages)
    if report.missing_outputs:
        lines.append("  missing outputs:")
        lines.extend(f"    {item}" for item in report.missing_outputs)
    if report.missing_configs:
        lines.append("  missing configs:")
        lines.extend(f"    {item}" for item in report.missing_configs)
    if report.missing_assets:
        lines.append("  missing assets:")
        lines.extend(f"    {item}" for item in report.missing_assets)

    install_capabilities = [*report.missing_tools, *report.missing_packages]
    if install_capabilities:
        lines.append("  install hints:")
        lines.extend(
            f"    {line}"
            for line in render_install_hint_lines(manifest, install_capabilities, distro_family)
        )
    return lines


def print_doctor_details(report: DoctorReport, manifest: dict) -> None:
    for line in format_doctor_detail_lines(report, manifest):
        print(line)


def clone_command(project: dict, target: Path) -> list[str]:
    primary_remote = project["primary_remote"]
    remote_url = project["remotes"][primary_remote]
    command = ["git", "clone"]
    if project.get("recursive", False):
        command.append("--recurse-submodules")
    command.extend(["--origin", primary_remote, "--branch", project["checkout"], remote_url, str(target)])
    return command


def update_commands(project: dict, target: Path) -> list[list[str]]:
    primary_remote = project["primary_remote"]
    checkout = project["checkout"]
    commands = [
        ["git", "-C", str(target), "fetch", primary_remote, checkout],
        ["git", "-C", str(target), "checkout", checkout],
        ["git", "-C", str(target), "pull", "--ff-only", primary_remote, checkout],
    ]
    if project.get("recursive", False):
        commands.append(["git", "-C", str(target), "submodule", "update", "--init", "--recursive"])
    return commands


def plan_project(project: dict, root: Path) -> PlannedProject:
    target = root / project["directory"]
    if target.exists():
        commands = update_commands(project, target)
    else:
        commands = [clone_command(project, target)]
    return PlannedProject(
        name=project["name"],
        path=target,
        commands=commands,
        build_commands=project.get("build", {}).get(current_platform(), []),
        profiles=list(project.get("profiles", [])),
    )


def plan_projects(
    manifest: dict,
    root: Path,
    names: Iterable[str] | None = None,
    include_non_default: bool = False,
) -> list[PlannedProject]:
    return [plan_project(project, root) for project in select_projects(manifest, names, include_non_default)]


def current_platform() -> str:
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "linux"
    return sys.platform


def shell_quote(args: list[str]) -> str:
    return " ".join(sh_quote(arg) for arg in args)


def sh_quote(value: str) -> str:
    if not value:
        return "''"
    safe = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-"
    if all(ch in safe for ch in value):
        return value
    return "'" + value.replace("'", "'\"'\"'") + "'"


def run_sync_commands(plan: list[PlannedProject], dry_run: bool) -> list[CommandPhaseResult]:
    results: list[CommandPhaseResult] = []
    for item in plan:
        printed_commands: list[str] = []
        error: Exception | None = None
        for command in item.commands:
            rendered = shell_quote(command)
            printed_commands.append(rendered)
            print(rendered)
            if dry_run:
                continue
            try:
                subprocess.run(command, check=True)
            except (subprocess.CalledProcessError, OSError) as exc:
                error = exc
                break
        results.append(
            CommandPhaseResult(
                name=item.name,
                path=item.path,
                printed_commands=printed_commands,
                status="failed" if error is not None else "succeeded",
                error=error,
            )
        )
    return results


def run_build_commands(plan: list[PlannedProject], dry_run: bool) -> list[CommandPhaseResult]:
    results: list[CommandPhaseResult] = []
    for item in plan:
        printed_commands: list[str] = []
        error: Exception | None = None
        for command in item.build_commands:
            printed_commands.append(command)
            print(f"  {command}")
            if dry_run:
                continue
            try:
                subprocess.run(command, check=True, cwd=item.path, shell=True)
            except (subprocess.CalledProcessError, OSError) as exc:
                error = exc
                break
        results.append(
            CommandPhaseResult(
                name=item.name,
                path=item.path,
                printed_commands=printed_commands,
                status="failed" if error is not None else "succeeded",
                error=error,
            )
        )
    return results


def skipped_phase_result(item: PlannedProject) -> CommandPhaseResult:
    return CommandPhaseResult(
        name=item.name,
        path=item.path,
        printed_commands=[],
        status="skipped",
    )


def run_plan(plan: list[PlannedProject], dry_run: bool) -> list[ProjectExecutionResult]:
    results: list[ProjectExecutionResult] = []
    for item in plan:
        print(f"==> {item.name}: {item.path}")
        if item.profiles:
            print("profiles: " + ", ".join(item.profiles))

        sync_result = run_sync_commands([item], dry_run)[0]

        if sync_result.status != "succeeded":
            build_result = skipped_phase_result(item)
        else:
            if item.build_commands:
                print("build:")
            build_result = run_build_commands([item], dry_run)[0]

        results.append(
            ProjectExecutionResult(
                name=item.name,
                path=item.path,
                sync=sync_result,
                build=build_result,
            )
        )
    return results


def run_build_only(plan: list[PlannedProject], dry_run: bool) -> list[ProjectExecutionResult]:
    results: list[ProjectExecutionResult] = []
    for item in plan:
        print(f"==> {item.name}: {item.path}")
        if item.profiles:
            print("profiles: " + ", ".join(item.profiles))
        if item.build_commands:
            print("build:")
        build_result = run_build_commands([item], dry_run)[0]
        results.append(
            ProjectExecutionResult(
                name=item.name,
                path=item.path,
                sync=skipped_phase_result(item),
                build=build_result,
            )
        )
    return results


def run_doctor_only(plan: list[PlannedProject]) -> list[ProjectExecutionResult]:
    return [
        ProjectExecutionResult(
            name=item.name,
            path=item.path,
            sync=skipped_phase_result(item),
            build=skipped_phase_result(item),
        )
        for item in plan
    ]


def has_failures(results: list[ProjectExecutionResult]) -> bool:
    return any(
        result.sync.status == "failed" or result.build.status == "failed"
        for result in results
    )


def doctor_has_failures(report: DoctorReport) -> bool:
    return any(
        [
            report.missing_tools,
            report.missing_packages,
            report.missing_outputs,
            report.missing_configs,
            report.missing_assets,
        ]
    )


def format_status_counts(statuses: Iterable[PhaseStatus]) -> str:
    counts = {"succeeded": 0, "failed": 0, "skipped": 0}
    for status in statuses:
        counts[status] += 1
    return ", ".join(f"{status}: {count}" for status, count in counts.items())


def print_final_summary(results: list[ProjectExecutionResult], doctor_report: DoctorReport) -> None:
    print("")
    print("Final summary:")
    print(f"  sync: {format_status_counts(result.sync.status for result in results)}")
    print(f"  build: {format_status_counts(result.build.status for result in results)}")
    print(f"  doctor: {doctor_report.summary}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Clone or update external app checkouts used by Katzensteg launcher profiles."
    )
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument(
        "--build-only",
        action="store_true",
        help="Skip clone/update commands and run build commands followed by doctor.",
    )
    mode_group.add_argument(
        "--doctor-only",
        action="store_true",
        help="Skip clone/update and build commands, then run doctor.",
    )
    parser.add_argument(
        "selection",
        nargs="*",
        help="Project names or launcher profile names. Defaults to all top-level projects.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help=f"Path to external project manifest. Default: {DEFAULT_MANIFEST}",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Checkout root. Defaults to manifest default_root.",
    )
    parser.add_argument(
        "--include-non-default",
        action="store_true",
        help="Include projects marked default=false when no explicit selection is given.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without running them.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    manifest = load_manifest(args.manifest)
    root = args.root if args.root is not None else expand_path(manifest.get("default_root", "$HOME/dev"))
    plan = plan_projects(manifest, root, args.selection, args.include_non_default)
    if args.doctor_only:
        results = run_doctor_only(plan)
    elif args.build_only:
        results = run_build_only(plan, args.dry_run)
    else:
        results = run_plan(plan, args.dry_run)
    doctor_report = run_doctor(manifest, root, args.selection, args.include_non_default)
    print_doctor_details(doctor_report, manifest)
    print_final_summary(results, doctor_report)
    if has_failures(results) or doctor_has_failures(doctor_report):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
