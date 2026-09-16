#!/usr/bin/env python3
"""Exercise the core library from an ordinary C process with its own signals."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = r'''
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
static void handler(int sig) { (void)sig; }
static void (*log_line)(const char *, const char *);
static void (*present)(int, int, const uint8_t *, size_t);
static void verify(void) {
    struct sigaction action;
    assert(sigaction(SIGIO, NULL, &action) == 0);
    assert(action.sa_handler == handler);
    assert(sigaction(SIGPIPE, NULL, &action) == 0);
    assert(action.sa_handler == handler);
}
static void *worker(void *unused) {
    (void)unused;
    for (int i = 0; i < 50; ++i) log_line("io-test", "ordinary pthread logging");
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    struct sigaction action = {0};
    action.sa_handler = handler;
    sigemptyset(&action.sa_mask);
    assert(sigaction(SIGIO, &action, NULL) == 0);
    assert(sigaction(SIGPIPE, &action, NULL) == 0);
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    assert(library);
    log_line = dlsym(library, "ks_katzensteg_log_c");
    present = dlsym(library, "ks_katzensteg_present_external_rgba");
    void (*shutdown_core)(void) = dlsym(library, "ks_katzensteg_shutdown");
    assert(log_line && present && shutdown_core);
    verify();
    log_line("io-test", "before runtime startup");
    uint8_t pixels[4 * 4 * 4] = {0};
    present(4, 4, pixels, sizeof(pixels));
    verify();
    pthread_t threads[4];
    for (int i = 0; i < 4; ++i) assert(pthread_create(&threads[i], NULL, worker, NULL) == 0);
    for (int i = 0; i < 4; ++i) assert(pthread_join(threads[i], NULL) == 0);
    shutdown_core();
    log_line("io-test", "after runtime shutdown");
    verify();
    assert(dlclose(library) == 0);
    verify();
    return 0;
}
'''


class InjectedIoTest(unittest.TestCase):
    def test_runtime_and_logging_preserve_application_signal_handlers(self):
        library = ROOT / "zig-out/lib" / ("libkatzensteg-core.dylib" if sys.platform == "darwin" else "libkatzensteg-core.so")
        self.assertTrue(library.exists(), "run the full zig build first")
        with tempfile.TemporaryDirectory(prefix="ks-injected-io-") as directory:
            folder = Path(directory)
            source, executable = folder / "probe.c", folder / "probe"
            source.write_text(SOURCE)
            command = ["cc", "-pthread", str(source), "-o", str(executable)]
            if sys.platform != "darwin":
                command.append("-ldl")
            subprocess.run(command, check=True, capture_output=True)
            for mode in ("sync_compose", "queued_replay"):
                with self.subTest(mode=mode), (folder / "frames").open("wb") as frames:
                    read_fd, write_fd = os.pipe()
                    try:
                        config = folder / "runtime.json"
                        config.write_text(json.dumps({"presentation_sink": "jsonl_fd", "presentation_fd": frames.fileno(), "presentation_control_fd": read_fd, "intercept_mode": mode}))
                        env = {key: value for key, value in os.environ.items() if not key.startswith("KATZENSTEG_")}
                        env["KATZENSTEG_CONFIG"] = str(config)
                        result = subprocess.run([str(executable), str(library)], env=env, pass_fds=(frames.fileno(), read_fd), capture_output=True, timeout=15)
                        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                        self.assertEqual(result.stdout, b"")
                        self.assertEqual(result.stderr, b"")
                    finally:
                        os.close(read_fd)
                        os.close(write_fd)


if __name__ == "__main__":
    unittest.main()
