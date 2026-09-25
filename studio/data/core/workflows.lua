-- Operational workflow surface; source/evidence inspection belongs to Library.
local core=require('core')
local View=require('core.view')
local common=require('core.common')
local style=require('core.style')
local widgets=require('core.widgets')
local command=require('core.command')
local M={}
local Workflows=View:extend()
function Workflows:new() Workflows.super.new(self);self.hits={};self.notice='' end
function Workflows:get_name()return 'Workflows'end
local function coordinator()return require('triggers').workflows end
function M.run(id)
 local c=coordinator();if not c then return nil,'No host workflow bindings' end
 -- A Studio thread, never the draw/click callback, drives the workflow.
 core.add_thread(function()
  local h,why=c:run(id,'button')
  M.last=h and h:snapshot() or {status='denied',error=why}
  core.redraw=true
 end)
 return true
end
function Workflows:on_mouse_pressed(button,x,y)
 if button~='left' then return end
 local hit=widgets.hit(self.hits,x,y)
 if hit and hit.action then hit.action();return true end
end
function Workflows:draw()
 self:draw_background(style.background)
 local x,y=self.position.x+style.padding.x,self.position.y+style.padding.y
 local width=self.size.x-2*style.padding.x
 common.draw_text(style.font,style.accent,'Workflows','left',x,y,width,30);y=y+40
 self.hits={}
 local c=coordinator();local records=c and c:status() or {}
 if #records==0 then common.draw_text(style.font,style.dim,'No trusted workflow bindings configured.','left',x,y,width,30) end
 for _,record in ipairs(records)do
  local last=record.occurrences[#record.occurrences]
  local text=record.id..'  '..(record.available and (record.enabled and 'ready' or 'paused') or 'binding unavailable')
   ..'  last: '..(last and last.status or 'never')..'  next: '..tostring(record.next_at or '-')
  common.draw_text(style.font,style.text,text,'left',x,y,width,30);y=y+32
  local hits=widgets.row(style.font,{
   {label='Run',action=function()M.run(record.id)end,dim=not record.available or not record.enabled},
   {label=record.enabled and 'Pause' or 'Resume',action=function()c:pause(record.id,record.enabled);core.redraw=true end},
   {label='Cancel',dim=not last,action=function()if last then c:cancel(record.id,last.occurrence);core.redraw=true end end},
   {label='Preview',action=function()M.preview=c:preview(record.id);self.notice='Preview '..record.id..': no effects; next '..tostring(M.preview.next_at or 'not scheduled');core.redraw=true end},
  },x,y,nil,x+width)
  for _,hit in ipairs(hits)do self.hits[#self.hits+1]=hit end
  y=y+widgets.height(style.font)+16
 end
 common.draw_text(style.font,style.dim,self.notice,'left',x,y,width,30)
 if M.last then common.draw_text(style.font,style.text,'Last button run: '..M.last.status,'left',x,y+32,width,30)end
end
function M.open()
 local view=Workflows();M.view=view
 core.root_view:get_primary_node():add_view(view);core.set_active_view(view)
 return view
end
command.add(nil,{['agent:workflows']=M.open})
M.View=Workflows
return M
