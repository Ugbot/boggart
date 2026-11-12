-- Studio adapter for the shared Fleet registry; native C still owns the PTY.
local core=require 'core'
local registry=require('fleet').default
local TerminalView=require 'core.terminalview'
local M={ registry=registry }
registry:set_source('boggart',function()
  local dash=require 'dash'; local out={}
  for _,id in ipairs(dash.order)do local rec=dash.agents[id];if rec then out[#out+1]=rec end end
  return out
end)

local close=TerminalView.try_close
function TerminalView:try_close(done)
  close(self,function()
    if self.fleet_agent_id then
      local rec=registry.agents[self.fleet_agent_id]
      if rec then
        local state=(rec.state=='exited' or rec.state=='failed') and rec.state or 'stopped'
        registry:retire(rec.id,rec.generation,state)
      end
      if self.fleet_workers then self.fleet_workers:close('owning TUI pane closed',true)end
      self.dead=true
    end
    done()
  end)
end

function M.install()
  if M.installed then return end
  M.installed=true
  core.add_thread(function()
    while true do registry:poll(); coroutine.yield(0.1) end
  end)
end

function M.bind(rec,view)
  M.install();view.fleet_agent_id=rec.id
  if view.spawn_error or not view.terminal then
    registry:retire(rec.id,rec.generation,'failed',view.spawn_error or 'no process')
    return
  end
  local revision=-1
  local channel=view.terminal:channel()
  local control=channel and require('agentcontrol').new(channel,rec.id,rec.generation)
  local reporter=control or view.provider_events
  local focus=function()return require('shell.workspaces.bmux').show(view)end
  local workers=control and require('fleetworkers').new(registry,rec,control,focus)
  view.fleet_workers=workers
  registry:bind(rec.id,rec.generation,{
    poll=function()
      if not view.terminal then return {state='stopped',activity='pane closed'}end
      if workers then workers:prune()end
      local semantic=reporter and reporter:poll()
      if semantic and workers then
        local applied,error=workers:apply(semantic.workers,semantic.worker_results)
        if not applied then semantic=control:fail(error)end
        if control.error then workers:unreachable(control.error)end
      end
      local current=view.terminal:process_revision()
      if current==revision and not semantic then return end
      revision=current
      local state=view.terminal:process_state()
      if not state then return {state='unreachable',activity='no process state'}end
      local status=reporter and reporter.status and reporter.status.state or 'alive'
      if state.error then status='failed'
      elseif state.exited and state.eof then status=state.exit_status==0 and state.term_signal==0 and 'exited' or 'failed' end
      if workers and (status=='exited' or status=='failed')then workers:close('owning TUI exited')end
      local activity=status=='alive' and 'process alive; agent activity unknown' or status
      local changed=rec.state~=status or rec.bytes~=state.bytes_read
      if changed or semantic then core.redraw=true end
      local fields=semantic or {}
      fields.state=status;fields.pid=state.pid;fields.bytes=state.bytes_read;fields.exit_status=state.exit_status
      fields.term_signal=state.term_signal;fields.activity=fields.activity or activity
      if state.error then fields.error=state.error end
      return fields
    end,
    focus=focus,
    stop=function()
      view:try_close(function()core.redraw=true end)
      return true
    end,
    prompt=control and function(_,payload)return control:command('prompt',payload)end,
    interrupt=control and function()return control:command('interrupt')end,
    approve=control and function(_,payload)return control:command('approve',payload)end,
  })
  if channel then
    channel:watch(function(owner)
      if registry.agents[rec.id]~=rec or rec.retired then owner:watch(nil);return end
      -- Control.poll consumes at most 64 frames; the native queue holds 128.
      -- Drain both bounded batches without waiting for a periodic roster scan.
      for _=1,2 do
        registry:poll(rec.id)
        if owner:state().received_frames==0 or control.error then break end
      end
      if control.error or owner:state().closed then owner:watch(nil)end
      core.redraw=true
    end)
  end
  registry:poll()
end
return M
