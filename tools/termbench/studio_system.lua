-- Child of system.lua: observe the first actual terminal frame, then leave the
-- normal app idle. No benchmark polling thread/timer remains after readiness.
local core=require 'core';local uv=require 'uv';local json=require 'json'
local socket=assert(os.getenv('BMUX_SYSTEM_SOCKET'))
local ready=assert(os.getenv('BMUX_SYSTEM_READY'))
local expected=assert(tonumber(os.getenv('BMUX_SYSTEM_PANES')))
local tracing=os.getenv('BOGGART_STUDIO_STARTUP_TRACE')=='1'
local milestones={}
local resumes={}
local resume=coroutine.resume
local resume_count=0
if os.getenv('BOGGART_STUDIO_COROUTINE_TRACE')=='1'then
  assert(tracing,'coroutine trace requires startup trace')
  coroutine.resume=function(co,...)
    local started=uv.hrtime();local result=table.pack(resume(co,...));local finished=uv.hrtime()
    resume_count=resume_count+1
    if #resumes<128 then
      resumes[#resumes+1]={start_ns=started,end_ns=finished,elapsed_ns=finished-started,
        stack=debug.traceback(co):sub(1,4096),status=coroutine.status(co)}
    end
    return table.unpack(result,1,result.n)
  end
end
local function mark(name)
  if tracing and not milestones[name]then milestones[name]=uv.hrtime()end
end
mark('script_loaded')
if tracing then
  local step,begin=core.step,renderer.begin_frame
  core.step=function(...)
    mark('first_step_enter');core.step=step;return step(...)
  end
  renderer.begin_frame=function(...)
    mark('first_draw_enter');renderer.begin_frame=begin;return begin(...)
  end
end
local joined,first_frame,view
local original_end=renderer.end_frame
local function fail(why)io.stderr:write(tostring(why),'\n');os.exit(1)end
system.set_window_size(1000,800)
renderer.end_frame=function()
  local ok,why=xpcall(function()
    mark('first_present_enter')
    if not first_frame and joined and view and view.remote.snapshot and view.size.x>0 then
      mark('terminal_probe_armed')
      local x,y=view:get_content_offset()
      system._test_present_probe(math.floor(x+view.cw/2),math.floor(y+view:header_height()+view.lh/2))
    end
    original_end()
    mark('first_present_return')
    mark('first_draw_return')
    if not first_frame then
      local p=system._test_present_probe()
      if p.valid and p.rgba[1]==0 and p.rgba[2]==64 and p.rgba[3]==192 and p.rgba[4]==255 then
        first_frame=p;system._test_present_probe(false);renderer.end_frame=original_end
      end
    end
  end,debug.traceback)
  if not ok then fail(why)end
end
core.add_thread(function()
  local ok,why=xpcall(function()
    local done,problem=false
    mark('join_requested')
    require('core.bmuxlayout').join(socket,nil,function(e,s)
      joined=s;problem=e;done=true;mark('join_callback');coroutine.resume=resume
    end)
    local deadline=uv.hrtime()+30e9;local diagnostic={}
    while uv.hrtime()<deadline do
      if problem then error(problem.message)end
      local live,total=0,0
      if done and joined then
        diagnostic.errors={}
        for _,v in pairs(joined.pool)do
          total=total+1
          if v.remote and v.remote.snapshot and v.remote:status()=='read-only'then live=live+1 end
          if v.remote and v.remote:status()~='read-only' and #diagnostic.errors<4 then
            diagnostic.errors[#diagnostic.errors+1]={status=v.remote:status(),error=v.remote.error,id=v.remote.id}
          end
        end
        view=core.active_view
        if view and view.remote then
          -- The fixed benchmark window fits the 24-row fixture. Explicit top
          -- position avoids startup scroll interpolation moving the marker.
          view.scroll.y=0;view.scroll.to.y=0
        end
      end
      diagnostic.total=total;diagnostic.live=live;diagnostic.frame=first_frame or system._test_present_probe()
      if first_frame and total==expected and live==expected then
        assert(view.cols==80 and view.rows==24 and view.history_rows==0,'unexpected fixture geometry')
        local function identify(path)
          local f=io.open(path,'rb')
          if not f then return {kind='embedded; executable hash identifies asset'}end
          local identity={kind='file',path=path,sha256=require('hash_c').sha256(f:read('a'))}
          f:close();return identity
        end
        local core_source=identify(DATADIR..'/core/init.lua')
        local font_assets={}
        for _,name in ipairs{'font.ttf','monospace.ttf','icons.ttf'}do
          font_assets[name]=identify(DATADIR..'/fonts/'..name)
        end
        local out={schema=1,pid=uv.os_getpid(),panes=total,attached=live,first_present_ns=first_frame.ns,
          core_source=core_source,
          font_assets=font_assets,font_scope='bundled requested fonts; OS-selected fallback faces are not fingerprinted',
          home=os.getenv('HOME'),store=bog.paths.data,
          all_attached_ns=uv.hrtime(),first_frame=first_frame,cols=view.cols,rows=view.rows,
          startup_milestones=tracing and milestones or nil,
          startup_resumes=#resumes>0 and resumes or nil,
          startup_resume_count=resume_count,startup_resumes_truncated=resume_count>#resumes,
          frame_limit=require('core.config').fps,window_points={1000,800},
          native_sources=require('terminal').source(),renderer_sources=renderer.terminal_sources()}
        -- A signal observer adds no idle wakeup/poll. Parent requests normal
        -- client detach/quit after sampling instead of killing a live window.
        local stop=uv.new_signal()
        stop:start('sigusr1',function()
          joined:disconnect();stop:stop();stop:close();core.quit(true)
        end)
        local f=assert(io.open(ready..'.tmp','wb'));assert(f:write(json.encode(out),'\n'));assert(f:close())
        assert(uv.fs_rename(ready..'.tmp',ready))
        return
      end
      coroutine.yield(0)
    end
    error('system benchmark Studio readiness deadline; '..json.encode(diagnostic))
  end,debug.traceback)
  if not ok then fail(why)end
end)
