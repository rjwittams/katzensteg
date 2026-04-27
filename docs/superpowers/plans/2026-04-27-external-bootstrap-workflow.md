# External Bootstrap Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the external project bootstrap helper so one command can clone/update project checkouts, run manifest-defined builds, and finish with doctor checks that report missing tools, packages, outputs, configs, and assets.

**Architecture:** Keep a single Python entry point in `scripts/katzensteg/bootstrap_external_projects.py` and deepen the existing manifest in `profiles/external-projects.json`. The script remains manifest-driven and dry-run friendly, while new tests lock down selection, package hint reporting, build execution, distro detection, and doctor summaries before implementation code is added.

**Tech Stack:** Python 3, `unittest`, JSON manifest metadata, subprocess-based command execution, `/etc/os-release`, `pkg-config`

---

## File Structure

**Create:**
- `docs/superpowers/plans/2026-04-27-external-bootstrap-workflow.md`

**Modify:**
- `profiles/external-projects.json`
- `scripts/katzensteg/bootstrap_external_projects.py`
- `scripts/katzensteg/test_bootstrap_external_projects.py`
- `docs/katzensteg/external-projects.md`

**Responsibilities:**
- `profiles/external-projects.json`: Declare build commands, doctor metadata, and distro package hints.
- `scripts/katzensteg/bootstrap_external_projects.py`: Implement clone/update, build, doctor, reporting, and CLI flags.
- `scripts/katzensteg/test_bootstrap_external_projects.py`: Lock down selection, planning, distro/package resolution, doctor classification, and build execution behavior.
- `docs/katzensteg/external-projects.md`: Record Linux build commands, required packages, and any project-specific caveats discovered during bring-up.

### Task 1: Extend Manifest Shape

**Files:**
- Modify: `profiles/external-projects.json`
- Test: `scripts/katzensteg/test_bootstrap_external_projects.py`

- [ ] **Step 1: Write the failing tests for manifest metadata**

Add tests that assert:
- top-level package hint maps exist for Arch and Debian/Ubuntu
- at least one known capability maps to exact package names
- project entries expose new doctor metadata for tools, pkg-config modules, paths, and assets where applicable

Example assertions to add:

```python
package_hints = manifest["package_hints"]
self.assertEqual("ffmpeg", package_hints["arch"]["ffplay"])
self.assertEqual("ffmpeg", package_hints["debian"]["ffplay"])
self.assertIn("doctor", bootstrap.project_by_name(manifest, "chiaki-ng"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- FAIL with missing `package_hints` / `doctor` keys or equivalent assertions

- [ ] **Step 3: Add minimal manifest metadata**

Update `profiles/external-projects.json` to include:
- top-level `package_hints`
- per-project `doctor` objects
- Linux-relevant tool, pkg-config, output-path, config-path, and asset-path entries

Keep entries explicit and conservative. Only add package names that are known with high confidence.

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- PASS for the new manifest assertions

- [ ] **Step 5: Commit**

```bash
git add profiles/external-projects.json scripts/katzensteg/test_bootstrap_external_projects.py
git commit -m "feat: record bootstrap doctor metadata"
```

### Task 2: Add Build Planning and Execution

**Files:**
- Modify: `scripts/katzensteg/bootstrap_external_projects.py`
- Test: `scripts/katzensteg/test_bootstrap_external_projects.py`

- [ ] **Step 1: Write failing tests for build planning and execution**

Add tests that cover:
- build commands are selected per current platform
- build commands execute from the project checkout directory
- `--dry-run` prints build commands without running them
- a failing build marks that project failed without preventing later projects from being attempted

Example test shape:

```python
result = bootstrap.run_build_commands(
    [planned_project],
    dry_run=True,
)
self.assertEqual([], recorded_subprocess_calls)
self.assertEqual(["cmake -S . -B build"], result[0].printed_commands)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- FAIL because build execution helpers and result reporting do not exist yet

- [ ] **Step 3: Implement minimal build execution flow**

In `scripts/katzensteg/bootstrap_external_projects.py`:
- introduce result records for clone/update/build
- convert build notes into executable commands for the selected platform
- run each command with `subprocess.run(..., check=True, cwd=...)`
- stop per project on first build failure
- continue with later projects
- preserve dry-run output

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- PASS for build planning/execution tests

- [ ] **Step 5: Commit**

```bash
git add scripts/katzensteg/bootstrap_external_projects.py scripts/katzensteg/test_bootstrap_external_projects.py
git commit -m "feat: execute external project builds"
```

### Task 3: Add Distro Detection and Package Hint Resolution

**Files:**
- Modify: `scripts/katzensteg/bootstrap_external_projects.py`
- Test: `scripts/katzensteg/test_bootstrap_external_projects.py`

- [ ] **Step 1: Write failing tests for distro detection and package suggestions**

Add tests that cover:
- `/etc/os-release` parsing into distro families
- Arch install command formatting
- Debian/Ubuntu install command formatting
- unsupported distro fallback
- missing package mapping fallback without guessing

Example assertions:

```python
self.assertEqual("arch", bootstrap.detect_distro_family(os_release_text))
self.assertIn("sudo pacman -S --needed ffmpeg", report_lines)
self.assertIn("sudo apt install ffmpeg", report_lines)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- FAIL because distro detection and package suggestion helpers are not implemented yet

- [ ] **Step 3: Implement minimal distro/package hint logic**

In `scripts/katzensteg/bootstrap_external_projects.py`:
- read `/etc/os-release`
- classify Arch vs Debian/Ubuntu vs unknown
- map missing capabilities to distro-specific package names from the manifest
- print exact suggested install commands without executing them

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- PASS for distro and package suggestion tests

- [ ] **Step 5: Commit**

```bash
git add scripts/katzensteg/bootstrap_external_projects.py scripts/katzensteg/test_bootstrap_external_projects.py
git commit -m "feat: report distro-specific package hints"
```

### Task 4: Add Doctor Checks for Tools, Libraries, Paths, and Assets

**Files:**
- Modify: `scripts/katzensteg/bootstrap_external_projects.py`
- Test: `scripts/katzensteg/test_bootstrap_external_projects.py`

- [ ] **Step 1: Write failing tests for doctor classification**

Add tests that cover:
- missing executable detection via tool lookup
- missing pkg-config module detection
- missing built output paths
- missing local config paths
- missing asset paths
- aggregate doctor summary output

Example assertions:

```python
report = bootstrap.run_doctor(...)
self.assertIn("missing tools", report.summary)
self.assertIn("missing assets", report.summary)
self.assertIn("$HOME/dev/cannonball/config.xml", report.missing_configs)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- FAIL because doctor checks and summary data do not exist yet

- [ ] **Step 3: Implement minimal doctor flow**

In `scripts/katzensteg/bootstrap_external_projects.py`:
- resolve manifest doctor entries
- check tool presence with `shutil.which`
- check dev-library signals with `pkg-config --exists`
- check file and directory presence using `Path.exists()`
- classify missing items into tools, packages, build outputs, configs, and assets
- collect a report without raising on the first miss

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- PASS for doctor tests

- [ ] **Step 5: Commit**

```bash
git add scripts/katzensteg/bootstrap_external_projects.py scripts/katzensteg/test_bootstrap_external_projects.py
git commit -m "feat: add external bootstrap doctor checks"
```

### Task 5: Wire CLI Modes and Final Summary

**Files:**
- Modify: `scripts/katzensteg/bootstrap_external_projects.py`
- Test: `scripts/katzensteg/test_bootstrap_external_projects.py`

- [ ] **Step 1: Write failing tests for CLI modes**

Add tests that cover:
- default mode runs clone/update, build, then doctor
- `--build-only` skips clone/update
- `--doctor-only` skips clone/update and build
- dry-run still reaches doctor planning/reporting in a non-destructive way
- non-zero exit code when build or doctor failures occur

Example assertions:

```python
exit_code = bootstrap.main(["--doctor-only"])
self.assertEqual(1, exit_code)
self.assertEqual([], recorded_clone_calls)
self.assertEqual([], recorded_build_calls)
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- FAIL because mode flags and final summary behavior are not implemented yet

- [ ] **Step 3: Implement CLI wiring and summaries**

In `scripts/katzensteg/bootstrap_external_projects.py`:
- add `--build-only` and `--doctor-only`
- preserve current selection and root behavior
- print a final structured summary
- return non-zero if any build or doctor failures remain

- [ ] **Step 4: Run tests to verify they pass**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
```

Expected:
- PASS for CLI mode tests

- [ ] **Step 5: Commit**

```bash
git add scripts/katzensteg/bootstrap_external_projects.py scripts/katzensteg/test_bootstrap_external_projects.py
git commit -m "feat: add bootstrap workflow modes and summaries"
```

### Task 6: Record Linux Build Notes and Validate End-to-End

**Files:**
- Modify: `docs/katzensteg/external-projects.md`
- Modify: `profiles/external-projects.json`
- Modify: `scripts/katzensteg/bootstrap_external_projects.py`

- [ ] **Step 1: Run the bootstrap workflow against real Linux selections**

Run the helper on the active Linux machine with repo-local caches or temp build dirs where needed.

Suggested commands:

```sh
scripts/katzensteg/bootstrap_external_projects.py --root ~/dev retroarch cannonball anese scummvm chiaki.sdl moonlight.steam
scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev
```

Expected:
- some builds may fail initially, but the script should complete and report them cleanly

- [ ] **Step 2: Refine manifest package hints and build commands based on observed results**

Update:
- exact package hints for tools and dev libraries that were empirically required
- build commands or path expectations that differ from current assumptions

- [ ] **Step 3: Document the discovered Linux requirements**

Update `docs/katzensteg/external-projects.md` with:
- build commands that actually worked
- extra packages/tools required on Linux
- any still-manual setup steps
- project-specific caveats uncovered during bring-up

- [ ] **Step 4: Re-run focused verification**

Run:

```sh
python3 -m unittest scripts/katzensteg/test_bootstrap_external_projects.py
python3 -m json.tool profiles/external-projects.json >/tmp/katzensteg-external-projects-json.out
scripts/katzensteg/bootstrap_external_projects.py --dry-run --root /tmp/ks-bootstrap-check retroarch chiaki.sdl
scripts/katzensteg/bootstrap_external_projects.py --doctor-only --root ~/dev
```

Expected:
- tests pass
- manifest JSON validates
- dry-run prints clone/update/build/doctor flow without executing
- doctor prints a stable summary

- [ ] **Step 5: Commit**

```bash
git add profiles/external-projects.json scripts/katzensteg/bootstrap_external_projects.py scripts/katzensteg/test_bootstrap_external_projects.py docs/katzensteg/external-projects.md
git commit -m "feat: bootstrap and doctor external linux test projects"
```
