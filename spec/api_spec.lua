local api = require("src.api")
local Store = require("src.store")
local json = require("src.json")

local function call(store, method, target, body, headers)
  headers = headers or {}
  local raw = body
  if type(body) == "table" then
    raw = json.encode(body)
    headers["content-type"] = "application/json"
  end
  local res = api.handle(store, { method = method, target = target, headers = headers, rawBody = raw })
  local decoded
  if res.contentType == "application/json" then
    decoded = json.decode(res.body)
  end
  return res.status, decoded, res.body
end

describe("api", function()
  local store
  before_each(function()
    store = Store.new()
    store:createProject({ name = "Main", key = "MAIN" })
  end)

  it("serves help", function()
    local status, _, body = call(store, "GET", "/")
    assert.equal(200, status)
    assert.truthy(body:find("KanbanEasy local API", 1, true))
  end)

  it("creates and fetches issues with the default project", function()
    local status, issue = call(store, "POST", "/issues", { title = "Hello", status = "todo", labels = "a,b" })
    assert.equal(201, status)
    assert.equal("MAIN-1", issue.id)
    assert.equal("todo", issue.status)
    assert.same({ "a", "b" }, issue.labels)
    local s2, got = call(store, "GET", "/issues/main-1")
    assert.equal(200, s2)
    assert.equal("Hello", got.title)
    assert.equal(1, #got.activity)
    assert.equal("agent", got.activity[1].author)
  end)

  it("accepts form-encoded bodies", function()
    local status, issue = call(store, "POST", "/issues", "title=Form+issue&priority=high", {
      ["content-type"] = "application/x-www-form-urlencoded",
    })
    assert.equal(201, status)
    assert.equal("Form issue", issue.title)
    assert.equal("high", issue.priority)
  end)

  it("updates, moves, comments and deletes", function()
    call(store, "POST", "/issues", { title = "A" })
    call(store, "POST", "/issues", { title = "B" })
    local s, u = call(store, "PATCH", "/issues/MAIN-1", { status = "In Progress", assignee = "claude" })
    assert.equal(200, s)
    assert.equal("in_progress", u.status)
    s, u = call(store, "POST", "/issues/MAIN-2/move", { status = "in_progress", index = 1 })
    assert.equal(200, s)
    assert.equal(1, u.position)
    s = call(store, "POST", "/issues/MAIN-2/comments", { body = "done soon" }, { ["x-actor"] = "codex" })
    assert.equal(201, s)
    assert.equal("codex", store:issue("MAIN-2").activity[3].author)
    s = call(store, "DELETE", "/issues/MAIN-2")
    assert.equal(200, s)
    s = call(store, "GET", "/issues/MAIN-2")
    assert.equal(404, s)
  end)

  it("lists and filters issues, including markdown", function()
    call(store, "POST", "/issues", { title = "One", status = "todo", assignee = "claude" })
    call(store, "POST", "/issues", { title = "Two", status = "done" })
    local _, list = call(store, "GET", "/issues?status=todo")
    assert.equal(1, #list)
    _, list = call(store, "GET", "/issues?assignee=claude")
    assert.equal("MAIN-1", list[1].id)
    local _, _, md = call(store, "GET", "/projects/MAIN?format=md")
    assert.truthy(md:find("- [x] MAIN-2 Two", 1, true))
  end)

  it("claims the next todo", function()
    call(store, "POST", "/issues", { title = "Mine", status = "todo", assignee = "other" })
    call(store, "POST", "/issues", { title = "Free", status = "todo" })
    local s, issue = call(store, "POST", "/claim", { assignee = "claude" })
    assert.equal(200, s)
    assert.equal("Free", issue.title)
    assert.equal("in_progress", issue.status)
    assert.equal("claude", issue.assignee)
    s = call(store, "POST", "/claim", { assignee = "claude" })
    assert.equal(404, s)
  end)

  it("sets people and column rules", function()
    local s, proj = call(store, "PATCH", "/projects/MAIN", { me = "sam", agent = "claude", default_assignee = "me" })
    assert.equal(200, s)
    assert.same({ me = "sam", agent = "claude" }, proj.people)
    assert.equal("sam", proj.default_assignee)
    call(store, "POST", "/issues", { title = "Decide auth", status = "review", assignee = "" })
    local col
    s, col = call(store, "PATCH", "/projects/MAIN/columns/Review", {
      auto_assign = "@agent",
      instructions = "Write the decision into docs/decisions.md, then move to done",
    })
    assert.equal(200, s)
    assert.equal("claude", col.auto_assign)
    assert.equal(1, col.reassigned)
    local _, issue = call(store, "POST", "/issues", { title = "Pick a DB", status = "in_progress" })
    assert.equal("sam", issue.assignee)
    assert.is_nil(issue.instructions)
    _, issue = call(store, "PATCH", "/issues/" .. issue.id, { status = "review" })
    assert.equal("claude", issue.assignee)
    assert.truthy(issue.instructions:find("docs/decisions.md", 1, true))
    local _, list = call(store, "GET", "/issues?assignee=agent&status=review")
    assert.equal(2, #list)
    local _, _, md = call(store, "GET", "/issues/MAIN-2?format=md")
    assert.truthy(md:find("### Review instructions", 1, true))
    assert.equal(404, (call(store, "PATCH", "/projects/MAIN/columns/nope", { auto_assign = "me" })))
  end)

  it("claims for the claimer even when the target column has a rule", function()
    store:setColumnRules("MAIN", "in_progress", { assign = "@me" })
    call(store, "POST", "/issues", { title = "Free", status = "todo" })
    local s, issue = call(store, "POST", "/claim", { assignee = "claude" })
    assert.equal(200, s)
    assert.equal("claude", issue.assignee)
    assert.equal("in_progress", issue.status)
  end)

  it("reports errors", function()
    assert.equal(400, (call(store, "POST", "/issues", { title = "" })))
    assert.equal(400, (call(store, "POST", "/issues", { title = "x", status = "nope" })))
    assert.equal(400, (call(store, "POST", "/issues", "{not json", { ["content-type"] = "application/json" })))
    assert.equal(404, (call(store, "GET", "/nope")))
    assert.equal(405, (call(store, "DELETE", "/projects")))
  end)

  it("rejects browser and remote-host requests", function()
    assert.equal(403, (call(store, "POST", "/issues", { title = "x" }, { origin = "https://evil.example" })))
    assert.equal(403, (call(store, "GET", "/projects", nil, { host = "evil.example:7420" })))
    assert.equal(200, (call(store, "GET", "/projects", nil, { host = "localhost:7420" })))
  end)

  it("requires a project when ambiguous", function()
    store:createProject({ name = "Other", key = "OT" })
    assert.equal(400, (call(store, "POST", "/issues", { title = "x" })))
    store:setSetting("activeProject", "OT")
    local _, issue = call(store, "POST", "/issues", { title = "x" })
    assert.equal("OT-1", issue.id)
  end)
end)

describe("server request parsing", function()
  -- server.lua needs LuaSocket; stub it so the parser can be tested standalone.
  package.preload["socket"] = package.preload["socket"] or function()
    return {}
  end
  local Server = require("src.server")

  it("waits for the full body and flags Expect: 100-continue", function()
    local head = "POST /issues HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\nExpect: 100-continue\r\n\r\n"
    local req, wantsContinue = Server.parseRequest(head)
    assert.is_nil(req)
    assert.is_true(wantsContinue)
    req = Server.parseRequest(head .. "0123456789")
    assert.equal("POST", req.method)
    assert.equal("/issues", req.target)
    assert.equal("0123456789", req.rawBody)
    assert.equal("localhost", req.headers.host)
  end)

  it("rejects garbage and oversized bodies", function()
    assert.is_true(Server.parseRequest("hello\r\n\r\n").bad)
    assert.is_true(Server.parseRequest("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n").tooLarge)
  end)
end)
