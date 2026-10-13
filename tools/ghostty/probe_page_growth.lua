-- Optional SDK diagnostic; C/Lua product builds do not invoke Zig.
package.path='tools/ghostty/?.lua;' .. package.path
local s, json, hash, uv = require 'growth_support', require 'json', require 'hash_c', require 'uv'
local build_anchor='    // All our steps which'
local build_extension=[=[    const growth_mod = b.createModule(.{
        .root_source_file = b.path("src/bmux_page_probe.zig"),
        .target = config.target, .optimize = config.optimize, .link_libc = true,
    });
    growth_mod.addImport("ghostty-vt", mod.vt);
    const growth_exe = b.addExecutable(.{ .name = "bmux-page-probe", .root_module = growth_mod });
    const growth_run = b.addRunArtifact(growth_exe);
    b.step("bmux-page-probe", "Trace terminal metadata growth").dependOn(&growth_run.step);

]=]
local growth_anchor='    // Create our new page and clone the old page into it.\n'
local trace=[=[    var bmux_free_run: usize = 0;
    var bmux_largest_run: usize = 0;
    for (page.grapheme_alloc.bitmap.ptr(page.memory)[0..page.grapheme_alloc.bitmap_count]) |bitmap| {
        for (0..64) |i| {
            if ((bitmap & (@as(u64, 1) << @intCast(i))) == 0) {
                bmux_free_run += 1;
                bmux_largest_run = @max(bmux_largest_run, bmux_free_run);
            } else bmux_free_run = 0;
        }
    }
    const bmux_json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{
        .growth = .{
            .serial = node.serial,
            .before = page.capacity, .after = cap, .used_rows = page.size.rows,
            .dimension = if (adjustment) |v| @tagName(v) else "rehash",
            .styles = page.styles.count(), .grapheme_bytes = page.grapheme_alloc.usedBytes(page.memory),
            .string_bytes = page.string_alloc.usedBytes(page.memory),
            .grapheme_entries = page.graphemeCount(), .grapheme_map_capacity = page.graphemeCapacity(),
            .grapheme_free_bytes = page.grapheme_alloc.capacityBytes() - page.grapheme_alloc.usedBytes(page.memory),
            .largest_grapheme_free_run_bytes = bmux_largest_run * 16,
            .shape = .{ .page_align = std.heap.page_size_min,
                .cell_align = @max(@alignOf(pagepkg.Cell), @min(std.atomic.cache_line, std.heap.page_size_min)),
                .word_bytes = @sizeOf(usize) },
        },
    }, .{});
    defer std.heap.page_allocator.free(bmux_json);
    std.debug.print("{s}\n", .{bmux_json});
]=]
local function oracle(binary, cases, frames, pin)
  local parent=assert(binary:match('^(.*)/[^/]+$'))
  local metadata=s.decode(parent .. '/oracle.json')
  assert(metadata.schema==1 and metadata.revision==pin.revision and metadata.archive_sha256==pin.archive_sha256
    and metadata.zig_version==pin.zig_version and metadata.binary_sha256==s.sha(binary)
    and metadata.adapter_sha256==s.sha('tools/ghostty/resize_oracle.c'),'oracle provenance mismatch')
  local offset,checks=0,{}
  for _,c in ipairs(cases) do
    local args={tostring(c.columns),tostring(c.rows),'snapshot'}
    for _,op in ipairs(c.operations) do
      if op.feed_hex then args[#args+1]='feed'; args[#args+1]=op.feed_hex
      else args[#args+1]='resize'; args[#args+1]=tostring(op.resize[1]); args[#args+1]=tostring(op.resize[2]) end
      args[#args+1]='snapshot'
    end
    local output=s.run(binary,args)
    local snapshots={}; for line in output:gmatch('[^\n]+') do snapshots[#snapshots+1]=json.decode(line) end
    assert(#snapshots==#c.operations+1,'incomplete C ABI snapshots')
    for i,snapshot in ipairs(snapshots) do
      local f=frames[offset+i]
      assert(f.name==c.name and f.step==i-1 and f.columns==snapshot.cols and f.rows==snapshot.rows
        and f.screen==(snapshot.alternate and 'alternate' or 'primary'),'diagnostic geometry differs from C ABI')
      local expected={}
      for _,rows in ipairs({snapshot.scrollback,snapshot.screen}) do
        for _,r in ipairs(rows) do expected[#expected+1]={wrapped=r.wrapped,head=r.cells[#r.cells].head} end
      end
      local actual={}; for _,p in ipairs(f.pages) do for _,r in ipairs(p.rows) do actual[#actual+1]=r end end
      assert(s.same(actual,expected),'diagnostic row order/wrap/head differs from C ABI')
    end
    checks[#checks+1]={name=c.name,snapshots=#snapshots,snapshot_output_sha256=hash.sha256(output)}
    offset=offset+#snapshots
  end
  assert(offset==#frames,'extra diagnostic frames')
  return {manifest=metadata,wrap_head_row_checks=checks}
end
local function main(args)
  local opts={}
  for i=1,#args,2 do
    local key=args[i]:match('^%-%-([%w-]+)$'); assert(key and args[i+1],'expected --option value')
    assert(not opts[key],'duplicate option'); opts[key]=args[i+1]
  end
  for _,key in ipairs({'work-root','archive','output','oracle-binary','global-cache-dir'}) do assert(opts[key],'missing --' .. key) end
  for key in pairs(opts) do assert(({['work-root']=true,archive=true,output=true,['oracle-binary']=true,['global-cache-dir']=true})[key],'unknown --' .. key) end
  assert(uv.os_uname().sysname~='Windows_NT','optional SDK capture currently supports macOS/Linux')
  local pin=s.decode('tools/ghostty/oracle-pin.json')
  assert(pin.revision==s.decode('THIRD_PARTY/ghostty-port.json').revision,'SDK ledger mismatch')
  assert(s.sha(opts.archive)==pin.archive_sha256,'SDK source archive hash mismatch')
  assert(s.run('zig',{'version'}):match('^%s*(.-)%s*$')==pin.zig_version,'pinned Zig required')
  s.mkdir(opts['work-root']); local work=assert(uv.fs_realpath(opts['work-root']))
  local archive=assert(uv.fs_realpath(opts.archive))
  local source,count=s.materialize(archive,work)
  local probe=work .. '/probe-source'; s.copy_tree(source,probe)
  local build,pagelist=probe .. '/build.zig',probe .. '/src/terminal/PageList.zig'
  s.write(build,s.replace_once(s.read(build),build_anchor,build_extension .. build_anchor))
  s.write(pagelist,s.replace_once(s.read(pagelist),growth_anchor,trace .. growth_anchor))
  local driver,template='tools/ghostty/probe_page_growth.lua','tools/ghostty/page_topology.zig'
  local driver_hash,template_hash=s.sha(driver),s.sha(template)
  local support_hash=s.sha('tools/ghostty/growth_support.lua')
  s.write(probe .. '/src/bmux_page_probe.zig',s.read(template))
  local cases=s.cases(); local generated=s.generated_cases(cases)
  s.write(probe .. '/src/bmux_page_cases.zig',generated)
  s.mkdir(opts['global-cache-dir']); local cache=assert(uv.fs_realpath(opts['global-cache-dir']))
  local command={'build','bmux-page-probe','-Demit-lib-vt=true','-Demit-xcframework=false',
    '-Doptimize=' .. pin.optimize,'-Dsimd=' .. tostring(pin.simd),'--cache-dir',work .. '/cache','--global-cache-dir',cache}
  local output,errors=s.run('zig',command,probe,600000)
  s.write(work .. '/build.log',output .. errors)
  local frames,growth,pending={},{},{}
  for line in errors:gmatch('[^\n]+') do
    if line:sub(1,1)=='{' then
      local r=json.decode(line)
      if r.growth then pending[#pending+1]=r.growth
      else
        frames[#frames+1]=r
        for _,e in ipairs(pending) do e.name,e.step=r.name,r.step; growth[#growth+1]=e end
        pending={}
      end
    end
  end
  assert(#pending==0 and #growth>0,'missing or unattached growth events')
  local binary=assert(uv.fs_realpath(opts['oracle-binary']))
  local abi=oracle(binary,cases,frames,pin)
  s.materialize(archive,work)
  assert(s.sha(driver)==driver_hash and s.sha(template)==template_hash
    and s.sha('tools/ghostty/growth_support.lua')==support_hash and s.generated_cases(s.cases())==generated,'capture inputs changed')
  local report={schema=1,kind='instrumented-sdk-page-growth',revision=pin.revision,archive_sha256=pin.archive_sha256,
    source_files_verified=count,zig_version=pin.zig_version,driver_sha256=driver_hash,probe_sha256=template_hash,
    support_sha256=support_hash,generated_cases_sha256=hash.sha256(generated),
    original_pagelist_sha256=s.sha(source .. '/src/terminal/PageList.zig'),instrumented_pagelist_sha256=s.sha(pagelist),
    c_abi_verification=abi,inputs=cases,growth=growth}
  s.write(opts.output,s.encode(report) .. '\n')
  print(('SDK growth: %d events, %d ABI-checked frames; %s'):format(#growth,#frames,opts.output))
end
local ok,problem=xpcall(function() main(boggart.args or {}) end,debug.traceback)
if not ok then io.stderr:write(tostring(problem),'\n'); return 1 end
return 0
