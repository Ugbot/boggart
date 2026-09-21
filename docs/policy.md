# Composable execution policy

`policy.compile(scopes)` returns an opaque snapshot or `nil, error`.
`policy.decide(compiled, descriptor, args, usage)` returns a verdict (`allow`,
`ask`, `deny`), reasons, policy revision and obligations. This is admission
policy; the invocation gate and quota ledger enforce its obligations. Calling
`decide` alone does not reserve quota or execute a capability.

```lua
local policy = require "policy"
local compiled = assert(policy.compile {
  { id = "user", revision = 1,
    capabilities = { allow = { "*" }, deny = { "system.destroy" } },
    limits = { tokens = 4000 },
    quotas = {{ id="requests", metric="calls", limit=20, window_seconds=60 }},
  },
  { id = "project", revision = 2,
    capabilities = { allow = { "files.read", "files.write" } },
    resources = { path = { evaluator="prefix", allow={"/workspace/project/"} } },
    approval = true,
  },
})
local decision = policy.decide(compiled, {
  id="files.read", version="1", effect="read",
  resources=function(args) return {path=args.canonical_path} end,
}, {canonical_path="/workspace/project/chapter.txt"}, {tokens=200})
assert(decision.verdict == "ask")
```

Scope IDs must be unique nonempty strings. Revisions are nonempty strings or
nonnegative integers; publishers must change the revision when changing a
scope. The canonical revision sorts scopes by ID, so scope ordering does not
change the decision. Policy values are plain acyclic data, not executable
predicates. Unknown fields, malformed lists/limits and unsupported evaluators
are rejected. Limits are finite nonnegative numbers; quota windows are positive
integer seconds. Quota `subject`, when supplied, names a host-bound subject
dimension (for example `principal`), never an authority selected by the caller.

All capability allow lists intersect. Any deny wins. Omitting an allow list
adds no restriction; an empty allow list denies everything. At least one scope
must grant capability access explicitly. Capability entries are exact IDs or
`*`; there is no implicit wildcard syntax such as `files.*`.

Resource constraints also intersect by field. `exact` (default) compares the
whole string; `prefix` compares a literal prefix. For directory containment,
include the trailing slash and have the host normalize and validate the actual
path, including symlinks, before extracting it. Resource matching is not an OS
sandbox. A missing, throwing or invalid host resource evaluator denies access;
arguments supplied by generated Lua are not themselves a trusted resource
label. This module does not canonicalize filesystems or establish tool identity.

Approval requirements accumulate; `approval=false` never removes an ancestor's
requirement. The minimum limit wins and all quotas are retained with their
originating scope identity/revision. Unknown effects require approval even with
an explicit capability grant. Descriptors require an ID, string version and an
effect of `pure`, `read`, `write` or `unknown`; missing/invalid descriptors deny.
Usage must contain finite nonnegative values. The caller supplies prospective
usage and enforces returned quotas/ceilings; absent usage starts at zero and
is not evidence of unlimited budget.

Compiled state is private and deep-copied. `policy.describe(handle)` and
decision obligations return copies. Mutating input scopes, introspection
results or a handle using `rawset` cannot alter authority. Trusted native code
and Lua debug introspection are outside this application-level boundary.

The legacy `perm.decide` adapter retains existing modes and named rules and
can additionally accept `state.policy` or `state.policy_scopes`, plus a trusted
`state.capabilities` descriptor map and `state.policy_usage`. Generic policy
can only narrow the legacy decision. Explicit per-tool grants no longer
override chat mode, agent restrictions, deny rules or credential guards.
Existing within-scope specific-rule precedence and advisory guard behavior
remain unchanged. This fixes admission precedence, not yet every nested
dispatch route or unattended approval resolution (tracked separately).

Regressions: `tests/policy.lua`, `tests/perm.lua`; run the registered `policy`
and `perm` CTest suites after rebuilding.
