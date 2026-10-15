-- Wire shape/budgets; native encoders validate key names, scalars and modes.
local M={}
local key_fields={key=true,action=true,modifiers=true,consumed_modifiers=true,right_modifiers=true,
  unshifted=true,base_layout=true,composing=true,option_as_alt=true,text=true,macos=true}
local mouse_fields={action=true,button=true,modifiers=true,x=true,y=true,any_button_pressed=true,cell_width=true,cell_height=true}
local string_fields={key=true,action=true,option_as_alt=true,text=true}
local boolean_fields={composing=true,macos=true,any_button_pressed=true}
local function plain(t)return type(t)=='table' and getmetatable(t)==nil end
local function only(t,fields)for k in pairs(t)do if not fields[k]then return false end end;return true end
function M.validate(events)
  if not plain(events) or #events<1 or #events>64 then return nil,'input batch must contain 1..64 events'end
  local count=0;for key in pairs(events)do
    if type(key)~='number' or key%1~=0 or key<1 or key>#events then return nil,'input batch must be a dense array'end
    count=count+1
  end
  if count~=#events then return nil,'input batch must be a dense array'end
  local text_bytes=0
  for _,event in ipairs(events)do
    if not plain(event) or not only(event,{kind=true,value=true})then return nil,'invalid input event'end
    local kind,value=event.kind,event.value
    if kind=='key' or kind=='mouse'then
      if not plain(value) or not only(value,kind=='key' and key_fields or mouse_fields)then return nil,'invalid input event fields'end
      for field,item in pairs(value)do
        if string_fields[field] then
          if type(item)~='string' or #item>(field=='text' and 4096 or 64)then return nil,'invalid input text field'end
        elseif boolean_fields[field]then if type(item)~='boolean'then return nil,'invalid input boolean'end
        elseif type(item)~='number' or item%1~=0 or math.abs(item)>9007199254740991 then return nil,'invalid input integer'end
      end
      if kind=='key' and value.text~=nil then
        if type(value.text)~='string' or #value.text>4096 then return nil,'invalid key text'end
        text_bytes=text_bytes+#value.text
      end
    elseif kind=='paste'then
      if type(value)~='string'then return nil,'paste text required'end;text_bytes=text_bytes+#value
    elseif kind=='focus'then if type(value)~='boolean'then return nil,'focus boolean required'end
    else return nil,'unknown input event kind'end
    if text_bytes>65536 then return nil,'input source text exceeds 64KiB'end
  end
  return events
end
return M
