-- Register after prepending novel_context.lua plus a newline; hash the combined source.
return {run=function(ctx)
 return ctx:step('character-evidence',function()
  local data,c,out=gather(ctx,'character');if not data then return out end
  assert(type(c.character_id)=='string' and c.character_id~='','character_id required')
  out.character_id=c.character_id;out.attributes={};out.conflicts={};out.rejected={}
  for _,a in ipairs(data.assertions or {}) do
   if a.character_id==c.character_id then
    local valid=type(a.attribute)=='string' and type(a.value)=='string' and type(a.source_refs)=='table' and #a.source_refs>0
    if a.scope then for _,key in ipairs({'novel','corpus','revision'}) do if a.scope[key]~=out.scope[key] then valid=false end end end
    if not valid then out.rejected[#out.rejected+1]=a else
     local group=out.attributes[a.attribute] or {assertions={},status='asserted'};out.attributes[a.attribute]=group
     group.assertions[#group.assertions+1]=a
    end
   end
  end
  for attribute,group in pairs(out.attributes) do
   local values,refs,n={}, {},0
   for _,a in ipairs(group.assertions) do
    if not values[a.value] then values[a.value]=true;n=n+1 end
    for _,ref in ipairs(a.source_refs) do refs[#refs+1]=ref end
   end
   if n>1 then group.status='contradictory';out.conflicts[#out.conflicts+1]={attribute=attribute,source_refs=refs} end
  end
  for _,attribute in ipairs(c.attributes or {}) do
   if not out.attributes[attribute] then out.attributes[attribute]={status='absent',assertions={}} end
  end
  out.coverage=#out.rejected>0 and 'incomplete' or 'provided_assertions_only'
  return out
 end)
end}
