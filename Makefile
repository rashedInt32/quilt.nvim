# Run the test suite: clones mini.nvim (test framework) on first use.
# make test FILE=tests/test_model.lua runs one file.
.PHONY: test lint fmt

deps/mini.nvim:
	mkdir -p deps
	git clone --depth 1 https://github.com/echasnovski/mini.nvim deps/mini.nvim

test: deps/mini.nvim
ifdef FILE
	nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run_file('$(FILE)')"
else
	nvim --headless --noplugin -u tests/minimal_init.lua -c "lua MiniTest.run()"
endif

lint:
	stylua --check .
	luacheck lua plugin tests

fmt:
	stylua .
