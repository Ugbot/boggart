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
remain unchanged. Invocation mediation and unattended resolution are described
below.

Regressions: `tests/policy.lua`, `tests/perm.lua`; run the registered `policy`
and `perm` CTest suites after rebuilding.

## Local control and unattended profiles

`control.start{}` authenticates every route by default, including loopback.
It generates a cryptographically random bearer token unless the operator supplies
`token` or `BOGGART_SERVE_TOKEN`. Configure CLI clients with an operator-supplied
`BOGGART_SERVE_TOKEN` and `Authorization: Bearer …`. A trusted in-process caller
can explicitly retrieve a generated token with `control.client_token()`;
there is no HTTP token-discovery endpoint. Startup events and invocation evidence
omit the credential. Do not put tokens in URLs or event payloads.

`control.start{profile="trusted_local"}` explicitly permits unauthenticated
loopback access. Native `serve.listen` requires a token unless this profile is
selected on loopback. Both profiles validate the actual parsed Host and optional
Origin headers. Host must match the configured bind host and actual port
(`localhost` and `127.0.0.1` are interchangeable on IPv4 loopback); Origin must
be exactly `http://<Host>`. Bind a concrete address for remote clients. Duplicate
Host, Origin, Authorization or Content-Length headers, malformed header fields
and transfer encoding are refused. Invalid authentication returns 401; invalid
Host/Origin and denied route authority return 403; malformed framing returns
400. Handler/store errors remain HTTP 500.

One listener has one token and one capability scope. For example:

```lua
control.start{
  token=operator_secret,
  capabilities={"control:GET:/health", "control:GET:/sessions"},
}
```

Capability IDs use `control:<METHOD>:<registered route pattern>` (without pattern
anchors). Omitted capabilities mean `{"*"}` for the operator's full-scope
client. Requests enter `invoke` with host-constructed scoped authority and still
intersect current global policy. Authentication does not bypass explicit denies,
mandatory policy approval, or legacy ask guards; an operator who needs repeated
unattended polling must explicitly configure those approval decisions.

Narrow tokens cannot enqueue prompts/hooks, mutate permissions, or create/fire/
delete triggers. These routes return 403 even if named in the token scope because
attenuated authority is not yet carried through deferred execution. BRAIN-35
tracks that integration. Full-scope clients retain the current routes under
current policy. This is a deliberate refusal, not claimed scoped queue support.

An unattended `ask` requires an explicit `state.headless="allow"` (or the
operator's `BOGGART_HEADLESS_POLICY=allow`). Missing, malformed and unknown
profiles deny. `"deny"` denies; `"queue"` refuses admission pending approval;
there is no durable approval queue in this contract. Both initial admission and
the post-callback effect check require explicit allow. Compiled mandatory
approvals still require an approver. A mode such as `auto` does not silently
resolve an ask raised by another guard. Synthetic context intersections are
neutral; the real inherited/global scopes enforce the restrictions.

Filesystem admission resolves existing paths or the existing parent of a new
file using native realpath, including symlinks, and rechecks after authorization
callbacks. Shell capabilities report no path resource: a path allowlist cannot
authorize an arbitrary command, even if the caller supplies a plausible path.
These checks do not prevent filesystem races between realpath and a subsequent
operation. Race-free filesystem confinement requires OS support or an isolated
process, not pathname policy.

## Restricted source and native execution

Generated tools, the `lua` tool, source workflows, generated event handlers and
choice Lua outcomes use protected native coroutine resumes. The allocator
refuses growth before `realloc` when any enclosing ceiling would be exceeded.
Budgets retain a conservative absolute **per-state** ceiling across yields;
this is not per-run allocation attribution. The ceiling is active only within a
protected resume/close, and restored before host event-loop work. Unrelated host
allocations during suspension may cause a later restricted resume to refuse.
Nested contexts cannot enlarge ancestors, and failed allocations remain sticky
even when source catches the error or immediately attempts an effect.

The default Lua growth allowance is 256 MiB, configurable through the trusted
`tools.LIMITS.memory_kb`; source instruction hooks are separate. Scope nesting is
limited to 64. This caps Lua-allocator bytes, not arbitrary native `malloc`, OS
resources, or wall-clock time. Worker threads keep their independent allocator;
restricted source on a host without the supported allocator explicitly fails
with `restricted allocator unavailable`. A worker thread is not an OS sandbox.

Restricted native primitives have a finite admitted work contract:

- String inputs/rep output are capped at 16 MiB; plain literal find is supported.
  Pattern operations admit fixed-width forms only, with at most 64 KiB subject
  and 256-byte pattern. Repetition, balanced matching and backreferences are
  refused. Native POSIX regex (`sys.re_*`, `gold.re`) is not admitted.
- String dump/pack/unpack/packsize and pointer/object formatting are refused.
  Format strings are capped at 4096 bytes and 127 values. Direct library and
  shared string-method calls use the same restrictions. Method selection checks
  the actual lookup frame before tail-call elimination; stored source aliases
  retain the bounded method. Trusted host lookups use their original library.
- Table ranges are capped at 65536 elements. Default sort uses a Lua comparator
  safepoint and refuses strings longer than 4096 bytes per comparison.
- Generated metatables are refused, preventing escaped GC/close/metamethod
  callbacks. Source results and outgoing capability arguments must be plain
  acyclic data (64 levels, 100000 visited nodes, 1 MiB string data); generated
  closures cannot escape as results. Generated tool primitive-string results
  separately admit up to 16 MiB, retaining the existing saved-file spill and
  `result_too_large` response above 1 MiB; larger strings are refused before
  host serialization. Trusted injected context providers remain
  supported. JSON sentinels and standard-library tables are environment-local;
  shared random-state/reseed operations are refused.

Instruction hooks bound Lua execution and interruptible Lua callbacks. They are
**not native-call timeouts**. For unsupported or blocking computations, use an
explicitly trusted host capability or a separately qualified isolated process
with enforceable resource controls. Installed trusted Lua/native modules and
trusted host workflows retain ordinary host authority; their native/private
allocations and callbacks are not made safe by a `pure` effect label. Generated
event handlers additionally retain registration authority and intersect it with
the emitter's current authority; their existing yield/drop behavior remains.

Regression coverage: `control`, `perm`, `invoke`, `luatool`, `workflow`, `events`
and `choose`. All fixtures use synthetic data and local effects.
