---
name: katzensteg-visualize
description: Show a chart, plot, graph, diagram, table or any other visual in a panel above the prompt, and iterate on it by looking. Use when the user asks to visualize, plot, chart, graph, diagram, draw, or show something visually in the terminal, or when a picture would explain data better than text.
---

# Visualize in a Katzensteg panel

Katzensteg renders an HTML page into a panel above the prompt through the
terminal's graphics protocol. The tools are `mcp__katzensteg__show`,
`observe`, `act` and `panels` (load them with ToolSearch if they are not in
context).

## Workflow

1. Write a complete, self-contained HTML document: inline CSS, inline SVG
   or a small inline script. No external stylesheets, fonts or scripts unless
   the user is known to be online; the viewer loads a local file.
2. Call `show` with the document as `html` (or `path` for an existing file).
   It returns the panel id and the file path.
3. Call `observe` and read the PNG it names. Check that labels are legible
   and nothing is clipped before telling the user it is done.
4. To change it, rewrite the same file with the Write tool. The viewer
   reloads on change; observe again.
5. Close it with `/katzensteg close` when the user is finished, or leave it
   for them to close with the × on its border.

## Layout rules that matter in a panel

- The panel is small: about 16 rows of a terminal, roughly a 3:1 to 4:1
  aspect, rendered at twice the cell size. Use large type (24 px and up for
  labels, 40 px and up for headings), thick lines, few series, and short
  labels. Prefer one clear chart to a dashboard.
- Use a white or very light background with high-contrast colours; the panel
  is composed into a terminal and thin dark-on-dark detail is lost.
- Let the document fill the viewport: `html, body { margin: 0; height: 100% }`
  and size the root SVG or container to 100% of the viewport, so nothing
  depends on the 800x600 default.
- Interactive pages get mouse, wheel and key events from the panel; keep
  interactions simple (hover tooltips, click to select).

## When not to use it

A small table or a few numbers read better as text in the transcript. Use
the panel for shapes, trends, layouts and anything spatial.

## Games and other programs

`mcp__katzensteg__open` runs a Katzensteg profile (a game or app) in a
panel; `act` sends keys and clicks; `observe` screenshots it. A plain
`katzensteg <profile>` in the Bash tool opens a panel too.
