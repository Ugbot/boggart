-- Native terminal pane: C owns PTY bytes, parsing, grids and scrollback.
-- Lua owns layout, input policy and presentation of visible/damaged rows.
local core=require 'core'
local common=require 'core.common'
local style=require 'core.style'
local keymap=require 'core.keymap'
local View=require 'core.view'
local terminal=require 'terminal'
local Input=require 'core.terminalinput'
local TerminalView=View:extend()
local PALETTE={
  [0]={common.color '#3f3f46'},[8]={common.color '#6b6b72'},
  [1]={common.color '#F77483'},[9]={common.color '#ff8f9c'},
  [2]={common.color '#7FB77E'},[10]={common.color '#96d194'},
  [3]={common.color '#FFA94D'},[11]={common.color '#ffc06b'},
  [4]={common.color '#93DDFA'},[12]={common.color '#b0e6ff'},
  [5]={common.color '#E58AC9'},[13]={common.color '#f0a8de'},
  [6]={common.color '#f7c95c'},[14]={common.color '#ffe08a'},
  [7]={common.color '#e1e1e6'},[15]={common.color '#ffffff'},
}
local cube={0,95,135,175,215,255}
local function color(value,bold)
  if not value or value==0 then return nil end
  if (value&terminal.COLOR_RGB)~=0 then return {(value>>16)&255,(value>>8)&255,value&255,255} end
  local index=value&255
  if index<16 then return PALETTE[bold and index<8 and index+8 or index] end
  if index>=232 then local level=8+(index-232)*10; return {level,level,level,255} end
  local n=index-16; return {cube[math.floor(n/36)+1],cube[math.floor(n/6)%6+1],cube[n%6+1],255}
end
function TerminalView:new(opts)
  TerminalView.super.new(self); opts=opts or {}; self.raw_keys=true; self.scrollable=true
  self.font=style.code_font; self.cw=self.font:get_width('M'); self.lh=self.font:get_height()
  self.cols,self.rows,self.history_rows=opts.cols or 80,opts.rows or 24,0
  self.last_size={x=0,y=0}; self.revision=-1
  self.mouse_buttons={}; self.custom_title=opts.title
  local cmd=opts.cmd or os.getenv('SHELL') or '/bin/sh'; self.title=opts.title or cmd:match('([^/]+)$') or 'terminal'
  self.owns_terminal=opts.terminal==nil; self.terminal=opts.terminal
  if opts.attachment then
    assert(not opts.terminal,'choose a local terminal or remote attachment')
    self.remote=require('core.terminalremote').new(opts.attachment,function()
      if self.remote and self.input then
        local controlling=self.remote:can_control()
        if controlling~=self.controlling then
          self.controlling=controlling
          self.input.pending=nil;self.input.held={};self.input.composing=false
          self.mouse_buttons={}
          if controlling then
            if core.active_view==self then self:on_focus_gained()else self:on_window_focus(false)end
          end
        end
      end
      core.redraw=true
    end)
    self.terminal=self.remote;self.remote_header=require('core.terminalremoteheader').new(self.remote)
  end
  if not self.terminal then
    local env=opts.bmux_context and require('core.manualagents').attach(self,opts.cwd,opts.fleet_agent) or opts.env
    local t,err=terminal.open{cmd=cmd,args=opts.args,cwd=opts.cwd,env=env,control=opts.control,cols=self.cols,rows=self.rows,history=opts.history or 2000}
    self.terminal=t; if not t then self.dead=true; self.spawn_error=err end
    if not t and self.manual_pane then require('core.manualagents').revoke(self)end
  end
  self.send_override=opts.send
  if self.terminal then
    self.render_theme={foreground=style.text,background=style.background,palette=PALETTE}
    self.render_context=renderer.new_terminal(self.font,self.remote and self.remote.image or self.terminal,self.render_theme)
    self.input=Input.new(self.terminal,function(bytes) return self:send(bytes) end,system.get_clipboard,
      self.remote and function(kind,value)
        local accepted=self.remote:event(kind,value)
        if accepted and (kind=='key' or kind=='paste')then self:scroll_to_bottom()end
        return accepted
      end)
    self.terminal:focus(false); self:sync(true)
  end
end
function TerminalView:get_name() return self.title..(self.dead and ' [exited]' or '') end
function TerminalView:is_text_input() return not self.dead and (not self.remote or self.remote:can_control()) end
function TerminalView:try_close(close)
  if self.manual_pane then require('core.manualagents').revoke(self)end
  if self.terminal and self.owns_terminal then self.terminal:close() end
  if self.render_context then getmetatable(self.render_context).__close(self.render_context)end
  self.terminal=nil; self.input=nil; self.render_context=nil; close()
end
function TerminalView:send(bytes)
  if self.dead or not self.terminal or #bytes==0 or self.remote and not self.remote:can_control()then return false end
  if self.send_override then return self.send_override(bytes) end
  local n,err=self.terminal:write(bytes)
  if not n then self.spawn_error=err; core.redraw=true; return false end
  self:scroll_to_bottom(); return true
end
function TerminalView:on_key_pressed(stroke,event)
  if self.dead or not self.input then return false end
  if self.remote and not self.remote:can_control()then return not stroke:find('ctrl+alt+',1,true),true end
  return self.input:key_pressed(stroke,event)
end
function TerminalView:on_key_released(key,event) if not self.dead and self.input then self.input:key_released(event) end end
function TerminalView:on_text_input(text) if not self.dead and self.input then self.input:text_input(text) end end
function TerminalView:on_text_editing(text) if not self.dead and self.input then self.input:text_editing(text) end end
function TerminalView:flush_input() if not self.dead and self.input then self.input:flush() end end
function TerminalView:on_window_focus(focused) if self.input and not self.dead then self.input:focus(focused) end end
function TerminalView:on_focus_lost() self:on_window_focus(false) end
function TerminalView:on_focus_gained()
  local focused=core.window_focused; if focused==nil then focused=system.window_has_focus() end
  self:on_window_focus(focused)
end
function TerminalView:resize_to_fit()
  -- New/hidden views have no layout yet. Keep the initial PTY geometry until
  -- they do: a transient 1x1 resize can put applications into a startup pager.
  if self.size.x<=0 or self:body_height()<=0 then return end
  local cols=common.clamp(math.floor(self.size.x/self.cw),1,4096)
  local rows=common.clamp(math.floor(self:body_height()/self.lh),1,4096)
  if self.remote then self.remote:resize(cols,rows);return end
  if cols==self.cols and rows==self.rows then return end
  if self.terminal then self.terminal:resize(cols,rows) end
  self.cols,self.rows=cols,rows; self:sync(true)
end
function TerminalView:header_height()return self.remote_header and self.remote_header:height(self.size.x) or 0 end
function TerminalView:body_height()return math.max(0,self.size.y-self:header_height())end
function TerminalView:get_scrollable_size()
  if self.remote then return self:header_height()+self.history_rows*self.lh+math.max(self.rows*self.lh,self:body_height())end
  return (self.history_rows+self.rows)*self.lh
end
function TerminalView:at_bottom() return self.scroll.to.y>=self:get_scrollable_size()-self.size.y-self.lh end
function TerminalView:scroll_to_bottom() self.scroll.to.y=math.max(0,self:get_scrollable_size()-self.size.y) end
function TerminalView:sync(force)
  if not self.terminal then return end
  local revision=self.terminal:process_revision(); if not force and revision and revision==self.revision then return end
  local was_bottom=not self.state or self:at_bottom(); local state=self.terminal:state()
  if not state then self.revision=revision;core.redraw=true;return end
  local cols,rows,history=self.terminal:geometry()
  local geometry_changed=cols~=self.cols or rows~=self.rows or history~=self.history_rows or (self.state and self.state.alternate~=state.alternate)
  self.cols,self.rows,self.history_rows=cols,rows,history; self.state=state; self.revision=revision
  local damaged=self.terminal:damage()
  self.terminal:ack_damage()
  local process=self.terminal:process_state()
  if process then self.dead=process.exited and process.eof; if process.error then self.spawn_error=process.error end end
  local events,dropped=self.terminal:events(); self.dropped_events=(self.dropped_events or 0)+dropped
  for _,event in ipairs(events) do
    if event.type=='title' and not self.custom_title then self.title=event.text
    elseif event.type=='cwd' then self.cwd=event.text
    elseif event.type=='bell' then self.bell=true
    elseif event.type=='notification' then self.notification=event end
  end
  if force or geometry_changed or #damaged>0 or process then core.redraw=true end
  if was_bottom or (state.alternate and geometry_changed) then self:scroll_to_bottom() end
end
function TerminalView:update()
  TerminalView.super.update(self)
  local header=self:header_height()
  if self.size.x~=self.last_size.x or self.size.y~=self.last_size.y or header~=self.last_header_height then
    self.last_size.x,self.last_size.y=self.size.x,self.size.y
    self.last_header_height=header
    if self.cw>0 and self.lh>0 then self:resize_to_fit() end
  end
  self:sync(false)
end
local buttons={left=1,middle=2,right=3,x1=8,x2=9}
function TerminalView:report_mouse(action,button,x,y)
  if self.dead or not self.input or not self:at_bottom() then return false end
  if y<self.position.y+self:header_height()then return false end
  local pressed=false; for _,down in pairs(self.mouse_buttons) do if down then pressed=true end end
  return self.input:mouse{action=action,button=button or 0,x=math.floor(x-self.position.x),y=math.floor(y-self.position.y-self:header_height()),
    cell_width=math.max(1,math.floor(self.cw)),cell_height=math.max(1,math.floor(self.lh)),
    modifiers=(keymap.input_modifiers or 0)&7,any_button_pressed=pressed}
end
function TerminalView:on_mouse_pressed(button,x,y,clicks)
  if self.remote_header and y<self.position.y+self:header_height()then
    self.remote_header:pressed(button,x,y);return true
  end
  if TerminalView.super.on_mouse_pressed(self,button,x,y,clicks) then return true end
  local number=buttons[button]; if not number then return false end
  self.mouse_buttons[number]=true; return self:report_mouse('press',number,x,y)
end
function TerminalView:on_mouse_released(button,x,y)
  TerminalView.super.on_mouse_released(self,button,x,y)
  local number=buttons[button]; if number then self.mouse_buttons[number]=nil; self:report_mouse('release',number,x,y) end
end
function TerminalView:on_mouse_moved(x,y,dx,dy)
  if self.remote_header then self.remote_header.mouse={x=x,y=y}end
  TerminalView.super.on_mouse_moved(self,x,y,dx,dy)
  if not self.dragging_scrollbar then
    local number=0; for b,down in pairs(self.mouse_buttons) do if down then number=b; break end end
    self:report_mouse('motion',number,x,y)
  end
end
function TerminalView:on_mouse_wheel(amount,x,y,horizontal)
  x,y=x or self.position.x,y or self.position.y; local reported=false
  local reporting=self.terminal and self:at_bottom() and self.terminal:input_state().mouse_mode~='none'
  if not reporting then TerminalView.super.on_mouse_wheel(self,amount); return end
  self.wheel_y=(self.wheel_y or 0)+amount; self.wheel_x=(self.wheel_x or 0)+(horizontal or 0)
  local function ticks(value) return value>=0 and math.floor(value) or math.ceil(value) end
  local vertical,lateral=ticks(self.wheel_y),ticks(self.wheel_x)
  self.wheel_y,self.wheel_x=self.wheel_y-vertical,self.wheel_x-lateral
  for _=1,math.min(100,math.abs(vertical)) do reported=self:report_mouse('press',vertical>0 and 4 or 5,x,y) or reported end
  for _=1,math.min(100,math.abs(lateral)) do reported=self:report_mouse('press',lateral>0 and 7 or 6,x,y) or reported end
  if vertical==0 and lateral==0 then return end
  if not reported then TerminalView.super.on_mouse_wheel(self,amount) end
end
function TerminalView:resolve_colors(cell)
  local pen=cell.style; local bold=(pen.attrs&terminal.BOLD)~=0
  local fg=color(pen.fg,bold) or (bold and PALETTE[15] or style.text); local bg=color(pen.bg,false)
  if (pen.attrs&terminal.INVERSE)~=0 then fg,bg=bg or style.background,fg end
  if (pen.attrs&terminal.FAINT)~=0 then fg={math.floor(fg[1]/2),math.floor(fg[2]/2),math.floor(fg[3]/2),fg[4] or 255} end
  return fg,bg,color(pen.underline,false) or fg
end
function TerminalView:visible_row(index)
  -- Inspection only; rendering captures and caches rows entirely in C.
  if index<=self.history_rows then return self.terminal:row(index,true) end
  return self.terminal:row(index-self.history_rows)
end
function TerminalView:draw()
  self:draw_background(style.background); core.push_clip_rect(self.position.x,self.position.y,self.size.x,self.size.y)
  local header=self:header_height()
  if self.remote_header then self.remote_header:draw(self.position.x,self.position.y,self.size.x)end
  core.push_clip_rect(self.position.x,self.position.y+header,self.size.x,self:body_height())
  if self.terminal and self.state then
    local ox,oy=self:get_content_offset(); local count=self.history_rows+self.rows
    oy=oy+header
    local first=common.clamp(math.floor(self.scroll.y/self.lh)+1,1,count)
    local last=common.clamp(math.floor((self.scroll.y+self:body_height())/self.lh)+1,1,count)
    self.render_theme.foreground,self.render_theme.background=style.text,style.background
    self.render_context:draw(ox,oy,self.cw,self.lh,first,last)
    local state=self.state; local cursor=state and self.history_rows+state.row
    if state and (state.modes&terminal.CURSOR_VISIBLE)~=0 and not self.dead and cursor>=first and cursor<=last then
      local x=ox+(state.col-1)*self.cw; local y=oy+(cursor-1)*self.lh
      local caret={style.caret[1],style.caret[2],style.caret[3],core.active_view==self and 200 or 90}
      if state.cursor_style==3 or state.cursor_style==4 then renderer.draw_rect(x,y+self.lh-2,self.cw,2,caret)
      elseif state.cursor_style==5 or state.cursor_style==6 then renderer.draw_rect(x,y,2,self.lh,caret)
      else renderer.draw_rect(x,y,self.cw,self.lh,caret) end
    end
  end
  core.pop_clip_rect();core.pop_clip_rect(); self:draw_scrollbar()
  if self.spawn_error then common.draw_text(style.font,style.error,self.spawn_error,'left',self.position.x+style.padding.x,self.position.y+style.padding.y,self.size.x,self.font:get_height()) end
end
return TerminalView
