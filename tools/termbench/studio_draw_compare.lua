-- Aggregate three independently warmed Studio processes per renderer.
local json=require 'json'
local prefix=assert(os.getenv('BMUX_DRAW_PREFIX'),'BMUX_DRAW_PREFIX required')
local groups={}
for _,backend in ipairs{'reference','native'} do
  for run=1,3 do
    local f=assert(io.open(prefix..'-'..backend..'-'..run..'.json','rb'))
    local report=json.decode(f:read('a')); f:close()
    for _,sample in ipairs(report.samples) do
      local key=sample.corpus..'/'..sample.mode
      groups[key]=groups[key] or {}; local all=groups[key][backend] or {cpu={},wall={},rect=0,text=0,captures=0,submissions=0}
      groups[key][backend]=all
      for _,v in ipairs(sample.cpu_ns) do all.cpu[#all.cpu+1]=v end
      for _,v in ipairs(sample.wall_ns) do all.wall[#all.wall+1]=v end
      all.rect=all.rect+sample.rect_calls; all.text=all.text+sample.text_calls
      all.captures=all.captures+(sample.captures or 0); all.submissions=all.submissions+(sample.submissions or 0)
    end
  end
end
local function median(values) table.sort(values); return values[(#values+1)//2] end
local summary={scope='80x24 pane draw, three warmed processes x 21 samples; SDL dummy, CPU/wall, no pixel latency',samples={}}
for _,corpus in ipairs{'plain','styled','unicode'} do
  for _,mode in ipairs{'unchanged','one-row-dirty'} do
    local group=groups[corpus..'/'..mode]; local old,new=group.reference,group.native
    local sample={corpus=corpus,mode=mode,reference_cpu_ns=median(old.cpu),native_cpu_ns=median(new.cpu),reference_wall_ns=median(old.wall),native_wall_ns=median(new.wall),
      reference_text_calls_per_frame=old.text/#old.cpu,native_text_calls_per_frame=new.text/#new.cpu,native_captures_per_frame=new.captures/#new.cpu,native_submissions_per_frame=new.submissions/#new.cpu}
    summary.samples[#summary.samples+1]=sample
    print(string.format('%s %s CPU %.0f -> %.0f ns; wall %.0f -> %.0f ns; text calls %.0f -> %.0f; captures %.0f',corpus,mode,sample.reference_cpu_ns,sample.native_cpu_ns,sample.reference_wall_ns,sample.native_wall_ns,sample.reference_text_calls_per_frame,sample.native_text_calls_per_frame,sample.native_captures_per_frame))
  end
end
local output=assert(os.getenv('BMUX_DRAW_SUMMARY'),'BMUX_DRAW_SUMMARY required')
local f=assert(io.open(output,'wb')); f:write(json.encode(summary)); f:close()
