local uv=require 'uv';local Codec=require 'bmux.checkpoint';local Files=require 'bmux.sessionfiles'
local fixture=assert(loadfile('tests/fixtures/bmux_checkpoint.lua'))()
local _,doc=fixture();local raw=assert(Codec.encode(doc))
local root=package.config:sub(1,1)=='\\'and(os.getenv('TEMP')..'/')or '/tmp/'
local dir=assert(uv.fs_mkdtemp(root..'bmux-files-XXXXXX'));local path=dir..'/session 🦊.json'
local ok,why=xpcall(function()
  assert(Files.write(path,raw))
  local info=assert(uv.fs_stat(path));assert(info.type=='file')
  if package.config:sub(1,1)~='\\'then assert(info.mode&63==0,'exports are private')end
  local imported=assert(Codec.decode(assert(Files.read(path))))
  assert(imported.terminals[1].launch=='saved'and imported.agents[1].launch=='saved')
  local f=assert(io.open(path,'rb'));local original=f:read('a');f:close()
  assert(original==raw and not Files.write(path,raw),'export never overwrites an existing file')
  assert(not Files.write(dir..'/invalid','{broken')and not uv.fs_stat(dir..'/invalid'))
  for _,p in ipairs{'',path..'\0suffix',path..'\nnext'}do assert(not Files.read(p)and not Files.write(p,raw))end
  assert(not Files.read(dir))
  f=assert(io.open(dir..'/bad','w'));f:write('{broken');f:close();assert(not Files.read(dir..'/bad'))
  f=assert(io.open(dir..'/big','w'));f:write(string.rep('x',4*1024*1024+1));f:close();assert(not Files.read(dir..'/big'))
  if package.config:sub(1,1)~='\\'then
    assert(uv.fs_symlink(path,dir..'/link'));assert(not Files.read(dir..'/link')and not Files.write(dir..'/link',raw))
    assert(os.execute('mkfifo '..dir..'/fifo'));assert(not Files.read(dir..'/fifo'),'FIFO import cannot block the UI')
    assert(uv.fs_unlink(dir..'/link'));assert(uv.fs_unlink(dir..'/fifo'))
  end
end,debug.traceback)
for _,p in ipairs{path,dir..'/bad',dir..'/big'}do uv.fs_unlink(p)end
assert(uv.fs_rmdir(dir));assert(ok,why)
print('Checkpoint files: private exclusive exports, bounded regular reads, inactive imports and no blocking FIFO/symlink reads pass')
return 0
