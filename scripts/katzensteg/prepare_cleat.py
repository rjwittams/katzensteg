#!/usr/bin/env python3
"""Prepare the pinned optional Cleat header/shared library for a native build."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def prepare(source, prefix, pin):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != pin["revision"]:
        raise SystemExit(f"Expected Cleat {pin['revision']}, got {revision}; use a checkout at the pinned revision")
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=source):
        raise SystemExit("Cleat source has tracked modifications")
    subprocess.run(["bash", "tools/prepare-ghostty-vt.sh"], cwd=source, check=True)
    # Use only the pinned static VT engine. The prepared library/binary must
    # not depend on a scratch checkout or an ambient CLEAT_GHOSTTY_PREFIX.
    vt_prefix = source / ".tools/ghostty-static"
    shutil.copytree(source / ".tools/ghostty-install/include", vt_prefix / "include", dirs_exist_ok=True)
    (vt_prefix / "lib").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / ".tools/ghostty-install/lib/libghostty-vt.a", vt_prefix / "lib/libghostty-vt.a")
    env = dict(os.environ, CLEAT_GHOSTTY_PREFIX=str(vt_prefix))
    command = ["cargo", "rustc", "--locked", "--release", "--target-dir", str(source / "target"), "-p", "cleat", "--lib"]
    if sys.platform == "linux":
        # Without a SONAME Zig records the prepared prefix's absolute library
        # path in DT_NEEDED, bypassing the installed package's relative rpath.
        command += ["--", "-C", "link-arg=-Wl,-soname,libcleat.so"]
    subprocess.run(command, cwd=source, env=env, check=True)
    subprocess.run(["cargo", "build", "--locked", "--release", "--target-dir", str(source / "target"), "-p", "cleat", "--bin", "cleat"], cwd=source, env=env, check=True)
    (prefix / "bin").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "target/release/cleat", prefix / "bin/cleat")
    (prefix / "include").mkdir(parents=True, exist_ok=True)
    (prefix / "lib").mkdir(exist_ok=True)
    for name in ("cleat_provider.h",):
        shutil.copy2(source / "crates/cleat/include" / name, prefix / "include" / name)
    library = "libcleat.dylib" if sys.platform == "darwin" else "libcleat.so"
    shutil.copy2(source / "target/release" / library, prefix / "lib" / library)
    if sys.platform == "darwin":
        subprocess.run(["install_name_tool", "-id", "@rpath/libcleat.dylib", str(prefix / "lib" / library)], check=True)
    (prefix / "cleat.json").write_text(json.dumps(pin, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="Explicit checkout at the pinned revision; otherwise clone it")
    args = parser.parse_args()
    if sys.platform not in ("darwin", "linux"):
        parser.error("Cleat currently supports macOS and Linux")
    pin = json.loads((ROOT / "profiles/cleat-dependency.json").read_text())
    if args.source:
        prepare(args.source.resolve(), args.prefix.resolve(), pin)
    else:
        with tempfile.TemporaryDirectory(prefix="katzensteg-cleat-") as tmp:
            source = Path(tmp) / "source"
            subprocess.run(["git", "clone", "--no-checkout", pin["repository"], str(source)], check=True)
            subprocess.run(["git", "checkout", "--detach", pin["revision"]], cwd=source, check=True)
            prepare(source, args.prefix.resolve(), pin)


if __name__ == "__main__":
    main()
