-- Session modal: all key/paste/mouse events stop here until explicitly closed.
local Actions=require 'bmux.sessionactions';local Input=require 'tui.input'
local M={};local UI={};UI.__index=UI
local function label(tc,y,text,w,selected)
  if w>0 then tc.puts(0,y,sys.cell_take(text,w),selected and '93ddfa'or 'e1e1e6',nil,selected and{bold=true}or nil)end
end
function M.new(app)return setmetatable({app=app,index=1},UI)end
function UI:open()
  if not self.app.client.host_id then self.app.message='Join a Bmux layout first';return end
  if not self.actions then
    local opts=self.app.opts
    local ok,a=pcall(Actions.new,{socket=opts.socket,token=opts.token,host_id=self.app.client.host_id},function()self.app.dirty=true end)
    if not ok then self.app.message=tostring(a);return end
    self.actions=a
  end
  self.mode=true;self.editor=nil;self.app.prefix=false;self.app.help=false;self.app.fleet.mode=nil
  self.app.dirty=true;self.actions:refresh()
end
function UI:edit(title,submit,default)
  local box=Input.new{completion=false};box:_set(default or '')
  self.editor={title=title,box=box,submit=submit}
end
function UI:items()
  local a=self.actions
  return {
    {key='e',text='Export session to new file',run=function()self:edit('Export session to new file',function(path)a:export(path);self.editor=nil end)end},
    {key='i',text='Import file as inactive session',run=function()self:edit('Import checkpoint file',function(path)
      self:edit('New saved session name (inactive)',function(name)a:import(path,name);self.editor=nil end)
    end)end},
    {key='c',text='Inspect saved session',run=function()self:edit('Saved session name',function(name)a:inspect(name);self.editor=nil end,a.import_name or a.saved_name)end},
    {key='r',text='Refresh session status',run=function()a:refresh()end},
    {key='v',text='Recover saving; preserve original',run=function()
      a:prepare_recovery(function(why,p)
        if why or not self.mode then return end
        self:edit('Save current layout; type name: '..p.name,function(name)a:recover(name);self.editor=nil end)
        self.editor.recovery=p
      end)
    end},
  }
end
function UI:input(e)
  local a=self.actions
  if e.type=='resize'then return end
  if self.editor then
    if e.type=='key'and(e.key=='esc'or e.key=='ctrl'and e.char=='c')then self.editor=nil;return end
    if e.type~='key'and e.type~='paste'then return end
    if e.type=='key'and e.key=='enter'then
      if not a.busy then self.editor.submit(self.editor.box.line)end;return
    end
    local box=self.editor.box
    if #(e.text or e.char or '')+#box.line>4096 then return end
    if e.key=='tab'or e.key=='ctrl'and(e.char=='g'or e.char=='r')then return end
    local before,cursor=box.line,box.cursor
    if e.type=='paste'then box:paste(e.text)else box:key(e)end
    if #box.line>4096 then box:_set(before);box.cursor=cursor end;return
  end
  if e.type=='key'and(e.key=='esc'or e.char=='q')then self.mode=nil;return end
  local items=self:items()
  if e.type=='mouse'and e.button&3==0 and e.button&64==0 then
    for _,hit in ipairs(self.hits or {})do if e.my==hit.y and e.mx>=0 and e.mx<hit.w then
      self.index=hit.index;if not a.busy then items[hit.index].run()end;return
    end end
  end
  if e.type~='key'then return end
  if e.key=='up'or e.char=='k'then self.index=(self.index-2)%#items+1
  elseif e.key=='down'or e.char=='j'then self.index=self.index%#items+1
  elseif not a.busy then
    for i,item in ipairs(items)do if e.char==item.key or e.key=='enter'and i==self.index then item.run();return end end
  end
end
function UI:draw(tc,w,h)
  tc.clear();self.hits={};if w<1 or h<1 then return end
  label(tc,0,' Bmux | Sessions'..(self.actions.busy and ' | working'or ''),w,true)
  if h<4 then if h>1 then label(tc,h-1,'Escape closes',w)end;return end
  label(tc,h-1,self.actions.message or 'Up/Down select | Enter choose | Escape close',w,true)
  if self.editor then
    label(tc,1,self.editor.title,w,true)
    local top=2
    if self.editor.recovery and h>8 then
      local p=self.editor.recovery
      label(tc,2,p.workspaces..' workspaces; '..p.terminals..' terminals will be saved',w)
      label(tc,3,'Original '..p.archive.bytes..' bytes kept at:',w);label(tc,4,p.archive.path,w)
      top=5
    end
    local lines,cy,cx=self.editor.box:visual(w);local capacity=math.max(1,h-top-2);local first=math.max(1,cy-capacity+1)
    for i=first,math.min(#lines,first+capacity-1)do
      local parts={};for _,run in ipairs(lines[i])do parts[#parts+1]=run.text end
      local body=table.concat(parts);local y=i-first+top;label(tc,y,body,w)
      if i==cy and cx<w then
        local tail=body:sub(#sys.cell_take(body,cx)+1);local cluster=tail:sub(1,require('grapheme').next(tail,1)-1)
        tc.puts(cx,y,cluster~=''and cluster or ' ',nil,nil,{reverse=true})
      end
    end
    if h>4 then label(tc,h-2,'Enter confirms | Escape cancels',w)end;return
  end
  label(tc,1,self.actions:summary(),w)
  local items=self:items();local capacity=math.max(1,h-4);local first=math.max(1,self.index-capacity+1)
  for i=first,math.min(#items,first+capacity-1)do
    local y=i-first+2;label(tc,y,(i==self.index and '> 'or '  ')..items[i].key..' '..items[i].text,w,i==self.index)
    self.hits[#self.hits+1]={y=y,w=w,index=i}
  end
end
function UI:close()if self.actions then self.actions:close()end end
return M
