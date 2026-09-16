"""Independent C ABI controller -> real SDL2/SDL3 apps through the launcher.

Build with Jackstay enabled. KATZENSTEG_JACKSTAY_PREFIX names the matching
prepared dependency. JACKSTAY_REFERENCE_VIEWER optionally enables the real SDL
viewer pairing as well; its source is from the pinned Jackstay revision.
"""
import ctypes as C
import fcntl
import pty
import struct
import termios
import threading
import json
import os
from pathlib import Path
import signal
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]

class Geometry(C.Structure):
    _fields_ = [("revision", C.c_uint64), ("width", C.c_double), ("height", C.c_double)]
class Config(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ("modes", "capabilities", "max_events", "max_bytes", "max_text_bytes", "idle_timeout_ms", "independent_contributions", "interaction_cancel")] + [("geometry", Geometry)]
class Event(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in ("kind", "action", "key_kind", "modifiers")] + [("press", C.c_uint64), ("geometry_revision", C.c_uint64), ("button", C.c_uint32), ("scroll_unit", C.c_uint32)] + [(name, C.c_double) for name in ("x", "y", "pointer_x", "pointer_y")] + [("key", C.c_char * 64), ("text", C.c_void_p), ("text_len", C.c_size_t)]
class Status(C.Structure):
    _fields_ = [("kind", C.c_uint32), ("result", C.c_int32), ("sequence", C.c_uint64), ("epoch", C.c_uint64), ("reason", C.c_uint32), ("clean", C.c_uint32), ("geometry", Geometry)]

class Client:
    def __init__(self, library, path):
        self.lib = library
        self.handle = C.c_void_p()
        stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stream.connect(str(path))
        fd = C.c_int32(stream.detach())
        status = library.ft_input_client_connect(C.byref(fd), 4, C.byref(self.handle))
        if fd.value >= 0:
            os.close(fd.value)
        assert status == 0, status
        self.config = Config()
        controller, epoch = C.c_uint64(), C.c_uint64()
        assert library.ft_input_client_describe(self.handle, C.byref(self.config), C.byref(controller), C.byref(epoch)) == 0
    def send(self, event):
        sequence = C.c_uint64()
        assert self.lib.ft_input_client_send(self.handle, C.byref(event), C.byref(sequence)) == 0
        return sequence.value
    def text(self, value):
        buf = C.create_string_buffer(value)
        return self.send(Event(kind=2, text=C.cast(buf, C.c_void_p), text_len=len(value)))
    def key(self, name, action, press=1, modifiers=0):
        return self.send(Event(kind=1, key_kind=1, key=name.encode(), action=action, press=press, modifiers=modifiers))
    def poll(self):
        result = Status()
        status = self.lib.ft_input_client_poll(self.handle, C.byref(result))
        if status == 1:
            return None
        assert status == 0, status
        return result
    def result(self, sequence, expected=0, kind=1):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = self.poll()
            if result is not None and result.sequence == sequence:
                assert (result.kind, result.result) == (kind, expected), (result.kind, result.result)
                return
            time.sleep(.005)
        raise AssertionError("execution result timed out")
    def reset(self):
        assert self.lib.ft_input_client_reset(self.handle) == 0
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = self.poll()
            if result is not None and result.kind == 3:
                self.config.geometry = result.geometry
                return
            time.sleep(.005)
        raise AssertionError("reset confirmation timed out")
    def close(self):
        self.lib.ft_input_client_close(self.handle)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result = self.poll()
            if result is not None and result.kind == 4:
                assert result.clean == 1, "remote cleanup unconfirmed"
                return
            time.sleep(.005)
        raise AssertionError("cleanup confirmation timed out")
    def destroy(self):
        self.lib.ft_input_client_destroy(C.byref(self.handle))

class App:
    def __init__(self, folder, version):
        self.media = folder / f"media{version}"
        self.input = folder / f"input{version}"
        self.stdout = open(folder / f"app{version}.jsonl", "w+")
        self.stderr = open(folder / f"app{version}.err", "w+")
        self.process = subprocess.Popen([str(ROOT / "zig-out/bin/katzensteg"), f"test.input{version}"], stdin=subprocess.PIPE, stdout=self.stdout, stderr=self.stderr, env=dict(os.environ, KATZENSTEG_PROFILE_DIR=f"{ROOT / 'profiles'}:{folder}", KATZENSTEG_REPO=str(ROOT), KATZENSTEG_TARGET=f"jackstay:{self.media}", KATZENSTEG_INPUT_SOCKET=str(self.input), SDL_VIDEODRIVER="dummy", SDL_RENDER_DRIVER="software", KATZENSTEG_REAL_WINDOW="hide"), start_new_session=True)
        try:
            self.wait(lambda events: any(e["event"] == "ready" for e in events) and self.input.exists())
        except Exception:
            self.cleanup()
            raise
    def events(self):
        self.stdout.flush()
        return [json.loads(line) for line in Path(self.stdout.name).read_text().splitlines() if line.endswith("}")]
    def wait(self, predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            events = self.events()
            if predicate(events):
                return events
            if self.process.poll() is not None:
                raise AssertionError(Path(self.stderr.name).read_text())
            time.sleep(.01)
        raise AssertionError(f"app evidence timed out: {self.events()[-8:]}")
    def command(self, value):
        self.process.stdin.write(value.encode()); self.process.stdin.flush()
    def cleanup(self):
        if self.process.poll() is None:
            self.command("q")
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL); self.process.wait()
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.process.stdin.close(); self.stdout.close(); self.stderr.close()

class Presenter:
    """A JSONL host with file-backed output, so video cannot block input tests."""
    def __init__(self, folder, media, input_path, placeholder=False):
        self.stdout = open(folder / "presenter.jsonl", "w+")
        self.stderr = open(folder / "presenter.err", "w+")
        self.process = subprocess.Popen([str(ROOT / "zig-out/bin/katzensteg"), "--embed-jsonl", "jackstay-source", str(media), "--input-socket", str(input_path)], stdin=subprocess.PIPE, stdout=self.stdout, stderr=self.stderr, env=dict(os.environ, KATZENSTEG_REPO=str(ROOT)), start_new_session=True)
        attach = dict(type="attach", window_id="main", aspect="fit", id_ranges=dict(image=[[10000,19999]], placement=[[20000,29999]]), rect_cells=dict(row=1, col=1, rows=10, cols=20), upload=dict(profile="file_whole", path=str(folder / "upload"), high_water=16*1024*1024))
        if placeholder:
            for key in ("rect_cells", "aspect", "id_ranges"):
                del attach[key]
            attach["placeholder"] = dict(image_id=777, cols=20, rows=10)
        self.send(attach)
    def send(self, event):
        self.process.stdin.write((json.dumps(event) + "\n").encode())
        self.process.stdin.flush()
    def input(self, **event):
        self.send(dict(type="input", window_id="main", **event))
    def wait_ready(self):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            events = [json.loads(line) for line in Path(self.stdout.name).read_text().splitlines() if line.endswith("}")]
            if any(e.get("type") == "presentation_status" and e.get("input_supported", True) for e in events):
                return
            assert self.process.poll() is None, Path(self.stderr.name).read_text()
            time.sleep(.01)
        raise AssertionError("presenter did not advertise input")
    def finish(self):
        self.send(dict(type="shutdown"))
        self.process.wait(timeout=6)
        assert self.process.returncode == 0, Path(self.stderr.name).read_text()
    def kill(self):
        # The embed launcher gives its producer a separate process group. Kill
        # that child, not just the launcher, to exercise real controller loss.
        if self.process.poll() is None:
            rows = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
            for row in rows.splitlines():
                pid, parent = map(int, row.split())
                if parent == self.process.pid:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill(); self.process.wait()
    def cleanup(self):
        self.kill()
        self.process.stdin.close(); self.stdout.close(); self.stderr.close()

class PublisherInput(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        check = subprocess.run([str(ROOT / "zig-out/bin/katzensteg"), "--dry-run", "jackstay-source"], capture_output=True)
        if b"JackstayUnavailable" in check.stderr:
            raise unittest.SkipTest("build with -Djackstay=true to exercise shared input")
        if check.returncode:
            raise AssertionError(check.stderr.decode())
        prefix = Path(os.environ.get("KATZENSTEG_JACKSTAY_PREFIX", str(ROOT / "zig-out")))
        suffix = "dylib" if sys.platform == "darwin" else "so"
        cls.lib = C.CDLL(str(prefix / "lib" / f"libjackstay.{suffix}"))
        for name, args in {
            "ft_input_client_connect": [C.POINTER(C.c_int32), C.c_uint32, C.POINTER(C.c_void_p)],
            "ft_input_client_describe": [C.c_void_p, C.POINTER(Config), C.POINTER(C.c_uint64), C.POINTER(C.c_uint64)],
            "ft_input_client_send": [C.c_void_p, C.POINTER(Event), C.POINTER(C.c_uint64)],
            "ft_input_client_poll": [C.c_void_p, C.POINTER(Status)],
            "ft_input_client_reset": [C.c_void_p],
            "ft_input_client_close": [C.c_void_p],
            "ft_input_client_destroy": [C.POINTER(C.c_void_p)],
        }.items():
            fn = getattr(cls.lib, name); fn.argtypes = args
            fn.restype = None if name.endswith(("close", "destroy")) else C.c_int32
        assert (C.sizeof(Config), C.sizeof(Event), C.sizeof(Status)) == (56, 152, 56)
        assert cls.lib.ft_abi_version() == 8
        cls.temp = tempfile.TemporaryDirectory(prefix="ks-input-", dir="/tmp")
        cls.folder = Path(cls.temp.name)
        profiles = {}
        for version in (2, 3):
            flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", f"sdl{version}"], text=True))
            binary = cls.folder / f"app{version}"
            subprocess.run(["cc", str(ROOT / "scripts/katzensteg/fixtures/jackstay_input_app.c"), "-o", str(binary)] + (["-DUSE_SDL3"] if version == 3 else []) + flags, check=True, capture_output=True)
            profiles[f"test.input{version}"] = {"extends": [f"adapter.sdl{version}_preload"], "target": str(binary), "stdout": "inherit", "stderr": "inherit"}
        (cls.folder / "profiles.json").write_text(json.dumps({"profiles": profiles}))
        cls.input_source = cls.folder / "input-source"
        subprocess.run(["cc", str(ROOT / "scripts/katzensteg/fixtures/jackstay_input_source.c"),
                        "-o", str(cls.input_source), "-I" + str(prefix / "include"),
                        "-L" + str(prefix / "lib"), "-ljackstay", "-Wl,-rpath," + str(prefix / "lib")],
                       check=True, capture_output=True)
    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
    def app(self, version):
        # Unique endpoints/logs for each test, sharing only compiled fixture profiles.
        directory = tempfile.TemporaryDirectory(prefix="ks-input-case-", dir="/tmp")
        self.addCleanup(directory.cleanup)
        folder = Path(directory.name)
        (folder / "profiles.json").write_text((self.folder / "profiles.json").read_text())
        app = App(folder, version)
        self.addCleanup(app.cleanup)
        return app
    def client(self, app):
        client = Client(self.lib, app.input)
        self.addCleanup(client.destroy)
        return client
    def test_state_only_polling_does_not_exhaust_event_retention(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version)
                client = self.client(app)
                app.command("s")
                app.wait(lambda es: any(e["event"] == "state" for e in es))
                client.result(client.key("ShiftLeft", 1, press=9000))
                # Cross the retained-event capacity with keys and buttons, while
                # keeping an unrelated modifier held throughout.
                for index in range(205):
                    client.result(client.key("KeyA", 1, press=index + 1))
                    client.result(client.key("KeyA", 2, press=index + 1))
                    client.result(client.send(Event(kind=4, action=1, button=1, geometry_revision=1, x=10, y=10)))
                    client.result(client.send(Event(kind=4, action=2, button=1, geometry_revision=1, x=10, y=10)))
                client.result(client.key("ShiftLeft", 2, press=9000))
                def released(es):
                    states = [e for e in es if e["event"] == "state"]
                    return states and states[-1]["a"] == 0 and states[-1]["shift"] == 0 and states[-1]["buttons"] == 0
                app.wait(released)
                client.close()
                # Cleanup must leave the target available to a fresh controller.
                fresh = self.client(app)
                fresh.result(fresh.key("KeyA", 1))
                fresh.result(fresh.key("KeyA", 2))
                fresh.close()

    def test_direct_terminal_presenter_forwards_input_and_focus_loss(self):
        app = self.app(2)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 800, 480))
        def controlling_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        viewer = subprocess.Popen([str(ROOT / "zig-out/bin/katzensteg"), "jackstay-source", str(app.media), "--input-socket", str(app.input)], stdin=slave, stdout=slave, stderr=slave, preexec_fn=controlling_terminal, env=dict(os.environ, KATZENSTEG_REPO=str(ROOT)))
        os.close(slave)
        output = bytearray()
        def drain():
            while True:
                try:
                    data = os.read(master, 65536)
                except OSError:
                    return
                if not data:
                    return
                output.extend(data)
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + 8
            while b"\x1b[?1004h" not in output:
                assert viewer.poll() is None and time.monotonic() < deadline
                time.sleep(.01)
            os.write(master, "é".encode())
            app.wait(lambda es: any(e["event"] == "text" and bytes.fromhex(e["hex"]) == "é".encode() for e in es))
            os.write(master, b"\x1b[<0;40;12M")
            app.wait(lambda es: any(e["event"] == "button" and e["down"] for e in es))
            os.write(master, b"\x1b[O")
            app.wait(lambda es: any(e["event"] == "button" and not e["down"] for e in es))
        finally:
            if viewer.poll() is None:
                os.killpg(viewer.pid, signal.SIGKILL)
            viewer.wait()
            os.close(master)
            reader.join(timeout=2)

    def test_presenter_controls_sdl_publisher_in_both_hosted_modes(self):
        for version in (2, 3):
            for placeholder in (False, True):
                with self.subTest(sdl=version, placeholder=placeholder):
                    app = self.app(version)
                    viewer = Presenter(Path(app.stdout.name).parent, app.media, app.input, placeholder)
                    self.addCleanup(viewer.cleanup)
                    viewer.wait_ready()
                    app.command("v")
                    app.wait(lambda es: any(e["event"] == "video" and e["value"] == 0 for e in es))
                    viewer.input(event="key", key="c", ctrl=True)
                    app.wait(lambda es: any(e["event"] == "key" and e["key"] == ord("c") and e["mods"] & 0x40 for e in es))
                    text = "hé🙂 日本語 " * 60
                    viewer.input(event="terminal_bytes", bytes=text)
                    app.wait(lambda es: b"".join(bytes.fromhex(e["hex"]) for e in es if e["event"] == "text") == text.encode())
                    viewer.input(event="source_pointer", x=320, y=240, width=640, height=480, kind="pointerdown", button=0, buttons=1)
                    app.wait(lambda es: any(e["event"] == "button" and e["down"] for e in es))
                    viewer.input(event="key", key="enter", action="down")
                    app.wait(lambda es: any(e["event"] == "key" and e["scan"] == 40 and e["down"] for e in es))
                    viewer.input(event="terminal_bytes", bytes="\x1b[O")
                    app.wait(lambda es: any(e["event"] == "key" and e["scan"] == 40 and not e["down"] for e in es) and any(e["event"] == "button" and not e["down"] for e in es))
                    viewer.finish()

    def test_presenter_to_independent_reference_source(self):
        for abrupt in (False, True):
            with self.subTest(abrupt=abrupt), tempfile.TemporaryDirectory(prefix="ks-source-", dir="/tmp") as directory:
                folder = Path(directory)
                media, control = folder / "media", folder / "input"
                with (folder / "source.log").open("w+") as report:
                    source = subprocess.Popen([str(self.input_source), str(media), str(control), "--report-state"], stdout=report, stderr=subprocess.PIPE)
                    viewer = None
                    try:
                        deadline = time.monotonic() + 8
                        while not (media.exists() and control.exists()):
                            assert source.poll() is None and time.monotonic() < deadline
                            time.sleep(.01)
                        viewer = Presenter(folder, media, control)
                        viewer.wait_ready()
                        viewer.input(event="key", key="enter", action="down")
                        viewer.input(event="key", key="enter", action="down")
                        text = "hé🙂" + "x" * 1024
                        viewer.input(event="terminal_bytes", bytes=text)
                        # Reference source has no logical mapping for printable
                        # chars: text still arrives, with no guessed physical keys.
                        viewer.input(event="pointer", kind="pointerdown", col=10, row=5, button=0, buttons=1)
                        deadline = time.monotonic() + 10
                        while "downs=1 repeats=1 releases=0 text_bytes=1031 held=1 buttons=1" not in (folder / "source.log").read_text():
                            assert source.poll() is None and time.monotonic() < deadline, (folder / "source.log").read_text()[-1000:]
                            time.sleep(.01)
                        if abrupt:
                            viewer.kill()
                        else:
                            viewer.finish()
                        _, err = source.communicate(timeout=6)
                        assert source.returncode == 0, err.decode()
                        assert "held=0 buttons=0" in (folder / "source.log").read_text().splitlines()[-1]
                    finally:
                        if viewer is not None:
                            viewer.cleanup()
                        if source.poll() is None:
                            source.kill()
                        source.communicate()

    def test_events_long_text_and_cleanup_without_video_progress(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version)
                client = self.client(app)
                app.command("v")
                app.wait(lambda es: any(e["event"] == "video" and e["value"] == 0 for e in es))
                client.result(client.send(Event(kind=3, x=10.25, y=20.5, geometry_revision=client.config.geometry.revision)))
                expected = {"event": "motion", "x": 10 if version == 2 else 10.25, "y": 20 if version == 2 else 20.5}
                app.wait(lambda es: expected in es)
                client.result(client.key("KeyA", 1))
                client.result(client.key("KeyA", 3))
                client.result(client.key("KeyA", 2))
                client.result(client.key("Unknown", 1), expected=2)
                client.result(client.send(Event(kind=1, key_kind=2, key=b"c", action=1, press=9, modifiers=2)))
                client.result(client.send(Event(kind=1, key_kind=2, key=b"c", action=2, press=9, modifiers=2)))
                app.wait(lambda es: any(e["event"] == "key" and e["key"] == ord("c") and e["mods"] & 0x40 for e in es))
                text = ("hé🙂 日本語 " * 100).encode()
                client.result(client.text(text))
                client.result(client.text(b"reject\0whole"), expected=2)
                client.result(client.send(Event(kind=5, scroll_unit=2, x=.25, y=.5, pointer_x=40, pointer_y=50, geometry_revision=client.config.geometry.revision)))
                client.result(client.key("ShiftLeft", 1, press=2))
                client.result(client.send(Event(kind=4, action=1, button=2, x=40, y=50, geometry_revision=client.config.geometry.revision)))
                client.close()
                events = app.wait(lambda es: any(e["event"] == "key" and e["scan"] == 225 and not e["down"] for e in es) and any(e["event"] == "button" and not e["down"] for e in es))
                self.assertEqual(b"".join(bytes.fromhex(e["hex"]) for e in events if e["event"] == "text"), text)
                self.assertTrue(any(e["event"] == "key" and e["repeat"] for e in events))
                self.assertIn({"event": "scroll", "x": .25, "y": -.5}, events)
                self.assertIn({"event": "button", "down": 1, "button": 3}, events)
    def test_state_only_queries_and_focus_cleanup(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version); app.command("s")
                client = self.client(app)
                client.result(client.key("ShiftLeft", 1, press=1))
                app.wait(lambda es: any(e["event"] == "state" and e["shift"] and e["mods"] & 1 for e in es))
                client.result(client.key("KeyA", 1, press=2))
                app.wait(lambda es: any(e["event"] == "state" and e["a"] for e in es))
                client.reset()
                app.wait(lambda es: es[-1]["event"] == "state" and es[-1]["a"] == 0 and es[-1]["shift"] == 0)
                client.close()
    def test_modifier_only_state_queries_complete_modifier_work(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version)
                app.command("m")
                client = self.client(app)
                client.result(client.key("ShiftLeft", 1))
                app.wait(lambda es: any(e["event"] == "state" and e["mods"] & 1 for e in es))
                client.close()

    def test_focus_reset_invalidates_input_while_app_execution_is_paused(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version)
                client = self.client(app)
                app.command("p")
                app.wait(lambda es: any(e["event"] == "paused" and e["value"] == 1 for e in es))
                client.key("KeyA", 1)
                time.sleep(.05)
                self.assertIsNone(client.poll())
                self.assertEqual(client.lib.ft_input_client_reset(client.handle), 0)
                time.sleep(.05)
                app.command("p")
                deadline = time.monotonic() + 5
                reset = False
                while time.monotonic() < deadline:
                    result = client.poll()
                    if result is not None and result.kind == 3:
                        reset = True
                        break
                    time.sleep(.005)
                self.assertTrue(reset)
                self.assertFalse(any(e["event"] == "key" and e["down"] for e in app.events()))
                client.close()

    def test_geometry_cleanup_retains_keyboard_and_rejects_stale_positions(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version)
                client = self.client(app)
                revision = client.config.geometry.revision
                client.result(client.key("KeyA", 1))
                client.result(client.send(Event(kind=4, action=1, button=1, x=40, y=50, geometry_revision=revision)))
                app.command("r")
                deadline = time.monotonic() + 5
                changed = False
                while time.monotonic() < deadline:
                    result = client.poll()
                    if result is not None and result.kind == 3:
                        self.assertGreater(result.geometry.revision, revision)
                        self.assertEqual((result.geometry.width, result.geometry.height), (800, 600))
                        changed = True
                        break
                    time.sleep(.005)
                self.assertTrue(changed, "geometry reset was not confirmed")
                events = app.wait(lambda es: any(e["event"] == "button" and not e["down"] for e in es))
                self.assertFalse(any(e["event"] == "key" and e["scan"] == 4 and not e["down"] for e in events))
                stale = Event(kind=3, x=20, y=20, geometry_revision=revision)
                sequence = C.c_uint64()
                self.assertEqual(client.lib.ft_input_client_send(client.handle, C.byref(stale), C.byref(sequence)), 13)
                client.result(client.key("KeyA", 2))
                client.close()
    def test_reconnect_and_publisher_exit_do_not_invent_cleanup_confirmation(self):
        for version in (2, 3):
            with self.subTest(sdl=version):
                app = self.app(version)
                first = self.client(app)
                first.result(first.key("ShiftLeft", 1))
                first.close()
                second = self.client(app)
                second.result(second.key("KeyA", 1))
                app.command("q")
                app.process.wait(timeout=5)
                deadline = time.monotonic() + 5
                closed = False
                while time.monotonic() < deadline:
                    result = second.poll()
                    if result is not None and result.kind == 4:
                        self.assertEqual(result.clean, 0)
                        closed = True
                        break
                    time.sleep(.005)
                self.assertTrue(closed, "publisher exit did not close the controller")

    @unittest.skipUnless(os.environ.get("JACKSTAY_REFERENCE_VIEWER"), "set JACKSTAY_REFERENCE_VIEWER for independent SDL viewer acceptance")
    def test_independent_sdl_viewer_and_abrupt_exit(self):
        for version in (2, 3):
            for abrupt in (False, True):
                with self.subTest(sdl=version, abrupt=abrupt):
                    app = self.app(version)
                    viewer = subprocess.Popen([os.environ["JACKSTAY_REFERENCE_VIEWER"], "--cpu-socket", str(app.media), "--input-socket", str(app.input), "--input-self-test", "--frames", "0" if abrupt else "60"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, SDL_VIDEODRIVER="dummy"))
                    def stop_viewer(viewer=viewer):
                        if viewer.poll() is None: viewer.kill()
                        viewer.communicate(timeout=5)
                    self.addCleanup(stop_viewer)
                    app.wait(lambda es: any(e["event"] == "key" and e["scan"] == 225 and e["down"] for e in es) and any(e["event"] == "button" and e["down"] for e in es))
                    if abrupt: viewer.kill()
                    stdout, stderr = viewer.communicate(timeout=10)
                    if not abrupt: self.assertEqual(viewer.returncode, 0, f"stdout:\n{stdout.decode()}\nstderr:\n{stderr.decode()}")
                    events = app.wait(lambda es: any(e["event"] == "key" and e["scan"] == 225 and not e["down"] for e in es) and any(e["event"] == "button" and not e["down"] for e in es))
                    self.assertTrue(any(e["event"] == "key" and e["repeat"] for e in events))
                    self.assertEqual(b"".join(bytes.fromhex(e["hex"]) for e in events if e["event"] == "text"), "hé🙂".encode() + b"x" * 1024)

if __name__ == "__main__":
    unittest.main()
