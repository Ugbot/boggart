-- Validate an entire native wire frame before replacing an independent view.
local json=require 'json';local M={};local Replica={};Replica.__index=Replica
local MAX=9007199254740991
local function need(ok,message)if not ok then error(message,0)end end
local function int(n,lo,hi)return type(n)=='number' and n%1==0 and n>=lo and n<=hi end
local function object(t)need(type(t)=='table' and getmetatable(t)==nil,'expected plain object');return t end
local function text(s,limit)need(type(s)=='string' and #s<=limit,'invalid text');return s end
local function boolean(b)need(type(b)=='boolean','invalid boolean');return b end
local function number(n,lo,hi)need(int(n,lo,hi),'invalid integer');return n end
local function array(t,limit)
  object(t);local n=#t;need(n<=limit,'array limit exceeded')
  local count=0;for key in pairs(t)do need(int(key,1,n),'invalid array index');count=count+1 end
  need(count==n,'sparse array');return n
end
local function identifier(s)text(s,128);need(s:match('^[%w_-]+$'),'invalid identifier');return s end
local function scalar(n)return int(n,0,0x10ffff) and not(n>=0xd800 and n<=0xdfff)end
local function style(s)
  object(s);return {fg=number(s.fg,0,0xffffffff),bg=number(s.bg,0,0xffffffff),
    underline=number(s.underline,0,0xffffffff),attrs=number(s.attrs,0,0xffffffff)}
end
local function row(r,cols)
  object(r);need(array(r.cells,4096)==cols,'wrong row width');local cells={}
  for x,c in ipairs(r.cells)do
    object(c);local cluster=text(c.text,65536)
    need(utf8.len(cluster)~=nil and scalar(c.codepoint),'invalid Unicode cell')
    local out={text=cluster,codepoint=c.codepoint,width=number(c.width,0,2),flags=number(c.flags,0,255),
      hyperlink=number(c.hyperlink,0,0xffffffff),style=style(c.style)}
    if c.link~=nil then object(c.link);out.link={id=text(c.link.id,65536),uri=text(c.link.uri,65536)}end
    need((out.hyperlink==0)==(out.link==nil),'invalid hyperlink')
    cells[x]=out
  end
  return {wrapped=boolean(r.wrapped),cells=cells}
end
local function state(s,cols,rows)
  object(s);local out={row=number(s.row,1,rows),col=number(s.col,1,cols),top=number(s.top,1,rows),bottom=number(s.bottom,1,rows),
    modes=number(s.modes,0,0xffffffff),cursor_style=number(s.cursor_style,0,0xffffffff),
    alternate=boolean(s.alternate),pending_wrap=boolean(s.pending_wrap),pen=style(s.pen)}
  need(out.top<=out.bottom,'invalid scroll region');return out
end
local function process(p,id,generation,cols,rows)
  object(p);need(p.id==id and p.generation==generation and p.cols==cols and p.rows==rows,'process identity/geometry mismatch')
  need(p.state=='alive' or p.state=='failed' or p.state=='exited' or p.state=='stopped' or p.state=='starting','invalid process state')
  local out={id=id,generation=generation,cols=cols,rows=rows,state=p.state,
    cmd=text(p.cmd,4096),cwd=text(p.cwd,4096),history=number(p.history,0,100000),
    bytes=number(p.bytes,0,MAX),queued_bytes=number(p.queued_bytes,0,MAX),revision=number(p.revision,0,MAX),
    closed=boolean(p.closed),attachment_controlled=boolean(p.attachment_controlled)}
  for _,key in ipairs{'pid','exit_status','term_signal'}do if p[key]~=nil then out[key]=number(p[key],-MAX,MAX)end end
  for _,key in ipairs{'process_exited','eof'}do if p[key]~=nil then out[key]=boolean(p[key])end end
  for _,key in ipairs{'error','push_error'}do if p[key]~=nil then out[key]=text(p[key],65536)end end
  return out
end
local function input_state(input)
  object(input)
  local modes={none=true,x10=true,normal=true,button=true,any=true}
  local formats={x10=true,utf8=true,sgr=true,urxvt=true,pixels=true}
  need(type(input.mouse_mode)=='string' and modes[input.mouse_mode] and type(input.mouse_format)=='string' and formats[input.mouse_format],'invalid mouse mode')
  local out={mouse_mode=input.mouse_mode,mouse_format=input.mouse_format,kitty_flags=number(input.kitty_flags,0,31)}
  for _,key in ipairs{'backarrow','ignore_keypad_numlock','alt_prefix','modify_other_keys_2','bracketed_paste','focus_reporting','focused'}do out[key]=boolean(input[key])end
  return out
end
function M.new(id,generation)
  identifier(id);number(generation,1,MAX)
  return setmetatable({id=id,generation=generation,view={cursor=0}},Replica)
end
function Replica:validate(frame)
  object(frame);need(frame.v==1 and frame.id==self.id and frame.generation==self.generation,'terminal frame identity mismatch')
  local aid=identifier(frame.attachment_id);need(not self.attachment_id or aid==self.attachment_id,'attachment identity mismatch')
  local cursor=number(frame.cursor,1,MAX);local after=number(frame.after,0,MAX)
  need(frame.kind=='snapshot' or frame.kind=='delta' or frame.kind=='unchanged','invalid terminal frame kind')
  if frame.kind=='unchanged'then
    need(self.view.cursor>0 and cursor==self.view.cursor and after==cursor,'invalid unchanged cursor');return self.view,false
  end
  need(cursor==after+1,'invalid terminal cursor step')
  if cursor<=self.view.cursor then return self.view,false end -- duplicate immutable retry
  need(after==self.view.cursor,'gap in terminal cursors; reattach')
  local cols,rows=number(frame.cols,1,4096),number(frame.rows,1,4096)
  need(cols*rows<=32768,'image cell limit exceeded')
  local out={id=self.id,generation=self.generation,attachment_id=aid,cursor=cursor,cols=cols,rows=rows}
  if frame.kind=='snapshot'then
    need(array(frame.screen,4096)==rows,'wrong screen height');out.screen={}
    for y,r in ipairs(frame.screen)do out.screen[y]=row(r,cols)end
  else
    need(self.view.cursor>0 and cols==self.view.cols and rows==self.view.rows,'delta geometry mismatch')
    array(frame.changes,rows);out.screen={table.unpack(self.view.screen)};local seen={}
    for _,change in ipairs(frame.changes)do
      object(change);local y=number(change.index,1,rows);need(not seen[y],'duplicate damage row');seen[y]=true
      out.screen[y]=row(change.row,cols)
    end
  end
  if frame.scrollback==false then
    need(frame.kind=='delta','snapshot requires scrollback');out.scrollback=self.view.scrollback
  else
    local h=object(frame.scrollback);local n=array(h.rows,256);local total=number(h.total,0,100000)
    need(total>=n and h.first==total-n+1 and cols*(rows+n)<=32768,'invalid history window')
    out.scrollback={first=h.first,total=total,rows={}}
    for i,r in ipairs(h.rows)do out.scrollback.rows[i]=row(r,cols)end
  end
  need(cols*(rows+#out.scrollback.rows)<=32768,'image cell limit exceeded')
  out.state=state(frame.state,cols,rows)
  need(frame.kind=='snapshot' or out.state.alternate==self.view.state.alternate,'delta changed screen buffer')
  out.process=process(frame.process,self.id,self.generation,cols,rows)
  if frame.input_state~=nil then out.input_state=input_state(frame.input_state)
  else need(self.view.input_state==nil,'input mode state missing')end
  need(out.scrollback.total<=out.process.history,'history exceeds capacity')
  return out,true
end
function Replica:apply(frame)
  local ok,out,changed=pcall(self.validate,self,frame)
  if not ok then return nil,{kind='protocol',message=tostring(out):sub(1,256)}end
  if changed then self.view=out;self.attachment_id=out.attachment_id end
  return changed
end
-- Native codec bounds nesting in C (MAX_DEPTH); bound the Lua fallback before
-- entering its recursive decoder. Avoid scanning every native JSON byte in Lua.
function M.decode(raw)
  if type(raw)~='string' or #raw>4*1024*1024 then return nil,{kind='protocol',message='frame size limit exceeded'}end
  if not raw:match('^%s*{')then return nil,{kind='protocol',message='expected JSON object'}end
  if not json.c or json.decode==json.lua_decode then
    local quoted,escape,depth=false,false,0
    for i=1,#raw do
      local c=raw:byte(i)
      if quoted then if escape then escape=false elseif c==92 then escape=true elseif c==34 then quoted=false end
      elseif c==34 then quoted=true
      elseif c==123 or c==91 then depth=depth+1;if depth>32 then return nil,{kind='protocol',message='frame nesting limit exceeded'}end
      elseif c==125 or c==93 then depth=depth-1 end
    end
  end
  local ok,value=pcall(json.decode,raw)
  if not ok or type(value)~='table' then return nil,{kind='protocol',message='invalid JSON object'}end
  return value
end
return M
