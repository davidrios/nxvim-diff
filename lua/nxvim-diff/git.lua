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

-- repo_relative(file, toplevel) — `file` expressed relative to the repo root, by simple
-- prefix strip. A standalone helper for a caller building its own spec; `head_spec` no
-- longer uses it (it asks git for the path via `--show-prefix`, which is symlink-safe —
-- a plain string strip breaks when `toplevel` is a resolved path and `file` is not).
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

    -- The file's path RELATIVE TO THE REPO ROOT, the form `git show HEAD:<rel>` wants.
    -- `--show-prefix` (run in the file's dir) is the repo-root→cwd path as git itself
    -- resolves it, so prefixing the file's basename onto it sidesteps any string math
    -- against an absolute path — and crucially survives a symlinked dir (e.g. macOS's
    -- /var → /private/var, where `--show-toplevel` returns the real path while ctx.file
    -- keeps the symlink, so a prefix-strip would fail and leave an absolute, unusable
    -- `HEAD:/abs/path`). Empty prefix ⇒ the file sits at the repo root.
    local pre = nx.await(nx.run({
      cmd = "git",
      args = { "rev-parse", "--show-prefix" },
      cwd = ctx.cwd,
    }))
    if pre.code ~= 0 then
      error("not a git repository", 0)
    end
    local prefix = M.to_lines(pre.stdout)[1] or ""
    local rel = prefix .. (ctx.file:match("[^/]+$") or ctx.file)

    local show = nx.await(nx.run({
      cmd = "git",
      args = { "show", "HEAD:" .. rel },
      cwd = ctx.cwd,
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
