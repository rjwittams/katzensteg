#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_MANIFEST = Path(__file__).resolve().parents[2] / "profiles" / "external-projects.json"


@dataclass
class PlannedProject:
    name: str
    path: Path
    commands: list[list[str]]
    build_commands: list[str]
    profiles: list[str]


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


def run_plan(plan: list[PlannedProject], dry_run: bool) -> None:
    for item in plan:
        print(f"==> {item.name}: {item.path}")
        if item.profiles:
            print("profiles: " + ", ".join(item.profiles))
        for command in item.commands:
            print(shell_quote(command))
            if not dry_run:
                subprocess.run(command, check=True)
        if item.build_commands:
            print("build notes:")
            for command in item.build_commands:
                print(f"  {command}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Clone or update external app checkouts used by Katzensteg launcher profiles."
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
    run_plan(plan, args.dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
