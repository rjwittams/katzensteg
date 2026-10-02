#!/usr/bin/env python3
"""Run the Zig provider scenario against a daemon owned by this test."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--fixture", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="katzensteg-cleat-test-") as root:
        # Both the daemon and provider receive this private root explicitly.
        with open(Path(root) / "daemon.log", "w+") as log:
            daemon = subprocess.Popen([args.binary, "--runtime-root", root, "--server", "default", "serve"], stdout=log, stderr=log)
            try:
                for _ in range(500):
                    if daemon.poll() is not None:
                        log.seek(0)
                        raise RuntimeError(f"cleat daemon exited: {log.read()}")
                    if any(path.is_socket() for path in Path(root).rglob("*")):
                        break
                    time.sleep(0.01)
                else:
                    raise RuntimeError("private cleat daemon did not become ready")
                subprocess.run([args.fixture, args.binary, root], check=True, timeout=30)
            finally:
                daemon.terminate()
                try:
                    daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait()


if __name__ == "__main__":
    main()
