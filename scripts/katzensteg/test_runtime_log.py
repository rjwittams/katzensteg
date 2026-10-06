"""Exercise shared file logging through privately loaded libraries."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SUFFIX = ".dylib" if sys.platform == "darwin" else ".so"

# An ordinary application process is the real shared-library boundary. Each
# run seeds only its own PID file and removes it before exiting.
PROBE = r'''
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
typedef void (*log_fn)(const char *, const char *);
typedef void (*lifetime_fn)(void);
struct writer { log_fn log; int id; };
static void *write_lines(void *arg) {
    struct writer *writer = arg;
    for (int i = 0; i < 50; ++i) {
        char message[64];
        snprintf(message, sizeof(message), "writer %d line %d", writer->id, i);
        writer->log("c", message);
    }
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 3);
    char path[256];
    snprintf(path, sizeof(path), "/tmp/katzensteg-%ld.log", (long)getpid());
    FILE *seed = fopen(path, "w");
    assert(seed);
    fputs("old process\nstale queued replay worker exiting\n", seed);
    assert(fclose(seed) == 0);
    void *first = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    void *second = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!first || !second) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    log_fn log_a = (log_fn)dlsym(first, "ks_katzensteg_log_c");
    log_fn log_b = (log_fn)dlsym(second, "ks_katzensteg_log_c");
    lifetime_fn retain_a = (lifetime_fn)dlsym(first, "ks_katzensteg_log_retain");
    lifetime_fn retain_b = (lifetime_fn)dlsym(second, "ks_katzensteg_log_retain");
    lifetime_fn release_a = (lifetime_fn)dlsym(first, "ks_katzensteg_log_release");
    lifetime_fn release_b = (lifetime_fn)dlsym(second, "ks_katzensteg_log_release");
    assert(log_a && log_b && retain_a && retain_b && release_a && release_b);
    assert(retain_a == retain_b && release_a == release_b);
    // Minimal Zig clients exercise Logger.init/deinit as well as the ABI.
    lifetime_fn open_a = (lifetime_fn)dlsym(first, "log_test_open");
    lifetime_fn open_b = (lifetime_fn)dlsym(second, "log_test_open");
    lifetime_fn close_a = (lifetime_fn)dlsym(first, "log_test_close");
    lifetime_fn close_b = (lifetime_fn)dlsym(second, "log_test_close");
    if (open_a && open_b && close_a && close_b) {
        retain_a = open_a; retain_b = open_b;
        release_a = close_a; release_b = close_b;
    }
    retain_a();
    log_a("c", "first");
    retain_b();
    log_b("c", "second");
    release_a();
    log_b("c", "after first close");
    release_b();
    retain_a();
    log_a("c", "reopened");
    struct writer writers[2] = {{log_a, 0}, {log_b, 1}};
    pthread_t threads[2];
    for (int i = 0; i < 2; ++i) assert(pthread_create(&threads[i], NULL, write_lines, &writers[i]) == 0);
    for (int i = 0; i < 2; ++i) assert(pthread_join(threads[i], NULL) == 0);
    release_a();
    FILE *output = fopen(path, "r");
    assert(output);
    const char *expected[] = {"first", "second", "after first close", "reopened"};
    char line[256], wanted[256];
    for (int i = 0; i < 4; ++i) {
        snprintf(wanted, sizeof(wanted), "katzensteg: warn(c): %s\n", expected[i]);
        assert(fgets(line, sizeof(line), output));
        assert(strcmp(line, wanted) == 0);
    }
    int seen[2][50] = {{0}}, count = 0;
    while (fgets(line, sizeof(line), output)) {
        int writer, index, consumed = 0;
        assert(sscanf(line, "katzensteg: warn(c): writer %d line %d%n", &writer, &index, &consumed) == 2);
        assert(writer >= 0 && writer < 2 && index >= 0 && index < 50);
        assert(strcmp(line + consumed, "\n") == 0);
        assert(seen[writer][index]++ == 0);
        ++count;
    }
    assert(count == 100);
    assert(fclose(output) == 0);
    assert(unlink(path) == 0);
    assert(dlclose(second) == 0);
    assert(dlclose(first) == 0);
    return 0;
}
'''

# Small clients use the production Zig logging facade. Their only stand-in is
# for the SDL/application boundary; the core logger and file I/O are real.
CLIENT = '''
const std = @import("std");
const log = @import("runtime_log");
pub const katzensteg_shared_log = true;
var logger: ?log.Logger = null;
pub export fn log_test_open() callconv(.c) void {
    logger = log.Logger.init(std.heap.c_allocator);
}
pub export fn log_test_close() callconv(.c) void {
    if (logger) |*value| value.deinit();
    logger = null;
}
pub export fn ks_katzensteg_log_c(scope: [*:0]const u8, message: [*:0]const u8) callconv(.c) void {
    log.writeCLog(std.mem.span(scope), std.mem.span(message));
}
'''


def copy_library_package(source, destination):
    # Relocate the installed package, including optional dependencies such as
    # Jackstay, so sibling-relative lookup tests the complete runtime package.
    pattern = "lib*.dylib" if sys.platform == "darwin" else "lib*.so*"
    for library in source.glob(pattern):
        if library.is_file():
            shutil.copy2(library, destination)


@unittest.skipUnless(sys.platform in ("linux", "darwin"), "POSIX library loader")
class RuntimeLogTest(unittest.TestCase):
    def compile_probe(self, folder):
        source = folder / "probe.c"
        source.write_text(PROBE)
        executable = folder / "probe"
        command = ["cc", "-pthread", str(source), "-o", str(executable)]
        if sys.platform != "darwin":
            command.append("-ldl")
        subprocess.run(command, check=True, capture_output=True)
        return executable

    def assert_shared_log(self, executable, libraries):
        # Both load orders and both clients must preserve the lifecycle lines
        # and every concurrently written line exactly once, with no stale tail.
        for first, second in (libraries, libraries[::-1]):
            with self.subTest(first=first.name, second=second.name):
                result = subprocess.run([str(executable), str(first), str(second)], capture_output=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr, b"")

    def test_shared_logger_without_graphics_dependencies(self):
        # Test the real ABI and facade in separate modules without SDL/Vulkan,
        # so logger regressions can be reproduced in the contained crew image.
        with tempfile.TemporaryDirectory(prefix="ks-runtime-log-") as directory:
            folder = Path(directory)
            owner = folder / ("libkatzensteg-core" + SUFFIX)
            subprocess.run([
                "zig", "build-lib", "--name", "katzensteg-core", "-dynamic", "-ODebug", "-lc", "--dep", "platform",
                "-Mroot=" + str(ROOT / "src/katzensteg/log_exports.zig"),
                "-Mplatform=" + str(ROOT / "src/platform/root.zig"),
                "-femit-bin=" + str(owner),
            ], check=True, capture_output=True)
            clients = []
            # Stand-in only for an optional shared-library dependency at the
            # loader boundary. It makes omitted package dependencies fail.
            dependency_source = folder / "dependency.c"
            dependency_source.write_text("int fixture_dependency(void) { return 1; }\n")
            dependency = folder / ("libjackstay" + SUFFIX)
            identity = "-Wl,-install_name,@rpath/libjackstay.dylib" if sys.platform == "darwin" else "-Wl,-soname,libjackstay.so"
            subprocess.run(["cc", "-shared", "-fPIC", identity, str(dependency_source), "-o", str(dependency)], check=True, capture_output=True)
            for index in range(2):
                source = folder / f"client{index}.zig"
                source.write_text(CLIENT + '''
extern fn fixture_dependency() callconv(.c) c_int;
pub export fn log_test_dependency() callconv(.c) c_int {
    return fixture_dependency();
}
''')
                name = f"katzensteg-sdl{index + 2}-dynapi"
                library = folder / ("lib" + name + SUFFIX)
                subprocess.run([
                    "zig", "build-lib", "--name", name, "-dynamic", "-ODebug", "-lc", str(owner), str(dependency),
                    "-fno-each-lib-rpath", "-rpath", "@loader_path" if sys.platform == "darwin" else "$ORIGIN",
                    "--dep", "runtime_log", "-Mroot=" + str(source),
                    "--dep", "platform", "-Mruntime_log=" + str(ROOT / "src/katzensteg/log.zig"),
                    "-Mplatform=" + str(ROOT / "src/platform/root.zig"),
                    "-femit-bin=" + str(library),
                ], check=True, capture_output=True)
                clients.append(library)
            relocated = folder / "relocated"
            relocated.mkdir()
            copy_library_package(folder, relocated)
            self.assert_shared_log(self.compile_probe(folder), [relocated / client.name for client in clients])

    def test_installed_dynapi_and_core_share_log_after_relocation(self):
        # Production dependency wiring must work outside the checkout/cache,
        # including the RTLD_LOCAL case that permits distinct runtime copies.
        directory = ROOT / "zig-out/lib"
        core = directory / ("libkatzensteg-core" + SUFFIX)
        if not core.exists() and not os.environ.get("CI"):
            self.skipTest("full build artifacts unavailable; minimal shared-library test still runs")
        self.assertTrue(core.exists(), "run the full zig build first")
        with tempfile.TemporaryDirectory(prefix="ks-installed-log-") as temporary:
            folder = Path(temporary)
            copy_library_package(directory, folder)
            copied_core = folder / core.name
            executable = self.compile_probe(folder)
            for version in (2, 3):
                dynapi = directory / (f"libkatzensteg-sdl{version}-dynapi" + SUFFIX)
                self.assertTrue(dynapi.exists(), "run the full zig build first")
                copied_dynapi = folder / dynapi.name
                self.assert_shared_log(executable, [copied_dynapi, copied_core])


if __name__ == "__main__":
    unittest.main()
