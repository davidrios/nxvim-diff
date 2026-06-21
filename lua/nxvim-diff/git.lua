-- nxvim-diff.git — build a spec comparing the current file's working tree against its
-- git HEAD (the `:NxDiffGit` backing). Deliberately minimal: HEAD only. Anything
-- fancier (an arbitrary revision, the index, rev..rev) is left to a caller building
-- its own spec and calling `require("nxvim-diff").open(spec)` directly — the Lua API
-- is the extension point, not a pile of command flags.
--
-- This is itself an ordinary client of the public API: it gathers content with the
-- async `nx.run` and returns a spec; init.lua awaits it and calls open().

local M = {}

-- to_lines(s) — split subprocess stdout into a line array, dropping the single
-- trailing empty a final newline produces (so "a\nb\n" → {"a","b"}).
function M.to_lines(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  if #out > 0 and out[#out] == "" then
    out[#out] = nil
  end
  return out
end

-- repo_relative(file, toplevel) — `file` expressed relative to the repo root.
function M.repo_relative(file, toplevel)
  local base = toplevel
  if base:sub(-1) ~= "/" then
    base = base .. "/"
  end
  if file:sub(1, #base) == base then
    return file:sub(#base + 1)
  end
  return file -- best effort; git resolves it against cwd anyway
end

-- head_spec(ctx) — a PROMISE of a spec: the current file at HEAD on the left
-- (read-only), the live working-tree buffer on the right (editable). `ctx` =
-- { file = <abs path>, bufnr = <n>, cwd = <file's dir> } (the shape init.lua builds).
--
-- Failures reject with a bare, position-free message (`error(msg, 0)`): the `:NxDiffGit`
-- path's `run` wrapper adds the single "nxvim-diff: " prefix and notifies, so prefixing
-- here too (or letting Lua tack on a "git.lua:NN:" prefix) would double up.
function M.head_spec(ctx)
  return nx.async(function()
    if ctx.file == nil or ctx.file == "" then
      error("this buffer has no file to diff", 0)
    end

    local top = nx.await(nx.run({
      cmd = "git",
      args = { "rev-parse", "--show-toplevel" },
      cwd = ctx.cwd,
    }))
    if top.code ~= 0 then
      error("not a git repository", 0)
    end
    local toplevel = M.to_lines(top.stdout)[1] or ctx.cwd
    local rel = M.repo_relative(ctx.file, toplevel)

    local show = nx.await(nx.run({
      cmd = "git",
      args = { "show", "HEAD:" .. rel },
      cwd = toplevel,
    }))
    if show.code ~= 0 then
      -- The usual cause is a new / untracked file (no version exists at HEAD); an empty
      -- repo with no commits lands here too. Either way: there's no HEAD side to diff.
      error(("no HEAD version of %s"):format(rel), 0)
    end

    local ft = vim.bo[ctx.bufnr] and vim.bo[ctx.bufnr].filetype or nil
    return {
      title = ("git HEAD — %s"):format(rel),
      panes = {
        { label = "HEAD", lines = M.to_lines(show.stdout), filetype = ft, readonly = true },
        { label = "working tree", buf = ctx.bufnr, filetype = ft, readonly = false },
      },
    }
  end)()
end

return M
