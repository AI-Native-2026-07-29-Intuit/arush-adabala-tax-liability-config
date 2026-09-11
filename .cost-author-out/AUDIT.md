# `cost-author` audit — the demonstrated pass

W6 D4 Task 4, third bullet. Run on branch `scratch/cost-author`, against
`.cost-author-out/candidate/` — three templates authored **to carry** the three
defects the task names, so the three rejections are events with output rather
than assertions about an absence.

Reproduce with `./.cost-author-out/audit.sh` from the repo root.

---

## Why this run exists at all

The first pass (recorded in `taxcalc-api/COST.md`) reviewed the committed
artefacts, found none of the three named failure modes, and said so:

> The skill's own named failure modes were checked against the committed
> artefacts and recorded as **not observed** rather than manufactured […] their
> absence is weak evidence and is reported that way.

That paragraph is honest and it is also not the deliverable. The task asks the
skill to **reject** three specific things; a rule that has never fired is
indistinguishable from a rule that is not wired, and the earlier pass could not
tell those apart. This run supplies inputs that earn the rejections, then
re-runs every detector against the real `cfn/` so a green result cannot come
from a detector that matches everything.

## Provenance — the same caveat, and it has not improved

`.claude/skills/cost-author/SKILL.md` was authored locally, because
`/cost-author` was absent from the session's skill listing — the fourth
deliverable to hit that gap after `cfn-author`, `argocd-author` and
`github-actions-author`. **This pass is still not cold.** The cost stack, the
taxonomy and the app's cost package were all written before the skill, and
before this audit. What changed between the two passes is narrower than it
looks, and worth stating exactly:

- **Still weak evidence:** that the committed `cfn/` passes. Author agreement
  with their own artefacts predicts that outcome regardless.
- **Now real evidence:** that the detectors *discriminate*. A detector proved to
  fire on a defect and stay silent on the real template has demonstrated
  something no amount of clean-diff reporting can.

The second is the only claim this run upgrades. It does not make the first
stronger.

---

## Rejected (3 of 3 — each with the output that produced it)

### 1. Untagged NAT Gateway, EIP and RDS instance

Gated by the repo's own `scripts/cfn-guardrails.sh --static` check 5, pointed at
the candidate via `CFN_DIR`. Delegating to the tracked gate rather than
reimplementing the rule is deliberate: it proves the **shipping** check catches
this, not that the audit script can.

```
5. Cost-allocation tag coverage on billable resources (static)
  FAIL  candidate/taxcalc-app-dev.yaml: DbInstance is billable but has no 'service' cost-allocation tag
  FAIL  candidate/taxcalc-app-dev.yaml: DbInstance is billable but has no 'env' cost-allocation tag
  FAIL  candidate/taxcalc-app-dev.yaml: DbInstance is billable but has no 'tenant' cost-allocation tag
  FAIL  candidate/taxcalc-app-dev.yaml: DbInstance is billable but has no 'feature' cost-allocation tag
  FAIL  candidate/taxcalc-network-dev.yaml: NatGatewayAEip is billable but has no 'service' cost-allocation tag
  …
  FAIL  candidate/taxcalc-network-dev.yaml: NatGatewayA is billable but has no 'feature' cost-allocation tag
```

Twelve findings across three resources × four keys. **Why it is a rejection and
not a nit:** a tag-scoped Budget filters on `service` AND `env`, so a resource
missing either contributes spend the Budget cannot see. The Budget does not go
red — it silently guards less while continuing to report green. The NAT is also
the largest recurring line item in the account, so the resource most worth
watching is the one the guardrail loses first.

The candidate's RDS instance carries `Env`/`Project`, which is the trap worth
naming: it *looks* tagged. `Env` and `env` are different cost-allocation keys
requiring separate activations, so "it has tags" and "the Budget can see it"
are unrelated statements.

### 2. `TreatMissingData: notBreaching` on a meaningful alarm

Check 6, same gate:

```
6. Billing alarm does not use TreatMissingData: notBreaching (static)
  FAIL  TreatMissingData: notBreaching found in .cost-author-out/candidate/
        .cost-author-out/candidate/taxcalc-cost-dev.yaml:142:      TreatMissingData: notBreaching
```

`AWS/Billing` `EstimatedCharges` refreshes roughly every 6h, so missing
datapoints are routine. `notBreaching` reads each gap as OK, which on this
metric **erases** a breach: the alarm goes ALARM, the next window has no data,
and it resets itself to OK having notified once or not at all.

The inverted case is the reason this is a judgement and not a lint rule. On a
metric-pipeline alarm — an app error rate — silence means the pipeline broke and
`breaching` is the safe reading. Same property, opposite answer, because the two
metrics fail in opposite directions. A detector that banned the token everywhere
would be wrong; this one is scoped to `cfn/`, where the only alarm is the
billing one.

### 3. An AWS Budget created to cap Anthropic spend

No counterpart exists in the tracked gate, so the detector lives in
`audit.sh` — see the acceptance below, which is about exactly that gap.

```
-- rejection 3, an AWS Budget aimed at non-AWS spend --
  .cost-author-out/candidate/taxcalc-cost-dev.yaml: LlmSpendBudget
  OK: rejected - AWS Budgets cannot see spend AWS does not bill
```

`LlmSpendBudget` is syntactically perfect, deploys cleanly, and would be
returned by `describe-budget` looking exactly like the legitimate budget beside
it. It would also report 0% utilisation forever. Anthropic bills to an Anthropic
workspace; AWS is not the merchant, so there is no AWS cost record for
`user:feature$explain-liability` to match and **no tag anybody could apply that
would create one.** This is the most dangerous of the three defects because it
is the one that produces a control a reviewer ticks off.

The correct control for that spend is named in `COST.md`: the Anthropic Console
workspace spend limit (the cap, enforced by the party doing the billing), with
`CostLogger`'s EMF line and the `X-Cost-Usd` header providing attribution.

**One deliberate non-match, and it is the whole distinction:** the detector does
**not** key on Amazon Bedrock. Bedrock is a hosted model *and* AWS-resident
spend, so a Bedrock-scoped Budget is legitimate. Keying on "is this about an
LLM?" would reject a correct template. The question is never *is it AI?* — it is
*who is the merchant?*, which is the same axis `COST.md` uses to put the
self-hosted embeddings service on neither plane.

---

## Accepted (1)

**Port the rejection-3 detector into `scripts/cfn-guardrails.sh` as check 7.**

Surfaced by this run rather than asserted: rejections 1 and 2 are enforced by the
tracked gate and therefore gate every PR, while rejection 3 was only ever a
paragraph in `COST.md` and a row in the skill's table. Nothing stopped an
Anthropic-targeted Budget being committed. That is the weakest of the three
controls guarding the defect with the most convincing disguise — precisely
inverted from where the effort should sit.

Adopted on `w6d4-implementation` as check 7, carrying the Bedrock exclusion and
the comment-stripping (so the paragraphs in `taxcalc-cost-dev.yaml` explaining
why an LLM budget is wrong do not trip the check that enforces it — the same
failure that forced check 6's first spelling to be rewritten).

Proved to fire by running it against the candidate, not merely by adding it.

## Carried forward from the first pass

- **Accepted:** tag the NAT Gateways' Elastic IPs, which the brief does not ask
  for. An attached EIP is free; a *detached* one bills ~$3.60/mo, and a detached
  EIP is exactly what a half-finished teardown leaves behind — untagged, it is
  invisible to the very Budget meant to catch it.
- **Rejected:** deriving `BillingAlarmUsd` from `MonthlyBudgetUsd` (e.g. `1.2x`)
  so the two never drift. They measure different things — the Budget is
  tag-scoped, the alarm is account-wide — so coupling them encodes the
  assumption that this service is the only thing in the account. Two independent
  numbers with stated derivations beat one number with a multiplier.

---

## Not planted, and therefore still unproven

The skill lists eight findings; this run exercised three. The other five —
missing `TopicPolicy`, a billing alarm outside us-east-1, mixed tag-key casing,
a price table with no staleness note, cost accumulated in `double` — were **not**
planted and are **not** claimed as verified. The candidate's `Env`/`env` pairing
brushes the casing rule without a detector asserting it.

Listing them is the point: the three the task names now have firing evidence,
and the rest have the same weak absence-evidence as before. Saying which is
which is the difference between an audit and a checklist.
