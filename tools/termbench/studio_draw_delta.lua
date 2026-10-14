-- Native before/after comparison. Both profiles use the same pane frontend.
local json=require 'json'
local prefix=assert(os.getenv('BMUX_DRAW_PREFIX'),'BMUX_DRAW_PREFIX required')
local groups,identity,corpus_identity={},nil,nil
for _,backend in ipairs{'before','after'} do
  for run=1,3 do
    local f=assert(io.open(prefix..'-'..backend..'-'..run..'.json','rb')); local report=json.decode(f:read('a')); f:close()
    assert(report.renderer=='native-row-commands','both sides must use the native pane')
    local fingerprint=report.view_sha256..report.font.sha256..tostring(report.font.size)
    identity=identity or fingerprint; assert(identity==fingerprint,'frontend/font changed between runs')
    if report.corpus_sha256 then
      for name,digest in pairs(report.corpus_sha256) do
        corpus_identity=corpus_identity or {};corpus_identity[name]=corpus_identity[name] or digest
        assert(corpus_identity[name]==digest,'corpus changed between runs: '..name)
      end
    end
    for _,sample in ipairs(report.samples) do
      local key=sample.corpus..'/'..sample.mode; groups[key]=groups[key] or {}
      local all=groups[key][backend] or {cpu={},wall={},captures=0,submissions=0,replay={}};groups[key][backend]=all
      for _,v in ipairs(sample.cpu_ns) do all.cpu[#all.cpu+1]=v end
      for _,v in ipairs(sample.wall_ns) do all.wall[#all.wall+1]=v end
      assert(sample.text_calls==0,'per-cell Lua draw reappeared')
      all.captures=all.captures+sample.captures;all.submissions=all.submissions+sample.submissions
      all.replay[#all.replay+1]=sample.last_frame_replay
    end
  end
end
local function median(values) table.sort(values);return values[(#values+1)//2] end
local summary={scope='native 80x24 pane, font 16, SDL dummy, three processes x 21 draw samples; CPU/wall, no input latency',samples={}}
for _,corpus in ipairs{'plain','styled','unicode','mixed'} do
  for _,mode in ipairs{'unchanged','one-row-dirty'} do
    local group=groups[corpus..'/'..mode];local before,after=group.before,group.after
    local sample={corpus=corpus,mode=mode,before_cpu_ns=median(before.cpu),after_cpu_ns=median(after.cpu),before_wall_ns=median(before.wall),after_wall_ns=median(after.wall),
      captures_per_frame=after.captures/#after.cpu,submissions_per_frame=after.submissions/#after.cpu,before_last_frame_replay=before.replay,after_last_frame_replay=after.replay}
    summary.samples[#summary.samples+1]=sample
    print(string.format('%s %s CPU %.0f -> %.0f ns; wall %.0f -> %.0f ns',corpus,mode,sample.before_cpu_ns,sample.after_cpu_ns,sample.before_wall_ns,sample.after_wall_ns))
    for _,stats in ipairs(after.replay) do print(string.format('  %d queued, %d replayed, %d skipped, %d dirty rects',stats.rows_queued,stats.rows_replayed,stats.rows_skipped,stats.dirty_rects)) end
  end
end
local f=assert(io.open(assert(os.getenv('BMUX_DRAW_SUMMARY'),'BMUX_DRAW_SUMMARY required'),'wb'));f:write(json.encode(summary));f:close()
