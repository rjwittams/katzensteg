# Unsupported Launch Agent Handoff Notes

## Purpose

Katzensteg should eventually treat an unsupported launch as an investigation artifact, not just a failed command. If simple inspection cannot classify or run a target, the launcher should produce a compact report and a prompt that a user can hand to a local coding agent.

The goal is reproducibility: preserve what was tried, what failed, and what evidence exists so maintainers can replay the path without relying on vague user reports or blindly accepting generated patches.

## Generated Report

A future `katzensteg diagnose <profile-or-command>` flow should collect:

- resolved argv, environment, profile fragments, seed files, and runtime config
- platform, terminal identity, graphics transport, and selected output profile
- preload/library paths and whether they exist
- obvious render-stack clues: SDL2, SDL3, OpenGL, Vulkan, Metal, Cocoa, Qt, unknown
- runtime logs and the most recent launcher/preload errors
- a classification such as:
  - known supported path, profile/config issue likely
  - SDL path present but capture failed
  - OpenGL or Vulkan path present but adapter failed
  - currently unsupported non-SDL/native UI path
  - not enough evidence

## Agent Prompt

The generated handoff prompt should include:

- exact command/profile the user ran
- exact dry-run output and relevant logs
- paths to local Katzensteg docs and investigation instructions
- clear constraints:
  - first try to make a launcher profile/config change
  - modify Katzensteg only for general runtime/adapter issues
  - do not directly upstream app patches unless the contributor understands that project’s contribution process
  - prefer contributing patches to our forks or opening an issue asking us to create/maintain a fork branch
- a request to attach the full agent session transcript or a reproducible investigation bundle, after scrubbing secrets, tokens, hostnames, and private paths as needed

## Investigation Skill

Add a repo-local skill/playbook later, likely at one of:

- `docs/katzensteg/agent-investigation-skill.md`
- `.agents/skills/katzensteg-investigate/SKILL.md`

It should teach an agent how to:

- identify whether the target uses SDL software, SDL GL, SDL Vulkan, or a non-SDL stack
- recognize cases that are not expected to work yet
- create or adjust launcher profiles
- add narrowly scoped config seed files
- collect useful logs and profiler evidence
- distinguish app-side changes from Katzensteg runtime changes
- prepare patches with a clear session log and reproduction steps

## Known Future Unsupported Paths

Native macOS app capture is not in scope for the current SDL/OpenGL/Vulkan bridge, but it is an interesting future direction.

Potential targets:

- Cocoa apps
- Qt apps that do not route through SDL
- Metal-backed apps
- iOS Simulator windows

Possible long-term shape:

- hook or observe Cocoa window/layer presentation
- capture app menus and expose them as terminal-side chrome or a nearby TUI
- allow terminal-side command palettes for native menus
- route input between terminal chrome and the captured app
- keep the normal app visible, hide it, or present both depending on profile/runtime policy

The iOS Simulator case is especially interesting because it combines native Cocoa windowing, app-like input, and menus/tooling that could be represented as terminal-side controls. It is not a near-term requirement, but it is a useful north star for keeping the runtime less SDL-specific over time.

## Open Questions

- Should diagnostic output be a plain text prompt, JSON bundle, or both?
- Where should privacy scrubbing happen: launcher, generated prompt, or user/agent checklist?
- Should the launcher include a stable `--bundle-diagnostics` command that writes a directory of logs/config/snapshots?
- How much binary inspection should happen locally before asking an agent to investigate?
- Should app fork contribution guidance live in this skill or in `docs/katzensteg/external-projects.md`?
