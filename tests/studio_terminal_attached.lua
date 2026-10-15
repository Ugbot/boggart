-- Visible front door and real SDL events against a server-owned native PTY.
local application=require 'core'
application.add_thread(function()
  local uv=require 'uv';local proc=require 'proc';local C=require 'terminal.client';local terminal=require 'terminal'
  local core=require 'core';local command=require 'core.command';local style=require 'core.style';local View=require 'core.terminalview'
  local config=require 'core.config';local attach=require 'core.terminalattach';local ws=require 'shell.workspaces.bmux'
  local daemon,client,view,second;local original_config=config.bmux_server
  local function q(s)return "'"..s:gsub("'","'\\''").."'"end
  local function read(path)local f=io.open(path,'rb');if not f then return ''end;local s=f:read('a');f:close();return s end
  local function tick()core.redraw=true;coroutine.yield(0)end
  local function await(check)
    local deadline=system.get_time()+7
    repeat tick();if check()then return end until system.get_time()>deadline
    error('attached SDL deadline; view='..tostring(core.active_view:get_name())..'; command='..core.command_view:get_text()..'; remote='..tostring(view and view.remote and view.remote:status())..': '..(daemon and daemon:result().out or ''))
  end
  local function good(fn)
    local done,why,result=false;fn(function(e,v)done=true;why=e;result=v end)
    await(function()return done end);assert(not why,why and why.message);return result
  end
  local function key(name,mods)
    local modifiers={{terminal.SHIFT,'Left Shift'},{terminal.CTRL,'Left Ctrl'},{terminal.ALT,'Left Alt'},{terminal.SUPER,'Left GUI'}}
    for _,m in ipairs(modifiers)do if mods and mods&m[1]~=0 then system._test_event{type='keypressed',key=m[2],modifiers=mods}end end
    system._test_event{type='keypressed',key=name,modifiers=mods or 0}
    system._test_event{type='keyreleased',key=name,modifiers=mods or 0}
    for _,m in ipairs(modifiers)do if mods and mods&m[1]~=0 then system._test_event{type='keyreleased',key=m[2],modifiers=0}end end
  end
  local function text(s)
    system._test_event{type='keypressed',key='E'};system._test_event{type='textinput',text=s};system._test_event{type='keyreleased',key='E'}
  end
  local function click(x,y)
    system._test_event{type='mousepressed',button=1,x=math.floor(x),y=math.floor(y)}
    system._test_event{type='mousereleased',button=1,x=math.floor(x),y=math.floor(y)}
  end
  local function action(v,label)
    local hit
    await(function()
      for _,r in ipairs(v.remote_header.hits)do if r.item.label==label and not r.item.dim then hit=r;return true end end
    end)
    click(hit.x+hit.w/2,hit.y+hit.h/2);tick()
  end
  local function idle(v)await(function()return not v.remote.busy and v.remote.head>v.remote.tail end)end
  local function close(v)if v and v.terminal then v:try_close(function()end)end end
  local function local_count()
    local n=0;for _,leaf in ipairs(core.root_view.root_node:get_leaves())do for _,v in ipairs(leaf.views)do
      if v:is(View) and not v.remote then n=n+1 end
    end end;return n
  end
  local function pixels(path,x,y,width,height)
    local bmp=read(path);local start=string.unpack('<I4',bmp,11);local bw=string.unpack('<i4',bmp,19);local bh=string.unpack('<i4',bmp,23)
    local bits=string.unpack('<I2',bmp,29);assert(bits==24 or bits==32);local size=bits//8;local stride=((bw*bits+31)//32)*4;local out={}
    for row=y,y+height-1 do
      local offset=start+(bh>0 and bh-1-row or row)*stride+x*size+1
      out[#out+1]=bmp:sub(offset,offset+width*size-1)
    end
    return table.concat(out)
  end
  local ok,err=xpcall(function()
    local dir=assert(uv.fs_mkdtemp('/tmp/bmux-attached-XXXXXX'));local socket=dir..'/sock';local input=dir..'/input'
    assert(uv.fs_mkdir(dir..'/home',448))
    daemon=proc.start('exec env HOME='..q(dir..'/home')..' BOGGART_HOME='..q(dir..'/home/.boggart')..' '
      ..q(require('core.agentlauncher').boggart_command())..' serve --socket '..q(socket),45)
    await(function()local s=uv.fs_lstat(socket);return s and s.mode&63==0 end)
    client=C.new{socket=socket}
    local ready,probing=false,false
    await(function()
      if ready then return true end
      if not probing then probing=true;client:request('GET','/health',nil,function(e,v)probing=false;ready=not e and v.ok==true end)end
    end)
    local script="stty raw -echo; i=0; while [ $i -lt 80 ]; do printf '\\033[32mhistory-日é 🦊\\033[0m\\r\\n'; i=$((i+1)); done; printf "
      ..q('\27[?1;2004;1004;1000;1006hREADY 👩‍💻')..'; cat >'..q(input)
    local record=good(function(cb)client:request('POST','/terminals',{cmd='/bin/sh',args={'-c',script},cols=80,rows=8,history=128},cb)end)
    config.bmux_server={socket=socket};local before=local_count()
    assert(command.perform('terminal:attach'));assert(core.command_view:get_text()==socket)
    key('Return');await(function()return core.active_view==core.command_view and core.command_view.label=='Attach terminal: 'end)
    text(record.id);await(function()return #core.command_view.suggestions==1 and core.command_view.suggestions[1].record end)
    key('Return');await(function()view=core.active_view;return view:is(View) and view.remote and view.remote:status()=='read-only' and view.state end)
    assert(local_count()==before,'first attached Bmux entry does not spawn a local shell')
    assert(view.owns_terminal and view.render_context and view.remote.image and view.history_rows>0)
    assert(view.remote:process_state().pid==record.pid);local pid=record.pid
    local found=false;for _,r in ipairs(ws.toolbar.hits)do if r.item.command=='terminal:attach'then found=true end end;assert(found,'visible Attach toolbar action')
    await(function()return uv.fs_stat(input)end);local baseline=#read(input)
    key('A');text('FORBIDDEN');tick();tick();assert(#read(input)==baseline and view.cols==80 and view.rows==8,'read-only SDL input/resize has no effect')
    system._test_event{type='focus',focused=1};tick();action(view,'Take control')
    await(function()return view.remote:can_control() and not view.remote.busy and view.cols==view.remote.desired.cols and view.rows==view.remote.desired.rows end)
    idle(view);baseline=#read(input)
    system._test_event{type='focus',focused=0};tick();system._test_event{type='focus',focused=1};tick()
    key('Up');tick();idle(view)
    local prefix='\27[O\27[I\27OA';await(function()return #read(input)>=baseline+#prefix end)
    local composing_bytes=#read(input)
    system._test_event{type='keypressed',key='E'};system._test_event{type='textediting',text='´'};tick();idle(view)
    assert(#read(input)==composing_bytes,'IME preedit does not send committed text')
    text('é👩‍💻');key('C',terminal.CTRL)
    view.input.clipboard=function()return 'paste\n'end;key('V',terminal.SUPER)
    local x=view.position.x+view.cw*2+1;local y=view.position.y+view:header_height()+view.lh*2+1
    assert(view:at_bottom(),'first attachment and typing follow the live screen')
    click(x,y);tick();idle(view)
    local wanted='\27[O\27[I\27OAé👩‍💻\3\27[200~paste\n\27[201~\27[<0;3;3M\27[<0;3;3m'
    await(function()return #read(input)>=baseline+#wanted end)
    assert(read(input):sub(baseline+1)==wanted,'real SDL focus/key/UTF-8/paste/mouse use authoritative native modes and body coordinates')
    baseline=#read(input);key('4',terminal.CTRL|terminal.ALT);tick();idle(view)
    assert(#read(input)==baseline and require('shell').current=='bmux','reserved Ctrl-Alt workspace chord remains application-owned')
    -- Compare real pane pixels against an independent reader/native image.
    local reader=good(function(cb)client:attach(record.id,record.generation,{tail=view.remote.tail_rows},cb)end)
    local json=require 'json';local function cells(v)return json.encode{screen=v.screen,scrollback=v.scrollback}end
    await(function()return cells(reader:view())==cells(view.remote.snapshot)end)
    local image=renderer.terminal_image();image:apply(reader:view());local context=renderer.new_terminal(view.font,image,view.render_theme)
    view:scroll_to_bottom();view.scroll.y=view.scroll.to.y;view.dead=true;tick()
    local actual=dir..'/actual.bmp';local expected=dir..'/expected.bmp';assert(system.save_screenshot(actual))
    local px,py=math.ceil(view.position.x),math.ceil(view.position.y+view:header_height())
    local width=math.max(1,math.floor(view.size.x)-24);local height=math.max(1,math.floor(view:body_height())-2)
    renderer.begin_frame();renderer.set_clip_rect(px,py,width,height);renderer.draw_rect(px,py,width,height,style.background)
    local ox,oy=view:get_content_offset();local first=math.max(1,math.floor(view.scroll.y/view.lh)+1)
    local last=math.min(view.history_rows+view.rows,math.floor((view.scroll.y+view:body_height())/view.lh)+1)
    context:draw(ox,oy+view:header_height(),view.cw,view.lh,first,last);renderer.end_frame();assert(system.save_screenshot(expected))
    assert(pixels(actual,px,py,width,height)==pixels(expected,px,py,width,height),'attached pane paints exact independent native cells/history')
    view.dead=false;image:close();getmetatable(context).__gc(context);reader:detach();tick()
    -- A second visible pane starts passive and offers explicit takeover on conflict.
    second=attach.open(socket,record);await(function()return second.remote:status()=='read-only'end)
    local old_cols=second.cols;system.set_window_size(640,480)
    await(function()return second.remote.desired and second.remote.desired.cols~=old_cols end)
    assert(second.cols==old_cols,'passive pane resizing does not change the server grid')
    action(second,'Take control');await(function()return second.remote.conflict end);action(second,'Take over')
    await(function()return second.remote:can_control() and not second.remote.busy end)
    assert(not view:send('OLD_OWNER') or view.remote.busy);idle(view);assert(not view.remote:can_control())
    action(second,'View only');await(function()return second.remote:status()=='read-only' and not second.remote.busy end)
    second.remote.session.stream:cancel();await(function()return second.remote:status()=='disconnected'end)
    action(second,'Reconnect');await(function()return second.remote:status()=='read-only'end);assert(second.remote:process_state().pid==pid)
    -- Reserved pane commands remain application-owned.
    core.set_active_view(second);assert(command.perform('terminal:take-control'));await(function()return second.remote:can_control() and not second.remote.busy end)
    local previous_size=second:header_height();second.remote.error={kind='state',message='fixture error'}
    assert(second:header_height()==previous_size,'errors do not cause resize feedback');second.remote.error=nil
    system.set_window_size(1050,760)
    await(function()return not second.remote.busy and second.remote.desired.cols==second.cols and second.remote.desired.rows==second.rows end)
    idle(second);local screenshot=os.getenv('BMUX_ATTACHED_SHOT') or os.getenv('BMUX_RENDER_DIR')..'/attached-pane.bmp'
    tick();assert(system.save_screenshot(screenshot))
    close(second);await(function()return second.remote.client.closed end)
    local reopened=attach.open(socket,record);second=reopened
    await(function()return reopened.remote:status()=='read-only' and reopened.remote:process_state()end)
    assert(reopened.remote:process_state().pid==pid,'close/reopen attaches to the same server process')
    close(reopened);close(view)
    assert(command.perform('terminal:attach'));key('Return')
    await(function()return core.active_view==core.command_view and core.command_view.label=='Attach terminal: 'end)
    key('Return');await(function()
      second=core.active_view;return second:is(View) and second.remote and second.remote.id~=record.id and second.remote:status()=='read-only'
    end)
    assert(second.remote:process_state().pid~=pid,'New shell on server creates an independent server-owned process');close(second)
    print('studio_terminal_attached: visible socket/terminal chooser, no local PTY, SDL semantic input, exact native pixels/history, control/takeover/reconnect and same-PID reattach pass')
  end,debug.traceback)
  config.bmux_server=original_config;close(second);close(view)
  if client then client:close()end
  if daemon and not daemon.done then uv.kill(daemon.pid,'sigterm');await(function()return daemon.done end)end
  if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
  application.quit(true)
end)
