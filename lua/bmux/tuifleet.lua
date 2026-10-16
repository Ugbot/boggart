-- Fleet modal for native Bmux. All execution policy stays in fleetclient.
local Fleet=require 'bmux.fleetclient';local Source=require 'bmux.fleetsource'
local Input=require 'tui.input';local Views=require 'bmux.agentviews'
local M={};local UI={};UI.__index=UI
local profiles={{text='Boggart TUI',provider='boggart',name='Boggart TUI'},
  {text='Resume Boggart TUI',resume=true},{text='Codex',provider='codex',cmd='codex',name='Codex'},
  {text='Claude Code',provider='claude',cmd='claude',name='Claude Code'},
  {text='Custom agent command',custom=true}}
local function label(tc,x,y,text,width,selected)
  if width>0 then tc.puts(x,y,sys.cell_take(text,width),selected and '93ddfa'or 'e1e1e6',nil,selected and {bold=true}or nil)end
end
function M.new(app)return setmetatable({app=app,index=1},UI)end
function UI:note(text)self.message=text;self.app.message=text;self.app.dirty=true end
function UI:failure(why)
  self:note(why.message..(self.client.pending and '; Escape closes editor, u retries the exact command'or ''))
end
function UI:start(host)
  if self.client or self.closed then return end
  local opts=self.app.opts
  self.client=Fleet.new{socket=opts.socket,token=opts.token,host_id=host,on_change=function()
    if self.source then self.source:update()end;self.app.dirty=true
  end}
  self.source=Source.new(require('fleet').default,self.client,function(id,gen)return self:focus(id,gen)end)
  self.client:start()
end
function UI:resolve(id)
  local r=self.client and self.client:find(id)
  if r and r.terminal_id then return r.terminal_id,r.terminal_generation,r.generation end
end
function UI:refresh()
  if not self.client then return end
  if self.client.watch then self.client:refresh()else self.client:start()end
end
function UI:open(mode)
  self.mode=mode or 'fleet';self.editor=nil;self.confirm=nil;self.message=nil
  self.app.prefix=false;self.app.help=false;self.app.dirty=true
  if self.mode=='launch'then self.index=1 end
end
function UI:rows()return self.source and self.source.rows or {}end
function UI:selected()
  local rows=self:rows()
  for i,row in ipairs(rows)do if row.remote_id==self.selected_id then self.index=i;return row end end
  self.index=math.max(1,math.min(self.index,#rows));local row=rows[self.index]
  self.selected_id=row and row.remote_id;return row
end
function UI:focus(id,generation)
  local app=self.app;local r=self.client and self.client:find(id)
  if not r or r.generation~=generation or not r.terminal_id or app.client.status~='live'or app.client.busy then
    self:note('Agent presentation unavailable; refresh the layout');return nil,self.message
  end
  local snapshot=app.client:view()
  if not snapshot.selected_workspace_id then
    app:command('workspace_create',{title='Bmux'},function(why)
      if not why then app:arrange(app.width,app.height);self:focus(id,generation)end
    end);return true
  end
  local w,s,pane,view=Views.find(snapshot,r,self.client);local ops={}
  if pane then
    if snapshot.selected_workspace_id~=w.id then ops[#ops+1]={'workspace_select',{workspace_id=w.id}}end
    if w.selected_surface_id~=s.id then ops[#ops+1]={'surface_select',{workspace_id=w.id,surface_id=s.id}}end
    ops[#ops+1]={'pane_focus',{workspace_id=w.id,surface_id=s.id,pane_id=pane,view_id=view}}
  else
    ops[1]={'view_add',app:where{pane_id=app.scene.focused.remote_id,view={kind='agent',agent_id=id,title=r.name}}}
  end
  local function send(i)
    if self.closed then return end
    local current=self.client:find(id)
    if not current or current.generation~=generation then self:note('Agent runtime expired');return end
    local op=ops[i];if not op then self.mode=nil;return end
    app:command(op[1],op[2],function(why)if why then self:note(why.message)else send(i+1)end end)
  end
  send(1);return true
end
function UI:_placed(result,target)
  self.pending_launch=nil
  target.view={kind='agent',agent_id=result.agent_id}
  self.app:command('view_add',target,function(why)
    if why then self:note('Agent retained on server; use Fleet Focus: '..result.agent_id)
    else self.mode=nil end
  end)
end
function UI:launch(profile)
  local app=self.app
  if not self.client or not self.client:can_command()or app.client.status~='live'or app.client.busy or app.creating then
    self:note('Launch unavailable; refresh or explicitly retry the pending command');return
  end
  if not app.scene.surface then
    app:command('workspace_create',{title='Bmux'},function(why)
      if why then self:note(why.message)else app:arrange(app.width,app.height);self:launch(profile)end
    end);return
  end
  local target=app:where{pane_id=app.scene.focused.remote_id};self.pending_launch=target
  self.client:launch({provider=profile.provider,name=profile.name,cmd=profile.cmd,args=profile.args,
    resume_id=profile.resume_id,cols=80,rows=24,history=2000},function(why,result)
    if self.closed then return end
    if why then
      if not self.client.pending then self.pending_launch=nil end
      self:failure(why)
    else self.editor=nil;self:_placed(result,target)end
  end)
end
function UI:retry()
  if not self.client then self:note('Fleet is connecting');return end
  local target=self.pending_launch
  self.client:retry(function(why,result)
    if self.closed then return end
    if why then self:failure(why)
    elseif target then self.editor=nil;self:_placed(result,target)
    else self.editor=nil;self:note('Pending agent command acknowledged')end
  end)
end
function UI:edit(title,submit)
  self.editor={title=title,input=Input.new{completion=false},submit=submit};self.confirm=nil
end
function UI:choose(profile)
  if profile.resume then self:edit('Server Boggart session ID',function(text)
    self:launch{provider='boggart',name='Boggart TUI',resume_id=text}
  end)
  elseif profile.custom then self:edit('Server agent command (quoted arguments)',function(text)
    local ok,argv=pcall(require('agentargv').parse,text)
    if not ok then self:note(tostring(argv));return end
    local args={};for i=2,#argv do args[#args+1]=argv[i]end
    self:launch{provider='custom',cmd=argv[1],args=args,name=argv[1]:match('([^/\\]+)$')or 'Custom agent'}
  end)
  else self:launch(profile)end
end
function UI:send(row,action,payload)
  local request=self.client:command(row.remote_id,row.generation,action,payload,function(why)
    if self.closed then return end
    if why then self:failure(why)
    else self.editor=nil;self.confirm=nil;self:note('Agent command accepted')end
  end)
  return request
end
function UI:actions(row)
  local out={{key='n',text='New agent',run=function()self:open('launch')end},
    {key='R',text='Refresh',run=function()self:refresh()end}}
  if self.client and self.client.pending and not self.client.busy then
    out[#out+1]={key='u',text='Retry pending',run=function()self:retry()end}
  end
  if not row then return out end
  local id,generation=row.remote_id,row.generation
  local function valid()
    local current=self.source:find(id)
    if current~=row or current.generation~=generation then self:note('Agent action expired');return false end
    return true
  end
  for _,entry in ipairs{{'focus','Enter','Focus pane'},{'prompt','p','Send prompt'},
    {'interrupt','i','Interrupt'},{'approve','a','Approve'},{'approve','r','Reject'},{'stop','x',row.worker and 'Cancel worker'or 'Stop'}}do
    local action,key,text=table.unpack(entry);local request=row.request and row.request.id
    if row.capabilities[action]and(action~='approve'or request)then
      out[#out+1]={key=key,text=text,run=function()
        if not valid()then return end
        if action=='focus'then self:focus(id,generation)
        elseif action=='prompt'then
          local revision,session=row.input_revision,row.session_id
          self:edit('Prompt '..row.name,function(value)
            if not valid()or row.session_id~=session then self:note('Agent conversation changed; reopen the prompt');return end
            self:send(row,'prompt',{text=value,input_revision=revision})
          end)
        elseif action=='approve'then
          if not row.request or row.request.id~=request then self:note('Approval request expired');return end
          self:send(row,'approve',{request_id=request,decision=key=='r'and 'reject'or 'approve'})
        elseif action=='stop'then self.confirm={text=text..' '..row.name..'? (y confirms, Escape cancels)',run=function()
          if valid()then self:send(row,'stop')end
        end}
        else self:send(row,action)end
      end}
    end
  end
  return out
end
function UI:input(e)
  if e.type=='resize'then return end
  if self.editor then
    if e.type=='key'and(e.key=='esc'or e.key=='ctrl'and e.char=='c')then self.editor=nil;return end
    if e.type~='key'and e.type~='paste'then return end
    if e.type=='key'and e.key=='enter'and not(e.shift or e.alt or e.ctrl)then
      if not self.client or not self.client:can_command()then self:note('Agent command pending; use Escape then u to retry');return end
      self.editor.submit(self.editor.input.line);return
    end
    local box=self.editor.input
    if #(e.text or e.char or '')+#box.line>16384 then self:note('Input exceeds 16384 bytes');return end
    if e.key=='tab'or e.key=='ctrl'and(e.char=='g'or e.char=='r')then return end
    local previous,cursor=box.line,box.cursor
    if e.type=='paste'then box:paste(e.text)else box:key(e)end
    if #box.line>16384 then box:_set(previous);box.cursor=cursor;self:note('Input exceeds 16384 bytes')end
    return
  end
  if e.type=='key'and(e.key=='esc'or e.char=='q')then
    if self.confirm then self.confirm=nil else self.mode=nil end;return
  end
  if self.confirm then
    if e.type=='key'and e.char=='y'then self.confirm.run()end;return
  end
  if e.type=='mouse'then
    if e.button&64~=0 then self:move(e.button&1==0 and -1 or 1);return end
    if e.button&3~=0 then return end
    for _,hit in ipairs(self.hits or {})do
      if e.mx>=hit.x and e.mx<hit.x+hit.w and e.my==hit.y then hit.run();return end
    end;return
  end
  if e.type~='key'then return end
  if e.key=='up'or e.char=='k'then self:move(-1);return end
  if e.key=='down'or e.char=='j'then self:move(1);return end
  if e.char=='u'and self.client and self.client.pending then self:retry();return end
  if self.mode=='launch'then
    if e.key=='enter'then self:choose(profiles[self.index])end
  else
    for _,item in ipairs(self:actions(self:selected()))do
      if item.key==(e.key=='enter'and 'Enter'or e.char)then item.run();return end
    end
  end
end
function UI:move(delta)
  local count=self.mode=='launch'and #profiles or #self:rows()
  self.index=count>0 and (self.index-1+delta)%count+1 or 1
  local row=self:rows()[self.index];self.selected_id=row and row.remote_id
end
function UI:draw(tc,w,h)
  self.hits={};tc.clear()
  if w<1 or h<1 then return end
  label(tc,0,0,' Bmux | '..(self.mode=='launch'and 'New server agent'or 'Fleet')..' | '..(self.client and self.client.status or 'connecting'),w,true)
  if h<4 then label(tc,0,h-1,'Escape closes',w);return end
  label(tc,0,h-1,self.confirm and self.confirm.text or self.message
    or self.client and self.client.pending and 'u Retry pending command | Escape close'
    or 'Up/Down select | Enter focus | n new | Escape close',w,true)
  if self.editor then
    label(tc,0,1,self.editor.title,w,true)
    local lines,cy,cx=self.editor.input:visual(w)
    local from=math.max(1,cy-(h-5));local y=2
    for i=from,math.min(#lines,from+h-5)do
      local text={};for _,run in ipairs(lines[i])do text[#text+1]=run.text end
      local body=table.concat(text);label(tc,0,y,body,w)
      if i==cy and cx<w then
        local tail=body:sub(#sys.cell_take(body,cx)+1)
        local cluster=tail:sub(1,require('grapheme').next(tail,1)-1)
        tc.puts(cx,y,cluster~=''and cluster or ' ',nil,nil,{reverse=true})
      end
      y=y+1
    end
    if h>4 then label(tc,0,h-2,'Enter sends | Ctrl-J newline | Escape cancels',w)end;return
  end
  if self.mode=='launch'then
    local capacity=h-3;local first=math.max(1,self.index-capacity+1)
    for i=first,math.min(#profiles,first+capacity-1)do
      local y=i-first+1;local index=i
      label(tc,0,y,(i==self.index and '> 'or '  ')..profiles[i].text,w,i==self.index)
      self.hits[#self.hits+1]={x=0,y=y,w=w,run=function()self.index=index;self:choose(profiles[index])end}
    end;return
  end
  local row=self:selected();local actions=self:actions(row);local action_rows={};local x,y=0,0
  for _,item in ipairs(actions)do
    local text=item.key..' '..item.text..'  ';local width=math.min(w,sys.cell_width(text))
    if x+width>w then x=0;y=y+1 end
    action_rows[#action_rows+1]={x=x,y=y,text=text,width=width,run=item.run};x=x+width
  end
  local action_count=y+1;local capacity=math.max(1,h-5-action_count)
  local first=math.max(1,self.index-capacity+1)
  for i=first,math.min(#self:rows(),first+capacity-1)do
    local rec=self:rows()[i];local row_y=i-first+1;local index=i
    label(tc,0,row_y,(rec==row and '> 'or '  ')..rec.short_id..' '..rec.name..' | '..rec.state,w,rec==row)
    self.hits[#self.hits+1]={x=0,y=row_y,w=w,run=function()self.index=index;self.selected_id=rec.remote_id end}
  end
  if not row then label(tc,0,1,'No agents. Press n to launch one.',w)end
  local bottom=math.max(2,h-3-action_count)
  if row then
    label(tc,0,bottom-1,(row.request and row.request.summary or row.activity or '')..' | '..row.provider,w)
    local result=row.control_result
    label(tc,0,h-2,row.error or result and not result.accepted and result.error or ('PID '..tostring(row.pid or '?')..' | session '..tostring(row.session_id or '?')),w)
  end
  for _,item in ipairs(action_rows)do
    local yy=bottom+item.y
    if yy<h-2 then
      label(tc,item.x,yy,item.text,item.width,true)
      self.hits[#self.hits+1]={x=item.x,y=yy,w=item.width,run=item.run}
    end
  end
end
function UI:close()
  if self.closed then return end;self.closed=true
  if self.source then self.source:close()end
  if self.client then self.client:close()end
end
return M
