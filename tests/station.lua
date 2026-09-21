-- station.lua -- the LLM Station ZMQ client's dormant contract, plus the
-- envelope codec, which works in every build because it needs no libzmq.
--
-- The opt-in rule under test (docs/station-zmq.md): a default build carries
-- station.built() == false and every entry point degrades to nil + an
-- explanatory error -- never a raise, never a hang. The msgpack codec and
-- endpoint discovery are unconditional, so they are exercised for real here;
-- the socket layer needs a live daemon and is covered by the manual smoke in
-- a -DBOGGART_STATION=ON build.
local passed, failed = 0, 0
local function ok(cond, name)
  if cond then passed = passed + 1
  else failed = failed + 1; io.write("FAIL: ", name, "\n") end
end

ok(type(station) == "table", "station global exists")
ok(type(station.built()) == "boolean", "built() returns a boolean")
ok(type(station.available()) == "boolean", "available() returns a boolean")

-- connect never raises: either a connection (flag build, workspace known) or
-- nil + a reason. Point it at a directory that cannot be registered.
do
  local conn, err = station.connect("/nonexistent/path/for/station/test")
  ok(conn == nil and type(err) == "string", "connect on a bogus workspace: nil, err")
end

-- endpoint discovery never raises either; on this bogus path it must miss.
do
  local ep, why = station.endpoint("/nonexistent/path/for/station/test")
  ok(ep == nil and type(why) == "string", "endpoint miss: nil, why")
end

-- ---- envelope codec round trip ---------------------------------------------

do
  local payload = {
    file = "src/main.c", line = "42", column = "7",
    prefix = "do_th", empty = "",
    long = string.rep("x", 300),               -- forces str16
  }
  local bytes = station._encode("tool_exec", "smart_complete", payload)
  ok(type(bytes) == "string" and #bytes > 0, "encode produces bytes")
  ok(bytes:byte(1) == 0x83, "envelope is a 3-field fixmap")

  local mt, tool, p = station._decode(bytes)
  ok(mt == "tool_exec", "msg_type round-trips")
  ok(tool == "smart_complete", "tool rides its own slot (STATION-138)")
  ok(type(p) == "table", "payload decodes to a table")
  local n = 0
  for _ in pairs(p or {}) do n = n + 1 end
  ok(n == 6, "payload pair count survives (" .. tostring(n) .. ")")
  ok(p.file == "src/main.c" and p.line == "42", "flat string values survive")
  ok(p.empty == "", "empty string value survives")
  ok(p.long == string.rep("x", 300), "str16-sized value survives")
end

-- Numbers are stringified on encode: the wire is flat strings by design.
do
  local bytes = station._encode("ping", nil, { n = 7 })
  local _, _, p = station._decode(bytes)
  ok(p and p.n == "7", "number payload value becomes a string")
end

-- No tool, no payload: both default rather than erroring.
do
  local bytes = station._encode("ping")
  local mt, tool, p = station._decode(bytes)
  ok(mt == "ping" and tool == "" and type(p) == "table" and next(p) == nil,
    "minimal envelope round-trips")
end

-- Garbage in: a clean nil, err -- decode must never raise on wire noise.
do
  local a, b = station._decode("not msgpack at all")
  ok(a == nil and type(b) == "string", "garbage decodes to nil, err")
  local c, d = station._decode(string.char(0x83, 0xa8) .. "msg_typ") -- truncated
  ok(c == nil and type(d) == "string", "truncated envelope: nil, err")
end

-- Forward compatibility: an envelope with an unknown extra field (here an
-- int, which the flat-strings wire never uses today) still decodes.
do
  -- fixmap(4): msg_type:"x", tool:"", payload:{}, extra:7
  local bytes = string.char(0x84)
    .. string.char(0xa8) .. "msg_type" .. string.char(0xa1) .. "x"
    .. string.char(0xa4) .. "tool" .. string.char(0xa0)
    .. string.char(0xa7) .. "payload" .. string.char(0x80)
    .. string.char(0xa5) .. "extra" .. string.char(0x07)
  local mt, tool, p = station._decode(bytes)
  ok(mt == "x" and tool == "" and type(p) == "table",
    "unknown top-level field is skipped, not fatal")
end

-- BRAIN-21: synthetic transports, no daemon/model/account effects.
do
  local loaded, adapter = pcall(require, "adapters.station")
  ok(loaded, "capability adapter exists")
  if loaded then
    local link, json = require("stationlink"), require("json")
    local saved_ensure, saved_ping, saved_env = link.ensure, link.ping, os.getenv
    local writes, mcp_calls, sends = 0, 0, 0
    local lost, wire_args = false, nil
    local conn = {}
    function conn:request(channel, kind, tool, args)
      sends = sends + 1
      local _, decoded_tool, decoded = station._decode(station._encode(kind, tool, args))
      local data
      if kind == "list_tools" then data = "fixture_write\tfixture\tSynthetic writer\n"
      elseif kind == "tool_schema" then
        ok(decoded_tool == "fixture_write", "schema target occupies tool slot")
        data = "Tool: fixture_write\nDescription: Synthetic writer\n\nParameters:\n  text (string) [required]: value\n  count (integer): count\n"
      else writes = writes + 1; wire_args = decoded; data = decoded.text end
      return {wait=function()
        if lost and kind == "tool_exec" then return nil, "reply lost" end
        return {ok="true",data=data,run_id="tool-owned"}, "tool_result", "result"
      end}
    end
    link.ensure = function() return conn end
    link.ping = function() return true end
    os.getenv = function(k) if k == "BOGGART_STATION_FORCE_MCP" then return "0" end return saved_env(k) end
    local fake_mcp = {call=function(_, name, encoded)
      mcp_calls=mcp_calls+1
      local args=json.decode(encoded)
      ok(args.count==7 and args.workspace=="fixture","MCP preserves integer and workspace values")
      return json.encode{content={{type="text",text=args.text}},structuredContent={run_id="tool-owned"}}
    end, list_tools=function() return json.encode{tools={{name="fixture_write",description="Synthetic writer",inputSchema={type="object",properties={text={type="string"},count={type="integer"}},required={"text"}}}}} end,
    info=function() return json.encode{protocol="fixture-protocol"} end}
    local z=adapter.new{link=link,mcp=fake_mcp,workspace="fixture"}
    local discovered=assert(z:discover())
    ok(discovered[1].name=="fixture_write" and discovered[1].input_schema.properties.count.type=="integer", "real daemon text discovery parsed")
    local d=assert(z:register("fixture_write",{id="station.fixture.z",version="fixture-1",effect="write"}))
    local ctx=require("invoke").context{state={mode="auto",guards=false}}
    local args={text="hello\nworld",count=7}
    local out=z:invoke(ctx,d.id,d.version,args,{operation_id="stable-write"})
    ok(out.status=="succeeded" and out.result==args.text and wire_args.count=="7", "native codec preserves supported values")
    ok(out.receipt.execution.run_id==out.receipt.evidence.run_id,"execution receipt carries local run correlation")
    ok(args.workspace==nil and out.receipt.execution.operation_id=="stable-write", "immutable arguments and operation correlation")
    ok(out.receipt.execution.invocation_id==out.receipt.invocation_id and out.receipt.execution.remote.run_id=="tool-owned", "local correlation distinct from tool metadata")
    local before=sends
    for _,bad in ipairs({{text="x",extra=true},{text="x",extra={x=1}},{text="x",count=1.5}}) do
      local r=z:invoke(ctx,d.id,d.version,bad)
      ok(r.status=="failed" and sends==before,"unsupported argument refused before send")
    end
    lost=true; writes=0
    out=z:invoke(ctx,d.id,d.version,args)
    ok(out.status=="uncertain" and writes==1 and mcp_calls==0,"lost write reply never retries through MCP")
    ok(z:cancel("stable-write").error.code=="unsupported" and z:status("stable-write").error.code=="unsupported", "unsupported operation status and cancellation explicit")
    lost=false
    os.getenv=function(k) if k=="BOGGART_STATION_FORCE_MCP" then return "1" end return saved_env(k) end
    local m=adapter.new{link=link,mcp=fake_mcp,workspace="fixture"}
    assert(m:discover());local md=assert(m:register("fixture_write",{id="station.fixture.m",version="fixture-1",effect="write"}))
    out=m:invoke(ctx,md.id,md.version,args,{operation_id="mcp-operation"})
    ok(out.status=="succeeded" and out.result==args.text and mcp_calls==1 and out.receipt.execution.operation_id=="mcp-operation", "explicit MCP parity and correlation")
    ok(m:features().protocol=="fixture-protocol" and not z:features().remote_policy, "only negotiated MCP version advertised; remote policy unverified")
    os.getenv=function(k) if k=="BOGGART_STATION_FORCE_MCP" then return "0" end return saved_env(k) end
    link.ensure=function() return nil,"not built" end
    out=z:invoke(ctx,d.id,d.version,args)
    ok(out.status=="failed" and out.receipt.execution.fallback=="native" and mcp_calls==1,"missing native transport degrades without MCP")
    -- Request errors and remote errors cannot prove nonexecution.
    link.ensure=function() return conn end
    local old_request=conn.request
    conn.request=function() error("request failed after partial send") end
    out=z:invoke(ctx,d.id,d.version,args)
    ok(out.status=="uncertain" and mcp_calls==1,"request exception remains uncertain")
    conn.request=function() return nil,"pending slots full" end
    out=z:invoke(ctx,d.id,d.version,args)
    ok(out.status=="failed" and out.receipt.execution.dispatch=="not_sent","native nil handle is a pre-send refusal")
    conn.request=function() return {wait=function() return {ok="false",err="partial write",data="diagnostic"},"tool_result","result" end} end
    out=z:invoke(ctx,d.id,d.version,args)
    ok(out.status=="uncertain" and out.error.code=="remote_error" and out.receipt.execution.remote.data=="diagnostic","remote error details retained without disproving effects")
    conn.request=function() return {wait=function() return {},"tool_result","result" end} end
    out=z:invoke(ctx,d.id,d.version,args)
    ok(out.status=="uncertain" and out.error.code=="invalid_response","missing native tool outcome is not success")
    conn.request=old_request
    -- No claimed encoding support for non-string keys, booleans, tables,
    -- nonfinite/fractional or unsafe integers, even outside the capability API.
    local count_before=sends
    for _,bad in ipairs({{[1]="x"},{x=true},{x={}},{x=0/0},{x=math.huge},{x=1.25},{x=math.mininteger}}) do
      local value,meta=link.request("fixture_write",bad)
      ok(value==nil and meta.effect_disproven and sends==count_before,"flat encoder refuses lossy arguments")
    end
    local ls=require("llmstation")
    local old_active,old_available,old_attach=link.active,ls.available,ls.attach
    local attaches=0
    link.active=function() return false end
    ls.available=function() return true end
    ls.attach=function() attaches=attaches+1;return {} end
    ok(ls.autostart()==false and attaches==0,"autostart does not silently mount MCP without FORCE_MCP")
    link.active,ls.available,ls.attach=old_active,old_available,old_attach
    local unknown=assert(z:register("fixture_write",{id="station.fixture.unknown",version="fixture-1"}))
    out=z:invoke(ctx,unknown.id,unknown.version,args)
    ok(out.status=="failed" and out.error.code=="permission_error","remote effect defaults to unknown and requires admission")
    os.getenv=function(k) if k=="BOGGART_STATION_FORCE_MCP" then return "1" end return saved_env(k) end
    local old_call=fake_mcp.call
    fake_mcp.call=function() mcp_calls=mcp_calls+1;return json.encode{isError=true,content={{type="text",text="partial change"}}} end
    out=m:invoke(ctx,md.id,md.version,args)
    ok(out.status=="uncertain" and out.error.code=="remote_error" and out.receipt.execution.mcp_result.isError,"MCP structured tool error remains uncertain")
    fake_mcp.call=function() mcp_calls=mcp_calls+1;return "malformed JSON" end
    out=m:invoke(ctx,md.id,md.version,args)
    ok(out.status=="uncertain" and out.error.code=="reply_unavailable","malformed MCP reply remains uncertain")
    for _,raw in ipairs({
      '{"content":null}', '{"content":{"unexpected":"value"}}',
      '{"content":{}}', '{"content":[]}', '{"content":[7]}',
      '{"content":[null]}', '{"content":[{"type":"text","text":"x"},null]}',
      '{"content":{"1":{"type":"text","text":"x"},"3":{"type":"text","text":"y"}}}',
      '{"isError":true,"content":null,"structuredContent":{"reason":"partial effect"}}'
    }) do
      local previous=mcp_calls
      fake_mcp.call=function() mcp_calls=mcp_calls+1;return raw end
      out=m:invoke(ctx,md.id,md.version,args)
      ok(out.status=="uncertain" and mcp_calls==previous+1 and out.receipt.execution and out.receipt.execution.mcp_result and type(out.receipt.execution.content_shape)=="string" and out.receipt.execution.mcp_raw==nil,
        "malformed content stays uncertain with structured receipt, shape and no retry")
    end
    fake_mcp.call=function() return '{"content":[{"type":"text","text":""}]}' end
    out=m:invoke(ctx,md.id,md.version,args)
    ok(out.status=="succeeded" and out.result=="","valid empty text block succeeds")
    fake_mcp.call=function() return '{"password":"escaped\\ncredential"' end
    out=m:invoke(ctx,md.id,md.version,args)
    ok(out.status=="uncertain" and not json.encode(out):find("credential",1,true),"malformed raw JSON is not duplicated into evidence/error strings")
    fake_mcp.call=old_call
    link.ensure,link.ping,os.getenv=saved_ensure,saved_ping,saved_env
  end
end

-- Actual native MCP serialization, with the existing offline stdio fixture.
-- Python JSON trace preserves whether cJSON emitted an integer or exponent/float.
do
  local json,adapter=require("json"),require("adapters.station")
  local trace=os.tmpname()
  local names,err=bog.mcphost.add{name="station_wire_fixture",command="python3",
    args={"tests/mock_mcp.py","--trace",trace}}
  ok(names~=nil,"native MCP fixture connects: "..tostring(err))
  if names then
    local saved_env=os.getenv
    os.getenv=function(k) if k=="BOGGART_STATION_FORCE_MCP" then return "1" end return saved_env(k) end
    local a=adapter.new{mcp=bog.mcphost.conns.station_wire_fixture}
    assert(a:discover())
    local d=assert(a:register("echo",{id="station.actual.mcp",version="1",effect="write"}))
    local ctx=require("invoke").context{state={mode="auto",guards=false}}
    local values={0,1,-1,2147483648,-2147483648,999999999999999,-999999999999999}
    for _,n in ipairs(values) do
      local r=a:invoke(ctx,d.id,d.version,{text="numeric wire fixture",count=n})
      ok(r.status=="succeeded","accepted integer reaches native MCP")
    end
    for _,n in ipairs({1000000000000000,-1000000000000000,9007199254740991}) do
      local r=a:invoke(ctx,d.id,d.version,{text="must not dispatch",count=n})
      ok(r.status=="failed" and r.error.code=="unsupported_encoding","exponent-prone integer refused before native MCP")
    end
    local r=a:invoke(ctx,d.id,d.version,{text="large explicit string",count="1000000000000000"})
    ok(r.status=="succeeded","large values supported as explicit strings")
    local calls={}
    local f=assert(io.open(trace,"r"))
    for line in f:lines() do
      local message=json.decode(line)
      if message.method=="tools/call" then calls[#calls+1]=message.params.arguments end
    end
    f:close()
    ok(#calls==#values+1,"rejected numeric values generate no tools/call frames")
    for i,n in ipairs(values) do
      local wire=calls[i] and calls[i].count
      local _,_,native=station._decode(station._encode("tool_exec","echo",{count=n}))
      ok(math.type(wire)=="integer" and tostring(wire)==native.count,"actual MCP integer representation matches native ZMQ")
    end
    ok(calls[#calls].count=="1000000000000000","explicit large string unchanged on native MCP wire")
    bog.mcphost.conns.station_wire_fixture:close()
    bog.mcphost.conns.station_wire_fixture=nil
    os.getenv=saved_env
  end
  os.remove(trace)
end

io.write(string.format("station: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
