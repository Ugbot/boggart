package.path='tools/ghostty/?.lua;' .. package.path
local s,inputs,json,hash=require 'growth_support',require 'bitmap_cases',require 'json',require 'hash_c'
local anchor='    // All our steps which'
local extension=[=[    const bitmap_mod = b.createModule(.{
        .root_source_file = b.path("src/bmux_bitmap_probe.zig"),
        .target = config.target, .optimize = config.optimize, .link_libc = true,
    });
    const bitmap_exe = b.addExecutable(.{ .name = "bmux-bitmap-probe", .root_module = bitmap_mod });
    const bitmap_run = b.addRunArtifact(bitmap_exe);
    b.step("bmux-bitmap-probe", "Capture terminal bitmap allocator").dependOn(&bitmap_run.step);

]=]
local function main(args)
  local opts={}; for i=1,#args,2 do local k=args[i]:match('^%-%-([%w-]+)$'); assert(k and args[i+1]); assert(not opts[k]); opts[k]=args[i+1] end
  local required={['work-root']=true,archive=true,['global-cache-dir']=true,output=true}
  for k in pairs(required) do assert(opts[k],'missing --' .. k) end
  for k in pairs(opts) do assert(required[k],'unknown option') end
  local pin=s.decode('tools/ghostty/oracle-pin.json')
  assert(s.sha(opts.archive)==pin.archive_sha256,'archive pin mismatch')
  assert(s.run('zig',{'version'}):match('^%s*(.-)%s*$')==pin.zig_version,'pinned Zig required')
  local identities={}; for _,p in ipairs({'tools/ghostty/probe_bitmap.lua','tools/ghostty/bitmap_cases.lua','tools/ghostty/bitmap_probe.zig','tools/ghostty/growth_support.lua'}) do identities[p]=s.sha(p) end
  s.mkdir(opts['work-root']); local work=assert(require('uv').fs_realpath(opts['work-root']))
  local archive=assert(require('uv').fs_realpath(opts.archive))
  local source,count=s.materialize(archive,work); local probe=work .. '/probe-source'; s.copy_tree(source,probe)
  s.write(probe .. '/build.zig',s.replace_once(s.read(probe .. '/build.zig'),anchor,extension .. anchor))
  s.write(probe .. '/src/bmux_bitmap_probe.zig',s.read('tools/ghostty/bitmap_probe.zig'))
  local cases=inputs.cases(); local generated=inputs.generated(cases)
  s.write(probe .. '/src/bmux_bitmap_cases.zig',generated)
  local output,errors=s.run('zig',{'build','bmux-bitmap-probe','-Demit-lib-vt=true','-Demit-xcframework=false',
    '-Doptimize=' .. pin.optimize,'-Dsimd=' .. tostring(pin.simd),'--cache-dir',work .. '/cache',
    '--global-cache-dir',opts['global-cache-dir']},probe,600000)
  s.write(work .. '/build.log',output .. errors)
  local events={}; for line in errors:gmatch('[^\n]+') do if line:sub(1,1)=='{' then events[#events+1]=json.decode(line) end end
  local index=0
  for _,c in ipairs(cases) do for step=0,#c.operations-1 do
    index=index+1; assert(events[index] and events[index].name==c.name and events[index].step==step,'incomplete SDK allocator sequence')
  end end
  assert(index==#events,'extra SDK allocator event')
  s.materialize(archive,work)
  for p,digest in pairs(identities) do assert(s.sha(p)==digest,'capture source changed') end
  assert(inputs.generated(inputs.cases())==generated,'allocator inputs changed')
  s.write(opts.output,s.encode({schema=1,kind='pinned-sdk-bitmap-allocator',revision=pin.revision,
    archive_sha256=pin.archive_sha256,source_files_verified=count,zig_version=pin.zig_version,
    source_sha256=s.sha(source .. '/src/terminal/bitmap_allocator.zig'),identities=identities,
    generated_cases_sha256=hash.sha256(generated),cases=cases,events=events}) .. '\n')
  print(('SDK allocator: %d cases, %d operations; %s'):format(#cases,#events,opts.output))
end
local ok,problem=xpcall(function() main(boggart.args or {}) end,debug.traceback)
if not ok then io.stderr:write(tostring(problem),'\n'); return 1 end
return 0
