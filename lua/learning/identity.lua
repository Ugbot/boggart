-- Shared exact evaluation identity; host functions require explicit revisions.
local M={}
local function canonical(v)
 if type(v)=='table' then
  local parts={};for k,x in pairs(v)do parts[#parts+1]=canonical(k)..'='..canonical(x) end
  table.sort(parts);return '{'..table.concat(parts,',')..'}'
 elseif type(v)=='function' then return '<trusted-host-function>'
 elseif type(v)=='string' then return string.format('%q',v)
 else return type(v)..':'..tostring(v) end
end
M.canonical=canonical
function M.hash(value)return require("workflow").hash(canonical(value))end
return M
