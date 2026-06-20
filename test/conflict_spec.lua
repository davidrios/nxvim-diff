-- The pure conflict-marker parser. Run with `nxvim --test-plugin`. No editor state.

local conflict = require("nxvim-diff.conflict")

local DIFF3 = {
  "common top",
  "<<<<<<< HEAD",
  "ours line",
  "||||||| merged common ancestor",
  "base line",
  "=======",
  "theirs line",
  ">>>>>>> feature-branch",
  "common bottom",
}

local MERGE = {
  "top",
  "<<<<<<< HEAD",
  "ours",
  "=======",
  "theirs",
  ">>>>>>> branch",
  "bot",
}

nx.test.describe("nxvim-diff.conflict", function()
  nx.test.it("reports no conflict on a clean file", function()
    local p = conflict.parse({ "a", "b", "======= not a marker outside a conflict" })
    nx.test.expect(p.has_conflict).to_be(false)
    nx.test.expect(p.count).to_be(0)
  end)

  nx.test.it("parses diff3 style into three full sides with context", function()
    local p = conflict.parse(DIFF3)
    nx.test.expect(p.has_conflict).to_be(true)
    nx.test.expect(p.diff3).to_be(true)
    nx.test.expect(p.count).to_be(1)
    nx.test.expect(p.ours_label).to_be("HEAD")
    nx.test.expect(p.theirs_label).to_be("feature-branch")
    -- each side is the whole file with its section substituted (context preserved)
    nx.test.expect(table.concat(p.ours, "|")).to_be("common top|ours line|common bottom")
    nx.test.expect(table.concat(p.base, "|")).to_be("common top|base line|common bottom")
    nx.test.expect(table.concat(p.theirs, "|")).to_be("common top|theirs line|common bottom")
  end)

  nx.test.it("parses plain merge style with no base (2-way)", function()
    local p = conflict.parse(MERGE)
    nx.test.expect(p.diff3).to_be(false)
    nx.test.expect(p.base).to_be_nil()
    nx.test.expect(table.concat(p.ours, "|")).to_be("top|ours|bot")
    nx.test.expect(table.concat(p.theirs, "|")).to_be("top|theirs|bot")
  end)

  nx.test.it("spec() builds 3 panes for diff3, 2 for plain merge", function()
    nx.test.expect(#conflict.spec(DIFF3, "f").panes).to_be(3)
    nx.test.expect(#conflict.spec(MERGE, "f").panes).to_be(2)
  end)

  nx.test.it("spec() returns nil + a reason for a clean file", function()
    local spec, reason = conflict.spec({ "a", "b" }, "f")
    nx.test.expect(spec).to_be_nil()
    nx.test.expect(reason).to_be("no conflict markers found")
  end)

  nx.test.it("fails loud on an unterminated conflict", function()
    nx.test
      .expect(function()
        conflict.parse({ "<<<<<<< HEAD", "ours" })
      end)
      .to_error("unterminated")
  end)
end)
