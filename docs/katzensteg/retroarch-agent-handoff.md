# RetroArch Agent Handoff

Use this prompt for an agent working in `/Users/robert/dev/RetroArch`.

## Prompt

You are working in my local RetroArch checkout at `/Users/robert/dev/RetroArch`.

Goal: split the current dirty RetroArch work into reviewable commits and push them to my fork remote `rjwittams` without losing any of the behavior currently used by Katzensteg.

Important context:

- Upstream remote: `origin = https://github.com/libretro/RetroArch.git`
- Fork remote: `rjwittams = https://github.com/rjwittams/RetroArch.git`
- Current branch: `robert/macos-sdl2-video-pr-cleanup`
- Existing pushed fork branch: `rjwittams/macos-sdl2-video-output`
- The current branch already has two committed changes:
  - `fa50e7ede8 macOS: allow SDL2 video and input drivers`
  - `a2288506a7 build: link QuartzCore on macOS`
- There is additional dirty work in the checkout. Do not squash it all into one vague commit.

Hard constraints:

- Do not run destructive git commands such as `git reset --hard`, `git checkout -- .`, or cleaning untracked files.
- Do not remove or overwrite my generated/local files. Leave generated artifacts untracked unless explicitly told otherwise.
- Do not push directly to upstream `origin`.
- Push only to the `rjwittams` remote.
- Use branch names that describe the RetroArch-side change, not Katzensteg itself.
- Preserve normal RetroArch behavior as far as possible; env/config escape hatches are acceptable for Katzensteg-specific launch behavior.

Current dirty source files to inspect:

- `Makefile.common`
- `gfx/common/vulkan_common.c`
- `gfx/common/vulkan_common.h`
- `gfx/drivers/sdl2_gfx.c`
- `gfx/drivers/vulkan.c`
- `gfx/drivers_context/sdl_gl_ctx.c`
- `gfx/drivers_context/sdl_vk_ctx.c` (currently untracked source file)
- `gfx/video_driver.c`
- `gfx/video_driver.h`
- `ui/drivers/cocoa/cocoa_common.m`
- `ui/drivers/ui_cocoa.m`

Current untracked artifacts to leave out of commits:

- `RetroArch.app/`
- `crash.txt`
- `vulkan-crash.txt`
- `vulkan-crash2.txt`
- `default.metallib`
- `gfx/common/metal/Shaders.air`

Expected split:

1. Cocoa/bootstrap-window commit
   - Candidate files: `ui/drivers/ui_cocoa.m`, `ui/drivers/cocoa/cocoa_common.m`
   - Purpose: allow RetroArch on macOS to run without creating the Cocoa bootstrap window when the SDL window owns video/input. Preserve normal bootstrap behavior by default. The current escape hatch is `RETROARCH_COCOA_BOOTSTRAP_WINDOW=0`.

2. SDL OpenGL context commit
   - Candidate files: `gfx/drivers_context/sdl_gl_ctx.c`, related parts of `gfx/video_driver.c`, possibly `gfx/video_driver.h`
   - Purpose: allow the SDL GL context driver to be selected on macOS when SDL2 owns the window, including GL core profile handling and shader/context flag reporting.

3. SDL Vulkan context commit
   - Candidate files: `gfx/drivers_context/sdl_vk_ctx.c`, `Makefile.common`, `gfx/common/vulkan_common.c`, `gfx/common/vulkan_common.h`, `gfx/drivers/vulkan.c`, related declarations in `gfx/video_driver.h`
   - Purpose: add an SDL2 Vulkan context driver and make the Vulkan driver select it when SDL2 owns the window. Include the MoltenVK loader/rpath handling and SDL-required instance extensions.

4. Generic video-driver/window-owner plumbing commit
   - Candidate files: `gfx/video_driver.c`, `gfx/video_driver.h`, small `gfx/drivers/sdl2_gfx.c` safety/title fixes
   - Purpose: track the video driver that originally owned the window before RetroArch switches to GL/Vulkan for hardware contexts, so the context-driver fallback can prefer SDL when appropriate.

The exact split may differ after inspection, but keep commits coherent and explain why each is separate.

Useful Katzensteg launch profiles that exercise this work:

- `sonic`: SDL2 software renderer
- `sm64ds`: SDL2/OpenGL path through melonDS
- `jsr`: SDL2/Vulkan path through Flycast

Validation to run if available:

```sh
git diff --check
make -j$(sysctl -n hw.ncpu)
```

If a full build is too slow or currently depends on local artifacts, state that clearly and run the narrowest useful compile/build command you can. Do not claim a path is verified unless you actually ran it.

Expected output:

- A concise summary of each commit made.
- The branch name(s) pushed to `rjwittams`.
- Any dirty/untracked files intentionally left behind.
- Any validation run and exact result.
- Any risks or places where the current design looks wrong.
