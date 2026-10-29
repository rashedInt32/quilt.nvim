# quilt.nvim spec

One buffer that holds editable excerpts from many files. Search results,
references, diagnostics, and git hunks show up with real code around them. You
edit them in place, and `:w` saves every file you touched.

## Why

Neovim puts results in the quickfix list: one line per hit, no context, and
every change means a jump to another file. Zed solved this with multibuffers.
Neovim issue #30463 asks for the same thing and has no owner. Today's plugins
do part of it. quicker.nvim edits single quickfix lines. zaucy/multibuffer.nvim
shows excerpts but cannot edit through them. zdiff.nvim covers git diffs only.

The name comes from justinmk's comment on #30463: many buffers stitched
together into one "quilt".

## Requirements

- Neovim 0.11 or newer. Tested on 0.12.
- `rg` for `:Quilt grep`. `git` for `:Quilt git`.
- No other plugin. Works with any picker, completion, or LSP setup.

## Words

- **Source**: a real buffer for a file on disk.
- **Excerpt**: a run of consecutive lines from one source.
- **Quilt**: the buffer that shows all excerpts, one after another.
- **Span**: a plain-data snapshot of one excerpt's position.

All rows are 0-based and all ranges are end-exclusive, everywhere in the code.
Only the user-facing text shows 1-based line numbers.

## User-facing behaviour

### Commands

| Command | Builds a quilt from |
| --- | --- |
| `:Quilt` or `:Quilt qf` | the current quickfix list |
| `:Quilt refs` | LSP references of the symbol under the cursor |
| `:Quilt grep {pattern}` | `rg --vimgrep {pattern}` in the cwd |
| `:Quilt diagnostics [error\|warn\|info\|hint]` | diagnostics at or above that severity, all buffers |
| `:Quilt git [ref]` | `git diff -U0 [ref]` hunks; with no ref, unstaged changes |
| `:Quilt refresh` | rereads every excerpt of the current quilt from its source |

Each command opens the quilt in the current window. An empty result shows a
notice and opens nothing.

### The quilt buffer

- Name `quilt://{n}/{title}`, `buftype=acwrite`, `filetype=quilt`, `swapfile`
  off. `acwrite` lets `:w` reach our `BufWriteCmd`.
- The buffer holds only source lines. There are no header lines in the text.
- Each excerpt gets a header drawn with `virt_lines` above its first line:
  a blank line (except the first excerpt), then the path relative to the cwd,
  then `:{first line}`.
- The status column shows the source line number of each row.
- Code is highlighted with the source's treesitter highlights, projected onto
  the quilt rows. A source without a parser gets no highlight.
- Diagnostics of each source show on the matching quilt rows.

### Editing

- Any edit in the quilt changes the source right after it. The source buffer
  changes, not the file. `:w` writes every changed source with its normal
  autocmds, so format-on-save runs.
- Any change to a source, from another window, a formatter, or an LSP rename,
  shows up in the quilt.
- Undo and redo work in the quilt like any edit and flow to the sources.
- Deleting every line of an excerpt deletes those lines from the source and
  removes the excerpt.
- A line inserted between two excerpts goes to the excerpt the cursor was in
  before the edit. `o` on the last line of one excerpt appends to it. `O` on
  the first line of the next prepends to that one.
- An edit that spans two excerpts, like `J` across a header, does exactly that
  to the sources: the new text goes to the first excerpt and the removed lines
  leave the second.

### Keys in the quilt

All keys are buffer-local and configurable. They follow Neovim's 0.11 LSP
defaults so muscle memory works.

| Key | Action |
| --- | --- |
| `<CR>` | open the source at this line |
| `]]` / `[[` | next / previous excerpt |
| `+` / `-` | grow / shrink context around this excerpt by `context` lines |
| `zd` | drop this excerpt from the quilt, source untouched |
| `K` | hover |
| `gd` | definition. Moves inside the quilt when the target is in it |
| `grn` | rename |
| `gra` | code action |
| `grr` | references, as a new quilt |
| `gri` | implementation, same as `gd` |

### Config

```lua
require("quilt").setup({
  context = 3,         -- lines of context around each hit
  max_excerpts = 200,  -- refuse to build a bigger quilt, with a notice
  keys = { ... },      -- the table above; false disables a key
})
```

`setup` is optional. The commands work without it.

## Architecture

```
lua/quilt/
  model.lua    pure excerpt model, no vim.api
  sources.lua  hits from qf / grep / diagnostics / git, hits -> ranges
  lsp.lua      LSP requests against a source position
  decor.lua    headers, status column, highlight and diagnostic projection
  buffer.lua   the quilt buffer: two-way sync, write, keys
  init.lua     setup, config, commands entry points
plugin/quilt.lua  the :Quilt command
```

Only `buffer.lua` and `init.lua` know about all the other modules.
`model.lua` knows nothing about Neovim. `lsp.lua`, `decor.lua`, and
`sources.lua` know nothing about the quilt buffer's sync.

### Shared types

```lua
---@class quilt.Range       input to model.new
---@field src integer       source bufnr
---@field start integer     first source row
---@field count integer     number of lines, >= 1

---@class quilt.Span        plain snapshot of one excerpt
---@field id integer        stable id, never reused within a model
---@field src integer
---@field src_start integer first source row
---@field q_start integer   first quilt row
---@field count integer     >= 1

---@class quilt.Hit         output of sources
---@field path string?      file path; one of path or bufnr is set
---@field bufnr integer?
---@field row integer       first row of the hit
---@field end_row integer?  exclusive; default row + 1
---@field text string?

---@class quilt.SrcEdit     a change model asks for in a source
---@field src integer
---@field first integer
---@field last integer      exclusive, old rows
---@field lines string[]

---@class quilt.QEdit       a change model asks for in the quilt
---@field first integer
---@field last integer      exclusive, old quilt rows
---@field lines string[]?   literal lines, or
---@field src integer?      read rows [src_first, src_last) from this source
---@field src_first integer?
---@field src_last integer?
```

Edit lists are applied in list order. Each edit's rows are valid after all
edits before it in the list have been applied.

### model.lua

The model is the truth about which source rows each quilt row shows. It never
reads text, except the `lines` it is given.

```lua
local M = require("quilt.model")
local m = M.new(ranges)              -- quilt.Range[] -> model
m:spans()                            -- quilt.Span[] in quilt order
m:line_count()                       -- total quilt rows
m:locate(qrow)                       -- span, src_row  | nil
m:to_quilt(src, src_row)             -- qrow | nil
m:find(id)                           -- span | nil
m:apply_quilt_change(first, last, lines, prefer)  -- -> quilt.SrcEdit[]
m:apply_source_change(src, first, last, lines)    -- -> quilt.QEdit[]
m:expand(id, above, below, src_line_count)        -- -> quilt.QEdit[]
m:shrink(id, above, below)                        -- -> quilt.QEdit[]
m:remove(id)                                      -- -> quilt.QEdit[]
m:clamp(src, src_line_count)                      -- -> quilt.QEdit[]
```

Rules:

- `new` groups ranges by source in order of first appearance, sorts each
  group by row, and merges ranges that overlap or touch. Ranges with a count
  below 1 are dropped.
- Invariants after every call:
  1. Quilt text equals the source rows of each span, concatenated in order.
  2. Every span has `count >= 1`.
  3. Spans of one source are contiguous in the quilt and sorted by row.
  4. Spans of one source never overlap.
- `apply_quilt_change(first, last, lines, prefer)` is called after quilt rows
  `[first, last)` became `lines`.
  - Rows removed from each span leave that span's source.
  - All new lines go to the first span the change touches, at the matching
    source row.
  - A pure insertion (`first == last`) at a boundary goes to the span above
    when `prefer == "above"` and to the span below when `prefer == "below"`.
    At row 0 it goes to the first span, and at the end it goes to the last.
  - Spans left with no lines are removed.
  - Later spans of the same source shift by the change in row count.
- `apply_source_change(src, first, last, lines)` is called after source rows
  `[first, last)` became `lines`.
  - A change above a span shifts it. Insertion at the span's first row counts
    as above. Insertion at the row after its last row is outside.
  - A change that overlaps a span grows that span to cover the changed rows.
  - A change that overlaps several spans of the source merges them into one.
  - A span left with no rows is removed.
  - The returned edits use `lines` when the change is literal and
    `src`/`src_first`/`src_last` when the quilt must read context rows.
- `expand` adds rows from the source, clamped to `[0, src_line_count)`, and
  merges with a neighbouring span of the same source when they meet.
  `shrink` never goes below 1 row. `remove` drops a span. These three only
  change the quilt. The sync layer must not mirror them into the source.
- `clamp` handles a source that was reloaded: spans past the new end shrink or
  go, and every remaining span is reread.

### sources.lua

```lua
local S = require("quilt.sources")
S.from_qf(list?)                -- quilt.Hit[]; default getqflist()
S.from_diagnostics(min_severity?) -- quilt.Hit[]
S.grep(pattern, opts, cb)       -- async; cb(hits | nil, err)
S.git(ref?, opts, cb)           -- async; cb(hits | nil, err)
S.parse_vimgrep(lines)          -- pure, used by grep
S.parse_diff(lines)             -- pure, used by git
S.to_ranges(hits, context)      -- loads buffers -> quilt.Range[]
```

- `to_ranges` resolves `path` to a bufnr with `bufadd` and `bufload`, marks
  buffers it created as unlisted, and pads each hit by `context` rows clamped
  to the file. It returns the bufnrs it created so the quilt can unload them
  later.
- Hits for files that can't be read are dropped with one notice that names
  how many were dropped.
- `parse_diff` returns one hit per hunk in the new file. A pure deletion
  hunk becomes a one-row hit at the row after the deletion, clamped.

### lsp.lua

Every function takes a source position, so it works the same from the quilt
or from a normal buffer.

```lua
---@class quilt.Pos
---@field src integer   source bufnr
---@field row integer
---@field col integer   byte column

local L = require("quilt.lsp")
L.hover(pos)
L.definition(pos, opts)      -- opts.on_location(bufnr, row, col) -> handled?
L.implementation(pos, opts)  -- same shape as definition
L.references(pos, cb)        -- cb(quilt.Hit[] | nil, err)
L.rename(pos, new_name?)     -- prompts with vim.ui.input when nil
L.code_action(pos)           -- vim.ui.select, then apply edit or command
```

- The position goes out in each client's own offset encoding.
- With no client attached to `pos.src` that supports the method, the call
  shows one notice and does nothing.
- `definition` asks `on_location` first. When that returns true, it does
  nothing more. Otherwise it opens the location with
  `vim.lsp.util.show_document`.
- `rename` and `code_action` apply workspace edits to the sources. The quilt
  sees those edits through normal source sync.

### decor.lua

```lua
local D = require("quilt.decor")
D.render(qbuf, spans, opts)   -- headers, highlights, diagnostics; idempotent
D.lnum(qbuf, qrow)            -- string for the status column
D.statuscolumn                -- the 'statuscolumn' expression string
D.setup_highlights()          -- default links for the Quilt* groups
```

- `render` clears its own namespaces and draws again. It keeps the last
  spans per quilt so `lnum` can answer without the model.
- Highlight groups: `QuiltHeader`, `QuiltHeaderPath`, `QuiltHeaderLnum`,
  `QuiltLineNr`. Defaults link to `Title`, `Directory`, `LineNr`, `LineNr`.
- Treesitter projection reads captures from the source's parser for each
  span's rows and sets extmarks with the same `hl_group` and priority on the
  quilt rows. Captures that cross a span edge are clipped.
- Diagnostics come from `vim.diagnostic.get(src)` and go into a quilt
  namespace with rows mapped through the spans. Rows outside every span are
  skipped.

### buffer.lua

The sync layer. It owns the model, the quilt buffer, and all attachments.

```lua
local B = require("quilt.buffer")
B.open(ranges, opts)   -- create and show a quilt; returns qbuf
B.get(qbuf)            -- state | nil
B.resync(qbuf)         -- reread every span from its source
B.write(qbuf)          -- write changed sources
```

How sync works:

1. `nvim_buf_attach` on the quilt. `on_lines` asks the model for source edits
   and queues them. Neovim raises E565 when another buffer is changed inside
   `on_lines`, so the queue is flushed with `vim.schedule`.
2. `nvim_buf_attach` on each source, once per quilt. `on_lines` asks the
   model for quilt edits and queues them the same way.
3. While the flush applies an edit, the matching `on_lines` ignores it. The
   flag is per buffer and is set only around the `nvim_buf_set_lines` call.
4. `prefer` comes from the cursor row before the edit. A `CursorMoved` and
   `CursorMovedI` autocmd records it. When the row is at or after the
   insertion row, the preference is "below".
5. A source change that arrives while quilt edits are still queued would see
   a model ahead of its buffer. In that case the quilt flushes first, then
   rereads every span (`resync`).
6. `on_reload` of a source calls `model:clamp`.
7. When the quilt is wiped, every callback returns true to detach. Buffers
   the quilt loaded are unloaded when they are not modified and not shown.

Writing: `BufWriteCmd` on the quilt runs `:write` in each modified source
with `nvim_buf_call`, then clears the quilt's modified flag.

## Out of scope for v1

- Completion inside the quilt. Use `<CR>` to edit in the source.
- Semantic token projection.
- Multiple cursors across excerpts.
- Saving quilts across sessions.

## Done when

- Every test in TEST_PLAN.md passes on Neovim 0.12.
- The fuzz tests run 2000 random edits per direction with no invariant break.
- A real session works: grep a project, edit three files from one quilt,
  rename a symbol, `:w`, and the files on disk match.
