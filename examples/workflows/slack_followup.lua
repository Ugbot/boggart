-- Source-backed package. Hosts register these exact bytes as workflow.source.
-- All three named capabilities are fake/local in tests/workflow.lua.
return {
  defaults={style='concise'},
  run=function(ctx)
    local expected=assert(ctx:resolve('expected_people'))
    local replies=ctx:step('gather',function()
      local outcome=ctx:call('fixture.slack.replies',assert(ctx:resolve('query')))
      assert(outcome.status=='succeeded')
      return outcome.result
    end)
    local missing=ctx:step('compare',function()
      local replied={};for _,person in ipairs(replies) do replied[person]=true end
      local result={};for _,person in ipairs(expected) do if not replied[person] then result[#result+1]=person end end
      return result
    end)
    local report
    if #missing>0 then
      report=ctx:step('draft',function()
        local outcome=ctx:call('fixture.model.report',{missing=missing,style=ctx:resolve('style')})
        assert(outcome.status=='succeeded');return outcome.result
      end)
    else report='Everyone has replied.' end
    return ctx:step('report',function()
      local outcome=ctx:call('fixture.report.record',{report=report,missing=missing})
      assert(outcome.status=='succeeded');return outcome.result
    end)
  end,
  verify=function(_,result) return type(result)=='table' and result.recorded==true end,
}
