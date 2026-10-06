# Session windows

A design for showing [cleat](https://github.com/flotilla-org/cleat) terminal
sessions as windows in the desktop WM, beside producer windows. Attached sessions
have an optional cells presentation; its entry points are described in
[launcher.md](launcher.md). Input and session images remain separate tickets. The decisions behind each rule are indexed on
[#89](https://github.com/rjwittams/katzensteg/issues/89); the ticket holding a
decision is linked where the rule is stated.

## Terms

- **Session**: a terminal session hosted by a cleat daemon. It has a program, a
  grid of cells, scrollback, and it outlives its clients.
- **Outer terminal**: the terminal the desktop WM runs in and draws to.
- **Producer window**: today's window. Its content is an image from a producer.
- **Session window**: a window whose content is a session.
- **Presentation**: how a session window's content is drawn. *Cells*: the WM
  paints the session's grid as text. *Frames*: the WM shows pictures of the
  session rendered elsewhere.
- **Mirror**: the WM's copy of a session's visible grid.

## Scope

In scope: the desktop WM (`src/katzensteg/wm_host.zig`), the cells presentation,
images drawn by programs inside a session, starting sessions and attaching to
them, and the WM's side of the frames presentation.

Out of scope, each for a later effort:

- background and split roles for a session window; virtual desktops;
- a session picker, and a more discoverable launch prompt;
- restoring session windows when the WM starts;
- selection and copy done by the WM;
- telling a producer inside a session to open its own window;
- session windows in the Claude pane, the wrap relay or pi (see
  [Other hosts](#other-hosts));
- wheelhouse's side of the frames presentation;
- cleat's attach client compositing panels
  ([cleat#216](https://github.com/flotilla-org/cleat/issues/216)), which is the
  arrangement for when no WM is running.

The WM is outermost. It owns the outer terminal, and sessions and producers are
both its windows.

## The window model

A window is one thing with two kinds of content
([#94](https://github.com/rjwittams/katzensteg/issues/94)).

The window owns its rectangle, its place in the one window order, focus, chrome
and title. These are the same for both kinds. A session window has no layering,
chrome or resize handling of its own.

| | Producer content | Session content |
|---|---|---|
| Drawn as | an image | cells, or frames |
| On close | the producer is shut down | the WM detaches; the session keeps running |
| Resize | keeps the image's aspect | free, in whole cells |
| Title | the profile name | the session id |

## Connecting to cleat

The WM links cleat's library through its C header, `cleat_provider.h`, with the
daemon backend ([#93](https://github.com/rjwittams/katzensteg/issues/93)). It
runs no terminal engine and does not speak cleat's packet protocol itself.

- **Build option.** Cleat support is off by default, as Jackstay is. The default
  build and CI need no Rust toolchain or cleat checkout.
- **Mirror.** For daemon sessions the library keeps no grid on the client side.
  It delivers full-replace, row-replace and scroll-copy operations. The WM keeps
  a mirror of the visible grid, cursor and terminal modes per session window, in
  the shared WM layer (`src/katzensteg/wm/`) and independent of presentation.
  Scrollback is not mirrored.
- **Wake.** The library calls back from its own reader thread. The WM bridges
  that into its event loop. A descriptor to wait on is requested in
  [cleat#292](https://github.com/flotilla-org/cleat/issues/292).
- **Version check.** The library and the installed daemon must agree on protocol
  version exactly. The WM checks at start, or on the first attempt to open a
  session. On a mismatch it refuses session windows and says why in the status
  row, naming both versions. Producer windows are unaffected
  ([#109](https://github.com/rjwittams/katzensteg/issues/109)).

## Opening, closing and ending

### Opening

Through the existing launch prompt and the command line
([#109](https://github.com/rjwittams/katzensteg/issues/109)):

| To do | Word form | Sigil form | Command line |
|---|---|---|---|
| Start a session running the shell | `term` | `!` | `--term` |
| Start a session running a command | `term <command>` | `!<command>` | `--term <command>` |
| Attach to an existing session | `attach <id>` | `@<id>` | `--attach <id>` |

The prompt accepts only profile-name characters today, so it has to accept
spaces and the two sigils. A profile named exactly `term` or `attach` is
shadowed by the word form: typing that name in the prompt opens a session, not
the profile. No profile in this repo has either name. Cleat allocates a new
session's id.

### Attaching

The WM attaches as a controller without taking exclusive control, and asks for
the window's content size in cells
([#94](https://github.com/rjwittams/katzensteg/issues/94)). Cleat sets the
session's size to the smallest any controller asks for, in each dimension. So
attaching a window smaller than the session's other controllers shrinks the
session for all of them, until the window grows or detaches.

- If the grid is smaller than the window, it is shown top-left and the rest of
  the content area is blank.
- If the grid is larger (a pinned size, or before a resize lands), the window
  shows its top-left part.

If another client takes exclusive control, cleat demotes the WM's attachment to
a watcher and drops its input. The chrome marks the window as watching, and a
command in the Ctrl-] menu asks cleat for control again. Control is not retaken
automatically; Ctrl-] then `r` asks for control ([#95](https://github.com/rjwittams/katzensteg/issues/95)).

### Closing and ending

- **Close always detaches.** The session keeps running and can be attached
  again.
- **When the session's program exits, the window closes.**
- **When the WM quits it detaches from every session.** The next WM starts with
  no session windows.
- **Ending is a second button in the title bar,** beside the one that closes
  ([#107](https://github.com/rjwittams/katzensteg/issues/107)). It ends the
  session at once when this window is its only client, and asks first when cleat
  reports others attached. The recording is kept. The button needs a call that
  cleat's library does not have yet
  ([cleat#292](https://github.com/flotilla-org/cleat/issues/292)); until it
  exists the button is not offered.

## What the program is told

The session is cleat's terminal, not the outer one. The WM presents what cleat's
engine holds and accepts cleat's answers to the program as they are
([#96](https://github.com/rjwittams/katzensteg/issues/96)).

- **Identity and capabilities.** The program is told it is Ghostty and that
  kitty graphics work, whether or not anyone is attached.
- **Size in pixels.** The WM reports the outer terminal's cell size in pixels
  when it attaches and whenever the terminal's size changes. If the outer
  terminal reports no pixel size, the WM reports nothing.
- **Default colours.** When the WM starts a session it asks the outer terminal
  for its default foreground and background once, and passes them at creation,
  so a program choosing a light or dark theme matches what the user sees. A
  session the WM attaches to keeps what it had, which may not match the outer
  terminal.

## Input

([#95](https://github.com/rjwittams/katzensteg/issues/95),
amended by [#106](https://github.com/rjwittams/katzensteg/issues/106).)

There are two layers, the WM and the program. Cleat's own Ctrl-] prefix belongs
to its attach command, which is not in the path.

- **Attention key.** Unchanged. Ctrl-] arms the WM's menu, and a doubled press
  sends one literal Ctrl-] to the focused window.
- **Keys.** The WM decodes terminal bytes into native keys and sends cleat
  structured key events: name, position, modifiers, press, repeat or release,
  and text. Raw bytes are never sent. Cleat encodes for the program from the
  session's live modes. On a terminal without the kitty keyboard protocol the
  WM sees whole taps and sends each as a press.
- **Paste.** Sent as a paste event.
- **Where the conversion lives.** In an adapter beside the SDL ones. The tty
  source and the input model are untouched, as the input boundaries in
  `CLAUDE.md` require.
- **Focus.** Arming the menu, or focus moving to another window, sends the
  session a focus-lost event and a release for each held key. Returning sends
  focus gained.
- **Pointer on the chrome.** The window's, as for producers.
- **Pointer in the content.** If the program has mouse tracking on, pointer
  events go to it as cleat mouse events with cell and pixel coordinates. If not,
  the wheel scrolls the scrollback and other pointer events do nothing.
- **No bypass.** While a program tracks the mouse there is no modifier that
  takes the wheel back. Shift with the mouse stays the outer terminal's.

## Painting cells

([#97](https://github.com/rjwittams/katzensteg/issues/97) is the prototype these
rules come from.)

- The WM paints rows that changed on each update from cleat, and the whole
  window after anything redraws the desktop over it.
- A window's old area is cleared and its new area painted inside one
  synchronized update, and only cells the new rectangle no longer covers are
  cleared. The prototype did these as two writes, which flickered when dragged.
- Each cell is painted with its glyph, colours and style. A cell whose
  background is the session's default is painted as the
  [covering rule](#one-window-covering-another) says.
- **Default colours are the outer terminal's.** A cell whose foreground is the
  session's default is painted with the outer terminal's default foreground (an
  SGR reset), and a default background follows the covering rule above, so
  default background too derives from the outer terminal. For sessions the WM
  starts, this matches, because they are created with the outer defaults ([What
  the program is told](#what-the-program-is-told)). A session the WM attaches to
  whose own defaults differ is shown in the outer terminal's defaults instead of
  its own. This mismatch is accepted
  ([#127](https://github.com/rjwittams/katzensteg/issues/127)); painting an
  attached session's own defaults is left undesigned.
- A wide character needs both of its columns inside the window and uncovered.
  Otherwise a space is painted in its place.
- The session's cursor is drawn in the focused window. The outer terminal's own
  cursor stays hidden.
- Cells covered by a higher window are not painted.

Measured in the prototype at 80×24: one changed row is about 120 bytes; all rows
about 2,100 bytes and under half a millisecond to build. Cleat coalesces
updates, and sends the whole visible grid on every scroll.

## One window covering another

([#101](https://github.com/rjwittams/katzensteg/issues/101), checked in kitty
and Ghostty in [#104](https://github.com/rjwittams/katzensteg/issues/104).)

Producer images move into the kitty z-index band that cells with a background
colour draw over (below `INT32_MIN/2`). The WM adds a constant to the z base it
already sends; producers do not change.

| Case | Rule |
|---|---|
| Text over image | The covering cells paint an explicit background. This applies to session cells and to chrome. |
| Image over image | Plain z order, from each window's place in the window order. |
| Image over text | Text draws above images in this band, so the WM leaves blank, at the default background, every text cell a higher image covers. |
| Bars beside an aspect-fitted image | Cells of a window's content area that its own image does not fill paint a background. Cells under the window's own image stay at the default background. |

- **Kitty's rule.** Kitty lets a cell cover only if its background differs in
  value from the terminal's default. Cells that would be the default are painted
  with the outer terminal's default colour changed by one step in one channel:
  the blue channel plus 1 in 8-bit, or minus 1 when blue is already 255. This is
  done on every terminal, so there is one code path.
- **Transparent pixels** in a higher image show a lower image through them.
- **Fallback.** Splitting an image into explicit placements around occlusion
  rectangles stays in the code for a terminal that does not honour the band.
- **Known limit.** Ghostty's `background-opacity-cells` with an opacity below 1
  is expected to make covering cells translucent. This was read from Ghostty's
  source and not checked by eye.

The rule must stay compatible with two things wanted later: window decorations
composed of images, and sub-cell placement of image windows.

## Images inside a session

([#99](https://github.com/rjwittams/katzensteg/issues/99).)

Implementation status: decoded-resource uploads, lifetime handling and explicit
placements are supported by the cells presentation. Unicode placeholders await
Cleat's original virtual placement declarations
([cleat#317](https://github.com/flotilla-org/cleat/issues/317)); the rules below
remain the contract for that follow-up.

Cleat hands the WM decoded pixels plus resolved placements. The program's own
graphics commands never reach a client. The WM uploads each image to the outer
terminal under an id of its own.

- **Drawn by the program with unicode placeholders.** The WM paints the same
  placeholder cells with its own image id, and makes one virtual placement. The
  per-row placements cleat also resolves for these are ignored.
- **Placed explicitly by the program.** The WM makes an explicit placement at
  the window's content origin plus the placement's grid position, in the low
  band, clipped to the content area and the terminal.
- **Cells under a session's own image** follow the program's z-index. For an
  image under the program's text, cells keep their glyphs and are painted with
  the true default background, so the image shows behind them. For an image over
  the program's text, the cells are left blank.
- **Order.** A session's images take their place in the band from the window's
  place in the window order, with the program's own order kept among them.
- **Pixels.** The WM copies the bytes the library gives it into shared memory or
  a file and uploads by name, never inline. When the library exposes the image's
  backing file ([cleat#292](https://github.com/flotilla-org/cleat/issues/292))
  the WM passes that and the copy goes away.
- **Lifetime.** The WM keeps an outer image while cleat lists it, deletes it
  when cleat stops listing it, and deletes all of a window's images when the
  window detaches.

A katzensteg-wrapped app run from a shell in a session window draws inside the
window by these rules, like any program that draws images
([#108](https://github.com/rjwittams/katzensteg/issues/108)).

## Scrollback, selection and copy

([#106](https://github.com/rjwittams/katzensteg/issues/106).)

- **Scrollback is cleat's.** The WM moves its own view of the session by cleat's
  viewport commands. Other clients' views do not move.
- **Wheel.** Scrolls when the program is not tracking the mouse.
- **Keyboard.** Shift+PageUp and Shift+PageDown scroll, except while the program
  is on its alternate screen, when they go to the program.
- **Typing snaps back.** Any key sent to the program returns the view to the
  bottom.
- **Indicator.** The title marks a window that is scrolled back.
- **Selection and copy** are the outer terminal's: its native Shift-drag. It
  selects straight across window borders, and only what is on screen.

## Not supported until cleat delivers it

Cleat's client interface carries none of these today. All are listed in
[cleat#292](https://github.com/flotilla-org/cleat/issues/292).

| Missing | What the WM does when it arrives |
|---|---|
| Clipboard writes by the program | Passes them on to the outer terminal |
| The bell | Marks the window's title |
| Notifications | Passes them on to the outer terminal |
| The program's window title | Not decided; the title is the session id |
| Environment variables at session creation | Not needed by this spec |

## The frames presentation

([#98](https://github.com/rjwittams/katzensteg/issues/98).) This is the last
stage and is deliberately thin.

A session window has a presentation: cells or frames. In the frames presentation
the picture of the session comes from a frame source over Jackstay. The intended
source is wheelhouse, publishing a view. Katzensteg builds no renderer and is
one client of that ability among others.

What the WM needs from a frame source: frames for a named session, at the
session's size, over Jackstay.

Not decided: who carries input and size while a window shows frames
([#102](https://github.com/rjwittams/katzensteg/issues/102)). The leading answer
is that the WM keeps its cleat attachment and Jackstay carries frames only, so
switching changes only what is drawn and the mirror keeps running.

Wheelhouse cannot do this today: it has no Jackstay source side, no production
readback path and no mode without a window, and Jackstay has no way to ask a
source to resize ([#91](https://github.com/rjwittams/katzensteg/issues/91)).

## Other hosts

Stated, not designed
([#109](https://github.com/rjwittams/katzensteg/issues/109)).

- **Claude pane.** It can show text through its own elements as well as images,
  but not everything a terminal grid holds. A session there has two possible
  presentations: limited text built from the pane's elements, or frames for full
  fidelity.
- **Wrap relay.** The wrapped program already owns the background. Session
  windows over it would be a new role.
- **Pi.** Its host does not use the WM layer. It would need either to adopt that
  layer or to have its own cleat client.

## Stages

1. **Plain cells.** The build option, the library link and version check, the
   mirror, the window model with session content, opening and attaching,
   closing, keys, focus, pointer, painting, and scrollback.
2. **The covering rule.** Producer images move to the low band; text covers by
   background; the WM blanks text under higher images. This changes producer
   windows too, and can be done before or alongside stage 1.
3. **Images inside a session.**
4. **The end button,** when cleat's library has the call.
5. **The frames presentation,** when a frame source exists.

## Risks

- **A full-motion app inside a session.** Every frame is decoded by cleat, then
  copied and uploaded again by the WM. Not measured.
- **Cleat moves quickly.** Its packet protocol changed version twice in 26
  commits during this design, and the library must match the daemon exactly.
- **Terminals other than kitty and Ghostty** were not checked for the low band.
