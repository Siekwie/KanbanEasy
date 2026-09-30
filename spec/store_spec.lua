local Store = require("src.store")

local function newStore()
  local t = 1000
  local s = Store.new(nil, {
    clock = function()
      t = t + 1
      return t
    end,
  })
  s:createProject({ name = "Kanban Easy", key = "KE" })
  return s
end

local function ids(list)
  local out = {}
  for i, x in ipairs(list) do
    out[i] = x.id
  end
  return out
end

describe("store", function()
  it("creates projects with default columns and suggested keys", function()
    local s = newStore()
    local p = s:project("ke")
    assert.equal("Kanban Easy", p.name)
    assert.equal(5, #p.columns)
    assert.equal("AT", s:suggestKey("Agent Tasks"))
    assert.equal("SCR", s:suggestKey("scraper"))
    assert.equal("KE2", s:suggestKey("Kanban Easy"))
    local _, err = s:createProject({ name = "Dup", key = "KE" })
    assert.truthy(err)
  end)

  it("creates issues with sequential ids", function()
    local s = newStore()
    local a = s:createIssue("KE", { title = "First" })
    local b = s:createIssue("KE", { title = "Second", status = "todo", priority = "high", labels = "bug, #api" })
    assert.equal("KE-1", a.id)
    assert.equal("KE-2", b.id)
    assert.equal("backlog", a.status)
    assert.equal("todo", b.status)
    assert.equal(3, b.priority)
    assert.same({ "bug", "api" }, b.labels)
    assert.equal(b, s:issue("ke-2"))
    local _, err = s:createIssue("KE", { title = "  " })
    assert.truthy(err)
  end)

  it("resolves loose status names", function()
    local s = newStore()
    local p = s:project("KE")
    assert.equal("in_progress", s:resolveStatus(p, "In Progress"))
    assert.equal("in_progress", s:resolveStatus(p, "doing"))
    assert.equal("in_progress", s:resolveStatus(p, "in-progress"))
    assert.equal("done", s:resolveStatus(p, "completed"))
    assert.equal("review", s:resolveStatus(p, "rev"))
    assert.is_nil(s:resolveStatus(p, "zzz"))
  end)

  it("moves and reorders issues", function()
    local s = newStore()
    local p = s:project("KE")
    for i = 1, 4 do
      s:createIssue("KE", { title = "t" .. i, status = "todo" })
    end
    s:moveIssue("KE-4", "todo", 1)
    assert.same({ "KE-4", "KE-1", "KE-2", "KE-3" }, ids(s:issuesIn(p, "todo")))
    s:moveIssue("KE-4", "todo", 3)
    assert.same({ "KE-1", "KE-2", "KE-4", "KE-3" }, ids(s:issuesIn(p, "todo")))
    s:moveIssue("KE-1", "done")
    assert.same({ "KE-2", "KE-4", "KE-3" }, ids(s:issuesIn(p, "todo")))
    assert.same({ "KE-1" }, ids(s:issuesIn(p, "done")))
    -- many midpoint inserts never break ordering
    for _ = 1, 80 do
      s:moveIssue("KE-3", "todo", 2)
      s:moveIssue("KE-4", "todo", 2)
    end
    local list = ids(s:issuesIn(p, "todo"))
    assert.equal(3, #list)
    assert.equal("KE-4", list[2])
  end)

  it("logs activity on status/assignee changes and comments", function()
    local s = newStore()
    s:createIssue("KE", { title = "x" })
    s:as("claude", function()
      s:updateIssue("KE-1", { status = "doing", assignee = "claude" })
      s:addComment("KE-1", "working on it")
    end)
    local issue = s:issue("KE-1")
    assert.equal("in_progress", issue.status)
    local last = issue.activity[#issue.activity]
    assert.equal("comment", last.kind)
    assert.equal("claude", last.author)
    assert.equal(4, #issue.activity)
  end)

  it("undoes and redoes", function()
    local s = newStore()
    s:createIssue("KE", { title = "x" })
    s:updateIssue("KE-1", { title = "y" })
    assert.equal("y", s:issue("KE-1").title)
    s:undo()
    assert.equal("x", s:issue("KE-1").title)
    s:redo()
    assert.equal("y", s:issue("KE-1").title)
    s:deleteIssue("KE-1")
    assert.is_nil(s:issue("KE-1"))
    s:undo()
    assert.equal("y", s:issue("KE-1").title)
  end)

  it("batches undo steps", function()
    local s = newStore()
    s:createIssue("KE", { title = "x" })
    s:duplicateIssue("KE-1")
    assert.truthy(s:issue("KE-2"))
    s:undo()
    assert.is_nil(s:issue("KE-2"))
    assert.truthy(s:issue("KE-1"))
  end)

  it("does not record no-op updates", function()
    local s = newStore()
    s:createIssue("KE", { title = "x" })
    local n = #s.undoStack
    s:updateIssue("KE-1", { title = "x", labels = {} })
    assert.equal(n, #s.undoStack)
  end)

  it("deletes columns by moving issues to a neighbour", function()
    local s = newStore()
    s:createIssue("KE", { title = "x", status = "review" })
    s:deleteColumn("KE", "review")
    assert.equal("in_progress", s:issue("KE-1").status)
    local col = s:addColumn("KE", "Blocked")
    assert.equal("blocked", col.id)
  end)

  it("filters with search syntax", function()
    local s = newStore()
    s:createIssue("KE", { title = "Fix login", labels = { "bug" }, assignee = "claude", priority = "high" })
    s:createIssue("KE", { title = "Write docs", description = "about login" })
    local p = s:project("KE")
    local function count(q)
      return #s:issuesIn(p, "backlog", Store.matcher(q))
    end
    assert.equal(2, count("login"))
    assert.equal(1, count("@claude"))
    assert.equal(1, count("#bug"))
    assert.equal(1, count("p:high"))
    assert.equal(0, count("#bug docs"))
    assert.equal(1, count("ke-2"))
  end)

  it("serializes and reloads", function()
    local s = newStore()
    s:createIssue("KE", { title = "x", labels = { "a" } })
    local s2 = Store.fromJSON(s:toJSON())
    assert.equal("x", s2:issue("KE-1").title)
    assert.equal(2, s2:project("KE").nextNum)
  end)

  it("exports markdown", function()
    local s = newStore()
    local issue = s:createIssue("KE", { title = "x", description = "do it", priority = "urgent" })
    s:addComment("KE-1", "hello", "bot")
    local md = s:issueMarkdown(issue, true)
    assert.truthy(md:find("## KE-1: x", 1, true))
    assert.truthy(md:find("Priority: Urgent", 1, true))
    assert.truthy(md:find("**bot**", 1, true))
    assert.truthy(s:projectMarkdown(s:project("KE")):find("- [ ] KE-1 x (urgent)", 1, true))
  end)
end)
