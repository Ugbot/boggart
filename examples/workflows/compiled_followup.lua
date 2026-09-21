-- Source for observation and mining, using injected current people/query. The
-- compiler keeps the list comparison in Lua and the report as a model call.
-- Hosts supply fake/local capabilities in tests; this example never sends.
return {run=function(ctx)
 local expected=ctx:resolve('expected_people')
 local replies=ctx:call('compile.followup.replies',{query=ctx:resolve('query')})
 local responded={}
 for _,person in ipairs(replies.result) do responded[person]=true end
 local missing={}
 for _,person in ipairs(expected) do
  if not responded[person] then missing[#missing+1]=person end
 end
 if #missing>0 then
  local report=ctx:call('compile.followup.report',{missing=missing,style=ctx:resolve('style')})
  return {missing=missing,report=report.result,filename=ctx:resolve('filename')}
 end
 return {missing=missing}
end}
