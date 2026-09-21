-- Source is executable truth. This index contains syntax and lexical references,
-- never inferred call effects, values, or executable workflow candidates.
local parser = require('mining_parser')
local hash = require('workflow').hash
local M = {}
local MAX_SOURCE = 262144
local function failure(code, message) return nil, {code=code, message=message} end
local function child(n, field)
  for _, c in ipairs(n.children) do if c.field == field then return c end end
end
local function kind_child(n, kind)
  for _, c in ipairs(n.children) do if c.kind == kind then return c end end
end
local function span(n)
  return {start_byte=n.start_byte, end_byte=n.end_byte,
    start_line=n.start_line, start_column=n.start_column,
    end_line=n.end_line, end_column=n.end_column}
end

function M.index(source, version)
  if type(source) ~= 'string' then return failure('invalid_source', 'source must be a string') end
  if #source > MAX_SOURCE then return failure('resource_limit', 'source exceeds 262144 bytes') end
  if version ~= nil and (type(version) ~= 'string' or #version > 256) then
    return failure('invalid_version', 'version must be a string of at most 256 bytes')
  end
  local root, err = parser.parse(source)
  if not root then return nil, err end
  local result = {schema_version=1, source=source, version=version,
    source_hash=hash(source), parser='tree-sitter-lua/0.5.0+lua/5.5.1',
    nodes={}, sites={}, unknowns={}, features={counts={}, def_use={}, bindings={}}}
  local nodes, features, mapped = result.nodes, result.features, {}
  local function text(n) return source:sub(n.start_byte, n.end_byte-1) end
  local function flatten(n, parent)
    if n.kind == 'comment' or n.kind == 'hash_bang_line' then return end
    local x = {id=#nodes+1, kind=n.kind, field=n.field, named=n.named,
      span=span(n), parent=parent, children={}}
    nodes[x.id], mapped[n] = x, x
    features.counts[n.kind] = (features.counts[n.kind] or 0)+1
    if #n.children == 0 then x.value=text(n) end
    for _, c in ipairs(n.children) do
      local id=flatten(c, x.id)
      if id then x.children[#x.children+1]=id end
    end
    return x.id
  end
  flatten(root)
  local function unknown(n, reason)
    result.unknowns[#result.unknowns+1]={node=mapped[n].id, span=span(n), reason=reason}
  end
  local function scope(parent, fn)
    return {parent=parent, names={}, fn=fn or (parent and parent.fn) or 0}
  end
  local serial, fnserial = 0, 0
  local function declare(n, s, is_global, implicit_name)
    local name=implicit_name or text(n)
    serial=serial+1
    local b={id=serial, name=name, declaration=mapped[n].id,
      kind=is_global and 'global' or 'local', function_scope=s.fn,
      implicit=implicit_name~=nil}
    features.bindings[#features.bindings+1]=b
    s.names[name]=b
    if not implicit_name then
      mapped[n].binding=b.id
      mapped[n].role='declaration'
      if not is_global and name~='_ENV' then mapped[n].normalized='local:'..b.id end
    end
    return b
  end
  local function lookup(s, name)
    while s do if s.names[name] then return s.names[name] end; s=s.parent end
  end
  local function reference(n,s,role)
    local b=lookup(s,text(n))
    local x=mapped[n]
    x.role=role or 'read'
    if b then
      x.binding=b.id
      if b.kind=='local' and b.name~='_ENV' then x.normalized='local:'..b.id end
      features.def_use[#features.def_use+1]={declaration=b.declaration, reference=x.id,
        binding=b.id, role=x.role, relation='lexical_binding', captured=b.kind=='local' and b.function_scope~=s.fn}
      if b.kind=='local' and b.function_scope~=s.fn then unknown(n,'captured_local_value') end
    else x.role='global_'..x.role end
  end
  local visit
  local function children(n,s)
    for _,c in ipairs(n.children) do visit(c,s) end
  end
  local function declarations(list,s,is_global)
    for _,c in ipairs(list.children) do
      if c.kind=='identifier' then declare(c,s,is_global)
      elseif c.kind=='attribute' then visit(c,s) end
    end
  end
  local function target(n,s)
    if n.kind=='identifier' then reference(n,s,'write') else visit(n,s) end
  end
  local function function_body(n,s)
    fnserial=fnserial+1
    local inside=scope(s,fnserial)
    local name=child(n,'name')
    if name and name.kind=='method_index_expression' then declare(name,inside,false,'self') end
    local params=child(n,'parameters')
    if params then declarations(params,inside,false) end
    local body=child(n,'body')
    if body then children(body,inside) end
    unknown(n,'closure_environment_and_effects')
  end
  visit=function(n,s)
    if not mapped[n] then return end
    local k=n.kind
    if k=='identifier' then reference(n,s)
    elseif k=='variable_declaration' then
      -- Initializers see the surrounding bindings, including an older same-name local.
      local assignment=kind_child(n,'assignment_statement')
      local list=kind_child(assignment or n,'variable_list')
      local values=assignment and kind_child(assignment,'expression_list')
      if values then visit(values,s) end
      if list then declarations(list,s,n.children[1].kind=='global') end
    elseif k=='function_declaration' then
      local name=child(n,'name')
      local first=n.children[1].kind
      if first=='local' or first=='global' then declare(name,s,first=='global') else target(name,s) end
      function_body(n,s)
    elseif k=='function_definition' then function_body(n,s)
    elseif k=='block' then children(n,scope(s))
    elseif k=='for_statement' then
      local clause=child(n,'clause')
      local inside=scope(s)
      if clause.kind=='for_numeric_clause' then
        for _,c in ipairs(clause.children) do if c.field~='name' then visit(c,s) end end
        declare(child(clause,'name'),inside,false)
      else
        local values=kind_child(clause,'expression_list')
        if values then visit(values,s) end
        declarations(kind_child(clause,'variable_list'),inside,false)
      end
      local body=child(n,'body'); if body then children(body,inside) end
    elseif k=='repeat_statement' then
      local inside=scope(s)
      local body=child(n,'body'); if body then children(body,inside) end
      visit(child(n,'condition'),inside)
    elseif k=='assignment_statement' then
      local values=kind_child(n,'expression_list'); if values then visit(values,s) end
      local list=kind_child(n,'variable_list')
      if list then for _,c in ipairs(list.children) do if c.named then target(c,s) end end end
      unknown(n,'assignment_values_and_control_flow')
    elseif k=='dot_index_expression' or k=='method_index_expression' then
      visit(child(n,'table'),s)
      unknown(n,'table_lookup_or_metamethod')
    elseif k=='bracket_index_expression' then
      children(n,s); unknown(n,'dynamic_table_lookup_or_metamethod')
    elseif k=='field' then
      local name=child(n,'name')
      if name and n.children[1].kind=='[' then visit(name,s) end
      local value=child(n,'value'); if value then visit(value,s) end
    elseif k=='binary_expression' or k=='unary_expression' then
      children(n,s); unknown(n,'operator_may_invoke_metamethod')
    elseif k=='attribute' or k=='label_statement' or k=='goto_statement' then
      -- These identifiers are neither local references nor alpha-renamable names.
      if k=='goto_statement' then unknown(n,'unresolved_control_flow')
      elseif k=='attribute' and text(n):find('close',1,true) then unknown(n,'close_metamethod') end
    elseif k=='function_call' then
      children(n,s)
      local callee=child(n,'name')
      result.sites[#result.sites+1]={node=mapped[n].id, kind='call', span=span(n),
        callee_span=span(callee), callee_node=mapped[callee].id,
        resolution='unknown', reason='runtime_callable_and_effects'}
      unknown(n,'runtime_callable_and_effects')
    else children(n,s) end
  end
  visit(root,scope(nil))
  -- Syntax-order serialization is unambiguous, whitespace/comment-independent,
  -- and preserves operator/literal/global/field spelling and AST relationships.
  local canonical={}
  local function emit(value) canonical[#canonical+1]=#value..':'..value end
  for _,n in ipairs(nodes) do
    emit(n.kind); emit(n.field or ''); emit(tostring(#n.children))
    emit(n.normalized or n.value or '')
  end
  features.structure_hash=hash(table.concat(canonical))
  features.structure_hash_version=1
  features.def_use_semantics='lexical bindings only; no reaching-definition or value claims'
  table.sort(result.sites,function(a,b) if a.span.start_byte==b.span.start_byte then return a.node<b.node end
    return a.span.start_byte<b.span.start_byte end)
  return result
end
return M
