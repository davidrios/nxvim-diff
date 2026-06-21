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

-- The LCS DP table is O(n·m) in memory, so a huge, highly-divergent diff could allocate
-- enough cells to freeze the editor. Two guards keep `compute` bounded:
--
--   1. PREFIX/SUFFIX TRIM — the shared leading/trailing lines (the overwhelmingly common
--      case: a few edits inside an otherwise-identical file) are peeled off as `same`
--      rows and only the differing MIDDLE runs the LCS. Normal edits shrink to a tiny
--      middle and get the exact, minimal alignment.
--   2. CELL CAP — if the trimmed middle is still larger than `LCS_CELL_LIMIT` cells, the
--      middle falls back to a coarse block-replace (every old line a `del`, every new
--      line an `add` → pair_changes turns the overlap into `change` rows). Still correct
--      — every line is shown — just not the minimal-edit alignment. O(n+m), never
--      allocates the big table. (Exposed on M so a test can lower it.)
--
-- Trimming doesn't change the result for normal inputs: the peeled lines are equal, so
-- the LCS would have matched them as `same` anyway.
M.LCS_CELL_LIMIT = 1000000

-- Count of shared leading lines of `a` and `b`.
local function common_prefix(a, b)
  local i, lim = 0, math.min(#a, #b)
  while i < lim and a[i + 1] == b[i + 1] do
    i = i + 1
  end
  return i
end

-- Count of shared trailing lines of `a` / `b` that don't overlap the `prefix` already
-- claimed (so a fully-identical file isn't counted twice).
local function common_suffix(a, b, prefix)
  local n, m = #a, #b
  local s, lim = 0, math.min(n, m) - prefix
  while s < lim and a[n - s] == b[m - s] do
    s = s + 1
  end
  return s
end

-- compute(a, b) → { rows = <alignment>, hunks = <ranges> }. `a` / `b` are line arrays.
-- Prefix/suffix-trimmed with a cell cap (see LCS_CELL_LIMIT) so it stays bounded on big,
-- divergent inputs; the result is the same as a plain LCS for ordinary edits.
function M.compute(a, b)
  a, b = a or {}, b or {}
  local n, m = #a, #b
  local p = common_prefix(a, b)
  local s = common_suffix(a, b, p)

  -- The differing middle: a[p+1 .. n-s] vs b[p+1 .. m-s].
  local mid_a, mid_b = {}, {}
  for i = p + 1, n - s do
    mid_a[#mid_a + 1] = a[i]
  end
  for j = p + 1, m - s do
    mid_b[#mid_b + 1] = b[j]
  end

  local mid_ops
  if #mid_a * #mid_b > M.LCS_CELL_LIMIT then
    mid_ops = {} -- coarse block-replace: del every old line, add every new line
    for i = 1, #mid_a do
      mid_ops[#mid_ops + 1] = { op = "del", a = i }
    end
    for j = 1, #mid_b do
      mid_ops[#mid_ops + 1] = { op = "add", b = j }
    end
  else
    mid_ops = lcs_ops(mid_a, mid_b)
  end

  -- Reassemble full ops, rebasing the middle's indices past the prefix.
  local ops = {}
  for i = 1, p do
    ops[#ops + 1] = { op = "same", a = i, b = i }
  end
  for _, o in ipairs(mid_ops) do
    ops[#ops + 1] = { op = o.op, a = o.a and o.a + p or nil, b = o.b and o.b + p or nil }
  end
  for k = 1, s do
    ops[#ops + 1] = { op = "same", a = n - s + k, b = m - s + k }
  end

  local rows = pair_changes(ops)
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

-- ===== 3-way (diff3) alignment ==============================================
--
-- A center-anchored alignment of three sides around a common `base` (Meld / vimdiff3
-- style): the middle pane is the base, the outer two (`ours`, `theirs`) are each
-- compared against it. Built from two ordinary 2-way diffs that share the base axis —
-- `compute(base, ours)` and `compute(base, theirs)` — merged on base line number so a
-- base line and the two sides' versions of it sit on one screen row.
--
--   row = {
--     kind = "same"|"change",          -- "same" iff neither side touched this row
--     base = <base index|nil>,         -- nil on a side-insertion row
--     cells = {                         -- one per pane role; line=nil ⇒ filler
--       ours   = { line = <idx|nil>, kind = "same"|"add"|"change"|nil },
--       base   = { line = <idx|nil>, kind = "change"|nil },
--       theirs = { line = <idx|nil>, kind = "same"|"add"|"change"|nil },
--     },
--   }
--
-- `project3(rows, role)` turns it into the same per-pane entry shape `project` yields
-- (`{ line=, kind= }` / `{ filler=true, kind= }`), so the view layer paints 2- and
-- 3-way diffs through one code path.

local ROLES = { ours = true, base = true, theirs = true }

local FILLER = { line = nil, kind = nil }

-- Index one pairwise `compute(base, side).rows` by base line: `at[bi]` is the row that
-- references base line `bi` (a same/change/del row — every base line has exactly one),
-- and `ins[bi]` is the list of side line indices inserted immediately *before* base line
-- `bi` (with `ins[n+1]` holding any lines appended after the last base line).
local function index_pairwise(rows, n)
  local at, ins, pending = {}, {}, {}
  for _, r in ipairs(rows) do
    if r.kind == "add" then -- a side-only line: belongs in the gap before the next base line
      pending[#pending + 1] = r.b
    else -- same / change / del — references base line r.a
      ins[r.a] = pending
      pending = {}
      at[r.a] = r
    end
  end
  ins[n + 1] = pending -- trailing insertions, after the last base line
  return at, ins
end

-- The cell for one side at a base line, from that side's pairwise row `r`:
--   same   → the side line, no tint;  change → the side line, DiffChange;
--   del    → a filler (the side dropped this base line).
local function side_cell(r)
  if r.kind == "same" then
    return { line = r.b, kind = nil }
  elseif r.kind == "change" then
    return { line = r.b, kind = "change" }
  end
  return FILLER -- del: the side has no line here
end

-- A side-insertion row (`role` added `line`, the other two panes are fillers).
local function insertion_row(role, line)
  local cells = { ours = FILLER, base = FILLER, theirs = FILLER }
  cells[role] = { line = line, kind = "add" }
  return { kind = "change", base = nil, cells = cells }
end

-- compute3(base, ours, theirs) → { rows = <3-way alignment>, hunks = <ranges> }. The
-- three arguments are line arrays; `base` is the common ancestor the outer two are
-- aligned against. Reuses the 2-way engine (so `change`-pairing and the hunk model are
-- shared) and merges the two diffs on the base axis.
function M.compute3(base, ours, theirs)
  base, ours, theirs = base or {}, ours or {}, theirs or {}
  local n = #base
  local o_at, o_ins = index_pairwise(M.compute(base, ours).rows, n)
  local t_at, t_ins = index_pairwise(M.compute(base, theirs).rows, n)

  local rows = {}
  for bi = 1, n + 1 do
    for _, oi in ipairs(o_ins[bi] or {}) do
      rows[#rows + 1] = insertion_row("ours", oi)
    end
    for _, ti in ipairs(t_ins[bi] or {}) do
      rows[#rows + 1] = insertion_row("theirs", ti)
    end
    if bi <= n then
      local orow, trow = o_at[bi], t_at[bi]
      local changed = orow.kind ~= "same" or trow.kind ~= "same"
      rows[#rows + 1] = {
        kind = changed and "change" or "same",
        base = bi,
        cells = {
          ours = side_cell(orow),
          base = { line = bi, kind = changed and "change" or nil },
          theirs = side_cell(trow),
        },
      }
    end
  end
  return { rows = rows, hunks = hunks_of(rows) }
end

-- project3(rows, role) — the per-pane entry list for "ours" / "base" / "theirs", the
-- same shape `project` yields for a 2-way side (so the view paints both uniformly).
function M.project3(rows, role)
  assert(ROLES[role], "nxvim-diff.diff.project3: role must be 'ours', 'base', or 'theirs'")
  local out = {}
  for _, r in ipairs(rows) do
    local c = r.cells[role]
    out[#out + 1] = c.line and { line = c.line, kind = c.kind } or { filler = true, kind = c.kind }
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
