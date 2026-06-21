-- ~~~ Runnable demo for nxvim-diff ~~~
--
-- Point nxvim at this folder as its config and open the sample file:
--
--     NXVIM_CONFIG=examples nxvim examples/sample/new.txt
--
-- TRY IT:
--   :NxDiffGit        diff the current file's working tree against git HEAD
--   :NxDiffConflict   if the file has conflict markers, open them as a 3-way diff
--
-- Inside a diff:
--   ]c / [c      next / previous changed hunk     [C / ]C   first / last hunk
--   R            refresh         q   close
-- The panes scroll and move their cursor in lockstep, and a changed line shows the
-- edited characters highlighted (DiffText).
--
-- Anything BEYOND those two commands is the Lua API — build a spec and call open().
-- The custom `<leader>du` mapping below diffs the current buffer against an
-- UPPERCASED copy of itself: that's the whole extension surface a git/LSP/formatter
-- plugin would use to "send a diff for preview".

vim.g.mapleader = " "

-- Load the plugin straight from this repo (a local-dev spec: `dir` is never cloned).
-- A real config would instead use `{ "davidrios/nxvim-diff", config = ... }`.
nx.plugins({
  {
    name = "nxvim-diff",
    dir = vim.fn.expand("<sfile>:p:h:h"), -- the repo root (this file's grandparent dir)
    config = function()
      require("nxvim-diff").setup({
        sync_scroll = true,
        inline = true,
      })
    end,
  },
})

-- Extensibility demo (Lua API only — no command needed): feed the viewer any diff.
vim.keymap.set("n", "<leader>du", function()
  local diff = require("nxvim-diff")
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local upper = {}
  for i, l in ipairs(lines) do
    upper[i] = l:upper()
  end
  diff.open({
    title = "caps demo",
    panes = {
      { label = "original", lines = lines, readonly = true },
      { label = "UPPER", lines = upper, readonly = true },
    },
  })
end, { desc = "nxvim-diff: diff this buffer against an uppercased copy" })
