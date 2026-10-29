# quilt.nvim

Edit many files from one buffer.

I search, find references, or open diagnostics, and Neovim gives me a quickfix
list: one line per hit, no context, and a jump to another file for every
change. quilt puts every hit in one buffer with real code around it. I edit
the excerpts in place, and `:w` saves every file I touched.

The idea is Zed's multibuffer. The name comes from a comment by justinmk on
[neovim#30463](https://github.com/neovim/neovim/issues/30463), where many
buffers get stitched together into one "quilt".

## What it does

- Builds a quilt from the quickfix list, LSP references, `rg`, diagnostics,
  or `git diff` hunks.
- Every excerpt has a header with its path and line, real line numbers in the
  status column, the source's treesitter colours, and its diagnostics.
- Any edit goes straight to the source buffer: typing, `:s`, macros, `J`,
  undo. Changes in the sources from other windows, formatters, or an LSP
  rename show up in the quilt.
- `:w` writes every changed file with its normal autocmds, so format-on-save
  still runs.
- LSP works inside the quilt: hover, definition, rename, code actions,
  references.

## Install

Neovim 0.11 or newer. `rg` for grep, `git` for hunks. No other plugin.

```lua
-- lazy.nvim
{ "rashedInt32/quilt.nvim", cmd = "Quilt", opts = {} }

-- vim.pack (0.12)
vim.pack.add({ "https://github.com/rashedInt32/quilt.nvim" })
```

## Commands

| Command | Quilt of |
| --- | --- |
| `:Quilt` | the quickfix list |
| `:Quilt refs` | LSP references under the cursor |
| `:Quilt grep {pattern}` | `rg` matches in the cwd |
| `:Quilt diagnostics [error\|warn\|info\|hint]` | diagnostics at or above a severity |
| `:Quilt git [ref]` | changed hunks, unstaged by default |
| `:Quilt refresh` | reread every excerpt from its file |

## Keys in a quilt

| Key | Action |
| --- | --- |
| `<CR>` | open the file at this line |
| `]]` / `[[` | next / previous excerpt |
| `+` / `-` | more / less context |
| `zd` | drop this excerpt from the quilt |
| `K` | hover |
| `gd` / `gri` | definition / implementation, inside the quilt when it's there |
| `grn` | rename |
| `gra` | code action |
| `grr` | references, as a new quilt |

## Config

`setup` is optional. These are the defaults.

```lua
require("quilt").setup({
  context = 3,
  max_excerpts = 200,
  keys = {
    open = "<CR>", next = "]]", prev = "[[",
    expand = "+", shrink = "-", drop = "zd",
    hover = "K", definition = "gd", implementation = "gri",
    rename = "grn", code_action = "gra", references = "grr",
  },
})
```

Set a key to `false` to turn it off.

## Edits at excerpt edges

A new line between two excerpts goes to the excerpt the cursor was in. `o` on
the last line of one excerpt adds to that file. `O` on the first line of the
next adds to that one. Deleting every line of an excerpt deletes them from the
file and removes the excerpt.

## Not yet

- Completion inside the quilt. `<CR>` to the file for that.
- Semantic token colours.

## Tests

```sh
make test
make test FILE=tests/test_model_fuzz.lua QUILT_SEED=42
```

SPEC.md is the contract and TEST_PLAN.md lists every case.
