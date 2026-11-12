-- Terminal-cell presentation of the same validated tree used by Studio.
local Snapshot=require 'bmux.snapshot'
local Tree=require 'bmux.tree'
local terminal=require 'terminal'
local M={};local Class=Tree.class{divider=1}
local palette={'000000','cd0000','00cd00','cdcd00','0000ee','cd00cd','00cdcd','e5e5e5',
  '7f7f7f','ff0000','00ff00','ffff00','5c5cff','ff00ff','00ffff','ffffff'}
local cube={0,95,135,175,215,255}
local attrs={}
for n=0,15 do attrs[n]={bold=n&1~=0,dim=n&2~=0,underline=n&4~=0,reverse=n&8~=0}end
local function color(value)
  if value==0 then return nil end
  if value&terminal.COLOR_RGB~=0 then return string.format('%06x',value&0xffffff) end
  local n=value&255
  if n<16 then return palette[n+1]end
  if n>=232 then local v=8+(n-232)*10;return string.format('%02x%02x%02x',v,v,v)end
  n=n-16;return string.format('%02x%02x%02x',cube[n//36+1],cube[n//6%6+1],cube[n%6+1])
end
function M.layout(snapshot,w,h)
  local scene={width=w,height=h,leaves={},nodes={},narrow=false}
  if not snapshot then return scene end
  for _,workspace in ipairs(snapshot.workspaces)do
    if workspace.id==snapshot.selected_workspace_id then
      scene.workspace=workspace
      for _,s in ipairs(workspace.surfaces)do if s.id==workspace.selected_surface_id then scene.surface=s end end
    end
  end
  if not scene.surface then return scene end
  scene.root,scene.selected,scene.nodes=Snapshot.project(snapshot.host_id,scene.surface,Class,function(v)return v end)
  if scene.root.zoomed then
    scene.root.zoomed.position={x=0,y=1};scene.root.zoomed.size={x=w,y=math.max(0,h-3)};scene.root.zoomed:update_layout()
  end
  scene.root.position={x=0,y=1};scene.root.size={x=w,y=math.max(0,h-3)};scene.root:update_layout()
  local leaves=scene.root:get_leaves()
  for _,leaf in ipairs(leaves)do if leaf.size.x<20 or leaf.size.y<4 then scene.narrow=true end end
  scene.focused=scene.nodes[scene.surface.focused_pane_id]
  if scene.narrow then
    leaves={scene.focused}
    -- Narrow presentation never mutates canonical node geometry/navigation.
  end
  for _,leaf in ipairs(leaves)do
    local x,y,c,r=leaf.position.x,leaf.position.y,leaf.size.x,leaf.size.y
    if scene.narrow then x,y,c,r=0,1,w,math.max(0,h-3)end
    scene.leaves[#scene.leaves+1]={node=leaf,view=leaf.active_view,x=x,y=y,w=c,h=r}
  end
  return scene
end
local function label(tc,x,y,text,width,fg,bg,attr)
  if width<=0 then return end
  tc.puts(x,y,sys.cell_take(text,width),fg,bg,attrs[attr or 0])
end
local function cell(tc,x,y,c,width,cursor,reverse)
  local style=c.style;local attr=0
  if style.attrs&terminal.BOLD~=0 then attr=attr|1 end
  if style.attrs&terminal.FAINT~=0 then attr=attr|2 end
  if style.attrs&terminal.UNDERLINE_MASK~=0 then attr=attr|4 end
  if (style.attrs&terminal.INVERSE~=0)~=reverse then attr=attr|8 end
  if cursor then attr=attr~8 end
  if c.width==2 and width<2 then tc.set(x,y,32,color(style.fg),color(style.bg),attrs[attr]);return end
  if style.attrs&terminal.INVISIBLE~=0 then
    for i=0,c.width-1 do tc.set(x+i,y,32,color(style.fg),color(style.bg),attrs[attr])end
  else tc.cluster(x,y,c.text~='' and c.text or ' ',c.width,color(style.fg),color(style.bg),attrs[attr])end
end
function M.draw(tc,scene,remotes,state)
  if state.overlay then state.overlay:draw(tc,scene.width,scene.height);tc.flush();return end
  tc.clear()
  local w,h=scene.width,scene.height
  if w<1 or h<1 then tc.flush();return end
  local title=' Bmux | '..(scene.workspace and scene.workspace.title..' / '..scene.surface.title or 'No workspace')
  title=title..' | '..state.status..(scene.narrow and ' | focused pane' or '')
  label(tc,0,0,title,w,'93ddfa',nil,1)
  for _,p in ipairs(scene.leaves)do
    if p.w>0 and p.h>0 then
      local v=p.view;local remote=v and remotes[v.id];local focused=p.node.remote_id==scene.surface.focused_pane_id
      local status=remote and remote:status()or v and v.kind=='agent' and 'agent adapter unavailable' or 'empty'
      label(tc,p.x,p.y,(focused and '> 'or '  ')..(v and (v.title or v.terminal_id or tostring(v.agent_id))or 'New terminal: Ctrl-B t')
        ..' ['..status..'] '..#p.node.views..' tabs',p.w,focused and '7fb77e'or '6b6b72',nil,1)
      local snapshot=remote and remote.snapshot
      if snapshot then
        local offset=state.scroll[v.id]or 0;local history=snapshot.scrollback.rows;local count=#history
        offset=math.min(offset,count)
        for y=1,math.min(p.h-1,snapshot.rows)do
          local index=count+y-offset
          local row=index<=count and history[index]or snapshot.screen[index-count]
          if row then for x=1,math.min(p.w,snapshot.cols)do
            local c=row.cells[x]
            if c and c.width>0 then
              local cursor=focused and offset==0 and snapshot.state.row==y and snapshot.state.col>=x
                and snapshot.state.col<x+c.width and snapshot.state.modes&4~=0
              cell(tc,p.x+x-1,p.y+y,c,p.w-x+1,cursor,snapshot.state.modes&512~=0)
            end
          end end
        end
      elseif p.h>1 then label(tc,p.x,p.y+1,remote and 'Attaching...'or v and 'Observation unavailable' or 'Ctrl-B t creates a server terminal',p.w,'6b6b72')end
    end
  end
  if h>1 then label(tc,0,h-2,state.message or '',w,'ffa94d')end
  if h>2 then label(tc,0,h-1,state.prefix and 'Ctrl-B: f Fleet  a agent  e sessions  t terminal  % / " split  n/p pane  c control  ! takeover  z zoom  q detach  ? help'
    or 'Ctrl-B commands | f Fleet | a agent | e sessions | c control | t terminal | ? help | q detach',w,'6b6b72')end
  if state.help then
    local lines={'Bmux commands (Ctrl-B first)',
      'f Fleet: focus/prompt/interrupt/approval/Stop   a new server agent',
      'e Sessions: status, export/import checkpoint files, inspect saved sessions',
      't new terminal   % split right   " split down   x close tab reference',
      'n/p next/previous pane   h/j/k/l directional focus   [/] previous/next tab',
      'z zoom   = balance   w/s next workspace/surface   W/S create workspace/surface',
      'c take control   ! explicit takeover   v read-only   r refresh/reconnect',
      'u retry uncertain terminal command   PageUp/PageDown local history',
      'q detach (server terminals keep running)   Ctrl-B Ctrl-B sends Ctrl-B',
      'Mouse click focuses pane; wheel reports to controlled app or scrolls history.',
      'Press Escape or Ctrl-B ? to close help'}
    for i,line in ipairs(lines)do if i<h-2 then
      label(tc,0,i,string.rep(' ',w),w,nil,'202028')
      label(tc,0,i,line,w,'e1e1e6','202028')
    end end
  end
  tc.flush()
end
return M
