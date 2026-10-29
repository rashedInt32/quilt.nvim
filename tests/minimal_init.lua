-- Minimal init for the test suite (mini.test). Also used by child Neovims.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(root .. "/deps/mini.nvim")
vim.o.swapfile = false

require("mini.test").setup()
