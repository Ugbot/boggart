-- Trusted private UDS selection; no credential forwarding to a different host.
local core=require 'core';local config=require 'core.config';local Client=require 'terminal.client'
local M={}
function M.open(socket,record,token)
  local tail=math.min(32,record.history or 0,math.max(0,math.floor(32768/record.cols)-record.rows))
  return require('shell.workspaces.bmux').open(nil,{title='Attached '..record.id,
    attachment={socket=socket,token=token,id=record.id,generation=record.generation,tail=tail,cols=record.cols,rows=record.rows}})
end
function M.list(socket,token,offset,client)
  if not client then
    local ok,value=pcall(Client.new,{socket=socket,token=token})
    if not ok then core.error('Attach requires a private socket and directory owned by you');return end
    client=value
  end
  client:request('GET','/terminals?limit=64&offset='..(offset or 0),nil,function(why,page)
    if why then client:close();core.error('Attach: %s',why.message);return end
    local choices={{text='+ New shell on server',create=true}}
    for _,rec in ipairs(page.terminals)do choices[#choices+1]={text=rec.id..'  '..rec.cmd..'  ['..rec.state..']',record=rec}end
    if type(page.next_offset)=='number'then choices[#choices+1]={text='Next page',offset=page.next_offset}end
    if offset and offset>0 then choices[#choices+1]={text='Previous page',offset=math.max(0,offset-64)}end
    require('shell.modal').chooser('Attach terminal',choices,function(pick)
      if pick.offset then M.list(socket,token,pick.offset,client);return end
      local function open(record)
        client:close();local ok,err=pcall(M.open,socket,record,token)
        if not ok then core.error('Attach: %s',tostring(err))end
      end
      if pick.create then
        client:request('POST','/terminals',{cols=80,rows=24,history=2000,cwd=core.project_dir},function(error,record)
          if error then client:close();core.error('Create terminal: %s',error.message)else open(record)end
        end)
      else open(pick.record)end
    end)
  end)
end
function M.choose()
  local opts=config.bmux_server or {};local socket=opts.socket or bog.userdir..'/control.sock'
  core.command_view:enter('Bmux server socket',function(path)
    M.list(path,path==opts.socket and opts.token or nil)
  end,nil,nil,socket)
end
return M
