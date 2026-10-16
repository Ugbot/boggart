-- One capability-filtered action list for Fleet pointer and keyboard controls.
local core=require 'core';local style=require 'core.style';local json=require 'json'
local M={}
function M.external(view,rec)
  local registry=require('core.fleetagents').registry
  local items={};local id,generation=rec.id,rec.generation
  local revision=rec.input_revision;local request_id=rec.request and rec.request.id
  for _,entry in ipairs{{'focus','Focus pane'},{'prompt','Send prompt'},
    {'interrupt','Interrupt',style.error},{'approve','Approve'},
    {'approve','Reject',style.error},{'stop',rec.worker and 'Cancel worker' or 'Stop',style.error}}do
    local action=entry[1];local decision=entry[2]=='Reject' and 'reject' or 'approve'
    if rec.capabilities[action] and (action~='approve' or request_id)then
      local function perform(payload)
        local current=registry:get(id)
        if current~=rec or current.generation~=generation or action=='approve' and (not current.request or current.request.id~=request_id)then
          view:note('agent action expired; choose the current action',true);return
        end
        local ok,err=registry:control(id,generation,action,payload)
        if not ok then view:note(err or 'agent action failed',true)end
        core.redraw=true
      end
      items[#items+1]={key=json.encode{id,generation,action,action=='approve' and request_id or false,action=='approve' and decision or false},
        label=entry[2],tone=entry[3],action=function()
          if view.selected~=id then view:note('agent selection changed',true);return end
          if action=='prompt'then
            core.command_view:enter('Prompt for '..rec.name,function(text)perform{text=text,input_revision=revision}end)
          else perform(action=='approve' and {request_id=request_id,decision=decision} or nil)end
        end}
    end
  end
  return items
end
function M.approvals(view,rec,pend)
  local items={}
  for _,entry in ipairs{{'Approve','approve',style.good},{'Reject','reject',style.error},{'Approve all','always'}}do
    items[#items+1]={key=json.encode{rec.id,tostring(pend),entry[2]},label=entry[1],tone=entry[3],action=function()
      if view.selected~=rec.id or view:pending_for(rec.id)~=pend then view:note('approval request expired',true);return end
      bog.approvals.decide(rec.id,entry[2]);core.redraw=true
    end}
  end
  return items
end
function M.actor(view,rec,actor)
  local items={}
  for _,entry in ipairs{{actor.paused and 'Resume' or 'Pause','pause'},{'Kill','kill',style.error}}do
    local paused=actor.paused
    items[#items+1]={key=json.encode{rec.id,tostring(actor),entry[1]},label=entry[1],tone=entry[3],action=function()
      if view.selected~=rec.id or not bog.sched or bog.sched.by_id[rec.id]~=actor then view:note('agent runtime expired',true);return end
      if entry[2]=='kill'then view:kill(rec.id)
      elseif actor.paused==paused then view:toggle_pause(rec.id)
      else view:note('agent pause state changed',true)end
    end}
  end
  return items
end
return M
