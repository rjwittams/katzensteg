# Katzensteg Claude Code plugin

A Claude Code function-hooks plugin that shows Katzensteg game panels above
the prompt. A headless `katzensteg-wm` owns the producers, image ids and the
graphics writes to the terminal; the plugin finds or starts it, draws one
panel per session as Kitty unicode-placeholder cells, sizes each panel's grid,
and relays the panel's keyboard and pointer input. The terminal composes each
producer's image into its panel's cells, so scrolling, band collapse and
redraws need no geometry.

Needs `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` (early access, 2.1.260+), a
terminal with Kitty unicode placeholders and truecolour (`COLORTERM=truecolor`),
and Claude Code's fullscreen TUI mode: mouse reporting is only enabled on the
alternate screen, and without it neither clicks on the band nor click-to-focus
into a panel arrive.

## Run

```sh
cd ~/dev/katzensteg
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude --plugin-dir tools/claude-code-plugin
```

To serialize Claude's output and panel graphics through one terminal writer:

```sh
cd ~/dev/katzensteg
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 ./zig-out/bin/katzensteg-wm --wrap -- \
  claude --plugin-dir tools/claude-code-plugin
```

The wrapper runs Claude on an inner PTY and forwards input unchanged, including
Ctrl-C. Exit Claude normally to stop the wrapper. This mode needs the plugin
from the same checkout: it attaches through `KATZENSTEG_WM_HOST`, supplied by
the wrapper. It refuses an invalid or unreachable explicit host instead of
starting another writer. Start it in a terminal without an existing headless
host; the host's per-terminal lock prevents a second host taking ownership.

```text
/katzensteg open mi2 [args...]   # open a panel
/katzensteg close [id]           # close the last or the named panel
/katzensteg size small|medium|large   # panel height preset (medium by default, remembered)
/katzensteg list                 # sessions the host knows
/katzensteg host                 # host status; reconnects or starts one
/katzensteg stop                 # close every panel
```

Click a panel to play; Escape returns the keyboard to the prompt. The border
is the panel's own UI: × at the top-right closes it, dragging the title row
reorders panels in the band, and dragging the right edge, bottom edge or the
corner resizes it, keeping the source aspect. A dragged size replaces the
preset for that panel until `/katzensteg size` is used again. The title shows
how many input events the panel has captured. The plugin
also exports `KATZENSTEG_TARGET=jsonl:<host socket>` and
`KATZENSTEG_OBSERVE=1` to the model's Bash tool, so a plain
`katzensteg mi2` in a shell opens a panel too, as it does under pi.

Environment:

- `KATZENSTEG_HOST_BIN`: host binary (default `<repo>/zig-out/bin/katzensteg-wm`),
  built with the Zig toolchain noted in the repo.
- `KATZENSTEG_REPO`: repo root when not `~/dev/katzensteg`.
- `KATZENSTEG_WM_HOST`: discovery JSON inherited from `--wrap`. The plugin
  uses this host before trying background discovery; do not set it manually.

## How the host is found and started

Without an explicit wrapper host, at session start the plugin runs
`katzensteg-wm --headless --background`,
which starts a host for this terminal or answers for the one already running,
and prints its discovery record (pid, port, token). The child inherits the
terminal and the host opens it before detaching, so `$.process.run` returns
as soon as HTTP is up. The plugin then registers a client
(`POST /v1/clients`), sends its id on every request, and sets the client's
launch target in `KATZENSTEG_TARGET`. Each plugin session is its own client
with its own producers; two Claude Code sessions in one terminal share the
host. Polling `/sessions` every 400 ms renews the client's lease; a host with
no clients exits on its own. If the host goes away the poll loop reconnects.

The host contract is documented in [the launcher guide](../../docs/launcher.md#headless-placeholder-host).
Observation and refresh use HTTP requests; session metadata is polled.
Event long-polling and animation-frame edits remain future work.

## Agent tools

Registered at session start, served by `tool.call` hooks in the hooks module:

- `mcp__katzensteg__open` `{profile, args?}`: open a panel; returns its id.
- `mcp__katzensteg__show` `{html | path, title?}`: show an HTML page in a
  panel through luchs (macOS). Writes `html` to a temp file, sizes the page to
  the panel's pixel area (doubled for crisp text), and opens it with
  `--watch`, so rewriting the file updates the picture; `observe` shows it.
- `mcp__katzensteg__panels`: id, title, state, source size, grid per panel.
- `mcp__katzensteg__act` `{panel?, actions}`: up to 16 `move`, `click`, `key`,
  `wait` actions. Coordinates are source pixels, converted to grid cells; a
  click holds 60 ms; keys are taps; waits total at most 5 s. `panel` may be
  omitted with one panel open.
- `mcp__katzensteg__observe` `{panel?, afterFrame?}`: the latest frame as a
  PNG path for the Read tool, with size and capture id.

Three things make a model reach for these on its own: a standing line in
the system prompt (a `prompt.section` hook appends it to the environment
section while a host is connected, and invalidates it when the connection
changes, so the cached prompt stays stable), the `katzensteg-visualize` skill
under `skills/`, whose description carries the trigger words and whose body
carries the workflow and layout rules for the small panel, and trigger words
in the tool descriptions, which ToolSearch matches on. The tools themselves
are deferred, so descriptions alone are not enough.

A hook's result is a string (or content blocks); a refusal is `{ deny }`,
which the model sees as an error result. A hook body may not declare a local
named `next`: the engine refuses the module at load.

## Files

- `hooks/register.tsx`: host discovery and start, commands, the band render,
  grid sizing, input relay and session polling.
- `hooks/panel.tsx`: the `Client` surface module drawing one panel and
  capturing its keys and pointer. Input is numbered and the recent tail is
  posted each frame; the hooks module forwards only what it has not sent.
- `hooks/placeholders.ts`: placeholder rows, image-id colour, aspect-fitted
  grid sizing. `hooks/host.ts`: discovery record, client, session and event parsing,
  input de-duplication. Both are pure and tested.
- `hooks/diacritics.ts`: the placeholder diacritic table, generated from
  `~/dev/kitty-image-tests/smoke/util/placement.py`.
- `.claude/types/`: written by `/plugin-types` inside Claude Code and
  git-ignored. Regenerate after a Claude Code update, then `tsc -p .`.

## Checks

```sh
cd tools/claude-code-plugin
npx -p typescript tsc -p .          # types, against the generated declarations
node --test hooks/*.test.ts         # pure-function tests (Node 22.18+)
```

## Status (2026-09-15)

Verified in a recorded session against the real headless wm: the plugin
starts the host with the terminal's device path, registers a client, sets the
launch target, opens the SDL demo, posts the fitted grid once the source size
is known, and the producer's file-backed transmits and virtual placements
reach the terminal with nothing torn. It reconnects if the host goes away.
Verified earlier in ghostty: a real game (sonic) composed into the band.

Verified in ghostty by Robert: click-to-focus, keys and pointer reaching the
game (fullscreen TUI mode required). Verified in a recorded session with a
model turn: the four agent tools `mcp__katzensteg__open`, `panels`, `act`
and `observe`, mirroring the pi extension; `observe` returns a 640x480 PNG
the Read tool renders, served by the host's `/observe`. Verified the same way: `show` renders a page, a rewrite of its file
re-renders (luchs `--watch`), and `observe` returns the new picture. Event long-polling, wheel input and animation-frame edits remain unsupported
by the host. Band redraws reuse the existing image instead of requesting another upload.
The host restores idle sessions every 500 ms by default, including after
terminal clears. Use `--idle-refresh-ms 0` when measuring producer frame cadence;
stationary images then need an explicit refresh after a clear.
Wrap mode instead detects `CSI 2 J` / `CSI 3 J` in the child's output and
requests retained frames after the clear. Its periodic idle refresh defaults
to off; `--idle-refresh-ms 500` before `--wrap` enables it as a fallback.

## Findings that shaped this

- Function hooks have no Node, no tty, no sockets. Escape hatches are
  `$.process.run` (one shot), `$.fs` (text, 4 MiB), `$.http.fetch` (text).
  Named pipes do not work: `$.fs.read` returns empty instead of blocking.
- Write one escape sequence per tty write. A large write is split by the
  kernel and Claude Code's own output tears the sequence; the terminal then
  prints base64 at the cursor. UTF-8 placeholders tear the same way in the
  other direction, which is why the host keeps its own output small.
- Without `COLORTERM=truecolor` Claude Code downgrades the placeholder
  foreground to a 256-colour index, which kitty reads as a different image id.
