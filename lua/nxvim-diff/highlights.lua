-- nxvim-diff.highlights — the diff palette and a fallback-only applier.
--
-- The line groups use the canonical **Diff\*** names vim/neovim diff mode uses
-- (`DiffAdd` / `DiffDelete` / `DiffChange` / `DiffText`), on purpose: a ported
-- colorscheme that styles those names themes the viewer UNMODIFIED. We only install
-- a default when the group isn't already defined (and an explicit user override always
-- wins), so a colorscheme that styles `Diff*` keeps its colors regardless of load
-- order. The plugin-private extras (the sign glyphs' colors, the filler tint) live
-- under the `NxDiff*` namespace.
--
-- Fallback colors are Catppuccin-Mocha values so a bare setup() reads well on a dark
-- background with no theme. Unlike a foreground-only palette these DO carry `bg` — a
-- diff wants the whole changed line tinted — kept dim so text stays legible.

local M = {}

-- name -> default spec (the `nx.hl.define` opts table).
M.defaults = {
  -- canonical Diff* (themed by a ported colorscheme)
  DiffAdd = { bg = "#1e3b2f" }, -- an added line (the b-only / insertion rows)
  DiffDelete = { bg = "#3b1f28" }, -- a deleted line (the a-only / deletion rows)
  DiffChange = { bg = "#1e2f3b" }, -- a changed line's unchanged background
  DiffText = { bg = "#28506e", bold = true }, -- the changed spans within a DiffChange line
  -- plugin-private extras
  NxDiffFiller = { fg = "#45475a" }, -- the alignment filler rows (fillchar gutter)
  NxDiffSignAdd = { fg = "#a6e3a1" }, -- the "+" hunk sign
  NxDiffSignChange = { fg = "#f9e2af" }, -- the "~" hunk sign
  NxDiffSignDelete = { fg = "#f38ba8" }, -- the "-" hunk sign
  NxDiffLabel = { fg = "#b4befe", bold = true }, -- a pane's header label (winbar/title)
}

-- apply(overrides) — define each group as a fallback (see the module header). An
-- entry in `overrides` is applied unconditionally; an unrecognized override name is
-- still honored (a caller may color an extra group). Idempotent.
function M.apply(overrides)
  overrides = overrides or {}
  for name, spec in pairs(M.defaults) do
    if overrides[name] then
      nx.hl.define(0, name, overrides[name])
    elseif not nx.hl.exists(name) then
      nx.hl.define(0, name, spec)
    end
  end
  for name, spec in pairs(overrides) do
    if not M.defaults[name] then
      nx.hl.define(0, name, spec)
    end
  end
end

-- hl_for(kind) — the line highlight group for an alignment row kind, or nil for an
-- unchanged / filler row that needs none.
function M.hl_for(kind)
  if kind == "add" then
    return "DiffAdd"
  elseif kind == "del" then
    return "DiffDelete"
  elseif kind == "change" then
    return "DiffChange"
  end
  return nil
end

return M
