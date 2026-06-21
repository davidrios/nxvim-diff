-- nxvim-diff.conflict — parse git conflict markers out of a file into the two/three
-- sides, and build a diff spec from them (the `:NxDiffConflict` backing).
--
-- Pure (no editor calls), so it is fully unit-tested. It reconstructs each FULL side
-- of the file (not just the conflicting hunks) so the resulting diff shows the
-- conflicts in their surrounding context:
--
--   <<<<<<< ours-label          → ours section
--   ours lines
--   ||||||| base-label          → base section (diff3 style only; optional)
--   base lines
--   =======                     → theirs section
--   theirs lines
--   >>>>>>> theirs-label        → end
--
-- With diff3 markers (merge.conflictStyle=diff3/zdiff3) all three sides exist → a true
-- 3-way diff. With plain merge style there is no base section → a 2-way ours/theirs
-- diff (the caller notifies). A `=======` is only treated as a separator while inside
-- a conflict, so a Markdown setext underline outside one is left alone.

local M = {}

local function strip_label(line, marker_len)
  return (line:sub(marker_len + 1):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- parse(lines) → {
--   has_conflict, diff3, count,
--   ours = {...}, theirs = {...}, base = {...}|nil,   -- full reconstructed sides
--   ours_label, theirs_label,
--   regions = { { first, last, ours, base?, theirs, recon }, ... },
-- }. Raises on an unterminated / malformed marker (fail loud, not silent skip).
--
-- `regions` is the write-back map the `choose_*` resolution actions need: one entry per
-- conflict block, carrying the 1-based line numbers of its `<<<<<<<` (`first`) and
-- `>>>>>>>` (`last`) in `lines`, plus that block's bare section contents (NOT the full
-- reconstructed sides) — so resolving a hunk means "replace lines first..last with the
-- chosen section". (The full `ours`/`base`/`theirs` above stay for the rendered diff.)
--
-- `recon` is each block's *reconstructed*-line span per side: `{ ours = {from,to}, base
-- = {from,to}?, theirs = {from,to} }`, 1-based inclusive indices into the matching full
-- reconstructed side above (an empty section is `from > to`). When all conflicts of a
-- file are shown at once, this is how the view maps each block to the alignment rows it
-- occupies, so the cursor can pick which conflict `choose_*` resolves.
function M.parse(lines)
  local ours, base, theirs = {}, {}, {}
  local mode = "common"
  local diff3, count = false, 0
  local ours_label, theirs_label
  local regions = {}
  local region -- the in-progress region while inside a conflict block

  for i, line in ipairs(lines) do
    local is_start = line:match("^<<<<<<<")
    local is_base = line:match("^|||||||")
    local is_sep = line:match("^=======")
    local is_end = line:match("^>>>>>>>")

    if mode == "common" then
      if is_start then
        mode, count = "ours", count + 1
        ours_label = ours_label or strip_label(line, 7)
        -- `recon.*.from` is the index the section WILL start at in each reconstructed
        -- side (the next append lands there); `.to` is filled in at the end marker.
        region = {
          first = i,
          ours = {},
          base = {},
          theirs = {},
          recon = {
            ours = { from = #ours + 1 },
            base = { from = #base + 1 },
            theirs = { from = #theirs + 1 },
          },
        }
      else
        ours[#ours + 1] = line
        base[#base + 1] = line
        theirs[#theirs + 1] = line
      end
    elseif mode == "ours" then
      if is_base then
        mode, diff3 = "base", true
      elseif is_sep then
        mode = "theirs"
      elseif is_end then
        error("nxvim-diff: malformed conflict (>>>>>>> before =======)")
      else
        ours[#ours + 1] = line
        region.ours[#region.ours + 1] = line
      end
    elseif mode == "base" then
      if is_sep then
        mode = "theirs"
      elseif is_end then
        error("nxvim-diff: malformed conflict (>>>>>>> before =======)")
      else
        base[#base + 1] = line
        region.base[#region.base + 1] = line
      end
    else -- mode == "theirs"
      if is_end then
        mode = "common"
        theirs_label = theirs_label or strip_label(line, 7)
        region.last = i
        -- Close the reconstructed spans (`to` = the last index each section reached;
        -- `from > to` when the section was empty).
        region.recon.ours.to = #ours
        region.recon.base.to = #base
        region.recon.theirs.to = #theirs
        if not diff3 then
          region.base = nil
          region.recon.base = nil
        end
        regions[#regions + 1] = region
        region = nil
      else
        theirs[#theirs + 1] = line
        region.theirs[#region.theirs + 1] = line
      end
    end
  end

  if mode ~= "common" then
    error("nxvim-diff: unterminated conflict marker")
  end

  return {
    has_conflict = count > 0,
    diff3 = diff3,
    count = count,
    ours = ours,
    theirs = theirs,
    base = diff3 and base or nil,
    ours_label = ours_label,
    theirs_label = theirs_label,
    regions = regions,
  }
end

-- spec(lines, name) → a diff spec (3-pane with base when diff3, else 2-pane), or
-- (nil, reason) when the file has no conflict markers.
function M.spec(lines, name)
  local p = M.parse(lines)
  if not p.has_conflict then
    return nil, "no conflict markers found"
  end
  local ours_label = (p.ours_label and p.ours_label ~= "" and p.ours_label) or "ours"
  local theirs_label = (p.theirs_label and p.theirs_label ~= "" and p.theirs_label) or "theirs"
  local panes = {
    { label = ours_label, lines = p.ours, readonly = true },
  }
  if p.base then
    panes[#panes + 1] = { label = "base", lines = p.base, readonly = true }
  end
  panes[#panes + 1] = { label = theirs_label, lines = p.theirs, readonly = true }
  return {
    title = ("conflict — %s%s"):format(name or "", p.base and " (3-way)" or " (2-way)"),
    panes = panes,
    is_conflict = true,
    -- The write-back map for `choose_ours` / `choose_theirs` (Phase 6). `regions` carries
    -- block-relative 1-based line ranges (relative to `lines`); the caller that knows the
    -- live buffer (`init.conflict`) rebases them to absolute buffer lines and sets `buf`.
    resolve = { regions = p.regions, diff3 = p.diff3 },
  }
end

return M
