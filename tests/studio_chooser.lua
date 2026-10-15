-- Query edits and submit can be drained in the same SDL event batch.
local ok,err=xpcall(function()
  local core=require 'core';local modal=require 'shell.modal'
  local choices={{text='Boggart TUI',provider='boggart'},{text='Codex',provider='codex'},{text='Claude Code',provider='claude'}}
  local picked
  local function choose()picked=nil;modal.chooser('Chooser regression',choices,function(item)picked=item end)end
  local function key(name)
    system._test_event{type='keypressed',key=name};system._test_event{type='keyreleased',key=name}
  end
  local function input(text)
    system._test_event{type='keypressed',key='C'};system._test_event{type='textinput',text=text};system._test_event{type='keyreleased',key='C'}
  end
  local function frame()core.redraw=true;core.frame_start=system.get_time();core.step()end
  choose();assert(core.command_view.suggestions[1]==choices[1],'empty chooser preserves the declared default')
  input('Claude Code');key('Return');frame()
  assert(picked==choices[3],'same-frame edit/Enter submits current filtered metadata')
  choose();input('Boggart TUI');key('Return');frame();assert(picked==choices[1])
  choose();input('Codex');key('Tab');key('Return');frame();assert(picked==choices[2],'same-frame completion uses the new query')
  choose();key('Down');frame();local selected=core.command_view.suggestions[core.command_view.suggestion_idx]
  assert(selected~=choices[1],'arrow selects another item');key('Return');frame();assert(picked==selected,'submit preserves explicit keyboard selection')
  choose();input('zzzz-no-match');key('Return');frame();assert(not picked,'a changed unmatched query never submits a stale item')
  print('studio_chooser: declared defaults, same-frame text/submit/completion, keyboard selection and no-match metadata pass')
end,debug.traceback)
if not ok then io.stderr:write(tostring(err),'\n');rawset(_G,'STUDIO_BOOT_FAILED',true)end
require('core').quit(true)
