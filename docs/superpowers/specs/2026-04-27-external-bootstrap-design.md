# Katzensteg External Bootstrap Design

Date: 2026-04-27

## Goal

Extend `scripts/katzensteg/bootstrap_external_projects.py` from a clone/update helper into a practical bootstrap workflow for Linux bring-up and future cross-distro setup work.

The end state should let a contributor run one command that:

1. clones or updates the external projects needed by Katzensteg launcher profiles
2. builds the selected projects using explicit manifest-defined commands
3. runs doctor-style checks at the end and reports any missing packages, tools, paths, or assets

The tool must not install packages automatically. It should detect gaps and print exact suggested install commands where package mappings are known.

## Non-Goals

- Automatic package installation
- Full cross-platform package management
- Automatic acquisition of ROMs, game assets, or private credentials
- Heuristic build discovery outside the manifest
- Replacing the launcher profile system

## Existing Baseline

Current bootstrap behavior:

- reads `profiles/external-projects.json`
- selects projects by project name or profile name
- clones or updates the selected checkouts
- prints platform-specific build notes

Current gaps:

- no automated build phase
- no doctor phase
- no package/dependency reporting
- no validation that launcher profile paths resolve on the current machine
- no validation that expected runtime assets exist

## Chosen Approach

Keep a single Python entry point:

- `scripts/katzensteg/bootstrap_external_projects.py`

Enhance it into a manifest-driven workflow tool rather than creating separate scripts. This preserves the current entry point and avoids splitting manifest, selection, and reporting logic across multiple files.

## User Experience

Primary workflow:

```sh
scripts/katzensteg/bootstrap_external_projects.py --root ~/dev
```

Expected behavior:

1. load the manifest
2. clone or update selected projects
3. run manifest-defined build commands for the current platform
4. run doctor checks automatically
5. print a final summary of:
   - completed clones/updates
   - successful builds
   - failed builds
   - missing tools
   - missing packages with suggested install commands
   - missing runtime paths or assets

Useful secondary workflows:

```sh
scripts/katzensteg/bootstrap_external_projects.py --dry-run
scripts/katzensteg/bootstrap_external_projects.py retroarch chiaki.sdl
scripts/katzensteg/bootstrap_external_projects.py --doctor-only
scripts/katzensteg/bootstrap_external_projects.py --build-only
```

## Script Responsibilities

### 1. Selection

Selection should continue to support:

- project names such as `retroarch`
- profile names such as `chiaki.sdl`

No change in matching semantics is required beyond the current behavior.

### 2. Clone / Update

Reuse current logic:

- clone if the checkout does not exist
- otherwise fetch, checkout, pull, and update submodules where required

This phase remains manifest-driven and explicit.

### 3. Build

Add a real build phase that executes the current platform’s manifest-defined commands instead of printing them as notes.

Rules:

- only run commands explicitly present in the manifest
- run project build commands from that project’s checkout directory
- print each command before execution
- stop that project’s build on first failure
- continue to later projects and report all failures at the end
- preserve `--dry-run` behavior by printing without executing

### 4. Doctor

Run doctor automatically after clone/update/build unless explicitly disabled later.

Doctor should validate four categories:

1. host tools
2. development libraries / headers
3. launcher-visible runtime paths
4. asset/config prerequisites

Doctor should report all failures in one pass rather than stopping on the first missing item.

## Manifest Extensions

Extend `profiles/external-projects.json` so each project can define the information needed for build and doctor phases.

### Required additions

Each project may define:

- `doctor.tools`
  - required executables such as `git`, `cmake`, `qmake6`, `uv`, `ffplay`
- `doctor.pkg_config`
  - pkg-config modules that signal needed dev packages such as `sdl2`, `gl`, `vulkan`
- `doctor.paths`
  - expected files or directories for built outputs or config inputs
- `doctor.assets`
  - launcher asset paths such as ROMs or local configs

At the top level, add package mappings by distro family for known capabilities.

Example shape:

```json
{
  "package_hints": {
    "arch": {
      "qmake6": "qt6-base",
      "ffplay": "ffmpeg",
      "sdl2": "sdl2",
      "vulkan_headers": "vulkan-headers"
    },
    "debian": {
      "qmake6": "qt6-base-dev",
      "ffplay": "ffmpeg",
      "sdl2": "libsdl2-dev",
      "vulkan_headers": "libvulkan-dev"
    }
  }
}
```

The actual package names should be recorded only when we are confident they are correct.

## Distro Detection

Doctor should detect the host distro family using `/etc/os-release`.

Initial supported families:

- Arch
- Debian/Ubuntu

Behavior:

- if the distro family is recognized and a missing capability has a package mapping, print an exact install command
- if the distro family is recognized but a capability has no known mapping, print the missing capability without guessing
- if the distro is unsupported, print raw missing capability names and note that package hints are unavailable

The script must never attempt package installation itself.

## Runtime Path Checks

Doctor should validate launcher-relevant paths that can be checked locally without launching apps.

Examples:

- `~/dev/cannonball/build/cannonball`
- `~/dev/cannonball/config.xml`
- `~/dev/chiaki-ng/.../chiaki-sdl`
- ROM paths referenced by bundled profiles
- ScummVM game directory

Checks should distinguish:

- missing code/build outputs
- missing local config files
- missing ROM or asset paths

That distinction matters because some gaps are fixed by building while others are fixed by copying local content.

## Build Logging and Reporting

The script should print enough context for later documentation updates:

- project name
- working directory
- command being run
- pass/fail outcome

At the end, summarize:

- built successfully
- clone/update failed
- build failed
- doctor warnings

This summary is the raw material for refining Linux build notes and package requirements over time.

## Error Handling

Clone/update/build errors should be isolated per project:

- one project failing must not prevent later projects from being attempted
- final exit code should be non-zero if any build or doctor failure occurred

Doctor errors should be non-fatal to information gathering:

- missing tools or assets should be reported, not crash the script

## Initial Linux Target

The first implementation should be sufficient to drive Linux bring-up for:

- RetroArch
- Moonlight Qt
- ScummVM
- Cannonball
- Chiaki NG
- ANESE

It should also report non-repo runtime prerequisites relevant to:

- `ffplay.testsrc`
- `probe.input`
- `sonic`
- `sm64ds`
- `jsr`
- `mi2`
- `smb3`
- `cannonball`
- `moonlight.steam`
- `chiaki.sdl`

## Success Criteria

- A contributor can run one bootstrap command and get clone/update, build, and doctor behavior in sequence.
- The script prints exact Arch and Debian/Ubuntu install suggestions for known missing tools/packages.
- The script reports launcher-relevant missing outputs, configs, and assets distinctly.
- Manifest-defined Linux build commands are executed and their results are summarized.
- The tool remains dry-run friendly and manifest-driven.

## Follow-Up Work

This design intentionally leaves room for later improvements:

- richer profile-to-asset introspection
- a standalone `doctor` subcommand if the workflow grows further
- more distro mappings
- profile-specific post-build smoke checks
- automatic documentation generation from collected results
