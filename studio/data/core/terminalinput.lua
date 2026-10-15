-- Host input policy only. Native encoders own all terminal bytes.
local protocol = require 'terminal'
local Input = {}; Input.__index = Input
local aliases = { ['return']='enter', ['keypad enter']='kp_enter', pageup='page_up', pagedown='page_down' }
local modifier_keys = {left_shift=true,right_shift=true,left_ctrl=true,right_ctrl=true,
  left_alt=true,right_alt=true,left_super=true,right_super=true}
local chord_modifiers = {shift=protocol.SHIFT,ctrl=protocol.CTRL,alt=protocol.ALT,
  altgr=protocol.ALT,cmd=protocol.SUPER}
local function copy(event)
  local out={}; for k,v in pairs(event) do out[k]=v end; return out
end
local function fallback(stroke)
  local key=stroke:match('([^+]+)$') or stroke; local mods=0
  if key=='space' then key=' ' end
  for name,bit in pairs(chord_modifiers) do if stroke:find(name..'+',1,true) then mods=mods|bit end end
  local named=aliases[key] or key
  local ok,scalar=pcall(utf8.codepoint,key)
  if ok and utf8.len(key)==1 then return {key='text',unshifted=scalar,base_layout=scalar,modifiers=mods,action='press',scancode=key} end
  return {key=named,modifiers=mods,action='press',scancode=key}
end
function Input.new(term,send,clipboard,dispatch)
  return setmetatable({term=term,send=send,clipboard=clipboard,dispatch=dispatch,held={},composing=false},Input)
end
function Input:send_event(kind,value)
  if self.dispatch then return self.dispatch(kind,value)end
  local bytes=self.term[kind](self.term,value)
  if #bytes==0 then return false end
  self.send(bytes);return true
end
function Input:emit(event)
  if event.text and #event.text>4096 then
    assert(utf8.len(event.text),'invalid committed UTF-8')
    local text=event.text; local first=true; local offset=1
    while offset<=#text do
      local limit=offset+4096
      if limit<=#text then limit=utf8.offset(text,0,limit) else limit=#text+1 end
      local part=first and copy(event) or {key='text',action='press'}
      part.text=text:sub(offset,limit-1); self:emit(part); first=false; offset=limit
    end
    return
  end
  self:send_event('key',event)
end
function Input:flush()
  local event=self.pending; self.pending=nil
  if not event then return end
  if event.text and #event.text>0 then
    -- SDL layout/IME text consumes Shift; right Alt may consume Ctrl+Alt.
    event.consumed_modifiers=(event.modifiers or 0)&protocol.SHIFT
    if ((event.right_modifiers or 0)&protocol.ALT)~=0 then
      event.consumed_modifiers=event.consumed_modifiers|((event.modifiers or 0)&(protocol.CTRL|protocol.ALT))
    end
  end
  self:emit(event)
end
function Input:key_pressed(stroke,metadata)
  if stroke:find('ctrl+alt+',1,true) then return false end
  self:flush()
  if stroke=='cmd+v' or stroke=='ctrl+shift+v' then
    local text=self.clipboard and self.clipboard()
    if text and #text>0 then self:send_event('paste',text) end
    return true,true
  end
  local event=metadata and copy(metadata) or fallback(stroke)
  local id=event.scancode or event.key; self.held[id]=copy(event)
  event.option_as_alt='none'
  if self.composing and not modifier_keys[event.key] then event.composing=true; self:emit(event)
  elseif event.key=='text' or event.key:match('^kp_') then self.pending=event
  else self:emit(event) end
  return true,false
end
function Input:key_released(metadata)
  if not metadata then return end
  self:flush()
  local id=metadata.scancode or metadata.key
  if not self.held[id] then return end
  self.held[id]=nil; local event=copy(metadata); event.action='release'; event.text=''; event.option_as_alt='none'
  self:emit(event)
end
function Input:text_input(text)
  if #text==0 then return end
  self.composing=false
  if self.pending and not self.pending.composing then self.pending.text=(self.pending.text or '')..text
  else self:emit{key='text',action='press',text=text} end
end
function Input:text_editing(text)
  self.composing=#text>0
  if self.composing and self.pending then self.pending.composing=true end
end
function Input:focus(focused)
  self:flush()
  if not focused then
    for _,held in pairs(self.held) do
      local event=copy(held); event.action='release'; event.modifiers=0; event.right_modifiers=0; event.text=''
      self:emit(event)
    end
    self.held={}; self.composing=false
  end
  self:send_event('focus',focused)
end
function Input:mouse(event)
  return self:send_event('mouse',event)
end
return Input
