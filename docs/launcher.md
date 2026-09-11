# Launcher And Profiles

Use the `katzensteg` launcher for normal runs.

```sh
./zig-out/bin/katzensteg
./zig-out/bin/katzensteg --dry-run <profile>
./zig-out/bin/katzensteg <profile>
```

The launcher exists so app-specific setup is repeatable. It resolves profiles, prepares the target environment, writes runtime configuration, redirects logs when needed, and starts the target application.

## Build First

```sh
zig build
```

Then list visible profiles:

```sh
./zig-out/bin/katzensteg
```

Start with the input probe on a new machine:

```sh
./zig-out/bin/katzensteg --dry-run probe.input
./zig-out/bin/katzensteg probe.input
```

## Profile Files

Profiles live in `profiles/*.json`.

A profile may:

- name a target executable
- provide arguments
- set environment values
- inherit reusable hidden fragments
- choose runtime policy
- seed local config files
- use platform-specific values

Hidden profiles are fragments such as adapter/runtime defaults. Visible profiles are intended to be run directly.

## Search Paths

By default, the launcher reads:

```text
{repo}/profiles
```

Overrides:

```sh
KATZENSTEG_PROFILE_DIR=/path/to/profiles ./zig-out/bin/katzensteg
KATZENSTEG_REPO=/path/to/katzensteg ./zig-out/bin/katzensteg probe.input
```

`KATZENSTEG_PROFILE_DIR` may be used for local/private profile sets without committing machine-specific paths to the repository.

## Real App Profiles

Real app profiles often assume:

- local source checkouts under `~/dev`
- patched app branches that expose output/input paths Katzensteg can currently exercise
- ROM, game, or media files that are not stored in this repository
- platform-specific build products

Always run `--dry-run` before trying a real app profile on a new machine. It shows the resolved command and environment without starting the target.

For the current app matrix, see `docs/external-projects.md`.


## WM External Clients

The WM can host producers connected through a local Unix socket alongside profiles it launches itself:

```sh
./zig-out/bin/katzensteg-wm --listen /tmp/my-wm.sock
./zig-out/bin/katzensteg-wm --listen /tmp/my-wm.sock --session probe.embed.basic_sdl
```

`--listen` must precede profiles or `--session`. Leading `~/` in the socket address is expanded by the WM. Binding happens before terminal initialization. An existing socket or file is never replaced; normal shutdown removes the socket created by this host. Listener mode stays available after the last window exits, including when started with initial profiles.

In another shell, select that WM and launch an existing profile:

```sh
export KATZENSTEG_TARGET="jsonl:/tmp/my-wm.sock"
./zig-out/bin/katzensteg probe.embed.basic_sdl
```

An unset target preserves standalone behaviour. An explicit invalid, unavailable or rejected target fails before the application starts, without opening or resetting the shell terminal. Leading `~/` in the address is expanded by the launcher. Registration has a five-second deadline. `--dry-run` reports the destination without connecting. Explicit `--embed-jsonl` takes precedence over the inherited target, so WM-owned and pi-owned launches keep using their existing pipes.

The shell launcher owns and reaps its application; the WM owns only its connection. Host disconnection or a window-close request terminates the application after a short grace period. Shell interruption also terminates and reaps it. Application stdin, profile-selected stdout/stderr and exit status remain separate from the rendering connection. This path currently requires an existing profile; arbitrary executable capture and reconnectable sessions are not implemented.

A client starts with one UTF-8 JSON line:

```json
{"type":"register","version":1,"title":"Monkey Island 2"}
```

The host replies with `{"type":"registered","version":1,"session_id":1}`, followed by the existing embedded `hello` and `attach` messages. The session ID is host-assigned and increases for each registration; the producer's window ID remains `main`. Subsequent traffic uses the existing embedded control and presentation protocols. Titles must contain 1–128 UTF-8 bytes without control characters. Registration is limited to 1,024 bytes, 16 pending clients and five seconds per handshake. Invalid registrations and excess connections are closed without disturbing existing windows.

The socket is mode `0600` and is a trusted, same-user rendering connection, like the existing embedded pipes. It carries terminal presentation commands, not an untrusted remote-display protocol. Incomplete registrations never block the event loop. Socket control output is buffered up to 512 KiB per client; exceeding that limit closes its control direction. Closing a window requests shutdown and drains final presentation output. On WM quit, external clients have two seconds to finish before their sockets are closed.

The host reuses completed slots (32 by default) after draining traffic and deleting that slot's graphics. Cleanup uses Kitty's image-ID range deletion, confirmed against the local Kitty implementation; terminals hosting the WM need support for that operation. Session IDs remain distinct when slots are reused.
