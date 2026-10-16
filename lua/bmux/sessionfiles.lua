-- Bounded regular-file imports and exclusive private checkpoint exports.
local uv=require 'uv';local Codec=require 'bmux.checkpoint';local M={}
local LIMIT=4*1024*1024
local function problem(message)return nil,{kind='file',message=('Checkpoint file: '..tostring(message)):sub(1,512)}end
local function valid(path)
  return type(path)=='string'and #path>0 and #path<=4096 and utf8.len(path)
    and not path:find('[%z\1-\31\127]')
end
function M.read(path)
  if not valid(path)then return problem('invalid path')end
  local before,why=uv.fs_lstat(path)
  if not before or before.type~='file'then return problem(why or 'regular file required')end
  local flags=uv.constants.O_RDONLY|(uv.constants.O_NONBLOCK or 0)|(uv.constants.O_NOFOLLOW or 0)
  local fd;fd,why=uv.fs_open(path,flags,0)
  if not fd then return problem(why)end
  local info;info,why=uv.fs_fstat(fd)
  if not info or info.type~='file'or info.size>LIMIT or info.dev~=before.dev or info.ino~=before.ino then
    uv.fs_close(fd);return problem(why or 'unchanged regular file up to 4 MiB required')
  end
  local parts,offset={},0
  while offset<=LIMIT do
    local bytes;bytes,why=uv.fs_read(fd,math.min(65536,LIMIT+1-offset),offset)
    if not bytes then uv.fs_close(fd);return problem(why)end
    if bytes==''then break end
    parts[#parts+1]=bytes;offset=offset+#bytes
  end
  local closed;closed,why=uv.fs_close(fd)
  if not closed then return problem(why)end
  if offset>LIMIT then return problem('file exceeds 4 MiB')end
  local raw=table.concat(parts);local doc;doc,why=Codec.import(raw)
  if not doc then return nil,why end
  return Codec.encode(doc)
end
local function write_new(path,text)
  if not valid(path)then return problem('invalid path')end
  local fd,why=uv.fs_open(path,'wx',384)
  if not fd then return problem(why)end
  local created=uv.fs_fstat(fd);local offset=0
  while offset<#text do
    local count;count,why=uv.fs_write(fd,text:sub(offset+1,offset+65536),offset)
    if not count or count==0 then why=why or 'short write';break end
    offset=offset+count
  end
  if offset==#text then local synced;synced,why=uv.fs_fsync(fd);if not synced then why=why or 'sync failed'end end
  local closed,close_error=uv.fs_close(fd);if not closed then why=why or close_error end
  if why then
    local current=uv.fs_lstat(path)
    if created and current and current.dev==created.dev and current.ino==created.ino then uv.fs_unlink(path)end
    return problem(why)
  end
  return true
end
function M.write(path,raw)
  local doc,why=Codec.decode(raw);if not doc then return nil,why end
  local text;text,why=Codec.encode(doc);if not text then return nil,why end
  return write_new(path,text)
end
local function private(info)
  return info and info.type=='directory'and info.uid==uv.getuid()and info.mode&63==0
end
function M.recovery_location(root,id)
  if not valid(root)or type(id)~='string'or not id:match('^[%w_-]+$')or #id>128 then return problem('invalid recovery location')end
  local canonical,why=uv.fs_realpath(root)
  if not canonical then return problem(why)end
  if not private(uv.fs_lstat(canonical))then return problem('recovery root must be an owned private directory')end
  local path=canonical..'/bmux-recovery/'..id..'.checkpoint'
  if not valid(path..'.json')then return problem('recovery path exceeds its limit')end
  return path
end
function M.archive(path,raw,metadata)
  if not valid(path)or type(raw)~='string'or #raw>64*1024*1024 then return problem('invalid recovery bytes or path')end
  local directory=path:match('^(.*)/[^/]+$');local root=directory and directory:match('^(.*)/bmux%-recovery$')
  if not root or not private(uv.fs_lstat(root))then return problem('recovery root is not private')end
  local info=uv.fs_lstat(directory)
  if not info then
    local made,why=uv.fs_mkdir(directory,448)
    if not made and not tostring(why):find('EEXIST',1,true)then return problem(why)end
    info=uv.fs_lstat(directory)
  end
  if not private(info)then return problem('recovery directory must be owned, private and not a symlink')end
  local ok,why=write_new(path,raw);if not ok then return nil,why end
  -- Keep raw data and its source metadata separate: binary/corrupt bytes are
  -- preserved exactly and never interpreted as a checkpoint or terminal input.
  local encoded,text=pcall(require('json').encode,metadata)
  if not encoded then return problem('recovery metadata encoding failed')end
  ok,why=write_new(path..'.json',text);if not ok then return nil,why end
  for _,dir in ipairs{directory,root}do
    local fd;fd,why=uv.fs_open(dir,uv.constants.O_RDONLY|(uv.constants.O_DIRECTORY or 0)|(uv.constants.O_NOFOLLOW or 0),0)
    if not fd then return problem(why)end
    local synced;synced,why=uv.fs_fsync(fd);local closed,close_error=uv.fs_close(fd)
    if not synced or not closed then return problem(why or close_error or 'recovery directory sync failed')end
  end
  return true
end
return M
