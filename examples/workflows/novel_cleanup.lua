-- Register after prepending novel_context.lua plus a newline; hash the combined source.
local function lines(text)
 local out,pos={},1
 while true do
  local at=text:find('\n',pos,true)
  if not at then out[#out+1]=text:sub(pos);return out end
  out[#out+1]=text:sub(pos,at-1);pos=at+1
 end
end
local function normalized(text)
 local rows=lines(text)
 for i,line in ipairs(rows) do
  if i<#rows and line:sub(-1)=='\r' then line=line:sub(1,-2) end
  local last=#line
  while last>0 and (line:sub(last,last)==' ' or line:sub(last,last)=='\t') do last=last-1 end
  rows[i]=line:sub(1,last)
 end
 return table.concat(rows,'\n')
end
local function occurrences(text,fact)
 local count,pos=0,1
 while true do local first,last=text:find(fact,pos,true);if not first then return count end;count=count+1;pos=last+1 end
end
return {run=function(ctx)
 return ctx:step('cleanup-proposal',function()
  local data,c,out=gather(ctx,'cleanup');if not data then return out end
  assert(type(data.text)=='string','source text required')
  out.original=data.text;out.proposed=c.proposed_text or normalized(data.text)
  assert(type(out.proposed)=='string','proposal text required')
  out.source_revision=out.scope.revision;out.diff={};out.fact_checks={};out.changed_facts=0
  local before,after=lines(out.original),lines(out.proposed)
  for i=1,math.max(#before,#after) do if before[i]~=after[i] then out.diff[#out.diff+1]={line=i,before=before[i],after=after[i]} end end
  local facts=c.facts or {};local unknown=false
  for _,fact in ipairs(facts) do
   assert(type(fact)=='string' and #fact>0,'nonempty literal fact required')
   local a,b=occurrences(out.original,fact),occurrences(out.proposed,fact)
   local status=a==0 and 'unavailable' or a==b and 'preserved' or 'changed'
   if status=='changed' then out.changed_facts=out.changed_facts+1 end
   if status=='unavailable' then unknown=true end
   out.fact_checks[#out.fact_checks+1]={fact=fact,before=a,after=b,status=status}
  end
  local formatting_only=normalized(out.original)==normalized(out.proposed)
  out.checks={formatting_only=formatting_only,literal_facts_checked=#facts,
   fact_preserving=formatting_only and not unknown and out.changed_facts==0,
   semantic_status=not formatting_only and 'unverified' or 'formatting_only'}
  out.fact_coverage=unknown and 'unavailable' or #facts==0 and 'no_explicit_facts' or 'provided_literals_only'
  out.review_required=true;out.applied=false
  return out
 end)
end}
