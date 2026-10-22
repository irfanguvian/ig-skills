---
name: figma-axi
description: 'Read Figma designs through the figma-axi CLI - file structure, frames, layout and style trees, design tokens (colours, typography, effects), component lists, rendered images, and comments. Use whenever a task needs design data from Figma: implementing a screen from a mockup, extracting colours or spacing, checking what a frame contains, or pulling a render of a design.'
---

# figma-axi

Agent ergonomic wrapper around the Figma REST API. Prefer this over raw `curl` to `api.figma.com`, and over pasting screenshots, for any Figma read.

The CLI lives in this skill folder at `bin/cli.mjs` and is usually linked onto the PATH as `figma-axi` (for example `~/.local/bin/figma-axi`). It is not on npm — there is no `npx` form. If `figma-axi` is not found, call it as `node ~/.claude/skills/figma-axi/bin/cli.mjs <command>`.

Requires a Figma personal access token in `FIGMA_TOKEN` (or `FIGMA_PERSONAL_ACCESS_TOKEN`). If a command reports a missing or rejected token, ask the user to create one at https://www.figma.com/settings (Security > Personal access tokens) and export it — do not attempt to mint one.

Read-only. It never writes to a Figma file.

## When to use

Use figma-axi whenever a task touches a Figma design: building a component from a mockup; extracting hex colours, font sizes, spacing or radii; listing the pages, frames or components in a file; getting the exact node id behind a Figma link; rendering a frame to PNG for visual comparison; or reading review comments left on a design.

## Workflow

1. Run `figma-axi` with no arguments for the home view — token status and the command list. Set `FIGMA_FILE_KEY=<key>` to make the home view open on that file instead.
2. `figma-axi file <key|url>` first — it gives the pages and every top-level frame with its node id. Everything else keys off those ids.
3. `figma-axi node <key|url> <node-id>` for the layout and style tree of one frame. This is the main command for implementing a screen.
4. `figma-axi tokens <key|url>` for the design system values — colours, text styles, effects — resolved to real hex and font values.
5. Every response ends with contextual next-step hints under `help:` — follow them.

## Commands

```
commands[8]:
  (none)=home, me, file, node, styles, components, tokens, images, comments
```

Both a raw file key and a full `figma.com/design/...` or `figma.com/file/...` URL are accepted anywhere `<key|url>` appears. A URL carrying `?node-id=1-42` is enough for `node` and `images` — the id does not have to be passed separately, and the URL's `1-42` form is converted to the API's `1:42` automatically.

Run `figma-axi --help` for the command list, or `figma-axi <command> --help` for per-command flags and examples.

### file

```sh
figma-axi file <key>                           # pages + top-level frames, max 50
figma-axi file <key> --page Onboarding         # frames on one page only
figma-axi file <key> --limit 200               # raise the frame cap
figma-axi file <url> --depth 3                 # go one level further into each frame
```

Returns file name, last modified, version, then a `pages` table and a `frames` table with node ids and sizes. The frame list is capped at 50 with a `shown: N of M frames` line — a real design file can carry hundreds. `--page` matches a page id or any substring of its name, and drops the `pages` table from the output.

Watch for divider pages: files often contain an empty page whose name repeats the real one (`✲ ・ Onboarding` next to `↪️ [All] Onboarding`). The `frames` count in the `pages` table tells you which is which.

### node

```sh
figma-axi node <key> 1:42                      # default depth 2, max 200 rows
figma-axi node <key> 1:42,1:88 --depth 5       # several nodes, deeper tree
figma-axi node "<figma url with ?node-id=1-42>" --depth 4
figma-axi node <key> 1:42 --limit 500          # raise the row cap
figma-axi node <key> 1:42 --full               # raw Figma JSON, very large
```

Each row is `depth,id,name,type,box,style,text`:

- `box` is `x,y WxH` in absolute page coordinates, rounded to whole pixels.
- `style` is a compressed summary — `Inter 14/20 w600 #111827`, `col gap8 pad16 radius12`, `border #E5E7EB 1px`, `drop_shadow`, `hidden`.
- `text` is the node's characters, truncated to 120 chars.

The tree is capped at 200 rows. When anything is left out, a `shown: N of M nodes` line says why — `depth 2` or `capped at --limit 200`. When the cap bites, pick a child id off the rows already printed and inspect that subtree; that is cheaper and more useful than raising `--limit`. Increase `--depth` rather than reaching for `--full` — on a 12,000-node frame `--full` is over a megabyte of raw JSON.

### tokens

```sh
figma-axi tokens <key>                         # works when the file publishes its styles
figma-axi tokens <key> --page Onboarding       # scan one page instead
figma-axi tokens <key> --from 12:345           # scan one frame
```

Returns `colors` (name, hex, description), `text` (name, font, size, weight, lineHeight, letterSpacing) and `effects`. The `source:` line says which path produced the values.

Two paths:

- **Published styles** — one cheap lookup, exact values. Nothing else needed.
- **Local styles** — unpublished styles carry no values, so figma-axi finds a node that uses each style and reads the value off it. That needs a scope: **Figma rejects a whole-file read on any large file** with `Request too large`, and the error tells you to pass `--page` or `--from`. Scope to the page you are actually implementing.

Because local values come from usage sites, a style whose name appears twice with different values is real information — some node overrides it. Identical rows are collapsed; differing ones are kept.

### styles / components

```sh
figma-axi styles <key>                         # published style metadata
figma-axi components <key>                     # components + component sets
```

`styles` is metadata only — use `tokens` for actual values.

### images

```sh
figma-axi images <key> 1:42 --scale 2          # prints signed urls
figma-axi images <key> 1:42 --out ./shots      # downloads instead
figma-axi images <key> 1:42 --format svg
```

Formats: `png` (default), `jpg`, `svg`, `pdf`; any other value is a usage error (exit 2). Scale defaults to `2`. Signed urls expire quickly — prefer `--out` when the file is needed more than once.

### comments / me

```sh
figma-axi comments <key> --limit 10            # newest first, message truncated to 160
figma-axi me                                   # verify the token
```

## Tips

- Output is TOON-encoded and token-efficient; pipe through `head` only when a tree is very long.
- Errors are structured and land on stdout, same as data. Exit codes: 0 success, 1 error, 2 usage error.
- Unknown flags are rejected by name with the command's valid flags listed — the fix is in the error, no `--help` round-trip needed.
- Start shallow. `file` then `node --depth 2` answers most questions; deepen only on the subtree that matters.
- For implementing a screen, `node` plus `tokens` beats a screenshot: exact spacing, exact hex, exact font weights.
- Figma rate-limits aggressively. A 429 means wait, not retry immediately.
- Large files are slow at the API, not in the CLI: 1–12 s per call is normal, and a single page can be 40 MB on the wire even when the printed output is under 2 KB.
- `styles` and `components` return nothing for a file that publishes no library — that is a real answer, not a failure. Use `tokens --page` instead.
