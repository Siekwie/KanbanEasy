local json = require("src.json")

describe("json", function()
  it("round-trips nested values", function()
    local v = { a = 1, b = { 1, 2, 3 }, c = 'hi "there"\n', d = true, e = { x = 1.5 } }
    assert.same(v, json.decode(json.encode(v)))
    assert.same(v, json.decode(json.encode(v, true)))
  end)

  it("sorts keys for stable output", function()
    assert.equal('{"a":1,"b":2,"c":3}', json.encode({ c = 3, a = 1, b = 2 }))
  end)

  it("encodes empty tables as arrays unless marked", function()
    assert.equal("[]", json.encode({}))
    assert.equal("{}", json.encode(json.object()))
  end)

  it("decodes unicode escapes and surrogate pairs", function()
    assert.equal("é😀", json.decode('"\\u00e9\\ud83d\\ude00"'))
  end)

  it("keeps utf-8 as-is", function()
    assert.equal('"→ ok"', json.encode("→ ok"))
  end)

  it("reports errors", function()
    assert.has_error(function()
      json.decode("{bad}")
    end)
    assert.has_error(function()
      json.decode("[1,2")
    end)
    assert.has_error(function()
      json.decode("1 2")
    end)
  end)

  it("decodes numbers and literals", function()
    assert.same({ -1.5, 2e3, true, false }, json.decode("[-1.5, 2e3, true, false]"))
  end)
end)
