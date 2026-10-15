if package.config:sub(1,1)=='\\' then return end
local uv=require 'uv';local hooks=require 'agenthooks';local proc=require 'proc'
local function q(s)return "'"..s:gsub("'","'\\''").."'"end
local dir=assert(uv.fs_mkdtemp('/tmp/bmux-hooks-XXXXXX'));local originals=dir..'/original bin'
assert(uv.fs_mkdir(originals,448))
local function executable(path,text)
  local f=assert(io.open(path,'w'));assert(f:write('#!/bin/sh\n'..text));assert(f:close());assert(uv.fs_chmod(path,448))
end
executable(originals..'/codex',[[printf 'REAL:%s\n' "$1"]])
local client=dir.."/native 'client"
executable(client,[[printf 'CLIENT'; for arg do printf '<%s>' "$arg"; done; printf '\n']])
local set=assert(hooks.install{directory=dir,executable=client,path=originals,cwd=dir})
assert(set.commands.codex and set.commands.boggart and not set.commands.claude)
assert(uv.fs_stat(set.bin).mode%512==448 and uv.fs_stat(set.bin..'/codex').mode%512==448)
local r=proc.run(q(set.bin..'/codex')..' '..q('$HOME $(literal) 🦊'),10)
assert(r.code==0 and r.out:find('<ctl><run><--best-effort><--provider><codex><--name><Codex><--><'..originals..'/codex><$HOME $(literal) 🦊>',1,true),r.out)
r=proc.run(q(set.bin..'/codex')..' --help',10);assert(r.code==0 and r.out=='REAL:--help\n',r.out)
r=proc.run('BOGGART_AGENT_HOOKS=0 '..q(set.bin..'/codex')..' literal',10);assert(r.out=='REAL:literal\n',r.out)
local native='BOGGART_SOCKET=/not-a-bmux-socket '..q(uv.exepath())..' ctl run '
r=proc.run(native..'--best-effort -- /bin/sh -c '..q('printf REAL_FALLBACK; exit 125'),10)
assert(r.code==125 and r.out:find('REAL_FALLBACK',1,true) and r.out:find('without registration',1,true),r.out)
r=proc.run(native..'-- /bin/sh -c '..q('printf SHOULD_NOT_RUN'),10)
assert(r.code==125 and not r.out:find('SHOULD_NOT_RUN',1,true),'explicit registration remains required')
assert(not hooks.install{directory=dir,executable=client,path=originals,cwd=dir},'a second setup never overwrites a live wrapper set')
local nested=assert(uv.fs_mkdtemp('/tmp/bmux-hooks-nested-XXXXXX'))
local inner=assert(hooks.install{directory=nested,executable="native 'client",path=set.path..':'..dir,cwd=dir,previous_bin=set.bin})
assert(inner.commands.codex==originals..'/codex' and not inner.path:find(set.bin,1,true),'nested Studio removes inherited wrappers')
inner:cleanup();assert(uv.fs_rmdir(nested))
-- A replaced file and user-added files survive cleanup, so rmdir may fail.
assert(uv.fs_unlink(set.bin..'/codex'));local f=assert(io.open(set.bin..'/codex','w'));f:write('replacement');f:close()
set:cleanup();set:cleanup();assert(uv.fs_stat(set.bin..'/codex'))
assert(uv.fs_unlink(set.bin..'/codex'));assert(uv.fs_rmdir(set.bin))
assert(not hooks.install{directory=dir,executable=client,path=originals,cwd=dir,disabled=true})
assert(not hooks.install{directory=dir,executable=client,path=string.rep('x',60001),cwd=dir},'PATH reserves room for pane capability overrides')
assert(uv.fs_unlink(client));assert(uv.fs_unlink(originals..'/codex'));assert(uv.fs_rmdir(originals));assert(uv.fs_rmdir(dir))
print('agenthooks: discovery, private wrappers, literal arguments, utility/opt-out bypass, collision, nested PATH and owned cleanup pass')
return 0
