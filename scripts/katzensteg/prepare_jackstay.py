#!/usr/bin/env python3
"""Prepare the pinned optional Jackstay header/shared library for a native build."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def prepare(source, prefix, pin):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
    if revision != pin["revision"]:
        raise SystemExit(f"Expected Jackstay {pin['revision']}, got {revision}; use a checkout at the pinned revision")
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=source):
        raise SystemExit("Jackstay source has tracked modifications")
    command = ["cargo", "rustc", "--locked", "--release", "--target-dir", str(source / "target"), "-p", "jackstay", "--lib"]
    if sys.platform == "linux":
        # Without a SONAME Zig records the prepared prefix's absolute library
        # path in DT_NEEDED, bypassing the installed package's relative rpath.
        command += ["--", "-C", "link-arg=-Wl,-soname,libjackstay.so"]
    subprocess.run(command, cwd=source, check=True)
    (prefix / "include").mkdir(parents=True, exist_ok=True)
    (prefix / "lib").mkdir(exist_ok=True)
    header = source / "crates/jackstay/include/capture_transfer.h"
    shutil.copy2(header, prefix / "include/capture_transfer.h")
    library = "libjackstay.dylib" if sys.platform == "darwin" else "libjackstay.so"
    shutil.copy2(source / "target/release" / library, prefix / "lib" / library)
    if sys.platform == "darwin":
        subprocess.run(["install_name_tool", "-id", "@rpath/libjackstay.dylib", str(prefix / "lib" / library)], check=True)
    (prefix / "jackstay.json").write_text(json.dumps(pin, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", required=True, type=Path)
    parser.add_argument("--source", type=Path, help="Explicit checkout at the pinned revision; otherwise clone it")
    args = parser.parse_args()
    if sys.platform not in ("darwin", "linux"):
        parser.error("CPU connectors currently support macOS and Linux")
    pin = json.loads((ROOT / "profiles/jackstay-dependency.json").read_text())
    if args.source:
        prepare(args.source.resolve(), args.prefix.resolve(), pin)
    else:
        with tempfile.TemporaryDirectory(prefix="katzensteg-jackstay-") as tmp:
            source = Path(tmp) / "source"
            subprocess.run(["git", "clone", "--no-checkout", pin["repository"], str(source)], check=True)
            subprocess.run(["git", "checkout", "--detach", pin["revision"]], cwd=source, check=True)
            prepare(source, args.prefix.resolve(), pin)


if __name__ == "__main__":
    main()
