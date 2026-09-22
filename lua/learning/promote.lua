-- Trusted host gates. Isolated evaluation never becomes production qualification.
local identity=require('learning.identity')
local M={}
local function require_gate(ok,code)if not ok then error({code=code},0)end end
function M.check(candidate,report)
 require_gate(type(report)=='table' and report.schema_version==1 and report.eligibility==true,'evaluation_failed')
 local refs=report.evidence_refs or {}
 require_gate(refs.candidate and refs.candidate.contract_hash==identity.hash(candidate) and refs.candidate.source_hash==candidate.source_hash,'candidate_report_mismatch')
 require_gate(candidate.source_hash==require('workflow').hash(candidate.source),'candidate_source_hash_mismatch')
 require_gate(refs.dataset and refs.dataset.hash and refs.policy and refs.policy.contract_hash and refs.source_authority and refs.source_authority.evidence_ref,'evidence_missing')
 require_gate(report.coverage and report.coverage.runtime=='isolated-compiler-subset-v1' and report.coverage.production_runtime_qualified==false and report.coverage.fresh_heldout>0 and report.coverage.recorded==0,'coverage_unsupported')
 require_gate(report.costs and report.costs.complete and #report.outcomes>0,'evidence_missing')
 for _,n in pairs(report.regressions or {})do require_gate(type(n)=='number' and n==0,'regression') end
 for _,outcome in ipairs(report.outcomes)do
  if outcome.selected then require_gate(outcome.verified==true,'verifier_failed') end
 end
 require_gate(type(refs.verifiers)=='table' and #refs.verifiers>0,'verifier_missing')
 return true
end
function M.activate(registry,...)return registry:activate(...)end
return M
