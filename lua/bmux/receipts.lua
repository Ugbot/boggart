-- Bounded client high-water marks. Old requests can never become fresh spawns.
local json=require 'json'
local M={};local Receipts={};Receipts.__index=Receipts
function M.new(limit)return setmetatable({limit=limit or 128,clients={},count=0},Receipts)end
function Receipts:run(client,sequence,fingerprint,apply)
  local old=self.clients[client]
  if old then
    if sequence==old.sequence then
      if fingerprint~=old.fingerprint then return nil,{status=409,message='command sequence payload changed'}end
      local copy=json.decode(old.response);return copy.value~=json.null and copy.value or nil,copy.error~=json.null and copy.error or nil
    end
    if sequence~=old.sequence+1 then return nil,{status=409,message='stale or gapped command sequence'}end
  else
    if sequence~=1 then return nil,{status=409,message='new client must start at command sequence 1'}end
    if self.count>=self.limit then return nil,{status=503,message='Fleet command client capacity reached'}end
  end
  local ok,value,why=pcall(apply)
  if not ok then value=nil;why={status=500,message='Fleet operation failed; inspect its state before another command'}end
  local receipt={client_id=client,command_seq=sequence}
  if value then value.receipt=receipt elseif why then why.receipt=receipt end
  local response=json.encode{value=value or json.null,error=why or json.null}
  if not old then self.count=self.count+1 end
  self.clients[client]={sequence=sequence,fingerprint=fingerprint,response=response}
  local copy=json.decode(response);return copy.value~=json.null and copy.value or nil,copy.error~=json.null and copy.error or nil
end
return M
