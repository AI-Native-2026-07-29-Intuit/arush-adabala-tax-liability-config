# INFRA.md — how this service's AWS substrate is provisioned, and what overrode the defaults

> **On the path.** W6 D2's `GITOPS.md` argued *against* a `taxcalc-api/`
> subdirectory, because that file lives in the application repo and *that
> repository is `taxcalc-api`* — a directory named after the repo nests every
> path one level deeper for nothing. The same argument points the other way
> here. This file lives in the **config** repo, which is not `taxcalc-api`; it
> holds one service's desired state today and is the obvious home for a second
> service's tomorrow. Here the subdirectory names something real: whose
> infrastructure this is.

---

## Status — read this before using anything below as evidence

**No stack in this document has been deployed.** There is no AWS account wired
to this repository: `aws sts get-caller-identity` fails with `NoCredentials` on
the default profile and `InvalidClientTokenId` on the only configured profile
(`floci`, whose static key is expired), and `vars.AWS_ACCOUNT_ID` is unset on
the repo, which is what keeps `cfn-validate.yml`'s AWS steps skipped rather
than red.

So this document separates cleanly into two halves, and the split is marked
throughout:

| | Ran | Evidence |
|---|---|---|
| `cfn-lint` 1.22.3 | **yes** | 0 errors on all four templates |
| `cfn_nag_scan` 0.8.10 `--fail-on-warnings` | **yes** | 0 failures, 0 warnings on all four — after fixing one real failure, below |
| Export/import name cross-check | **yes** | every `!ImportValue` in the app stack resolves to an export the network stack declares |
| `aws cloudformation validate-template` | no | needs credentials |
| ChangeSet create → describe → execute | no | needs credentials |
| `detect-stack-drift` | no | needs credentials |
| Cross-stack delete refusal | no | needs credentials |

Everything in the second group has its exact command recorded below with the
output to expect, so it is a matter of running them once an account exists —
not of writing anything new. **Nothing in this file is a transcript of a run
that did not happen.**

---

## Stack layout

Four stacks, deliberately split along blast-radius lines rather than by
convenience. The rule: things with different lifetimes do not share a stack.

```
taxcalc-bootstrap-dev    Artefact bucket for `aws cloudformation package`
                         + the IAM role GitHub Actions assumes via OIDC to
                         deploy everything else. Deployed once, by a human
                         with admin, and then essentially never again.

taxcalc-artifacts-dev    The hardened S3 artefact bucket the W5 D4 SAM builds
                         and Argo CD config snapshots land in. Imports
                         nothing, so it is orderable anywhere before the app
                         stack that writes to it.

taxcalc-network-dev      3-AZ VPC, 6 subnets (public + private per AZ), IGW,
                         1-3 NAT GWs gated by EnvName, route tables, and the
                         application security group. Exports VpcId, VpcCidr,
                         PublicSubnets, PrivateSubnets, AppSgId,
                         AppDesiredCount. Long-lived; rebuilding it churns
                         every subnet id in the account.

taxcalc-app-dev          RDS Postgres + DB subnet group + DB SG + the
                         Secrets Manager master credentials. Consumes the
                         network stack via !ImportValue. The stack that
                         changes most often.
```

### Deploy order

```
1. taxcalc-bootstrap-dev    creates role/taxcalc-api-cfn-deploy, which every
                            later CI-driven deploy assumes
2. taxcalc-artifacts-dev    independent; before the app stack writes to it
3. taxcalc-network-dev      exports the ids stack 4 imports
4. taxcalc-app-dev          fails at CREATE if 3 has not exported yet
```

Only one edge is enforced by CloudFormation itself: step 4's `!ImportValue`
calls fail outright if step 3's exports do not exist, with
`No export named taxcalc-network-dev-PrivateSubnets found`. The other three
orderings are conventions, and a human can violate them.

### Export naming

Every export is `${AWS::StackName}-<Thing>`, never a hardcoded string.

```yaml
Export: {Name: !Sub "${AWS::StackName}-PrivateSubnets"}
```

The consumer parameterises the producing stack's name rather than the export:

```yaml
NetworkStackName:
  Type: String
  Default: taxcalc-network-dev
...
!ImportValue
  "Fn::Sub": "${NetworkStackName}-PrivateSubnets"
```

Two things fall out of that. A throwaway network (`taxcalc-network-scratch`)
can be stood up and pointed at with a `--parameters` override and no template
edit. And export names cannot collide across environments, because the stack
name already carries `dev`/`staging`/`prod` — **export names are unique per
region per account**, so a literal `taxcalc-PrivateSubnets` would make the
second environment in the account undeployable.

**Subnet ids are comma-joined on the way out and `!Split` on the way in**,
because a CFN export cannot hold a `List` type. Exporting three ids under one
name has no other spelling.

---

## The ChangeSet flow

Every stack, every change. Never `aws cloudformation deploy`, which creates a
ChangeSet and immediately executes it — the review step is the entire point.

```bash
aws cloudformation create-change-set \
  --stack-name       taxcalc-network-dev \
  --change-set-name  w6d3-initial \
  --change-set-type  CREATE \
  --template-body    file://cfn/taxcalc-network-dev.yaml \
  --capabilities     CAPABILITY_NAMED_IAM \
  --parameters       ParameterKey=EnvName,ParameterValue=dev \
  --region           us-east-1

aws cloudformation wait change-set-create-complete \
  --stack-name taxcalc-network-dev --change-set-name w6d3-initial --region us-east-1

aws cloudformation describe-change-set \
  --stack-name taxcalc-network-dev --change-set-name w6d3-initial --region us-east-1
# review; paste the JSON diff into the PR body

aws cloudformation execute-change-set \
  --stack-name taxcalc-network-dev --change-set-name w6d3-initial --region us-east-1
```

`--change-set-type CREATE` for a stack that does not exist yet, `UPDATE`
thereafter. Getting this wrong is a clear error rather than a silent one:
`CREATE` against an existing stack fails with `AlreadyExistsException`.

`CAPABILITY_NAMED_IAM`, not `CAPABILITY_IAM`, wherever an IAM principal's
name is fixed by the template — `CfnDeployRole` sets `RoleName:
taxcalc-api-cfn-deploy`, and CFN demands the stronger acknowledgement
whenever a name is pinned rather than generated, because a pinned name can
collide with or impersonate an existing principal.

**What to read in `describe-change-set`.** The field that matters is
`Replacement` on each `ResourceChange`:

- `Replacement: False` on a `Modify` — changed in place, no downtime.
- `Replacement: True` — **the resource is destroyed and recreated.** On an
  RDS instance or an S3 bucket that is data loss unless
  `UpdateReplacePolicy: Retain` is set, which is why every data resource here
  carries it.
- `Replacement: Conditional` — CFN cannot tell in advance. Treat as `True`.

A ChangeSet that reports `Replacement: True` on `DbInstance` should not be
executed without a snapshot, whatever the PR says it does.

---

## Drift detection

*(Commands recorded; not yet run — see Status.)*

```bash
aws cloudformation detect-stack-drift \
  --stack-name taxcalc-artifacts-dev --region us-east-1
# -> {"StackDriftDetectionId": "..."}

aws cloudformation describe-stack-drift-detection-status \
  --stack-drift-detection-id <id> --region us-east-1
# poll until DetectionStatus == DETECTION_COMPLETE, then read StackDriftStatus

aws cloudformation describe-stack-resource-drifts \
  --stack-name taxcalc-artifacts-dev --region us-east-1 \
  --query "StackResourceDrifts[?StackResourceDriftStatus!='IN_SYNC']"
```

The intended exercise: add a tag to the artefact bucket in the console, expect
`StackDriftStatus: DRIFTED` with the `BucketPolicy` or bucket resource
`MODIFIED` and a `PropertyDifferences` entry naming the added tag; revert the
console edit; re-run and expect `IN_SYNC`.

**Two things worth knowing before relying on this.** Drift detection does not
cover every resource type — unsupported resources come back
`NOT_CHECKED`, and a stack full of them can report `IN_SYNC` while being
anything but. And it is a **point-in-time poll, not a watch**: nothing runs it
on a schedule here, so today drift is found when somebody asks. That is a
strictly weaker guarantee than the Argo CD half of this repo, where
`selfHeal` reverts a drifted ConfigMap within about 10 seconds
(measured, W6 D2 — see `GITOPS.md`). The asymmetry is worth stating plainly:
**the Kubernetes layer self-heals, the AWS layer does not even alarm.** A
scheduled `detect-stack-drift` job belongs on the W6 D5 list.

---

## Cross-stack reference health check

*(Not yet run — see Status.)*

```bash
aws cloudformation delete-stack --stack-name taxcalc-network-dev --region us-east-1
```

Expected: refusal, with

```
Export taxcalc-network-dev-PrivateSubnets cannot be deleted as it is in use by taxcalc-app-dev
```

That refusal is the safety `Export.Name` buys, and it is the argument for
`!ImportValue` over copied ids in one line. A hardcoded subnet id gives no
such protection — the network stack deletes cleanly, and the app stack keeps
pointing at subnets that no longer exist until the next operation that
touches them fails for a reason that names the subnet rather than the cause.

---

## Six decisions that departed from the reference layout

These are the places the committed templates disagree with the cohort's
canonical appendix. Each one changed the YAML.

### 1. `DependsOn: DbMasterSecret` on the RDS instance — a real race

The reference sets `MasterUserPassword` to a
`{{resolve:secretsmanager:...}}` string and creates the secret in the same
stack, with no dependency between them. **CFN does not parse dynamic
references when it builds the dependency graph** — the resolve string is an
opaque literal, so nothing tells CloudFormation the instance needs the secret
to exist first. The two are then free to be created in parallel, and the
deploy fails intermittently on a secret that "does not exist" moments before
it does. Intermittently is the bad part: it will pass in dev and fail in prod.
The explicit `DependsOn` is the fix.

### 2. The DB security group had implicit allow-all egress — caught by cfn-nag

The reference `DbSecurityGroup` specifies only `SecurityGroupIngress`.
**Omitting egress is not "no egress"** — CFN falls back to the default
allow-all rule, so the database could open outbound connections to anywhere
on the internet. `cfn_nag_scan` flagged it as a **FAIL**, not a warning:

```
| FAIL F1000
| Resource: ["DbSecurityGroup"]
| Missing egress rule means all traffic is allowed outbound.
```

This is the one finding in the whole pass that came from the tool rather than
from reading, and it is a good argument for the tool. The fix is awkward and
worth explaining: CFN treats `SecurityGroupEgress: []` as *unset* and restores
the allow-all default, so "no egress" has no direct spelling. The narrowest
expressible rule — tcp/5432 to `127.0.0.1/32`, unroutable from the ENI — is
inert by construction while still being a rule, which is what displaces the
default.

### 3. `MapPublicIpOnLaunch` removed rather than suppressed

The reference sets it `true` on all three public subnets; `cfn-nag` W33 flags
it. "Public" here means IGW-routed, not auto-addressed — the only things this
stack puts in those subnets are NAT Gateways, which carry their own Elastic
IPs and ignore the flag entirely. It bought nothing and would have silently
given a public address to anything a later stack launched there. **Removed,
not suppressed**: a suppression would have kept the exposure and hidden the
warning.

### 4. Egress 5432 is CIDR-scoped, not SG-to-SG — a cycle that has no clean fix

The task text asks the app SG for "egress 5432 to the RDS SG". Taken
literally that is a **cross-stack cycle**: the network stack would import from
the app stack, which already imports `AppSgId` from the network stack.

The usual escape — declare an `AWS::EC2::SecurityGroupEgress` in the app stack
and attach it to the imported SG — breaks the cycle but has a cost nobody
mentions: it leaves the *network* stack permanently `DRIFTED`, because a rule
exists on that SG which the network template does not describe. Task 4's whole
point is a `detect-stack-drift` that can read `IN_SYNC`, and this would make
that impossible forever.

So the app SG egresses to `5432` on the **VPC CIDR**, and the tight direction
is enforced where it costs nothing: the DB SG's *ingress* is
`SourceSecurityGroupId: !ImportValue ...-AppSgId`. Membership of the app SG is
the credential. A box merely sitting in the same subnet range still cannot
open a Postgres connection — which is the property the SG-to-SG pairing was
wanted for in the first place.

### 5. `EngineVersion` is a Parameter, not a literal

The reference hardcodes `"16.3"`. AWS deprecates RDS minor versions on its own
schedule, and when this one goes away a hardcoded literal makes the fix a
template edit, a PR and a review — for a value that has nothing to do with the
change being deployed. As a Parameter it is a `--parameters` override on the
next ChangeSet.

### 6. Explicit names kept only where they are load-bearing

`cfn-nag` W28 flags every explicitly-named resource, because an explicit name
blocks any update that needs replacement. Both calls were made on that basis
rather than uniformly:

- **`CfnDeployRole` keeps `RoleName`** — GitHub Actions has to name the role in
  `role-to-assume` *before* the stack can be queried, so the ARN must be
  derivable from the account id alone.
- **`DbInstance` keeps `DBInstanceIdentifier`** — it is the handle every
  operational path uses: `describe-db-instances`, snapshot names, console
  search, CloudWatch metric dimensions.
- **`TaxcalcAppSecurityGroup` lost its `GroupName`** — nothing consumes it.
  Consumers import the SG *id*, so a generated name costs nothing and keeps
  the SG replaceable in place.

---

## Every cfn-nag suppression, and why

A suppression is an argument, so each one is written at the resource with its
reasoning in `Metadata.cfn_nag.rules_to_suppress` — in the diff, where a
reviewer can disagree with it. There are five.

| Rule | Resource | Why |
|---|---|---|
| W35 | both S3 buckets | Access logging off. Writers are CI roles, readers are CFN and Argo CD, and both are already audited at the API layer by account-scoped CloudTrail. A dedicated log bucket would need its own W35 exemption — that moves the suppression rather than removing it. |
| W28 | `CfnDeployRole`, `DbInstance` | Explicit names that are load-bearing; see decision 6. |
| W5 | app SG | 443 egress to `0.0.0.0/0`. ECR, STS and Secrets Manager are reached over public service endpoints with no stable IP range. The narrower fix is VPC endpoints — W6 D4 scope. |
| W9 | app SG | Ingress is the VPC CIDR rather than a /32. Callers are pods with no stable address. **This is not `0.0.0.0/0`** — nothing outside the VPC reaches 8080. |
| W60 | `Vpc` | No flow log. Flow logs are only worth having when they land somewhere durable and queryable; wiring a per-VPC log group here would create a second destination divergent from the W6 D5 observability stack. |
| W77 | `DbMasterSecret` | No CMK, so the secret uses the AWS-managed key. Cross-account sharing and key-policy revocation have no consumer today. Becomes wrong the moment ESO reads it from another account. |

---

## Why `NoEcho: true` is not good enough for a password

It is the single most common way a secret leaks out of CloudFormation, so it
is worth being exact about what `NoEcho` does and does not do.

`NoEcho: true` masks the parameter's value in `describe-stacks` output and in
the console. It does **not** stop the value from travelling as plaintext in
the `CreateStack` / `CreateChangeSet` API call, from sitting in the ChangeSet
until that is deleted, or from appearing in the shell history and CI logs of
whoever passed it on the command line.

The dynamic reference has a different shape entirely: the value never enters
the template, the API call or the stack state. CloudFormation resolves
`{{resolve:secretsmanager:taxcalc/dev/db-master:SecretString:password}}` at
resource-creation time and hands the result straight to the RDS API. Reading
it needs a `secretsmanager:GetSecretValue` grant on that specific secret —
`cloudformation:DescribeStacks` and `GetTemplate` reveal nothing.

Here the password is never even written down: `GenerateSecretString` has
Secrets Manager mint a 32-character value that no human and no template has
ever seen.

---

## AI deliverable — `cfn-author` Skill audit notes

### Provenance — read this before weighing the findings

**The `cfn-author` Skill was not distributed by the course.** It was absent
from the session's skill listing, exactly as `argocd-author` was for W6 D2 and
`github-actions-author` for W6 D1 (both recorded in the application repo's
README). It was therefore **authored locally**, at
`.claude/skills/cfn-author/SKILL.md` in the application repo, written to
standard CloudFormation conventions and the cohort reference layout.

It was then run:

```
/cfn-author taxcalc --region us-east-1 --env dev --vpc-cidr 10.41.0.0/16 \
  --out .cfn-author-out/
```

Output is on this repo's **`scratch/cfn-author`** branch under
`.cfn-author-out/`, mirroring the real paths so each artefact diffs against
its counterpart. The branch is never merged.

Two caveats, stated rather than buried, because they bound what the section
below is worth:

- **The pass was not cold, and could not have been.** `argocd-author`'s
  SKILL.md carries a hard rule against reading the artefacts under review, and
  so does this one — but that rule constrains the *procedure*, not the memory
  behind it. The four templates and the skill were written in the same working
  session. A cold pass is not something that can be claimed here.
- **A generator written by the same author as the artefacts will tend to
  agree.** Under-disagreement is the expected failure mode. **A clean diff
  would have been evidence of nothing** — the deviations below are worth
  something because they exist, not because they are numerous.

### The one measurement the caveats do not touch

Whatever the provenance argument, both trees were run through the same two
tools, and they do not agree:

```
generated (.cfn-author-out/cfn)   cfn-lint 0 errors
                                  cfn_nag_scan  1 FAILURE, 11 warnings
                                  (F1000, W28 ×3, W33, W35 ×2, W5, W60, W77)

committed (cfn/)                  cfn-lint 0 errors
                                  cfn_nag_scan  0 failures, 0 warnings
```

**The generated set does not pass this repo's own CI gate.** Its
`cfn-validate.yml` job would go red on `cfn_nag_scan --fail-on-warnings` at
the F1000 failure alone. That is not a stylistic difference and it does not
rest on anybody's judgement.

### What the generated output actually disagreed about

Five substantive deviations, from `diff -u` per artefact. Comment-only
differences are excluded — the generated files are terse and the committed
ones are heavily commented, which accounts for most of the raw diff and none
of the meaning.

| # | Field | Generated | Committed | Correct |
|---|---|---|---|---|
| 1 | `DbSecurityGroup` egress | absent (allow-all) | explicit, inert rule | **committed** |
| 2 | App SG egress to 5432 | absent entirely | present, VPC-CIDR scoped | **committed** |
| 3 | `DependsOn: DbMasterSecret` | absent | present | **committed** |
| 4 | `MapPublicIpOnLaunch` | `true` | omitted | **committed** |
| 5 | `EngineVersion` | literal `"16.3"` | a Parameter | **committed** |

**1 is the one the tool caught rather than a human.** See decision 2 above —
it is a `FAIL`, not a warning, and it means the database could open outbound
connections to anywhere on the internet.

**2 is the one that would have looked fine and not worked.** The generated app
SG enumerates egress on 443 only. Enumerating *any* egress replaces the
default allow-all, so the application would have had no route to Postgres on
5432 at all — a VPC, a database and a security group that all deploy cleanly,
report `CREATE_COMPLETE`, and cannot talk to each other. Neither cfn-lint nor
cfn-nag flags this; it is only visible by reading the rule set as a whole and
asking what is missing. **This is the strongest argument in the audit for
reading generated infrastructure rather than deploying it**: the failure is an
absence, and no linter has an opinion about absences that are legal.

**5 is the mildest and still worth taking.** A hardcoded engine version is
correct until AWS deprecates it, at which point it is a template edit and a PR
for a value unrelated to the change being shipped.

### A sixth deviation, in the generated workflow

`.cfn-author-out/.github/workflows/cfn-validate.yml` pins
`aws-actions/configure-aws-credentials` to a **42-character string**. A git
SHA is 40. It is not a valid ref, and GitHub agrees:

```
$ gh api repos/aws-actions/configure-aws-credentials/commits/e3dd6a429d7300a6a6a4c196c26e071d42e0343502
No commit found for SHA: ... (HTTP 422)
```

The workflow would fail at step setup with an unresolvable action, on every
run, forever. The committed workflow pins `@cbe3b392738ccf3f987d68400dafcf4b0624a56c`
(v6.2.4) — the same SHA the application repo already uses — and all three of
its action pins were checked against the GitHub API before commit. Worth
generalising: **a pinned SHA is only as good as the one check nobody runs.**

### The three checklist quirks

The skill's own audit checklist names three failure modes to look for. Checked
one by one against the generated output:

| # | Quirk | Observed? | Committed templates |
|---|---|---|---|
| 1 | `StringLike` on the OIDC `aud` claim | **No** — generated output uses `StringEquals` on `aud`, `StringLike` only on `sub` | same |
| 2 | `NoEcho: true` on a password Parameter | **No** — generated output uses `GenerateSecretString` + a dynamic reference | same |
| 3 | `DeletionPolicy: Retain` without `UpdateReplacePolicy: Retain` | **No** — both present on all five data resources | same |

**All three recorded as *not observed*, not manufactured.** They are named in
the skill's own non-negotiables, so a generator following that skill will not
commit them — which is exactly why their absence is weak evidence and is
reported as such. Inventing a finding to fill the table would make every other
row in this document worth less.

### One suggestion accepted, and one rejected

**Accepted — `Metadata.cfn_nag.rules_to_suppress` with a written reason,
rather than a CI allow-list.** The alternative was to pass `--deny-list-path`
or drop `--fail-on-warnings` in `cfn-validate.yml`, which is less work and
strictly worse: it moves the exemption away from the thing being exempted, so
a reviewer reading the resource cannot see that a control was waived, and the
waiver silently applies to resources added later that nobody argued about.
Suppressing at the resource puts the justification in the diff. All six
suppressions above are written that way.

**Rejected — the `cfn-lint-serverless` profile in CI.** The task text asks for
`cfn-lint` with the `cfn-lint-serverless` rule pack. It is not wired up.
That pack adds rules about Lambda, API Gateway and SAM transforms; `cfn/` here
contains a VPC, an RDS instance, two S3 buckets and an IAM role, and no
`Transform` of any kind. Every rule in it is inapplicable, so it would add an
install step and a dependency to this repo's only CI job in exchange for
scanning for resource types that are not present. It becomes correct in W6 D4,
when the LLM cost-monitoring Lambda stack lands in `cfn/` — and that is the
change that should add it, so the dependency arrives with the first template
that justifies it.

---

## What this substrate does NOT do (yet)

- **Nothing is deployed.** See Status. Every command above is recorded, none
  has been run against an account.
- **No VPC flow logs.** `cfn-nag` W60 is suppressed against this. The
  destination belongs with the W6 D5 observability work rather than as a
  second, divergent log group here.
- **No VPC endpoints.** The app SG's 443 egress is therefore `0.0.0.0/0`
  (W5, suppressed). Endpoints for ECR, STS and Secrets Manager would let that
  become a prefix-list rule and keep image pulls off the NAT Gateway, which is
  also where a chunk of the NAT data-processing charge goes.
- **No scheduled drift detection.** Drift is a poll somebody runs, not an
  alarm. The Kubernetes half of this repo self-heals in ~10 seconds; the AWS
  half would not notice for as long as nobody looked.
- **No CMK on the secret.** W77 suppressed; required once External Secrets
  Operator reads it cross-account.
- **`cfn-validate.yml` is not yet a required status check.** Enabling it is a
  branch-protection change on `main` in this repo, which is a repository
  settings change rather than a file in this PR — it needs an admin to make it
  deliberately. Until then the workflow runs and reports but cannot block.
- **`RetentionDays` and the artefact lifecycle are dev-shaped.** 30 days of
  noncurrent versions and a 90/365-day tiering schedule are not an audit
  retention policy; staging and prod should override both on the ChangeSet.

---

## Running the checks locally

```bash
# cfn-lint
pip install cfn-lint==1.22.3
cfn-lint cfn/*.yaml

# cfn-nag. Ruby 3.3 specifically - cfn-nag 0.8.10 pulls kwalify 0.7.2, which
# calls StringScanner#peep. That was removed in Ruby 4.0, so on 4.x the scan
# dies in the require chain with a NoMethodError before it reads a template.
# Verified: identical templates, 0 findings on 3.3, a stack trace on 4.0.6.
gem install cfn-nag -v 0.8.10 --no-document
cfn_nag_scan --input-path cfn --fail-on-warnings --output-format txt
```

Current state of both, on all four templates: **cfn-lint 0 errors; cfn-nag 0
failures, 0 warnings.**
