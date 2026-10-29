# quilt.nvim test plan

Tests use mini.test, headless. `make test` runs everything. `make test
FILE=tests/test_model.lua` runs one file. Every case below must exist as a
named test. A case may be split into several tests.

The goal is proof, not coverage numbers. Each module is tested at its own
seam, and the risky parts get randomised tests with an independent oracle.

## Levels

1. **Pure unit**: `model`, `sources.parse_*`. No buffers. Fast, many cases.
2. **Fuzz**: `model` against a simple simulator. Seeded, reproducible, and
   the seed is printed on failure.
3. **Module with real buffers**: `sources.to_ranges`, `decor`, `lsp`. Real
   buffers in the test process, a fake in-process LSP server, real
   treesitter (the `lua` parser ships with Neovim).
4. **End to end**: a child Neovim (`MiniTest.new_child_neovim`) with the
   plugin on the runtimepath, real keys sent with `child.type_keys`, real
   files in a temp dir, screenshots for the headers.

## 1. model (tests/test_model.lua)

new:
- [ ] groups by source in first-seen order, sorts rows within a source
- [ ] merges overlapping ranges and touching ranges
- [ ] drops ranges with count < 1
- [ ] spans have stable unique ids and correct q_start

queries:
- [ ] locate maps every quilt row and returns nil past the end
- [ ] to_quilt maps rows inside spans and returns nil outside

apply_quilt_change:
- [ ] edit inside one span changes only that source row
- [ ] insert in the middle of a span shifts later spans of the same source
- [ ] boundary insert with prefer "above" appends to the span above
- [ ] boundary insert with prefer "below" prepends to the span below
- [ ] insert at row 0 and at the end
- [ ] delete all lines of a span removes it and deletes its source rows
- [ ] change spanning two spans of different sources (the `J` case)
- [ ] change spanning two spans of the same source
- [ ] delete the whole quilt
- [ ] returned SrcEdits are valid when applied in order

apply_source_change:
- [ ] change above a span shifts it, change below leaves it
- [ ] insert at a span's first row shifts it, insert after its last row is outside
- [ ] change inside a span edits the quilt with literal lines
- [ ] change overlapping a span's top edge grows the span upward
- [ ] change overlapping a span's bottom edge grows it downward
- [ ] change covering two spans merges them, gap rows come from the change
- [ ] delete covering a whole span removes it
- [ ] change in a source not in the quilt returns no edits

expand / shrink / remove / clamp:
- [ ] expand clamps to 0 and to the source length
- [ ] expand into a neighbour merges the two spans
- [ ] shrink stops at one row
- [ ] remove drops the span and its quilt rows only
- [ ] clamp after the source got shorter

## 2. model fuzz (tests/test_model_fuzz.lua)

The simulator holds sources as plain string arrays and the quilt as a plain
array. The oracle is invariant 1 from SPEC: the quilt equals the
concatenated source rows of each span. Invariants 2 to 4 are checked too.

- [ ] 2000 random quilt edits: random first/last/lines, random prefer.
      Apply to the quilt array, route through the model, apply the SrcEdits
      to the source arrays, check every invariant.
- [ ] 2000 random source edits, same check in the other direction.
- [ ] 2000 mixed steps: quilt edits, source edits, expand, shrink, remove.
- [ ] Sources of 1 to 40 lines, 1 to 4 sources, 1 to 6 starting ranges,
      edits of 0 to 4 lines including empty strings.
- [ ] Seed from `QUILT_SEED` when set, printed with the first failing step.

## 3. sources (tests/test_sources.lua)

- [ ] parse_vimgrep: paths with colons in the text, Windows-free paths,
      blank lines ignored
- [ ] parse_diff: add, change, pure delete, multiple files, `/dev/null` new
      file, deleted file skipped, rename
- [ ] from_qf: items with bufnr, items with only filename, invalid items skipped
- [ ] from_diagnostics: severity filter
- [ ] to_ranges: context clamps at file start and end, unlisted for new
      buffers, unreadable path dropped with one notice
- [ ] grep: runs rg in a temp dir and returns hits (skipped when rg is missing)
- [ ] git: runs in a temp repo with one changed file (skipped without git)

## 4. lsp (tests/test_lsp.lua)

A fake server started with `vim.lsp.start({ cmd = function(dispatchers) ... })`
lives in `tests/helpers/fake_lsp.lua`. It records requests and answers from a
table the test sets.

- [ ] position goes out in utf-16 and in utf-8 for a line with multibyte text
- [ ] hover opens a float with the markdown content
- [ ] definition calls on_location first and stops when it returns true
- [ ] definition falls back to show_document when on_location returns false
- [ ] references returns hits with rows and paths
- [ ] rename applies the workspace edit to the source buffer
- [ ] code_action applies an edit chosen through vim.ui.select (stubbed)
- [ ] no client: one notice, no error

## 5. decor (tests/test_decor.lua)

- [ ] headers: one virt_lines block above each span's first row, path is
      relative to cwd, first one has no blank spacer
- [ ] render twice leaves one set of extmarks
- [ ] lnum returns the source line number, 1-based, for every row
- [ ] lua source: projected highlight extmarks on the right quilt rows and cols
- [ ] capture crossing a span edge is clipped
- [ ] source with no parser: no error, no highlights
- [ ] diagnostics inside spans show on mapped rows, outside are skipped

## 6. end to end (tests/test_e2e.lua)

Each test writes real files to a temp dir, opens a quilt in a child Neovim,
and drives it with keys.

- [ ] `:Quilt` from a quickfix list shows the right lines and headers (screenshot)
- [ ] typing in an excerpt changes the source buffer, not the file
- [ ] `o` on the last row of an excerpt appends to that source
- [ ] `O` on the first row of the next excerpt prepends to that source
- [ ] `p` and `P` at a boundary follow the same rule
- [ ] `dd` on the only row of an excerpt deletes the source row and the excerpt
- [ ] `J` across two excerpts
- [ ] `:%s/foo/bar/g` changes every excerpt
- [ ] a macro over several excerpts
- [ ] `u` and `<C-r>` flow to the sources
- [ ] editing a source in another window updates the quilt
- [ ] a source change that touches an excerpt edge grows the excerpt
- [ ] `:w` writes every changed file to disk and clears modified
- [ ] format-on-save style BufWritePre on a source flows back into the quilt
- [ ] `+` / `-` / `zd` change the quilt and never the source
- [ ] `]]` / `[[` move between excerpts
- [ ] `<CR>` opens the source at the right line
- [ ] `:e!` on a source after an outside change on disk (clamp + reread)
- [ ] rename through the fake LSP updates the source and the quilt
- [ ] wiping the quilt detaches and unloads buffers it loaded
- [ ] after every e2e test, the quilt equals the source rows of each span
      (the same oracle as the fuzz test, read from real buffers)

## 7. review gates

- [ ] `make lint` clean (stylua, luacheck)
- [ ] a fresh-context code review of the full diff, findings fixed or answered
- [ ] an adversarial pass that tries to break sync with key sequences not in
      this plan; every break becomes a new e2e test before it is fixed
- [ ] a manual session in a real project, steps in SPEC "Done when"
