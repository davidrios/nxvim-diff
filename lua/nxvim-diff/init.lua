-- nxvim-diff — a Meld-style side-by-side (and 3-way) diff viewer for nxvim, built on
-- the native `nx.*` plugin API (ADR 0002): no buffer-mutation hacks. The "old" side
-- is a read-only `nx.view`; alignment fillers, line tints, and intra-line spans are
-- extmarks; the panes stay locked together via the `WinScrolled` event plus
-- `nx.win.set_topline` / `set_leftcol` / `set_cursor` (the editor's scrollbind seam).
--
-- THE BIG IDEA — it's a *renderer* you feed a diff to, not a git tool. The public Lua
-- entry point is:
--
--   require("nxvim-diff").open({ panes = { {label=,lines=}, {label=,buf=} } })
--
-- Any plugin (a git integration, an LSP-rename preview, a formatter preview) builds a
-- spec and calls open() to show it. ONLY TWO things are exposed as :commands, because
-- everything else is better expressed in Lua than as command flags:
--
--   :NxDiffGit        diff the current file's working tree against git HEAD
--   :NxDiffConflict   if the current file has conflict markers, open them as a 3-way
--
-- Both are thin wrappers over the Lua API (git.head_spec → open, conflict.spec →
-- open), so the bundled git/conflict support is itself just a client of open().
--
-- Module map (one concern each):
--   config.lua      defaults + validated merge
--   diff.lua        the pure LCS line-diff engine (alignment + hunks + projection)
--   conflict.lua    pure conflict-marker parser → sides → spec (:NxDiffConflict)
--   git.lua         build a working-tree-vs-HEAD spec via nx.run (:NxDiffGit)
--   highlights.lua  the Diff* palette (fallback-applied)
--   view.lua        spec → panes: create views, lay out the split, paint fillers/tints
--   nav.lua         hunk navigation (]c / [c) + scroll / cursor sync
--   keymap.lua      install the configured bindings on each pane buffer

local config = require("nxvim-diff.config")
local highlights = require("nxvim-diff.highlights")

local M = {}

-- The effective configuration (rebuilt from defaults on every setup()).
M.config = config.defaults()

local session = nil -- the active diff session (one at a time), owned by view.lua
local hl_applied = false

-- Run an async body, surfacing any rejection as a notification rather than an
-- unhandled promise error (the git source / view content reads nx.await promises).
local function run(body)
  nx.async(body)():catch(function(e)
    local msg = type(e) == "table" and e.message or e
    nx.notify("nxvim-diff: " .. tostring(msg), 4)
  end)
end
M._run = run

-- ===== public Lua API =======================================================

-- validate_spec(spec) — fail loud on a malformed spec and return it. Pure (no editor
-- calls). A spec is:
--   { title = <string?>, panes = { <pane>, <pane> [, <pane>] } }
-- and each pane carries EXACTLY ONE content source:
--   { lines = {<string>...} | buf = <bufnr> | path = <abs path>,
--     label = <string?>, filetype = <string?>, readonly = <bool, default true> }
function M.validate_spec(spec)
  if type(spec) ~= "table" then
    error("nxvim-diff: a diff spec must be a table", 2)
  end
  local panes = spec.panes
  if type(panes) ~= "table" or (#panes ~= 2 and #panes ~= 3) then
    error("nxvim-diff: spec.panes must hold 2 or 3 panes", 2)
  end
  for idx, pane in ipairs(panes) do
    if type(pane) ~= "table" then
      error(("nxvim-diff: pane %d must be a table"):format(idx), 2)
    end
    local sources = 0
    for _, key in ipairs({ "lines", "buf", "path" }) do
      if pane[key] ~= nil then
        sources = sources + 1
      end
    end
    if sources ~= 1 then
      error(
        ("nxvim-diff: pane %d needs exactly one of lines / buf / path (got %d)"):format(
          idx,
          sources
        ),
        2
      )
    end
    if pane.lines ~= nil and type(pane.lines) ~= "table" then
      error(("nxvim-diff: pane %d .lines must be an array of strings"):format(idx), 2)
    end
  end
  return spec
end

-- open(spec) — THE generic entry point. Validate the spec, close any live session,
-- and render it. This is how any plugin "sends a diff for preview". Content for
-- `buf`/`path` panes may be read async, so rendering happens over the next ticks; a
-- render error surfaces via the async wrapper as a notification.
function M.open(spec)
  M.validate_spec(spec)
  M.ensure_highlights()
  M.close()
  run(function()
    session = require("nxvim-diff.view").open(M, spec)
  end)
end

-- git_head() — open the current file's working tree vs git HEAD. Backs :NxDiffGit, and
-- callable from Lua. Builds the ctx the git module expects, awaits its spec, opens.
--
-- `cwd` is the FILE's directory, not the editor's working directory: git must run inside
-- the repo the file actually lives in (you may be editing a file outside `:pwd`).
-- `expand("%:p")` is "" for a buffer with no file, which head_spec rejects loudly.
function M.git_head()
  local file = vim.fn.expand("%:p")
  local ctx = {
    file = file,
    bufnr = vim.api.nvim_get_current_buf(),
    cwd = (file ~= "" and vim.fn.fnamemodify(file, ":h")) or vim.fn.getcwd(),
  }
  run(function()
    M.open(nx.await(require("nxvim-diff.git").head_spec(ctx)))
  end)
end

-- conflict() — if the current buffer has git conflict markers, open the WHOLE file as a
-- 3-way (diff3 style) or 2-way (plain merge style) diff, with every conflict shown in
-- context. Backs :NxDiffConflict. A clean file just notifies.
--
-- A cheap `nx.buf.search` for the start marker answers "is there a conflict?" before the
-- whole buffer is read (a clean file pays nothing). The whole buffer is then parsed: the
-- reconstructed sides carry all conflicts AND their surrounding context, so the diff is a
-- full-file 3-way you can navigate; `spec.resolve.regions` (already in absolute buffer
-- lines — the parse ran over the whole buffer) is what `choose_*` resolves the conflict
-- under the cursor from. A malformed / unterminated marker makes `conflict.spec` raise;
-- it is caught and surfaced as a clean notification.
function M.conflict()
  local conflict = require("nxvim-diff.conflict")
  if not nx.buf.search(0, "^<<<<<<<", { engine = "vim" }) then
    nx.notify("nxvim-diff: no conflict markers found")
    return
  end
  -- Stamp the conflicted buffer's own filetype on every reconstructed pane so each side
  -- gets the same syntax highlighting as the original file (mirrors git.head_spec).
  local ft = vim.bo[0] and vim.bo[0].filetype or nil
  local ok, spec, reason = pcall(conflict.spec, nx.buf.lines(0, 0, -1), vim.fn.expand("%:t"), ft)
  if not ok then
    -- `spec` holds the raise (an unterminated / malformed marker); strip any position
    -- prefix so the notice reads cleanly.
    nx.notify("nxvim-diff: " .. tostring(spec):gsub("^.-nxvim%-diff: ", ""), 4)
    return
  end
  if not spec then
    nx.notify("nxvim-diff: " .. reason)
    return
  end
  -- Wire the write-back target so `choose_ours` / `choose_theirs` can replace the
  -- conflict under the cursor in the live buffer. The region line ranges are already
  -- absolute (the parse ran over the whole buffer), so only the buffer needs recording.
  if spec.resolve then
    spec.resolve.buf = vim.api.nvim_get_current_buf()
  end
  M.open(spec)
end

-- ===== lifecycle ============================================================

-- close() — tear down the active session (restore the prior layout), if any.
function M.close()
  if session then
    require("nxvim-diff.view").close(session)
    session = nil
  end
end

-- refresh() — re-run the session's originating source and re-render in place.
function M.refresh()
  if session and session.reopen then
    session.reopen()
  end
end

-- session() — the live session handle (or nil), for add-ons and tests.
function M.session()
  return session
end

-- ensure_highlights() — apply the Diff* palette once (and after a setup() reconfigure).
function M.ensure_highlights()
  if not hl_applied then
    highlights.apply(M.config.highlights)
    hl_applied = true
  end
end

-- ===== setup ================================================================

-- setup(opts) — merge config, apply highlights, and register the two commands.
-- Re-runnable (a full reconfigure from defaults). See config.lua for the options.
function M.setup(opts)
  M.config = config.merge(config.defaults(), opts)
  hl_applied = false
  M.ensure_highlights()
  if session then
    session.config = M.config
  end

  nx.command("NxDiffGit", function()
    M.git_head()
  end, { desc = "Diff the current file's working tree against git HEAD" })

  nx.command("NxDiffConflict", function()
    M.conflict()
  end, { desc = "Open the current file's git conflict markers as a 3-way diff" })

  return M
end

return M
