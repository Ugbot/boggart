-- Exercise the real scanner coroutine with a deterministic large directory.
local core=require 'core';local uv=require 'uv'
local list,info=system.list_dir,system.get_file_info
local root=assert(uv.fs_mkdtemp('/tmp/bmux-scan-XXXXXX'))
local ok,why=xpcall(function()
  -- core.init registers its project scanner before any plugin/startup threads.
  local scanner=assert(core.threads[1]).cr;core.threads[1]=nil
  local names={};for i=1,800 do names[i]=string.format('scan-fixture-%04d.lua',i)end
  local directories,late=false,false
  system.list_dir=function(path)
    if path=='.'then
      local copy={};for i,name in ipairs(names)do copy[i]=name end
      if directories then for i=1,32 do copy[#copy+1]=string.format('scan-dir-%02d',i)end end
      return copy
    end
    if path:match('^scan%-dir%-%d+$')then return late and {'late.lua'}or {}end
    if path==root then return {'extra.lua'}end
    return list(path)
  end
  system.get_file_info=function(path)
    if path:match('^scan%-dir%-%d+$')then return {type='dir',size=0,modified=1}end
    if path:match('^scan%-dir%-%d+/late%.lua$')then return {type='file',size=1,modified=1}end
    if path:match('^scan%-fixture%-%d+%.lua$')or path==root..'/extra.lua'then
      if path=='scan-fixture-0001.lua'and names[1]~='scan-fixture-0001.lua'then return nil end
      return {type='file',size=1,modified=1}
    end
    return info(path)
  end
  local original=core.project_files
  assert(coroutine.resume(scanner))
  assert(core.project_files==original and core.project_rescans==0,'large rebuild must yield before publishing')
  core.project_roots={root}
  assert(coroutine.resume(scanner))
  assert(core.project_files==original and core.project_rescans==0,'root change must cancel staged rebuild')
  local turns=0
  while core.project_rescans==0 and turns<100 do turns=turns+1;assert(coroutine.resume(scanner))end
  assert(turns>1 and turns<100 and #core.project_files==801,'complete multi-root scan must publish all files')
  assert(core.project_files[1].filename==names[1]and core.project_files[800].filename==names[800])
  assert(core.project_files[801].filename==root..'/extra.lua')
  local replacement={}
  core.project_files=replacement
  assert(coroutine.resume(scanner))
  assert(core.project_files==replacement,'old list retained throughout rebuild')
  local changed={};core.project_files=changed
  assert(coroutine.resume(scanner))
  assert(core.project_files==changed and core.project_rescans==1,'owner replacement must cancel staged rebuild')
  -- After a retry starts reading '.', remove an already-read file and add a
  -- replacement. The scan's directory snapshot must be reconciled after watch
  -- installation, even when the watcher supplied no event for this interval.
  assert(coroutine.resume(scanner))
  names[1]='scan-fixture-0801.lua'
  turns=0
  while core.project_rescans==1 and turns<100 do turns=turns+1;assert(coroutine.resume(scanner))end
  assert(turns>1 and turns<100 and core.project_rescans==2 and #core.project_files==801)
  local found={};for _,entry in ipairs(core.project_files)do found[entry.filename]=true end
  assert(not found['scan-fixture-0001.lua']and found['scan-fixture-0801.lua'],'changes during build must reconcile')
  local cwd=system.absolute_path('.')
  local switched={};core.project_files=switched
  assert(coroutine.resume(scanner));system.chdir(root)
  assert(coroutine.resume(scanner))
  assert(core.project_files==switched and core.project_rescans==2,'working-directory change must cancel staged rebuild')
  system.chdir(cwd);turns=0
  while core.project_rescans==2 and turns<100 do turns=turns+1;assert(coroutine.resume(scanner))end
  assert(turns>1 and turns<100 and core.project_rescans==3 and #core.project_files==801)
  -- Reconciliation also yields. Switching owners there must not splice old
  -- directory updates into the new project's list before the retry starts.
  directories=true;core.project_files={};turns=0
  while core.project_rescans==3 and turns<100 do turns=turns+1;assert(coroutine.resume(scanner))end
  assert(core.project_rescans==4)
  local next_owner={};core.project_files=next_owner;late=true
  assert(coroutine.resume(scanner))
  assert(core.project_files==next_owner and #next_owner==0,'reconciliation must cancel before editing a new owner')
  turns=0
  while (core.project_rescans<5 or #core.project_files<865)and turns<100 do turns=turns+1;assert(coroutine.resume(scanner))end
  assert(core.project_rescans==5 and #core.project_files==865)
end,debug.traceback)
system.list_dir,system.get_file_info=list,info
uv.fs_rmdir(root)
if not ok then io.stderr:write(why,'\n');os.exit(1)end
print('Project scan: yields before publication, complete sorted roots, cancellation and atomic owner replacement pass')
core.quit(true)
