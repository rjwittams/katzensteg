#!/usr/bin/env python3
"""Checks the SDL_DYNAMIC_API slot generator and the committed slot headers."""
import pathlib
import re
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "katzensteg"))

import gen_dynapi_slots as gen  # noqa: E402

SRC = ROOT / "src" / "katzensteg"

PROCS = """
#ifndef SDL_DYNAPI_PROC_NO_VARARGS
SDL_DYNAPI_PROC(int,SDL_SetError,(const char *a, ...),(a),return)
#endif
#if defined(__WIN32__) || defined(__GDK__)
SDL_DYNAPI_PROC(SDL_Thread*,SDL_CreateThread,(SDL_ThreadFunction a, const char *b, void *c, void *d, void *e),(a,b,c,d,e),return)
#elif defined(__OS2__)
SDL_DYNAPI_PROC(SDL_Thread*,SDL_CreateThread,(SDL_ThreadFunction a, const char *b, void *c, void *d, void *e),(a,b,c,d,e),return)
#else
SDL_DYNAPI_PROC(SDL_Thread*,SDL_CreateThread,(SDL_ThreadFunction a, const char *b, void *c),(a,b,c),return)
#endif
#if defined(__WIN32__) || defined(__WINGDK__)
SDL_DYNAPI_PROC(int,SDL_RegisterApp,(const char *a, Uint32 b, void *c),(a,b,c),return)
#endif
#ifdef __LINUX__
SDL_DYNAPI_PROC(int,SDL_LinuxSetThreadPriority,(Sint64 a, int b),(a,b),return)
#endif
SDL_DYNAPI_PROC(int,SDL_Init,(Uint32 a),(a),return)
"""


def names(header):
    return [m.group(1) for m in re.finditer(r"^KS_(?:REAL|REAL_VOID|WRAP)\((\w+)", header.read_text(), re.M)]


class GeneratorTests(unittest.TestCase):
    def test_table_order_follows_each_platform_conditionals(self):
        windows = gen.table_order(PROCS, gen.SDL2_PLATFORMS["windows"][1])
        linux = gen.table_order(PROCS, gen.SDL2_PLATFORMS["linux"][1])
        macos = gen.table_order(PROCS, gen.SDL2_PLATFORMS["macos"][1])
        self.assertEqual(["SDL_SetError", "SDL_CreateThread", "SDL_RegisterApp", "SDL_Init"], windows)
        self.assertEqual(["SDL_SetError", "SDL_CreateThread", "SDL_LinuxSetThreadPriority", "SDL_Init"], linux)
        self.assertEqual(["SDL_SetError", "SDL_CreateThread", "SDL_Init"], macos)

    def test_sdl2_header_numbers_each_platform_and_rejects_others(self):
        text = gen.render(2, "test", PROCS, ["SDL_Init"])
        self.assertIn("#if defined(_WIN32) /* windows */\n#define KS_SDL2_SLOT_SDL_Init 3", text)
        self.assertIn("#elif defined(__linux__) /* linux */\n#define KS_SDL2_SLOT_SDL_Init 3", text)
        self.assertIn("#elif defined(__APPLE__) /* macos */\n#define KS_SDL2_SLOT_SDL_Init 2", text)
        self.assertIn("#error", text)

    def test_names_missing_from_the_api_get_no_slot(self):
        text = gen.render(3, "test", PROCS, ["SDL_Init", "SDL_GetRendererInfo"])
        self.assertIn("#define KS_SDL3_SLOT_SDL_Init 2", text)
        self.assertIn("#define KS_SDL3_SLOT_SDL_GetRendererInfo 0xffffffffu", text)

    def test_conditions_inside_inactive_blocks_are_not_evaluated(self):
        procs = "#ifdef __ANDROID__\n#if SDL_VERSION_ATLEAST(2,0,0)\n#elif SDL_OTHER(1)\n#endif\n#endif\nSDL_DYNAPI_PROC(int,SDL_Init,(Uint32 a),(a),return)\n"
        self.assertEqual(["SDL_Init"], gen.table_order(procs, {"__LINUX__"}))

    def test_unsupported_conditionals_are_rejected(self):
        with self.assertRaises(ValueError):
            gen.table_order("#if SDL_VERSION_ATLEAST(2,0,0)\n#endif\n", set())


class CommittedHeaderTests(unittest.TestCase):
    def test_every_listed_function_has_a_slot(self):
        for sdl, lists in (
            (2, ("real_sdl2_functions.h", "interpose_sdl2_dynapi_functions.h")),
            (3, ("real_sdl3_functions.h", "interpose_sdl3_dynapi_functions.h")),
        ):
            slots = (SRC / f"sdl{sdl}_dynapi_slots.h").read_text()
            blocks = re.split(r"^#(?:if|elif) .*$", slots, flags=re.M)[1:] if sdl == 2 else [slots]
            self.assertEqual(3 if sdl == 2 else 1, len(blocks))
            for header in lists:
                for name in names(SRC / header):
                    for block in blocks:
                        with self.subTest(sdl=sdl, name=name):
                            self.assertRegex(block, rf"#define KS_SDL{sdl}_SLOT_{name} ")

    def test_wrapper_lists_match_the_preload_interposers(self):
        for sdl, interpose, wrappers in (
            (2, "interpose_linux.c", "interpose_sdl2_dynapi_functions.h"),
            (3, "interpose_sdl3_linux.c", "interpose_sdl3_dynapi_functions.h"),
        ):
            exported = set(re.findall(r"\bks_(SDL_\w+)\(", (SRC / interpose).read_text()))
            with self.subTest(sdl=sdl):
                self.assertEqual(exported, set(names(SRC / wrappers)))


if __name__ == "__main__":
    unittest.main()
