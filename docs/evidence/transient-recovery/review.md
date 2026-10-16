# Independent evidence review

I retrieved the evidence through `manifest.json` and `evidence.tar.gz` in this
directory, verified `SHA256SUMS`, independently checked the source snapshot,
and ran `python3 scripts/verify-recovery-evidence.py` successfully. All 287
archive members and both original receipts verified, including 168 historical
artifact hashes. The 296 tested project files match the retained snapshot and
current files. Runtime, tests, dependencies and existing proof scripts have no
diff from tested trunk `3e44ab78b4321d41d1e676ad86088360e30952f1`.
The authoritative contract bytes hash to
`a53a3a4eb118fa4687dd703d6ce918dd40dd6cb4eda796abc6c429a6e932e7a3`.

I inspected raw focused captures, decoded request/response bytes and complete
lifecycle objects, rather than accepting the correlation totals. A separate
check independently constructed every expected lifecycle object for all 33
public interruption cases: original unmasked logical/attempt identities,
wire number, provider, operation, acceptance, transitions, category, status,
phase, eligibility, reason, absent optional fields and complete observed and
delivered progress. Each failed call had exactly one matching socket request;
session setup requests belong to separate logical calls. There was no replay.
Both retained capture sets also passed the executable byte/ordering correlator.

Concrete checks included:

- `interruption/ollama/tools/session/content`: logical ID
  `22A74C1D-587A-4078-9138-ADB3BF5E894C`, attempt ID
  `F294A398-6681-4CF1-911E-BDAA53FC0EC8`, wire 1. Socket request bytes exactly
  match wire capture, with system/user/assistant/user contents
  `existing-system`, `existing-user`, `recovered`, `failed-user`. The exact
  response is `{"done":false,"model":"payload-sentinel","message":{"content":"é🐈"}}`
  followed by LF: 73 UTF-8 bytes. Complete terminal progress records six
  observed and delivered content bytes, no reasoning/tools; ordered events
  are `attemptStarted`, `attemptFailed`, `interrupted`, with transport/200,
  streaming phase, eligibility false and `observedSemanticOutput`.
- `interruption/omlx/tools/session/tool`: logical ID
  `882B5B21-225D-4347-92C9-263E031EA1B9`, attempt ID
  `489C18DB-C1D3-476A-86CF-AC118D1853E3`, wire 1. The 145-byte SSE response
  contains tool `original-tool`, function `resolve_date`, and unfinished
  arguments `{"relative":`. It records one observed fragment, zero completed
  calls and zero delivered semantic output. Hidden reasoning and withheld tool
  expectations also agree across the remaining adapters.
- `sender/ollama/tools/session/framed`: logical ID
  `1BFAB7BB-CD25-4577-A429-A435ED11126B`, attempt ID
  `E31583A3-36C2-4D18-8843-9B8CADD13631`, wire 1. Its separately received LF
  completes a 195-byte record carrying `é`, `ré` and `original-tool`.
  Observed content/reasoning are 2/3 bytes with one completed tool; delivered
  content/reasoning are 2/3 with zero delivered tools. Cancellation retains
  these identities and progress. HTTP completion reports cancellation -999;
  broker, session and gateway producer completion precede consumer resumption.
  Paired incomplete framing instead remains transport failure before semantic
  readiness; all 20 framing pairs pass the ordering checks.

I read `PublicRecoveryInterruptionTests`, its support, sender cancellation and
framing assertions, `RecoveryLifecycleEvidence`, and streaming/session source.
They independently compare exact delivered prefixes (`content:é🐈`, visible
`reasoning:想`, and provider progress/metrics), typed causes, raw body evidence,
zero admission and zero counting-tool execution, and seeded session history
rollback after producer completion. Full event-array equality checks optional
nil fields omitted in JSON. This supplements the raw captures, which alone do
not serialize tool counters or final session history.

The retained subprocess runner records actual return codes and sequential
start/end times. Complete stdout/stderr and results agree: format, lint,
release build, parallel tests (388), full-traits tests (401), DocC, unfiltered
OSV scan and scripted executable example all exit 0. The example explicitly
admits one retry and verifies byte-identical resend and exact `café 猫` output.
SwiftPM reports inaccessible user-cache warnings; these are retained. The
direct proof has valid field types, a nonempty evidence-only reason, a real
corrected log and exit 0; rerunning its retained correlator input succeeds.

The record preserves every assertion mapping and historical causal limit.
Seven old log hashes remain explicitly unavailable, without an equivalence
claim for regenerated logs. Controlled interleavings establish their measured
behavior and cannot identify historical causes. Apple platforms and Swift 6.1
remain unverified. No cross-repository boundary changed or other repository
provider verification is claimed. Within these stated limits, the evidence
retrieval and independent conformance acceptance checks pass.
