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
function M.write(path,raw)
  if not valid(path)then return problem('invalid path')end
  local doc,why=Codec.decode(raw);if not doc then return nil,why end
  local text;text,why=Codec.encode(doc);if not text then return nil,why end
  local fd;fd,why=uv.fs_open(path,'wx',384)
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
return M
