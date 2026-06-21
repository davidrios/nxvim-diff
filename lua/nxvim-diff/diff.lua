-- nxvim-diff.diff — the pure line-diff engine.
--
-- No editor calls: it takes two arrays of strings and returns an *alignment* — the
-- row-by-row model a side-by-side viewer renders. Being pure, it is fully unit-tested
-- (test/diff_spec.lua) and shared unchanged by every source and by the wasm build.
--
-- The algorithm is a longest-common-subsequence backtrace (O(n*m) time and memory —
-- ample for source files; docs/plans notes the histogram/Myers upgrade for huge
-- inputs). A post-pass pairs an adjacent deletion run + insertion run into `change`
-- rows (Meld/vimdiff style) so a modified line shows old-vs-new on the same row.
--
--   row = { kind = "same"|"add"|"del"|"change", a = <a-index|nil>, b = <b-index|nil> }
--     same   : unchanged line, present in both (a and b set)
--     change : a[a] became b[b] — both set, rendered on one row, spans highlightable
--     del    : a-only line (b is nil → the b pane gets a filler row here)
--     add    : b-only line (a is nil → the a pane gets a filler row here)

local M = {}

-- LCS backtrace → an ordered op list of { op="same"/"del"/"add", a=, b= }.
local function lcs_ops(a, b)
  local n, m = #a, #b
  -- dp[i][j] = LCS length of a[i+1..n] vs b[j+1..m] (0-indexed origins).
  local dp = {}
  for i = 0, n do
    dp[i] = {}
    dp[i][m] = 0
  end
  for j = 0, m do
    dp[n][j] = 0
  end
  for i = n - 1, 0, -1 do
    for j = m - 1, 0, -1 do
      if a[i + 1] == b[j + 1] then
        dp[i][j] = dp[i + 1][j + 1] + 1
      else
        dp[i][j] = math.max(dp[i + 1][j], dp[i][j + 1])
      end
    end
  end

  local ops = {}
  local i, j = 0, 0
  while i < n and j < m do
    if a[i + 1] == b[j + 1] then
      ops[#ops + 1] = { op = "same", a = i + 1, b = j + 1 }
      i, j = i + 1, j + 1
    elseif dp[i + 1][j] >= dp[i][j + 1] then
      ops[#ops + 1] = { op = "del", a = i + 1 }
      i = i + 1
    else
      ops[#ops + 1] = { op = "add", b = j + 1 }
      j = j + 1
    end
  end
  while i < n do
    ops[#ops + 1] = { op = "del", a = i + 1 }
    i = i + 1
  end
  while j < m do
    ops[#ops + 1] = { op = "add", b = j + 1 }
    j = j + 1
  end
  return ops
end

-- Pair an adjacent del-run + add-run into `change` rows; leftovers stay del/add.
local function pair_changes(ops)
  local rows = {}
  local i = 1
  while i <= #ops do
    local op = ops[i]
    if op.op == "same" then
      rows[#rows + 1] = { kind = "same", a = op.a, b = op.b }
      i = i + 1
    elseif op.op == "del" then
      local dels, adds = {}, {}
      while i <= #ops and ops[i].op == "del" do
        dels[#dels + 1] = ops[i]
        i = i + 1
      end
      while i <= #ops and ops[i].op == "add" do
        adds[#adds + 1] = ops[i]
        i = i + 1
      end
      local paired = math.min(#dels, #adds)
      for k = 1, paired do
        rows[#rows + 1] = { kind = "change", a = dels[k].a, b = adds[k].b }
      end
      for k = paired + 1, #dels do
        rows[#rows + 1] = { kind = "del", a = dels[k].a }
      end
      for k = paired + 1, #adds do
        rows[#rows + 1] = { kind = "add", b = adds[k].b }
      end
    else -- an add run with no preceding del
      while i <= #ops and ops[i].op == "add" do
        rows[#rows + 1] = { kind = "add", b = ops[i].b }
        i = i + 1
      end
    end
  end
  return rows
end

-- Contiguous runs of non-`same` rows → { first, last } row-index ranges, for ]c / [c.
local function hunks_of(rows)
  local hunks, start = {}, nil
  for idx, r in ipairs(rows) do
    if r.kind ~= "same" then
      start = start or idx
    elseif start then
      hunks[#hunks + 1] = { first = start, last = idx - 1 }
      start = nil
    end
  end
  if start then
    hunks[#hunks + 1] = { first = start, last = #rows }
  end
  return hunks
end

-- compute(a, b) → { rows = <alignment>, hunks = <ranges> }. `a` / `b` are line arrays.
function M.compute(a, b)
  local rows = pair_changes(lcs_ops(a or {}, b or {}))
  return { rows = rows, hunks = hunks_of(rows) }
end

-- project(rows, side) → the per-pane row list for "a" or "b": one entry per alignment
-- row, either { line = <source index>, kind = } or { filler = true, kind = }. Both
-- panes get the same length, so corresponding lines sit on the same screen row — the
-- fillers are what the view paints as alignment gaps (extmark virt_lines / fillchar).
function M.project(rows, side)
  assert(side == "a" or side == "b", "nxvim-diff.diff.project: side must be 'a' or 'b'")
  local out = {}
  for _, r in ipairs(rows) do
    local idx = r[side]
    out[#out + 1] = idx and { line = idx, kind = r.kind } or { filler = true, kind = r.kind }
  end
  return out
end

-- Split `s` into its UTF-8 characters, returning each char's 0-based byte start (and the
-- line's total byte length). Falls back to one entry per byte for invalid UTF-8 so a
-- binary / mojibake line still diffs (byte-wise) instead of erroring inside `utf8.codes`.
local function char_starts(s)
  local starts = {}
  local ok = pcall(function()
    for p in utf8.codes(s) do
      starts[#starts + 1] = p - 1 -- utf8.codes yields 1-based byte positions
    end
  end)
  if not ok then
    starts = {}
    for p = 0, #s - 1 do
      starts[#starts + 1] = p
    end
  end
  return starts, #s
end

-- The substring of each character (byte end = the next char's start, or the line length),
-- so the LCS compares whole characters rather than bytes (no split multibyte sequences).
local function chars_of(s, starts, total)
  local out = {}
  for i = 1, #starts do
    out[i] = s:sub(starts[i] + 1, (starts[i + 1] or total))
  end
  return out
end

-- Coalesce the set of changed character indices into half-open, 0-based BYTE ranges
-- `{ {from, to}, … }` — adjacent changed characters merge into one span (so a run of
-- edited characters is one DiffText extmark, not one per character).
local function coalesce(changed, starts, total)
  local ranges, i, n = {}, 1, #starts
  while i <= n do
    if changed[i] then
      local from, j = starts[i], i
      while j <= n and changed[j] do
        j = j + 1
      end
      ranges[#ranges + 1] = { from, starts[j] or total }
      i = j
    else
      i = i + 1
    end
  end
  return ranges
end

-- inline(a_line, b_line) → the changed character spans within a `change` row, as
-- { a = {{from,to}...}, b = {{from,to}...} } half-open 0-based BYTE ranges, ready to drop
-- into `DiffText` extmarks (col / end_col). A character-level LCS of the two lines: the
-- characters NOT on the common subsequence are the edits — deletions land on the `a`
-- side, insertions on the `b` side. O(len_a · len_b) per row (lines are short); the
-- caller gates it behind `config.inline`.
function M.inline(a_line, b_line)
  a_line, b_line = a_line or "", b_line or ""
  local sa, la = char_starts(a_line)
  local sb, lb = char_starts(b_line)
  local ops = lcs_ops(chars_of(a_line, sa, la), chars_of(b_line, sb, lb))
  local changed_a, changed_b = {}, {}
  for _, op in ipairs(ops) do
    if op.op == "del" then
      changed_a[op.a] = true
    elseif op.op == "add" then
      changed_b[op.b] = true
    end
  end
  return { a = coalesce(changed_a, sa, la), b = coalesce(changed_b, sb, lb) }
end

return M
