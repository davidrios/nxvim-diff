-- nxvim-diff.config — the default configuration and the merge used by setup().
--
-- Pure data + validation, no editor calls (mirrors nxvim-tree.config), so it is
-- trivially testable and the same table drives both the live plugin and the tests.
-- `defaults()` hands out a fresh deep copy each call; `merge(into, opts)` deep-merges
-- a user table over it and validates the closed-domain values, failing loud on a typo
-- (the project's no-silent-stubs rule) rather than mis-configuring silently.

local M = {}

-- The mappable navigation actions (the diff panes' buffer-local keymap). A `keymaps`
-- value must be one of these names, a function (a custom action `fn(session, api)`),
-- or `false` (disable the key). Kept here so `merge` can reject an unknown name up
-- front. The set grows as phases land (a 3-way merge adds `choose_*`); see docs/plans.
M.ACTIONS = {
  next_hunk = true, -- jump the cursor to the next changed hunk (and sync panes)
  prev_hunk = true, -- jump to the previous changed hunk
  first_hunk = true, -- jump to the first hunk
  last_hunk = true, -- jump to the last hunk
  refresh = true, -- re-run the source and re-render
  close = true, -- close the diff session, restoring the prior layout
  -- Conflict resolution (`:NxDiffConflict` sessions only): write the chosen side back
  -- into the live buffer, replacing the marker block, then close the diff. On a plain
  -- diff these just notify "nothing to resolve".
  choose_ours = true,
  choose_theirs = true,
}

-- The built-in default key bindings (normal mode, buffer-local on every diff pane).
-- `]c` / `[c` match vim's diff-mode hunk motions on purpose (muscle memory).
local DEFAULT_KEYMAPS = {
  ["]c"] = "next_hunk",
  ["[c"] = "prev_hunk",
  ["[C"] = "first_hunk",
  ["]C"] = "last_hunk",
  -- `co` / `ct` resolve a conflict to ours / theirs (no-ops with a notice on a plain
  -- diff). The panes are read-only, so the `c` change operator is inert there anyway.
  co = "choose_ours",
  ct = "choose_theirs",
  R = "refresh",
  q = "close",
}

-- The default configuration. `defaults()` hands out a deep copy.
local DEFAULTS = {
  sync_scroll = true, -- keep the panes' viewports locked together (uses WinScrolled)
  sync_cursor = true, -- keep the panes' cursor row aligned
  wrap = false, -- soft-wrap inside the panes (off → columns line up, leftcol syncs)
  inline = true, -- highlight the changed spans within a changed line (DiffText)
  -- Per-hunk gutter signs (`+` add / `~` change / `-` del), via the core `sign_text`
  -- extmark decoration. Opt-in (the tint + DiffText already convey a change); when on,
  -- every pane reserves the sign column so they stay aligned.
  signs = false,
  -- The glyph drawn across a blank filler (alignment) row, vim's diff `fillchars` style,
  -- via the core `line_fill` extmark decoration. "" leaves the row blank.
  fillchar = "-",
  layout = "auto", -- "auto" (by pane count), "vertical" (side-by-side), or "horizontal"
  keymaps = DEFAULT_KEYMAPS,
  highlights = {}, -- highlight-group overrides, keyed by group name (see highlights.lua)
  on_attach = nil, -- fn(session, api, bufnr): run once per pane buffer (custom maps)
}

local LAYOUTS = { auto = true, vertical = true, horizontal = true }

-- Deep-copy a plain data table (config is data, never functions-in-arrays).
local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, val in pairs(v) do
    out[k] = copy(val)
  end
  return out
end
M.copy = copy

-- defaults() — a fresh, independent copy of the default config.
function M.defaults()
  return copy(DEFAULTS)
end

-- validate(cfg) — fail loud on an out-of-domain value (raises at level 3 → setup()'s
-- caller). Called by merge after the merge, so it sees the effective config.
local function validate(cfg)
  if not LAYOUTS[cfg.layout] then
    error("nxvim-diff: layout must be 'auto', 'vertical', or 'horizontal'", 3)
  end
  for _, key in ipairs({ "sync_scroll", "sync_cursor", "wrap", "inline", "signs" }) do
    if type(cfg[key]) ~= "boolean" then
      error(("nxvim-diff: %s must be a boolean"):format(key), 3)
    end
  end
  if type(cfg.fillchar) ~= "string" then
    error("nxvim-diff: fillchar must be a string", 3)
  end
  for key, action in pairs(cfg.keymaps) do
    if action ~= false and type(action) ~= "function" and not M.ACTIONS[action] then
      error(
        ("nxvim-diff: keymap %q → unknown action %q (see config.ACTIONS)"):format(
          tostring(key),
          tostring(action)
        ),
        3
      )
    end
  end
end

-- merge(into, opts) — deep-merge `opts` over `into` (mutating and returning it), then
-- validate. `keymaps` / `highlights` merge key-by-key (so a user adds/overrides
-- individual entries without redeclaring the whole table); other keys overwrite.
-- Unknown top-level keys are kept (forward-compat for add-ons stashing namespaced
-- config).
function M.merge(into, opts)
  opts = opts or {}
  if type(opts) ~= "table" then
    error("nxvim-diff.setup: opts must be a table", 3)
  end
  for k, v in pairs(opts) do
    if (k == "keymaps" or k == "highlights") and type(v) == "table" then
      into[k] = into[k] or {}
      for kk, vv in pairs(v) do
        into[k][kk] = vv
      end
    else
      into[k] = v
    end
  end
  validate(into)
  return into
end

return M
