-- Native terminal front end. The server alone owns layouts and PTYs.
local uv=require 'uv'
local Layout=require 'bmux.client'
local Remote=require 'terminal.remote'
local Canvas=require 'bmux.canvas'
local terminal=require 'terminal'
local M={};local App={};App.__index=App
function M.new(opts)
  local self=setmetatable({opts=opts,remotes={},scroll={},inputs={},input_bytes=0,dirty=true,status='connecting'},App)
  self.client=Layout.new{socket=opts.socket,token=opts.token,on_change=function(c)
    self.status=c.status;self.dirty=true
    if c.status=='disconnected' or c.uncertain then self.inputs={};self.input_bytes=0;self.prefix=false end
    if c.error then self.message=c.error.message end
  end}
  return self
end
function App:start()self.client:start(function(why)if why then self.message=why.message end;self.dirty=true end)end
function App:arrange(w,h)
  if not self.scene or self.layout_revision~=self.client.revision or w~=self.width or h~=self.height then
    self.scene=Canvas.layout(self.client:view(),w,h)
    self.layout_revision,self.width,self.height=self.client.revision,w,h
  end
  local wanted={};local count=0
  -- Focus gets the first attachment slot when observing a very large surface.
  local panes={};for _,p in ipairs(self.scene.leaves)do
    if p.node.remote_id==self.scene.surface.focused_pane_id then table.insert(panes,1,p)else panes[#panes+1]=p end
  end
  for _,p in ipairs(panes)do
    local v=p.view
    if v and v.kind=='terminal' and p.w>0 and p.h>1 and count<32 then
      count=count+1;wanted[v.id]=true
      if not self.remotes[v.id]then
        self.remotes[v.id]=Remote.new({socket=self.opts.socket,token=self.opts.token,id=v.terminal_id,generation=v.generation,tail=256},function()self.dirty=true end)
      end
      local remote=self.remotes[v.id]
      if remote:can_control()then
        remote:resize(math.max(1,p.w),math.max(1,p.h-1))
        local focused=p.node.remote_id==self.scene.surface.focused_pane_id
        if remote.ctui_focused~=focused then remote.ctui_focused=focused;remote:event('focus',focused)end
      else remote.ctui_focused=nil end
    end
  end
  for id,remote in pairs(self.remotes)do if not wanted[id]then remote:close();self.remotes[id]=nil;self.scroll[id]=nil end end
end
function App:active()
  local s=self.scene;local v=s and s.focused and s.focused.active_view
  return v and self.remotes[v.id],v
end
function App:command(op,args,done)
  if self.closed then return end
  self.client:command(op,args,function(why,snapshot)
    if why then self.inputs={};self.input_bytes=0;self.prefix=false end
    self.message=why and why.message or nil;self.dirty=true
    if done then done(why,snapshot)end
  end)
end
function App:where(extra)
  local s=self.scene
  if not s or not s.surface then return end
  local out={workspace_id=s.workspace.id,surface_id=s.surface.id}
  for k,v in pairs(extra or {})do out[k]=v end
  return out
end
function App:focus(pane,view)
  if pane then self:command('pane_focus',self:where{pane_id=pane.remote_id,view_id=view and view.id})end
end
function App:cycle(collection,selected)
  for i,item in ipairs(collection)do if item.id==selected then return collection[i%#collection+1]end end
end
function App:new_terminal(direction)
  if self.creating or self.client.status~='live' or self.client.busy then return end
  if not self.scene.surface then
    self:command('workspace_create',{title='Workspace'},function(why)
      if not why then self:arrange(self.scene.width,self.scene.height);self:new_terminal(direction)end
    end);return
  end
  self.creating=true
  local target=self:where{pane_id=self.scene.focused.remote_id}
  self.client.transport:request('POST','/terminals',{cols=80,rows=24,history=2000},function(why,record)
    self.creating=false;if self.closed then return end
    if why then self.message=why.message;self.dirty=true;return end
    target.view={kind='terminal',terminal_id=record.id,generation=record.generation}
    if direction then target.direction=direction end
    self:command(direction and 'pane_split'or 'view_add',target,function(error)
      if error then self.message='Terminal retained: '..record.id..' (attach explicitly after refresh). '..error.message end
    end)
  end)
end
function App:action(key)
  self.message=nil
  local scene=self.scene;local pane=scene and scene.focused;local remote,v=self:active()
  if key=='q'then self.done=true;return end
  if key=='?'then self.help=not self.help;return end
  if key=='r'then
    if self.client.watch then self.client:refresh()else self.client:start()end
    for _,r in pairs(self.remotes)do r:reconnect()end;return
  end
  if key=='t'or key=='%'or key=='"'then self:new_terminal(key=='%' and 'right'or key=='"' and 'down'or nil);return end
  if key=='W'then self:command('workspace_create',{title='Workspace'});return end
  if not pane then return end
  if key=='c'or key=='!'then if remote then remote:control(key=='!')end
  elseif key=='v'then if remote then remote:view_only()end
  elseif key=='u'then if remote then remote:retry()end
  elseif key=='z'then self:command('pane_zoom',self:where{pane_id=pane.remote_id})
  elseif key=='='then self:command('balance',self:where())
  elseif key=='x'and v then self:command('view_close',self:where{pane_id=pane.remote_id,view_id=v.id})
  elseif key=='n'or key=='p'then
    local leaves=(scene.root.zoomed or scene.root):get_leaves()
    for i,leaf in ipairs(leaves)do if leaf.remote_id==pane.remote_id then self:focus(leaves[(i-1+(key=='n'and 1 or -1))%#leaves+1]);break end end
  elseif key=='['or key==']'then
    for i,item in ipairs(pane.views)do if item==pane.active_view then self:focus(pane,pane.views[(i-1+(key==']'and 1 or -1))%#pane.views+1]);break end end
  elseif ({h='left',j='down',k='up',l='right'})[key]then
    self:focus(pane:get_node_in_direction(scene.root.zoomed or scene.root,({h='left',j='down',k='up',l='right'})[key]))
  elseif key=='w'then
    local next=self:cycle(self.client:view().workspaces,scene.workspace.id)
    if next then self:command('workspace_select',{workspace_id=next.id})end
  elseif key=='s'then
    local next=self:cycle(scene.workspace.surfaces,scene.surface.id)
    if next then self:command('surface_select',{workspace_id=scene.workspace.id,surface_id=next.id})end
  elseif key=='S'then self:command('surface_create',{workspace_id=scene.workspace.id,title='Surface'})
  end
end
local aliases={esc='escape',pageup='page_up',pagedown='page_down'}
function M.key(event)
  local mods=(event.shift and terminal.SHIFT or 0)|(event.alt and terminal.ALT or 0)|(event.ctrl and terminal.CTRL or 0)
  if event.key=='char'or event.key=='ctrl'then
    local ch=event.char;local scalar=utf8.codepoint(ch)
    if event.key=='ctrl'then mods=mods|terminal.CTRL end
    return {key='text',action='press',modifiers=mods,unshifted=scalar,base_layout=scalar,
      text=event.key=='char' and ch or '',option_as_alt='all'}
  end
  return {key=aliases[event.key]or event.key,action='press',modifiers=mods,option_as_alt='all'}
end
function App:_input(e)
  self.dirty=true
  local remote,v=self:active()
  if self.help and e.type~='key'then return end
  if e.type=='resize'then return end
  if e.type=='key'then
    local prefix=e.key=='ctrl' and e.char=='b'
    if self.prefix then
      self.prefix=false
      if not prefix then self:action(e.char or e.key);return end
    elseif prefix then self.prefix=true;return end
    if self.help then if e.key=='esc'then self.help=false end;return end
    if (e.key=='pageup'or e.key=='pagedown')and remote and remote.snapshot then
      self.scroll[v.id]=math.max(0,math.min(#remote.snapshot.scrollback.rows,(self.scroll[v.id]or 0)+(e.key=='pageup' and 10 or -10)));return
    end
    if remote and remote:can_control()then self.scroll[v.id]=0;remote:event('key',M.key(e))
    else self.message='Read-only. Ctrl-B c takes control; Ctrl-B ! explicitly takes over.'end
  elseif e.type=='paste'and remote then
    if not remote:event('paste',e.text)then self.message='Paste needs input control: Ctrl-B c' end
  elseif e.type=='mouse'then
    for _,p in ipairs(self.scene.leaves)do
      if e.mx>=p.x and e.mx<p.x+p.w and e.my>=p.y and e.my<p.y+p.h then
        if p.node.remote_id~=self.scene.surface.focused_pane_id then self:focus(p.node);return end
        local button=e.button&3;local wheel=e.button&64~=0
        if remote and e.my>p.y and remote:can_control()and remote:input_state().mouse_mode~='none' then
          remote:event('mouse',{action=button==3 and not wheel and 'release'or 'press',button=wheel and (button==0 and 4 or 5)or (button==3 and 1 or button+1),
            x=e.mx-p.x,y=e.my-p.y-1,cell_width=1,cell_height=1,modifiers=0,any_button_pressed=button~=3 and not wheel})
        elseif wheel and remote and remote.snapshot then
          self.scroll[v.id]=math.max(0,math.min(#remote.snapshot.scrollback.rows,(self.scroll[v.id]or 0)+(button==0 and 3 or -3)))
        end
        return
      end
    end
  end
end
function App:input(e)
  if e.type=='resize'then self:arrange(e.w,e.h);self.dirty=true;return end
  local bytes=#(e.text or '')+#(e.char or '')+32
  if #self.inputs>=128 or self.input_bytes+bytes>1024*1024 then
    self.message='Pending input queue is full';self.dirty=true;return
  end
  self.inputs[#self.inputs+1]={event=e,bytes=bytes};self.input_bytes=self.input_bytes+bytes
  self:pump_input()
end
function App:pump_input()
  while not self.closed and not self.done and not self.client.busy and not self.creating and #self.inputs>0 do
    if self.width then self:arrange(self.width,self.height)end
    local next=self.inputs[1].event
    if self.prefix and next.type=='key' and ({c=true,['!']=true,v=true,u=true})[next.char]then
      local remote=self:active()
      if remote and (remote.busy or remote:status()=='attaching' or remote:status()=='connecting')then return end
    end
    local item=table.remove(self.inputs,1);self.input_bytes=self.input_bytes-item.bytes
    self:_input(item.event)
  end
end
function App:draw(canvas)
  local w,h=canvas.size();self:arrange(w,h)
  local remote=self:active();local message=remote and remote.error and remote.error.message
  Canvas.draw(canvas,self.scene,self.remotes,{status=self.status,message=message or self.message,prefix=self.prefix,help=self.help,scroll=self.scroll})
  self.dirty=false
end
function App:close()
  if self.closed then return end;self.closed=true
  for _,remote in pairs(self.remotes)do remote:close()end;self.remotes={};self.client:close()
end
function M.run(opts)
  if not opts.socket or opts.socket==''then io.stderr:write('usage: boggart bmux --socket <private-server-socket> [--token <token>]\n');return 1 end
  if not tc.init()then tc.shutdown();io.stderr:write('Bmux needs an interactive terminal\n');return 1 end
  if not tc.attach()then tc.shutdown();io.stderr:write('Bmux needs an interactive terminal\n');return 1 end
  local app,signal
  local ok,why=xpcall(function()
    app=M.new(opts)
    signal=uv.new_signal();signal:start('sigwinch',function()tc.request_resize();app.dirty=true end)
    tc.mouse(true);app:start()
    while not app.done do
      local e=tc.poll(0)
      while e.type~='none' do app:input(e);if app.done then break end;e=tc.poll(0)end
      app:pump_input()
      if app.dirty then app:draw(tc)end
      if not app.done then uv.run('once')end
    end
  end,debug.traceback)
  if app then app:close()end
  if signal then signal:stop();signal:close()end
  tc.shutdown();uv.run('nowait')
  if not ok then io.stderr:write(tostring(why),'\n');return 1 end
  return 0
end
return M
