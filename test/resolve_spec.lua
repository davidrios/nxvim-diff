-- Live conflict-resolution test (Phase 6 `choose_*`): drives the real editor end to
-- end. It writes a file with git conflict markers, `:edit`s it, opens the conflict diff
-- via diff.conflict(), then invokes the choose action and asserts the MARKER BLOCK in
-- the live buffer was replaced by the chosen side (markers gone, the picked lines kept,
-- the surrounding context untouched). Run with `nxvim --test-plugin .`.

local diff = require("nxvim-diff")
local nav = require("nxvim-diff.nav")

local CONFLICT = {
  "top",
  "<<<<<<< HEAD",
  "our change",
  "=======",
  "their change",
  ">>>>>>> branch",
  "bot",
}

-- Wait until the open()'d session has finished rendering, then hand it back.
local function await_ready()
  nx.await(nx.wait_for(function()
    local s = diff.session()
    return s and s._ready
  end, { tries = 200, interval = 5, message = "diff never became ready" }))
  return diff.session()
end

-- `:edit` a fresh temp file holding the conflict, returning (path, bufnr).
local function open_conflict(t)
  local path = nx.test.tempdir() .. "/merge.txt"
  nx.await(nx.fs.write(path, table.concat(CONFLICT, "\n") .. "\n"))
  t:cmd("edit " .. path)
  return path, t:buf()
end

-- Wait until `bufnr`'s content equals `expected` (the resolve runs async, after the diff
-- closes, on the next tick), then return the lines.
local function await_lines(t, bufnr, expected)
  t:wait_for(function()
    return table.concat(nx.buf.lines(bufnr, 0, -1), "\n") == table.concat(expected, "\n")
  end, { tries = 300, interval = 10, message = "buffer never reached the resolved content" })
  return nx.buf.lines(bufnr, 0, -1)
end

nx.test.describe("nxvim-diff conflict resolve", function()
  nx.test.before_each(function()
    require("nxvim-diff").setup({})
  end)
  nx.test.after_each(function()
    diff.close()
  end)

  nx.test.it("threads the resolve target (live buf + absolute marker lines)", function(t)
    local _, bufnr = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    nx.test.expect(s.resolve ~= nil).to_be(true)
    nx.test.expect(s.resolve.buf).to_be(bufnr)
    local r = s.resolve.regions[1]
    -- Absolute buffer lines: <<< is line 2, >>> is line 6 in the file above.
    nx.test.expect(r.first).to_be(2)
    nx.test.expect(r.last).to_be(6)
    nx.test.expect(table.concat(r.ours, "|")).to_be("our change")
    nx.test.expect(table.concat(r.theirs, "|")).to_be("their change")
  end)

  nx.test.it("choose_ours replaces the marker block with our side", function(t)
    local _, bufnr = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    nav.choose_ours(s)
    local lines = await_lines(t, bufnr, { "top", "our change", "bot" })
    nx.test.expect(table.concat(lines, "|")).to_be("top|our change|bot")
    -- The diff tab is gone (resolve closes it) — back to a single window on the file.
    nx.test.expect(diff.session()).to_be_nil()
  end)

  nx.test.it("choose_theirs replaces the marker block with their side", function(t)
    local _, bufnr = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    nav.choose_theirs(s)
    local lines = await_lines(t, bufnr, { "top", "their change", "bot" })
    nx.test.expect(table.concat(lines, "|")).to_be("top|their change|bot")
  end)

  nx.test.it("choose_both keeps both sides — ours then theirs", function(t)
    local _, bufnr = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    nav.choose_both(s)
    local lines = await_lines(t, bufnr, { "top", "our change", "their change", "bot" })
    nx.test.expect(table.concat(lines, "|")).to_be("top|our change|their change|bot")
  end)

  nx.test.it("pick_lines + apply_picked composes a resolution from either side", function(t)
    local _, bufnr = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    local row = s.resolve.regions[1].rows.first

    -- Stage theirs first, then ours, from their respective panes: the picks accumulate in
    -- selection order, so the result is "their change" then "our change".
    local function pick_from(pane_idx)
      s.panes[pane_idx].view:set_cursor(row)
      s.panes[pane_idx].view:focus()
      nx.await(nx.wait_for(function()
        return nx.win.current() == s.panes[pane_idx].view:winid() and s:cursor_row() == row
      end, { tries = 100, interval = 5, message = "pane never focused at the conflict row" }))
      nav.pick_lines(s)
    end
    pick_from(2) -- theirs (2-way: ours | theirs)
    pick_from(1) -- ours
    local picks = s.resolve.regions[1].picks
    local text = {}
    for _, p in ipairs(picks) do
      text[#text + 1] = p.text
    end
    nx.test.expect(table.concat(text, "|")).to_be("their change|our change")
    -- Each pick recorded the pane it came from (for the gutter sign): theirs = side "b",
    -- ours = side "a" (a 2-way conflict is ours | theirs).
    nx.test.expect(picks[1].side).to_be("b")
    nx.test.expect(picks[2].side).to_be("a")

    nav.apply_picked(s)
    local lines = await_lines(t, bufnr, { "top", "their change", "our change", "bot" })
    nx.test.expect(table.concat(lines, "|")).to_be("top|their change|our change|bot")
  end)

  nx.test.it("pick_lines refuses lines outside the conflict (shared context)", function(t)
    open_conflict(t)
    diff.conflict()
    local s = await_ready()
    -- Row 1 is "top" — shared context, above the conflict region — so picking it stages
    -- nothing and warns. (The conflict region starts at regions[1].rows.first.)
    s.panes[1].view:set_cursor(1)
    s.panes[1].view:focus()
    nx.await(nx.wait_for(function()
      return nx.win.current() == s.panes[1].view:winid() and s:cursor_row() == 1
    end, { tries = 100, interval = 5, message = "pane never focused on row 1" }))
    nav.pick_lines(s)
    local msg = t:wait_for(function()
      local m = t:message()
      return (m:match("aren't part of the conflict") and m) or nil
    end, { tries = 200, interval = 10, message = "no out-of-conflict notice appeared" })
    nx.test.expect(msg:match("aren't part of the conflict") ~= nil).to_be(true)
    nx.test.expect(s.resolve.regions[1].picks == nil or #s.resolve.regions[1].picks == 0).to_be(true)
  end)

  nx.test.it("apply_picked with nothing staged notifies and writes nothing", function(t)
    local _, bufnr = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    nav.apply_picked(s)
    local msg = t:wait_for(function()
      local m = t:message()
      return (m:match("no lines picked") and m) or nil
    end, { tries = 200, interval = 10, message = "no 'no lines picked' notice appeared" })
    nx.test.expect(msg:match("no lines picked") ~= nil).to_be(true)
    -- The diff is still open and the buffer still holds its markers (nothing was written).
    nx.test.expect(diff.session() ~= nil).to_be(true)
    nx.test.expect(nx.buf.lines(bufnr, 1, 2)[1]).to_be("<<<<<<< HEAD")
  end)

  nx.test.it("clear_picked discards what pick_lines staged", function(t)
    local _, _ = open_conflict(t)
    diff.conflict()
    local s = await_ready()
    local region = s.resolve.regions[1]
    region.picks = { { side = "a", row = region.rows.first, text = "leftover" } }
    nav.clear_picked(s)
    nx.test.expect(region.picks).to_be_nil()
  end)

  nx.test.it("resolves only the conflict under the cursor in a multi-conflict file", function(t)
    local content = {
      "top",
      "<<<<<<< HEAD",
      "ours1",
      "=======",
      "theirs1",
      ">>>>>>> b",
      "mid",
      "<<<<<<< HEAD",
      "ours2",
      "=======",
      "theirs2",
      ">>>>>>> b",
      "bot",
    }
    local path = nx.test.tempdir() .. "/multi.txt"
    nx.await(nx.fs.write(path, table.concat(content, "\n") .. "\n"))
    t:cmd("edit " .. path)
    local bufnr = t:buf()
    diff.conflict()
    local s = await_ready()
    nx.test.expect(#s.resolve.regions).to_be(2)

    -- Put the cursor on the SECOND conflict (its alignment-row range), then resolve it.
    local row = s.resolve.regions[2].rows.first
    s:goto_row(row)
    nx.await(nx.wait_for(function()
      return s:cursor_row() == row
    end, { tries = 100, interval = 5, message = "cursor never reached the 2nd conflict" }))
    nav.choose_theirs(s)

    -- The first conflict's markers stay; only the second block becomes "theirs2".
    local lines = await_lines(t, bufnr, {
      "top",
      "<<<<<<< HEAD",
      "ours1",
      "=======",
      "theirs1",
      ">>>>>>> b",
      "mid",
      "theirs2",
      "bot",
    })
    nx.test
      .expect(table.concat(lines, "|"))
      .to_be("top|<<<<<<< HEAD|ours1|=======|theirs1|>>>>>>> b|mid|theirs2|bot")
  end)

  nx.test.it("choose_* on a non-conflict diff is a no-op notice", function(t)
    -- A plain (generic) diff has no resolve target — choosing must not touch anything.
    diff.open({
      panes = {
        { label = "a", lines = { "x" } },
        { label = "b", lines = { "y" } },
      },
    })
    local s = await_ready()
    nx.test.expect(s.resolve).to_be_nil()
    nav.choose_ours(s) -- just notifies; no crash, no write
    local msg = t:wait_for(function()
      local m = t:message()
      return (m:match("nothing to resolve") and m) or nil
    end, { tries = 200, interval = 10, message = "no 'nothing to resolve' notice appeared" })
    nx.test.expect(msg:match("nothing to resolve") ~= nil).to_be(true)
  end)
end)
