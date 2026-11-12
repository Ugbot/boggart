-- Development capture helpers. Run through boggart --eval; no extra runtime.
local uv, json, hash = require 'uv', require 'json', require 'hash_c'
local M = {root = uv.cwd()}
function M.read(path)
  local f = assert(io.open(path, 'rb')); local s = f:read('a'); f:close(); return s
end
function M.write(path, s)
  local f = assert(io.open(path, 'wb')); assert(f:write(s)); assert(f:close())
end
function M.sha(path) return hash.sha256(M.read(path)) end
function M.decode(path) return json.decode(M.read(path)) end
function M.encode(v)
  if type(v) ~= 'table' or v == json.null or v == json.array then return json.encode(v) end
  local n, keys = 0, {}
  for k in pairs(v) do n = n + 1; keys[#keys+1] = k end
  if n > 0 and n == #v then
    local parts = {}; for i = 1, #v do parts[i] = M.encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  table.sort(keys)
  local parts = {}; for _, k in ipairs(keys) do parts[#parts+1] = json.encode(k) .. ':' .. M.encode(v[k]) end
  return '{' .. table.concat(parts, ',') .. '}'
end
function M.same(a,b) return M.encode(a) == M.encode(b) end
function M.mkdir(path)
  local stat = uv.fs_lstat(path)
  if stat then assert(stat.type == 'directory', 'expected directory: ' .. path); return end
  local parent = path:match('^(.*)/[^/]+$')
  if parent and parent ~= '' then M.mkdir(parent) end
  assert(uv.fs_mkdir(path, 493))
end
function M.walk(path, visit)
  local scan = assert(uv.fs_scandir(path))
  while true do
    local name, kind = uv.fs_scandir_next(scan); if not name then break end
    local p = path .. '/' .. name
    assert(kind == 'file' or kind == 'directory', 'unsupported file type: ' .. p)
    if kind == 'directory' then M.walk(p,visit) else visit(p) end
  end
end
function M.run(exe, args, cwd, timeout)
  local out, err, bytes, finished, expired = {}, {}, 0, false, false
  local stdout, stderr, timer = uv.new_pipe(false), uv.new_pipe(false), uv.new_timer()
  local code, process
  process = assert(uv.spawn(exe, {args=args, cwd=cwd, stdio={nil,stdout,stderr}}, function(c)
    code, finished = c, true; uv.timer_stop(timer); uv.close(timer); uv.close(process)
  end))
  local function receive(pipe, chunks)
    uv.read_start(pipe, function(problem, data)
      assert(not problem, problem)
      if data then
        bytes = bytes + #data
        assert(bytes <= 67108864, 'capture output exceeds 64 MiB')
        chunks[#chunks+1] = data
      else uv.read_stop(pipe); uv.close(pipe) end
    end)
  end
  receive(stdout,out); receive(stderr,err)
  uv.timer_start(timer,timeout or 30000,0,function() expired=true; process:kill('sigkill') end)
  while not finished do uv.run('once') end
  while not uv.is_closing(stdout) or not uv.is_closing(stderr) do uv.run('once') end
  assert(not expired, exe .. ' timed out')
  local a,b = table.concat(out),table.concat(err)
  assert(code == 0, exe .. ' failed (' .. tostring(code) .. '): ' .. b:sub(1,2000))
  return a,b
end
function M.replace_once(text, anchor, replacement)
  local a,b = text:find(anchor,1,true); assert(a, 'SDK anchor missing')
  assert(not text:find(anchor,b+1,true), 'SDK anchor duplicated')
  return text:sub(1,a-1) .. replacement .. text:sub(b+1)
end
function M.materialize(archive, work)
  local check, source = work .. '/archive-check', work .. '/pinned-source'
  M.mkdir(check)
  M.run('tar',{'-xzf',archive,'-C',check,'--strip-components=1'})
  local count = 0; local exists = uv.fs_lstat(source)
  if exists then assert(exists.type == 'directory', 'source root must be a directory') else M.mkdir(source) end
  M.walk(check,function(p)
    local relative = p:sub(#check+2); local target = source .. '/' .. relative
    if exists then
      assert(uv.fs_lstat(target).type == 'file' and M.read(target) == M.read(p), 'pinned source differs: ' .. relative)
    else
      M.mkdir(assert(target:match('^(.*)/[^/]+$'))); M.write(target,M.read(p))
      assert(uv.fs_chmod(target,uv.fs_stat(p).mode & 511))
    end
    count = count + 1
  end)
  assert(count == 5915, 'unexpected pinned SDK file count')
  local actual = 0; M.walk(source,function() actual=actual+1 end)
  assert(actual == count, 'unexpected file in pristine SDK tree')
  return source,count
end
function M.copy_tree(source, target)
  M.mkdir(target)
  M.walk(source,function(p)
    local destination = target .. '/' .. p:sub(#source+2)
    M.mkdir(assert(destination:match('^(.*)/[^/]+$')))
    local stat = uv.fs_lstat(destination)
    assert(not stat or stat.type == 'file', 'copy target must be a file')
    M.write(destination,M.read(p))
    assert(uv.fs_chmod(destination,uv.fs_stat(p).mode & 511))
  end)
end
function M.hex(s) return (s:gsub('.',function(c) return ('%02x'):format(c:byte()) end)) end
function M.cases()
  local cases = {}
  for _, c in ipairs(M.decode(M.root .. '/tests/fixtures/ghostty-resize-large.json').cases) do
    cases[#cases+1] = {name=c.name,columns=c.columns,rows=c.rows,operations=c.operations}
  end
  local styles, graphemes, links, esc = {}, {}, {}, '\27'
  for i=0,256 do
    styles[#styles+1] = esc .. ('[38;2;%d;%d;19mX'):format(i >> 8,i & 255)
    links[#links+1] = esc .. (']8;id=key%d;https://example.com/link/%d\7X'):format(i,i)
  end
  for i=0,179 do
    local p={'a'}
    for bit=15,0,-1 do p[#p+1]=utf8.char(((i >> bit) & 1) == 1 and 0x301 or 0x300) end
    graphemes[#graphemes+1]=table.concat(p)
  end
  local function add(name,cols,rows,text)
    cases[#cases+1]={name=name,columns=cols,rows=rows,operations={{feed_hex=M.hex(text)}}}
  end
  add('sparse_style_projection',100,25,table.concat(styles))
  add('sparse_style_projection_bounded',100,1,table.concat(styles))
  add('sparse_grapheme_projection',100,25,table.concat(graphemes))
  add('sparse_grapheme_projection_bounded',6,3,table.concat(graphemes))
  add('hyperlink_and_string_growth',100,25,table.concat(links) .. esc .. ']8;;\7')
  return cases
end
function M.generated_cases(cases)
  local lines = {'const Resize = struct { columns: u16, rows: u16 };',
    'const Operation = union(enum) { feed: []const u8, resize: Resize };',
    'const Case = struct { name: []const u8, columns: u16, rows: u16, operations: []const Operation };',
    'pub const cases = [_]Case{'}
  local function literal(s) return '"' .. s:gsub('.',function(c) return ('\\x%02x'):format(c:byte()) end) .. '"' end
  local names={}
  for _,c in ipairs(cases) do
    assert(type(c.name)=='string' and c.name~='' and not names[c.name]); names[c.name]=true
    for _,n in ipairs({c.columns,c.rows}) do assert(type(n)=='number' and n%1==0 and n>0 and n<=4096) end
    lines[#lines+1]=('.{ .name=%s, .columns=%d, .rows=%d, .operations=&.{'):format(literal(c.name),c.columns,c.rows)
    for _,op in ipairs(c.operations) do
      if op.feed_hex then
        assert(type(op.feed_hex)=='string' and #op.feed_hex%2==0 and not op.feed_hex:find('[^%da-f]'))
        local bytes=op.feed_hex:gsub('..',function(h) return string.char(tonumber(h,16)) end)
        lines[#lines+1]='.{ .feed=' .. literal(bytes) .. ' },'
      else
        for _,n in ipairs(op.resize) do assert(type(n)=='number' and n%1==0 and n>0 and n<=4096) end
        assert(#op.resize==2)
        lines[#lines+1]=('.{ .resize=.{ .columns=%d, .rows=%d } },'):format(op.resize[1],op.resize[2])
      end
    end
    lines[#lines+1]='} },'
  end
  lines[#lines+1]='};'; return table.concat(lines,'\n') .. '\n'
end
return M
