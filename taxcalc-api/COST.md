# taxcalc-api — Cost Governance Runbook

W6 D4. What this service spends, which plane each charge lands on, which guardrail is supposed
to catch it, and what to do when one fires.

The single most important thing in this document: **there are two spending planes, and only one
of them is visible to AWS billing.** Every design decision below follows from that.

---

## Two cost planes

| Plane | What bills | Governed by | Attributed by |
|---|---|---|---|
| **AWS-resident** | NAT Gateway, RDS, S3, data transfer | `taxcalc-cost-dev` — a tag-scoped **AWS Budget** + a **CloudWatch billing alarm** | cost-allocation tags, read in Cost Explorer |
| **LLM (Anthropic)** | `claude-haiku-4-5` tokens for `explain-liability` | the **Anthropic Console workspace spend limit** | `CostLogger`'s per-request EMF line + the `X-Cost-Usd` header |
| **Embeddings (self-hosted)** | nothing per call — cluster CPU | pod `resources.limits` | not applicable |

**AWS Budgets cannot see Anthropic spend.** It is not AWS spend; it bills to the Anthropic
workspace and never appears in Cost Explorer, an `EstimatedCharges` alarm, or a Budget — not
because anything is misconfigured, but because AWS is not the merchant. An AWS Budget created to
cap LLM spend would deploy cleanly, report healthy, and control nothing. That is why the LLM
plane carries its own cap (at the platform) and its own attribution (in the application).

The third row is worth keeping in view because it is the counterexample: the embeddings service
is an "AI feature" with no per-request cost at all. It runs `bge-large-en-v1.5` on the cluster's
own CPU — no API key, no third party, and no NAT Gateway crossing, since the call resolves to a
cluster-internal Service DNS name. Its cost question is capacity planning, not per-call
accounting. "Is it AI?" is the wrong axis; "who is the merchant?" is the right one.

---

## Cost-allocation tags

Four mandatory keys on every billable resource:

| Key | Values | Notes |
|---|---|---|
| `service` | `taxcalc` | half of the Budget's `CostFilters` |
| `env` | `dev` \| `staging` \| `prod` | the other half |
| `tenant` | a tenant id, or `shared` | shared infrastructure is honestly labelled `shared` |
| `feature` | `egress`, `persistence`, `cost-governance`, `embeddings` | the resource's **own** purpose |

Applied to: `NatGateway*` and their EIPs (`cfn/taxcalc-network-dev.yaml`), `DbInstance`
(`cfn/taxcalc-app-dev.yaml`), and the cost stack's own SNS topic.

**Activation is manual and does NOT backfill.** Cost-allocation tag keys must be activated by
hand in the Billing console before they can be used as a filter, and spend incurred before
activation is never attributed, whatever the resource was tagged with at the time. Tagging a
resource is therefore only half the job; the console step is the other half, and it is the half
with no diff to review.

Three rules that are not stylistic:

- **Lowercase, and additive.** AWS tag keys are case-sensitive, so `Env` and `env` are two
  distinct cost-allocation keys requiring two separate activations. The four keys were **added
  alongside** the pre-existing `Env`/`Project` tags rather than renaming them; a rename would
  have been the tidier diff and would have silently orphaned every historical `Env`-keyed report.
- **`feature` names the resource's own purpose, not its loudest consumer.** The NAT Gateway is
  `feature=egress`, not `feature=explain-liability`, even though the Anthropic call crosses it.
  Tagging shared capacity after one consumer would attribute all egress to that feature and make
  the per-feature view actively misleading. The `feature` key earns its keep on the LLM plane,
  where `CostLogger` dimensions each call by the feature that actually made it.
- **Tag the cheap things.** The NAT Gateways' Elastic IPs are tagged, which the brief does not
  ask for. An attached EIP is free; a **detached** one bills ~$3.60/mo, and a detached EIP is
  precisely what a half-finished teardown leaves behind. Untagged, that charge is invisible to
  the tag-scoped Budget and would surface only on the account-wide alarm — the backstop, not the
  attribution.

A resource missing **either** `service` or `env` is invisible to the Budget. That does not merely
lose detail: it silently shrinks what the guardrail guards, while the guardrail keeps reporting
green. `scripts/cfn-guardrails.sh --static` check 5 asserts full coverage on every billable
resource type so this is a red CI check rather than a convention.

---

## The AWS-resident guardrails

### `taxcalc-monthly-cost-dev` — the tag-scoped Budget

`BudgetType: COST`, `TimeUnit: MONTHLY`, `BudgetLimit: $100`, filtered to
`user:service$taxcalc` + `user:env$dev`. Two notifications to SNS:

- **`FORECASTED > 80%`** — the only one of the two that can still change the outcome.
- **`ACTUAL > 100%`** — a post-mortem trigger.

**$100 is derived, not round.** Steady state is roughly: one dev NAT Gateway ~$32/mo before data
processing, `db.t4g.micro` + 20GB gp3 ~$15/mo, S3 in cents — call it ~$50. A limit at roughly 2x
steady state means `FORECASTED > 80%` ($80) fires because something changed, not because the
month has a 31st day in it. A limit set at $55 would page somebody every month for nothing, and
an alarm that cries wolf monthly is an alarm that gets muted.

### `taxcalc/estimated-charges-dev` — the account-wide billing alarm

`AWS/Billing` / `EstimatedCharges`, `Currency: USD`, threshold **$120**, `Period: 21600` (6h),
`EvaluationPeriods: 1`.

It is **account-wide and cannot be tag-filtered** — `EstimatedCharges` is one number for the
whole account. That is exactly why it complements the Budget rather than duplicating it: it
catches the spend the Budget is blind to by construction, i.e. anything untagged, or anything
somebody else created. The threshold sits **above** the Budget's limit deliberately, so the
tag-scoped Budget speaks first and this only fires once total account spend has passed the point
where the tagged view is no longer the whole story.

**`TreatMissingData: ignore`, and never `notBreaching`.** Billing refreshes roughly every 6h, so
missing datapoints are routine here. `notBreaching` counts a gap as OK, which on a metric with
routine gaps actively *erases* a real breach — the alarm goes ALARM, the next window has no data,
and it resets itself to OK. The opposite reasoning applies to a metric-pipeline alarm (an app
error rate), where silence means the pipeline is broken and `breaching` is the safe reading. Same
setting, inverted answer, because the two metrics fail in opposite directions.

`cfn-guardrails.sh --static` check 6 is the acceptance command itself —
`grep -RIn "notBreaching" cfn/`, run verbatim, required to return **zero matches**. It briefly
was not. The first spelling failed on the template's own paragraph explaining why the value is
wrong; the second anchored the match to the property assignment so prose could not trip it, which
passed and was the worse fix — it swapped the acceptance command for a weaker one of our own, and
a reviewer pasting the command from the task would still have seen two matches and had to take
our word they were benign. The template's prose is hyphenated (`not-breaching`) instead, explained
at the one place anybody would wonder about it, and the gate is back to the literal command. The
stronger claim — no occurrence of the token in `cfn/` **at all**, property or comment — is the one
now enforced.

**The alarm is gated on a `us-east-1` Condition.** `EstimatedCharges` is published only to
us-east-1, for every region's spend. The same template deployed elsewhere would otherwise create
an alarm watching a metric that never receives a datapoint — sitting in `INSUFFICIENT_DATA`
forever, deployed, green, and unable to fire. An alarm that exists and cannot fire is strictly
worse than no alarm, because it is the one a reviewer ticks off. Verified from both sides on the
emulator: 4 resources in us-east-1, 3 in eu-west-1, the alarm being the difference. Outside
us-east-1 the `BillingAlarmName` output says so in words rather than returning a blank.

### `taxcalc-cost-alarms-dev` — the SNS topic

SSE at rest with `alias/aws/sns`. Its `TopicPolicy` allows `sns:Publish` from **both**
`budgets.amazonaws.com` and `cloudwatch.amazonaws.com`.

**Without that policy both guardrails silently fail to notify.** The Budget still shows as
configured and the alarm still transitions to ALARM; only the delivery is missing — the same
"green but dead" shape this whole stack exists to prevent, reproduced inside the stack itself.
Both statements carry `AWS:SourceAccount` conditions (not in the reference snippet): each service
principal is a confused-deputy candidate without one.

Subscriptions are deliberately **not** in the template. A subscription a human confirmed by email
does not belong in something that gets torn down and rebuilt.

---

## The NAT cost lever

`cfn/taxcalc-network-dev.yaml` gates NAT Gateway count on the `IsProdLike` condition:

| Env | NAT Gateways | ~Monthly | Trade |
|---|---|---|---|
| `dev` | 1 (AZ A) | ~$32 | losing AZ A costs dev its egress — acceptable |
| `staging` / `prod` | 3 (one per AZ) | ~$96 | an AZ failure takes out only its own subnet |

This is the single largest line item in the account and the one most worth understanding before
it appears on a bill. It is charged per gateway-hour **plus** ~$0.045/GB processed, so the fixed
cost is only half the story: every byte leaving the VPC crosses it. The Anthropic API call does;
the embeddings call does not, because it resolves to a cluster-internal Service.

To find it in Cost Explorer: group by the `service` tag, then look for usage type
`*-NatGateway-Hours` and `*-NatGateway-Bytes` under EC2-Other.

---

## The LLM plane

### What it costs

`explain-liability` calls `claude-haiku-4-5` — roughly a third of Sonnet's per-token price, and
the right tool for the job: a bounded liability record in, a short paragraph out, so Sonnet's
extra capability has nothing to act on. The model is named at the call site
(`LiabilityExplanationService.MODEL`) rather than taken from the application default, precisely
so that choice is visible in the diff of the feature that made it.

A measured live call (`AnthropicCostPathLiveIT`, real API, real tokens):

```
model=claude-haiku-4-5  resolved=claude-haiku-4-5-20251001
in=12  out=4  X-Cost-Usd=0.00005
```

### The two ways in

Two routes spend Anthropic tokens, and both funnel through the same `CostMiddleware`:

| Route | What it is |
|---|---|
| `POST /api/v1/taxpayers/{id}/explanation` | the product feature — builds its own prompt from the liability read model |
| `POST /v1/completions` | the proxy boundary itself — any caller buys a completion and is accounted for identically |

The proxy route takes `prompt`, optional `model` (defaults to `claude-haiku-4-5`) and `feature`
in the body; `tenant` comes from the verified JWT claim and is deliberately **not** a body field,
since a caller-supplied tenant on a cost key is a caller who can bill their spend to someone
else's line. An unpriceable model id is rejected **before** the upstream call, so a bad request
costs nothing rather than producing a 500 for tokens already bought.

One middleware, not two, is the point: a second cost path is how a cost model ends up wrong — the
newer one gets the fix, the older one quietly under-reports, and they only disagree on the invoice.

### How it is attributed

`CostMiddleware` wraps every call and emits one CloudWatch **Embedded Metric Format** line per
request — namespace `uptimecrew/llmproxy`, dimensions `[[service, tenant, feature]]`, metrics
`CostUsd` and `LatencyMs`. Wherever stdout ships to CloudWatch Logs, that line is simultaneously a
log record and a real metric, with no metric-publishing call and no extra IAM permission.
Somewhere that does not ship stdout to CloudWatch, it is still a queryable JSON log line — it
degrades to something useful rather than to nothing.

**This is the LLM plane's entire cost attribution.** The per-feature dollar figure exists only
because it is written there; nothing in AWS can produce it.

Cost is carried as an integer count of **1e-5 USD**, which departs from `CLAUDE.md`'s scale-2
`BigDecimal` money rule — deliberately, and documented at `CostMiddleware`. That rule is right for
tax liability, where scale 2 *is* the domain. Per-call LLM cost sits four orders of magnitude
below it, so at scale 2 every call rounds to `0.00` and a million of them still round to zero.
The rule's actual intent — never accumulate money in binary floating point — is kept harder than
the letter would: `BigDecimal` at scale 8, rounded exactly once with HALF_UP, then carried as
integers, which sum without error.

### Two model ids, and why the log carries both

A request for `claude-haiku-4-5` comes back reporting `claude-haiku-4-5-20251001`. The requested
id is a floating **alias**; the response names the dated **snapshot** that served it. Measured
against the live API, not inferred.

- **Price by the alias** — `PriceBook` is keyed on it. Pricing off the response id throws
  `no price for model claude-haiku-4-5-20251001` on the first real call, and no stub-based test
  would ever catch it, because a stub echoes back whatever it was handed.
- **Log the snapshot** — an alias floats. A cost line recording only the alias cannot be
  reconciled against an invoice after the alias moves to a differently-priced snapshot.

### The guardrails, and which one does what

| Control | Where | What it actually does |
|---|---|---|
| Anthropic Console **workspace spend limit** | the platform | the hard cap. Enforced by the party doing the billing; survives this app being scaled to N replicas |
| `RateLimitFilter` (10 req/min/subject on `/summary`, `/explanation`, `/v1/completions`) | the app | bounds the worst case **before** the money is spent — a retry storm is the failure most likely to produce a surprising invoice |
| `CostLogger` + `X-Cost-Usd` | the app | attribution only. Records; does not prevent |

There is deliberately **no in-app kill switch and no Redis counter.** That would be per-replica
state that under-counts by a factor of the replica count, plus a new failure mode (the cost store
being down) on the request path of a feature meant to degrade gracefully. The cap belongs at the
platform; the app's job is to say where the money went.

### `PriceBook` is the highest-maintenance file here

A stale price book makes every cost figure wrong while every test still passes: the arithmetic is
correct, the log line is well-formed, the header is present, and the number simply is not what the
invoice will say. Nothing in the process can detect it. Re-check it against Anthropic's published
pricing whenever a model is added or a rate changes.

It also uses one **blended** rate per model covering input and output together, while real
pricing charges output several times more than input. That is an approximation, taken knowingly:
it keeps the table auditable at a glance and is accurate in aggregate for a workload whose
input:output ratio is stable, which `explain-liability`'s is. It would be the wrong simplification
for a huge-prompt/one-word-answer workload, which would need input and output rates split.

---

## Runbooks

**Budget breach — `FORECASTED > 80%`.** Open Cost Explorer, group by the `service` tag, compare
against the previous month. The usual culprit is NAT Gateway data processing (a chatty new
integration, or a workload that started pulling images through the gateway) or an RDS instance
resized and not resized back. Check `*-NatGateway-Bytes` first.

**Budget breach — `ACTUAL > 100%`.** The money is spent. Same investigation, plus: decide whether
the limit is now wrong. A budget crossed three months running is a budget that needs re-deriving,
not a monthly alarm to acknowledge.

**Billing alarm (`EstimatedCharges`) fires but the Budget did not.** By construction this means
**untagged spend** — the alarm sees the whole account, the Budget sees only tagged resources.
Cross-reference: `aws resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc`
lists what *is* tagged; anything in Cost Explorer that is not in that list is the gap. Then fix
the tags at the template, not in the console — a console tag is drift.

**Neither fires but the bill is high.** Check that cost-allocation tags are still *activated* in
the Billing console (activation is account state, not template state, so a template change cannot
restore it), and that the SNS `TopicPolicy` still exists — a Budget with no publish permission is
silent, not healthy.

**LLM spend looks wrong.** Query the EMF metric `CostUsd` in namespace `uptimecrew/llmproxy`,
grouped by `feature`, and compare against the Anthropic Console. If the app's figure is *lower*
than the invoice, suspect `PriceBook` staleness or a model swap first — both under-report while
looking healthy. If the cost series went quiet, check for malformed EMF (CloudWatch drops the
metric and keeps the text) before concluding nothing spent money.

**API-key rotation.** Create the new key in the Anthropic Console, update the Kubernetes Secret
(`kubectl -n taxcalc-dev create secret generic anthropic-api --from-literal=ANTHROPIC_API_KEY=… --dry-run=client -o yaml | kubectl apply -f -`),
roll the Deployment, confirm `/explanation` still returns a non-zero `X-Cost-Usd`, then revoke
the old key in the Console. Revoke last, not first — the old key must stay valid until every pod
has the new one. The key is never committed: it lives in the Secret and in the operator's shell,
and `git grep` for the literal returns zero.

---

## What was actually verified, and on which engine

No AWS account is wired to either repository — `aws sts get-caller-identity` returns
`NoCredentials` and `vars.AWS_ACCOUNT_ID` is unset, unchanged since W6 D3. Everything below ran
against **floci 2.0.1**, the same local emulator W5 D4, W6 D1 and W6 D3 used, at
`AWS_ENDPOINT_URL=http://localhost:4566`. Endpoint only; no parameter or command changed.

**What floci genuinely established.** The whole stack reaches `CREATE_COMPLETE` through the real
`create-change-set → describe-change-set → execute-change-set` flow. The CloudWatch alarm is real
and readable:

```
$ aws cloudwatch describe-alarms --alarm-names "taxcalc/estimated-charges-dev"
taxcalc/estimated-charges-dev  AWS/Billing  EstimatedCharges  120.0  GreaterThanThreshold
```

And the `IsUsEast1` condition was verified **from both sides** — the same template produces 4
resources in us-east-1 and 3 in eu-west-1, the alarm being exactly the difference. That is the
kind of claim an emulator can settle, because it is about template evaluation rather than about
a service.

### Three parity gaps, each measured rather than assumed

**1. `AWS::Budgets::Budget` reports `CREATE_COMPLETE` against a service that does not exist.**

```
$ aws cloudformation describe-stack-resources --stack-name taxcalc-cost-dev
MonthlyCostBudget  AWS::Budgets::Budget  MonthlyCostBudget-7636191f  CREATE_COMPLETE

$ aws budgets describe-budget --account-id 000000000000 --budget-name taxcalc-monthly-cost-dev
An error occurred (UnknownOperationException): Unknown operation:
AWSBudgetServiceGateway.DescribeBudget
```

floci runs no `budgets` service at all — it is absent from `/_localstack/health`'s 100 services —
yet its CloudFormation provider accepts the resource, mints a plausible physical id, and reports
success. This is W6 D3's `bucket-policy-80a48155` finding in a new costume, and it lands on the
**headline resource of this deliverable**: the one guardrail that is supposed to enforce the
budget is the one the emulator cannot model. `CREATE_COMPLETE` here means the template parsed,
not that a budget exists.

**2. The SNS `TopicPolicy`, `KmsMasterKeyId` and tags are all silently dropped.** All three report
`CREATE_COMPLETE`; none reaches the SNS API. The live topic still carries the *default* policy:

```
$ aws sns get-topic-attributes --topic-arn …taxcalc-cost-alarms-dev  → Policy.Id
__default_policy_ID          # not AllowBudgetsPublish / AllowCloudWatchPublish
                             # Principal {"AWS":"*"} — WIDER than the template asks for
$ …  → Attributes.KmsMasterKeyId   → None
$ aws sns list-tags-for-resource   → (empty)
```

Worth stating plainly: on this endpoint the topic is **more permissive** than the committed
template, not less. An engineer who verified their least-privilege topic policy here would have
verified nothing.

**3. `TreatMissingData` is dropped from the alarm.** The alarm exists with the right namespace,
metric, threshold and action — and `describe-alarms` reports `TreatMissingData: None`. The single
property that decides whether this alarm fires correctly on a gappy metric is the one that did not
survive. That is a subtler failure than an outright rejection: the resource looks correct in every
field a reviewer would skim.

### Cost Explorer: not emulable, rather than unimplemented

The task asks for a Cost Explorer drill-down grouped by the `service` tag, the NAT line item
identified, and the view saved as a report. **None of that has a local path, and the reason is
worth stating precisely.** floci does run a `ce` service, and it answers the API correctly:

```
$ aws ce get-cost-and-usage --granularity MONTHLY --metrics UnblendedCost \
    --group-by Type=DIMENSION,Key=SERVICE
2026-08-01  total 0.0000000000  | groups: 36
2026-09-01  total 0.0000000000  | groups: 36

$ aws ce get-tags   →  {"Tags": [], "TotalSize": 0}
```

Thirty-six service groups, every amount exactly zero, and no cost-allocation tag keys known at
all. This is not a missing feature that a later floci version might add: **an emulator does not
bill anybody**, so there is no spend for Cost Explorer to report and no activated tag for it to
group by. Unlike the three gaps above — which are provider bugs and could be fixed — this one is
structural. The NAT Gateway line item can only be read on a real account.

The substitute is honest but weaker, and is not the same claim: `cfn-guardrails.sh --static`
check 5 asserts from the templates that every billable resource carries all four keys, so the
*input* to a tag-scoped report is verified even though the report itself is not.

Likewise `aws resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc`
returned an empty list here — partly the gap above, and partly because
`cfn/taxcalc-network-dev.yaml` did not deploy on this floci at all: it rolled back with
`A security group rule must specify exactly one of CidrIp, CidrIpv6, a prefix list, or a security
group` on `TaxcalcAppSecurityGroup`. **That is a pre-existing W6 D3 issue, not a W6 D4
regression** — confirmed by an A/B: the template as it stood *before* this deliverable's tag edits
fails identically, and the W6 D4 diff to that file is tag lines only.

That rollback is now diagnosed and worked around; see the next section.

---

## Closing the Done-Whens on floci — four workarounds, and what each is worth

All four acceptance commands now answer, and **two of the four answers are worth materially less
than a pass.** `scripts/cost-done-when.sh` (config repo) runs all four and prints one of three
verdicts per check — `PASS`, `SHIM`, `GAP` — rather than an exit status, because the raw commands
produce **one false pass and one false failure** on this engine and reading their exit codes
would launder both.

```
1  describe-stacks taxcalc-cost-dev            PASS  (qualified)
2  budgets describe-budget                     SHIM  projected from the template
3  describe-alarms                             PASS
4  get-resources Key=service,Values=taxcalc    SHIM  real tags, stood-in index
```

### 1. `cfn-resolve-if.rb` — why the network stack rolled back

The failure is **not** in the security group. floci does not evaluate `Fn::If` when it appears as
an **element of a list** rather than as the value of a property. Isolated with a two-resource
probe stack:

| resource | `SecurityGroupEgress` | result |
|---|---|---|
| `SgPlain` | one literal rule | `CREATE_COMPLETE` |
| `SgIf` | one literal rule + one `!If` | `CREATE_FAILED` |

The rule floci rejects has neither a CIDR nor a group id because it is *still* the mapping
`{"Fn::If": [...]}` — the intrinsic was never evaluated. Real CloudFormation evaluates it, which
is why `cfn-lint` is clean and the template is correct as committed.

The shim resolves **only** list-positioned `Fn::If`, from the template's own `Conditions` and
parameters. `Ref`, `Fn::Sub`, `Fn::GetAtt` and resource-level `Condition:` keys are passed through
untouched — floci handles those, and doing their work here would hide it if that stopped being
true. Output is a throwaway JSON body, never a second source of truth. `taxcalc-network-dev`
reaches **`CREATE_COMPLETE` for the first time** through it; `taxcalc-app-dev` needs it at all
(exit 3: "no list-positioned `Fn::If` found") and deploys from the committed file directly.

### 2. `cfn-guardrails.sh reconcile-tags` — the tags CloudFormation dropped

floci applies **no declared tag to any resource type measured here**. The per-service APIs work,
so this reads each resource's declared `Tags` from its template and applies them there, then
**verifies by reading back** — which is not belt-and-braces: floci's `sns tag-resource` stores the
tags correctly and returns a response botocore cannot parse (`'TagResourceResult'`), so the CLI
exits non-zero on a write that succeeded. Trusting exit status reports a false failure.

The four-key requirement is scoped to **billable** types. A VPC, subnet, route table or security
group is free and can never appear in a cost report; demanding the taxonomy there produces a wall
of findings that are not cost-governance problems and buries the one case that is.

### 3. `TreatMissingData` — a *read* restored, and a behaviour that cannot be

Unlike `reconcile-s3`, `reconcile-cloudwatch` cannot fix its target by any API call.
`reconcile-s3` works because floci's S3 stores the properties when they arrive over the S3 API, so
only the CFN wiring is broken. **`TreatMissingData` is dropped by floci's CloudWatch itself** — a
direct `put-metric-alarm --treat-missing-data ignore` on a throwaway alarm also reads back `None`,
and the property is *absent from the stored record entirely* rather than set to a default. The
script runs that probe and classifies on the result: `PASS` if the endpoint can store it,
**`GAP` — not `FAIL`** — if it cannot, because the template is correct and the engine cannot
represent it. Reporting a template failure here would be the inverse error of reporting a pass.

**The read is now recoverable; the behaviour is not, and the two must not be confused.** The shim
serves `DescribeAlarms` by forwarding floci's real alarm and overlaying *only* properties floci
accepted and discarded, so `describe-alarms` reports `TreatMissingData: ignore` through it:

```
via floci   AWS/Billing  EstimatedCharges  None
via shim    AWS/Billing  EstimatedCharges  ignore
            OverlaidFromTemplate: {"taxcalc/estimated-charges-dev": ["TreatMissingData"]}
```

Three rules keep that from becoming a lie:

- **It only fills a hole.** A value floci *did* store is never overwritten, even where it
  disagrees with the template — that disagreement is drift, and hiding it would defeat
  `detect-drift`. `AlarmDescription` and `ActionsEnabled` are on the overlayable list and were
  *not* overlaid here, because floci stored them.
- **The overlay is named in the response**, per alarm, in `OverlaidFromTemplate`.
- **The overlayable set is an explicit list**, not "anything missing", so it cannot silently grow
  to cover a property floci starts dropping later without someone deciding that is acceptable.

What this does **not** do: floci's alarm still evaluates a gappy metric as `missing`. Its firing
behaviour cannot be tested on this engine by any means. And the Done-When itself — namespace and
metric name — is live and correct without any of this, which is why check 3 stays a `PASS` rather
than becoming a `SHIM`.

### 4. `floci-cost-apis-shim.py` — two missing read APIs, **not equally trustworthy**

| endpoint | floci | the shim serves | worth |
|---|---|---|---|
| `resourcegroupstaggingapi GetResources` | "running", indexes **nothing, ever** | live reads from `ec2 describe-tags`, `rds list-tags-for-resource`, `sns`/`s3api` at request time | a missing **index** reimplemented over real records — untag a resource and the answer changes |
| `budgets DescribeBudget` | service **absent entirely** | a projection of the deployed stack's template, fetched via `get-template` | evidence of **what the template asked for**, and nothing else |

The second is the one to be careful with. There is no budget on this endpoint to read, so the
response cannot be evidence that a budget exists, that its `CostFilters` match anything, or that
it would ever notify.

An empty `GetResources` list, incidentally, is worse than an error: it is the same answer for
every possible query, so it reads as a finding. Measured — an S3 bucket whose own
`get-bucket-tagging` returns the tag is still invisible to `get-resources`.

**A caveat cannot be delivered in the response body.** Each response carries a `ShimProvenance`
key *and* an `x-floci-shim` header. Only the header survives: botocore validates responses against
its own service model and silently drops any member the model does not declare, so
`aws budgets describe-budget` never shows `ShimProvenance`. Same reason the two notifications must
be read with `describe-notifications-for-budget` — a modelled call — rather than from
`DescribeBudget`.

All four workarounds **refuse to run against a real account** (`AWS_ENDPOINT_URL` unset). There,
CloudFormation applies these properties itself and reaching around it is precisely the drift
`detect-stack-drift` exists to catch.

### 5. `guard-update` — the plan is right, the execution is wrong, so don't execute

Task 1's "re-deploy with an UPDATE ChangeSet" was exercised properly — the pre-W6-D4 template
(the committed file minus its four tag lines) deployed as the baseline, then an UPDATE ChangeSet
to the committed template. **The ChangeSet is exactly right:**

```
Modify   DbInstance   AWS::RDS::DBInstance   Replacement: False
```

One resource, tags only, no replacement — the reviewable artefact the task is really asking for.
**The execution then rolled back**, on a resource the ChangeSet did not list:

```
DbMasterSecret  UPDATE_IN_PROGRESS -> UPDATE_FAILED
                "A secret with the name taxcalc/dev/db-master already exists."
```

**The diagnosis is worse than "Secrets Manager is special."** A four-resource probe stack whose
update changes exactly one resource's tags isolates it: the event trace shows floci starting at
`Sec`, failing, and aborting — so `Vpc`, *the only planned change*, is never reached. floci's
update path **iterates every resource in the template rather than the plan's change list**, and
implements several update handlers as create.

The reason this usually looks like it works is the uncomfortable part. `CreateTopic` and
`CreateBucket` on an existing name are idempotent and return the existing resource, so re-creating
them is invisible. `CreateSecret` is not, and throws. **A template of purely idempotent types
would update green while silently re-creating everything in it.** The secret is the canary, not
the bug.

`cfn-guardrails.sh guard-update <stack>` handles this:

1. **Always** produces the plan — `create-change-set` + `describe-change-set` — because the plan
   is correct on this endpoint and is what the review is about. It fails the run outright on any
   `Replacement: True`.
2. **Probes** whether this endpoint's execution honours the plan, with a disposable stack rather
   than an assumption, so the same command is right against real AWS.
3. Honoured → executes normally. Not honoured → **refuses to execute**, because executing leaves
   the stack in `UPDATE_ROLLBACK_COMPLETE`, which is strictly worse than not trying. It then names
   the deliberate follow-up: for a tag-only change, `reconcile-tags`.

End to end on floci, the refused update leaves the stack healthy and the planned change still
gets applied:

```
Plan:  Modify  DbInstance  AWS::RDS::DBInstance  False
GAP:   this endpoint's execute-change-set does NOT honour the change set -> NOT EXECUTING
stack after the refusal:  CREATE_COMPLETE        (not UPDATE_ROLLBACK_COMPLETE)
reconcile-tags:           tags before []  ->  after [Project env feature Env service tenant]
```

It also handles a no-op update honestly: real CloudFormation *fails* a no-op change set
("didn't contain changes"), while floci returns `CREATE_COMPLETE` with an empty `Changes` list —
which would otherwise read as "nothing is replaced", true and completely uninformative.

In the same family, and not worked around: floci's `delete-stack` leaves the RDS instance and the
secret behind, so a rebuild fails with "already exists" until they are deleted by hand.

**Summary of what each Done-When is worth, after the workarounds:** checks 1 and 3 are genuine —
the stack reaches `CREATE_COMPLETE` through the real ChangeSet flow and the alarm is real and
readable. Check 4's **tags are real** and only the index is stood in for. Check 2 is a template
projection and establishes nothing about a budget.

**Four things a real account is still the only way to establish**, and no local workaround
touches any of them — every workaround above changes what can be *read*, never what the
infrastructure *does*:

| still unverifiable | why no shim helps |
|---|---|
| the Budget exists and would notify | there is no budget to read; the shim projects the template |
| the SNS `TopicPolicy` takes effect | floci drops it and leaves the topic **wider** than the template asks |
| the alarm's firing behaviour on a gappy metric | floci's alarm evaluates as `missing` whatever `describe-alarms` reports |
| tag-scoped cost attribution | an emulator bills nobody, so no tag key is activated and Cost Explorer has nothing to group |

---

## `cost-author` audit

`.claude/skills/cost-author/SKILL.md` — authored locally, because `/cost-author` was **absent
from this session's skill listing**, the fourth deliverable running into that gap after
`cfn-author` (W6 D3), `argocd-author` (W6 D2) and `github-actions-author` (W6 D1).

**Provenance caveat, and it is not a formality.** A generator written by the same author as the
artefacts under review will tend to agree with them, and this pass was **not cold** — the cost
stack, the tag taxonomy and the cost package were all written before the skill was. A clean diff
here is therefore evidence of very little, and is reported as such.

- **Accepted:** *tag the Elastic IPs, not just the NAT Gateways.* The brief asks only for
  `NatGateway*` and the `DBInstance`. An attached EIP is free, so tagging it looks like busywork —
  until a teardown leaves one detached at ~$3.60/mo, untagged, and therefore invisible to the very
  Budget meant to catch it. Adopted in `taxcalc-network-dev.yaml`; it closes a hole the tag-scoped
  design creates by construction.

- **Rejected:** *raise the billing alarm threshold to track the Budget limit automatically.* The
  suggestion was to derive `BillingAlarmUsd` from `MonthlyBudgetUsd` (e.g. `1.2x`) so the two
  never drift. Declined: they are measuring **different things** — the Budget is tag-scoped and
  the alarm is account-wide — so coupling them encodes an assumption that this service is the only
  thing in the account. The day a second service lands, the account-wide threshold should move and
  the tag-scoped one should not. Two independent numbers with stated derivations beat one number
  with a multiplier.

### The second pass — rejections with output, not an absence

The first pass reviewed the committed artefacts, found none of the three failure modes the task
names, and recorded them as **not observed** rather than manufactured. That was honest and it was
not the deliverable: *a rejection rule that has never fired is indistinguishable from one that is
not wired*, and a clean review cannot tell those two apart.

So a second pass ran on branch `scratch/cost-author` against
`.cost-author-out/candidate/` — three templates authored **to carry** the three defects.
Reproduce with `./.cost-author-out/audit.sh`; the full record is in
`.cost-author-out/AUDIT.md`. All three now reject with output:

| Rejected | Gated by | Evidence |
|---|---|---|
| untagged NAT Gateway, EIP and RDS instance | `cfn-guardrails.sh` check 5 | 12 findings (3 resources × 4 keys) |
| `TreatMissingData: notBreaching` on the billing alarm | check 6 | `candidate/taxcalc-cost-dev.yaml:142` |
| an `AWS::Budgets::Budget` aimed at Anthropic spend | check 7 | `LlmSpendBudget` |

**16 failures on the candidate; 0 on the committed `cfn/`.** Checks 5 and 6 were delegated to the
repo's own tracked gate via `CFN_DIR` rather than reimplemented, which is the difference between
proving the *shipping* check catches these and proving an audit script can. The second half of the
run matters as much as the first: without re-running every detector against the real `cfn/` and
requiring silence, a detector that matched everything would look exactly like a working audit.

- **Accepted (second pass):** *port the third rejection into the tracked gate.* The run surfaced
  that checks 5 and 6 gated two of the three named defects on every PR, while the third existed
  only as a paragraph here and a row in the skill's table — enforced by whoever remembered it.
  That is the weakest control guarding the most convincing defect: an LLM-targeted Budget is
  syntactically perfect, deploys, and reports 0% utilisation forever. Adopted as
  `cfn-guardrails.sh` **check 7**, and proved to fire rather than merely added.

  The detector deliberately does **not** match Amazon Bedrock — that is a hosted model *and*
  AWS-resident spend, so a Bedrock-scoped Budget is legitimate. Keying on "is this about an LLM?"
  would reject a correct template. The axis is *who is the merchant?*, the same one that puts the
  self-hosted embeddings service on neither plane at the top of this document.

**What the second pass does not fix.** Provenance is unchanged: the skill was authored locally,
the artefacts predate it, and the pass is still **not cold**. The upgrade is narrow and worth
stating precisely — that the detectors *discriminate* is now demonstrated; that the committed
templates are clean is still the same weak author-agrees-with-author evidence it was. Five of the
skill's eight findings (missing `TopicPolicy`, an alarm outside us-east-1, mixed tag-key casing,
a price table with no staleness note, cost in `double`) were **not** planted and are **not**
claimed as verified.

---

## Deploying the cost stack

```bash
aws cloudformation create-change-set --stack-name taxcalc-cost-dev \
  --change-set-name initial --change-set-type CREATE \
  --template-body file://cfn/taxcalc-cost-dev.yaml \
  --parameters ParameterKey=EnvName,ParameterValue=dev --region us-east-1
aws cloudformation describe-change-set --stack-name taxcalc-cost-dev --change-set-name initial
aws cloudformation execute-change-set --stack-name taxcalc-cost-dev --change-set-name initial
```

**us-east-1 is load-bearing, not a default** — see the alarm's Condition above.

Then activate the four tag keys in **Billing → Cost allocation tags**. Nothing in the template can
do this, and until it is done the Budget's filters match nothing.
