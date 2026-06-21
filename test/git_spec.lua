-- Live :NxDiffGit test (Phase 5): exercises the git source end to end — a real init'd
-- repo (HEAD read), plus the not-a-repo / nameless / not-in-HEAD error paths — and
-- asserts the notifications read cleanly (one "nxvim-diff: " prefix, no Lua position
-- noise). The not-a-repo case doubles as the regression test for the fix that runs git
-- in the FILE's directory, not the editor cwd. Run with `nxvim --test-plugin`.

local diff = require("nxvim-diff")
local gitmod = require("nxvim-diff.git")

-- Run a git command in `dir`, awaiting it; fail the test loud on a non-zero exit.
local function git(dir, ...)
  local r = nx.await(nx.run({ cmd = "git", args = { ... }, cwd = dir }))
  if r.code ~= 0 then
    error(("git %s failed: %s"):format(table.concat({ ... }, " "), r.stderr), 0)
  end
  return r
end

-- A fresh repo with one committed file (`a.txt` = "one\ntwo\n").
local function repo_with_commit(dir)
  git(dir, "init", "-q")
  git(dir, "config", "user.email", "t@example.com")
  git(dir, "config", "user.name", "Test")
  nx.await(nx.fs.write(dir .. "/a.txt", "one\ntwo\n"))
  git(dir, "add", "a.txt")
  git(dir, "commit", "-q", "-m", "init")
end

-- `:edit` a path and settle. (The buffer name reaches Lua's current-buffer snapshot
-- right after `:edit` now — `expand("%:p")` reads it.)
local function edit(t, path)
  t:cmd("edit " .. path)
end

-- Run `fn` (kicking off the async git path) and return the plugin's own notification —
-- matched by its "nxvim-diff:" prefix so a stale `:edit` echo isn't mistaken for it.
local function notify_after(t, fn)
  fn()
  return t:wait_for(function()
    local m = t:message()
    return (m:match("^nxvim%-diff:") and m) or nil
  end, { tries = 300, interval = 10, message = "nxvim-diff git: no notification appeared" })
end

nx.test.describe("nxvim-diff git", function()
  nx.test.before_each(function()
    require("nxvim-diff").setup({})
  end)
  nx.test.after_each(function()
    diff.close()
  end)

  nx.test.it("head_spec reads HEAD from the file's own repo dir", function(t)
    local dir = nx.test.tempdir()
    repo_with_commit(dir)
    -- head_spec runs git in ctx.cwd; pointing it at the repo dir, its `git show HEAD:a.txt`
    -- must yield the committed content. (If git ran anywhere else, show would fail.)
    local spec = nx.await(gitmod.head_spec({
      file = dir .. "/a.txt",
      bufnr = t:buf(),
      cwd = dir,
    }))
    nx.test.expect(#spec.panes).to_be(2)
    nx.test.expect(spec.panes[1].label).to_be("HEAD")
    nx.test.expect(table.concat(spec.panes[1].lines, "|")).to_be("one|two")
    nx.test.expect(spec.panes[1].readonly).to_be(true)
    nx.test.expect(spec.panes[2].buf).to_be(t:buf()) -- the live working-tree buffer
  end)

  nx.test.it("a file outside any git repo reports 'not a git repository'", function(t)
    -- The editor cwd is this plugin's repo; the file is in /tmp. The OLD code ran git in
    -- the editor cwd and found THIS repo (then failed on `git show`); running it in the
    -- file's dir correctly reports no repo.
    local dir = nx.test.tempdir()
    edit(t, dir .. "/foo.txt")
    nx.test
      .expect(notify_after(t, function()
        diff.git_head()
      end))
      .to_be("nxvim-diff: not a git repository")
  end)

  nx.test.it("a nameless buffer reports it has no file to diff", function(t)
    t:cmd("enew")
    nx.test
      .expect(notify_after(t, function()
        diff.git_head()
      end))
      .to_be("nxvim-diff: this buffer has no file to diff")
  end)

  nx.test.it("a file not in HEAD reports no HEAD version", function(t)
    local dir = nx.test.tempdir()
    repo_with_commit(dir)
    edit(t, dir .. "/new.txt") -- in the repo, but never committed
    nx.test
      .expect(notify_after(t, function()
        diff.git_head()
      end))
      .to_be("nxvim-diff: no HEAD version of new.txt")
  end)
end)
