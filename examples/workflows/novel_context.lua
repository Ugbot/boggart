-- Shared source fragment: prepend these exact bytes plus a newline to a novel domain source.
-- Authored source workflow; all retrieval effects remain in injected providers.
local function gather(ctx,kind)
 local scope=assert(ctx:resolve('scope'))
 for _,key in ipairs({'novel','corpus','revision'}) do assert(type(scope[key])=='string' and scope[key]~='', 'scope required: '..key) end
 local config=assert(ctx:resolve('config'))
 local data,provenance,failure=ctx:resolve('evidence',{kind=kind,scope=scope,config=config},{required=false})
 local out={scope=scope,provenance=data and provenance or failure,source_refs={},status='available',proposal=true}
 if not data or data.available~=true then out.status='unavailable';out.error=not data and provenance or nil;return nil,config,out end
 out.source_refs=data.source_refs or {}
 for _,key in ipairs({'novel','corpus','revision'}) do
  if not data.scope or data.scope[key]~=scope[key] then out.status='scope_mismatch';return nil,config,out end
 end
 return data,config,out
end
