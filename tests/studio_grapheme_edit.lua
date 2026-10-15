local ok,err=xpcall(function()
  local AgentView=require('core.agentview');local modes=require('vimmode')
  local original=modes.enabled;local clipboard=system.set_clipboard
  system.set_clipboard=function()end -- Modal yank must not alter user clipboard.
  local view=AgentView();view.entries={}
  local vectors={'é','👩‍💻','👍🏽','🇬🇧','❤️','क्‍ष','क्ष'}
  for _,cluster in ipairs(vectors) do
    modes.enabled=function()return false end;view.edit_mode='insert'
    view:set_input('A'..cluster..'B')
    view:on_key_pressed('left');view:on_key_pressed('left');assert(view.cx==2)
    view:on_key_pressed('right');view:on_key_pressed('backspace');assert(view:input_text()=='AB')
    view:set_input('A'..cluster..'B');view:on_key_pressed('home');view:on_key_pressed('right')
    view:on_key_pressed('shift+right');assert(view:composer_selection()==cluster)
    view:on_key_pressed('delete');assert(view:input_text()=='AB')
    modes.enabled=function()return true end
    view:set_input('A'..cluster..cluster..'B');view.edit_mode='insert';view:on_key_pressed('escape')
    for _,key in ipairs({'0','l','2','x'}) do view:on_text_input(key) end
    assert(view:input_text()=='AB');view:on_text_input('P')
    assert(view:input_text()=='A'..cluster..cluster..'B')
    view:on_text_input('u');assert(view:input_text()=='AB')
    view:set_input('A'..cluster..'B');view.edit_mode='insert';view:on_key_pressed('escape')
    for _,key in ipairs({'0','l','a','X'}) do view:on_text_input(key) end
    assert(view:input_text()=='A'..cluster..'XB')
    view:on_key_pressed('escape');view:on_text_input('0');view:on_text_input('/')
    view:on_text_input(cluster);view:on_key_pressed('return');assert(view.cx==2)
  end
  modes.enabled=function()return false end;view.edit_mode='insert'
  view:set_input('Grapheme editing: é 👩‍💻 👍🏽 🇬🇧 ❤️ क्‍ष')
  view.position.x,view.position.y=0,0;view.size.x,view.size.y=900,600
  renderer.begin_frame();renderer.set_clip_rect(0,0,10000,10000)
  renderer.draw_rect(0,0,10000,10000,{0,0,0,255});view:draw();renderer.end_frame()
  assert(system.save_screenshot(assert(os.getenv('BMUX_RENDER_DIR'))..'/composer-graphemes.bmp'))
  modes.enabled=original;system.set_clipboard=clipboard
  print('Studio composer: native cluster movement/delete/selection, modal counts/paste/append/Unicode search and draw pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
