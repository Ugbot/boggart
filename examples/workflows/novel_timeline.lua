-- Register after prepending novel_context.lua plus a newline; hash the combined source.
return {run=function(ctx)
 return ctx:step('timeline-constraints',function()
  local data,c,out=gather(ctx,'timeline');if not data then return out end
  out.events=data.events or {};out.constraints=data.constraints or {};out.layers={};out.conflicts={};out.unordered={}
  local nodes,edges,degree={}, {},{}
  for _,e in ipairs(out.events) do assert(type(e.id)=='string' and not nodes[e.id],'unique event id required');nodes[e.id]=e;edges[e.id]={};degree[e.id]=0 end
  for _,edge in ipairs(out.constraints) do
   assert(type(edge.source_refs)=='table' and #edge.source_refs>0,'constraint provenance required')
   if not nodes[edge.before] or not nodes[edge.after] then
    out.conflicts[#out.conflicts+1]={kind='unknown_event',constraint=edge,source_refs=edge.source_refs}
   else edges[edge.before][#edges[edge.before]+1]=edge;degree[edge.after]=degree[edge.after]+1 end
  end
  local done={}
  while true do
   local layer={};for id,n in pairs(degree) do if n==0 and not done[id] then layer[#layer+1]=id end end
   if #layer==0 then break end;table.sort(layer);out.layers[#out.layers+1]=layer
   for _,id in ipairs(layer) do done[id]=true;for _,edge in ipairs(edges[id]) do degree[edge.after]=degree[edge.after]-1 end end
  end
  -- Identify genuine cyclic edges by reachability, excluding merely blocked descendants.
  local function reaches(start,target,seen)
   if start==target then return true end
   if seen[start] then return false end;seen[start]=true
   for _,edge in ipairs(edges[start]) do if reaches(edge.after,target,seen) then return true end end
   return false
  end
  local cyclic,refs={},{}
  for id in pairs(nodes) do if not done[id] then out.unordered[#out.unordered+1]=id end end;table.sort(out.unordered)
  for _,edge in ipairs(out.constraints) do
   if nodes[edge.before] and nodes[edge.after] and reaches(edge.after,edge.before,{}) then
    cyclic[#cyclic+1]=edge;for _,ref in ipairs(edge.source_refs) do refs[#refs+1]=ref end
   end
  end
  if #cyclic>0 then out.conflicts[#out.conflicts+1]={kind='cycle',constraints=cyclic,source_refs=refs} end
  out.ordering='partial; layer membership does not assert simultaneity'
  return out
 end)
end}
