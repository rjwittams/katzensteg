#!/usr/bin/env python3
import sys
import time


def main():
    try:
        import pygame
        from pygame._sdl2.video import Renderer, Window
    except ImportError as err:
        print(f"pygame unavailable: {err}", file=sys.stderr)
        return 77

    pygame.init()
    try:
        window = Window("katzensteg pygame rebind smoke", size=(160, 120))
        renderer = Renderer(window)
        renderer.draw_color = (20, 80, 180, 255)
        renderer.clear()
        renderer.present()
        time.sleep(0.1)
    finally:
        pygame.quit()

    print("pygame renderer smoke ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
