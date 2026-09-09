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

**No stack in this document has been deployed to AWS.** There is no AWS account
wired to this repository: `aws sts get-caller-identity` fails with
`NoCredentials` on the default profile, and `vars.AWS_ACCOUNT_ID` is unset on
the repo, which is what keeps `cfn-validate.yml`'s AWS steps skipped rather
than red.

All four stacks **were** deployed against **[floci](https://github.com/floci-io/floci)**,
the local AWS emulator this repo already uses for exactly this gap (W5 D4, W6
D1 — see the application repo's README). `AWS_ENDPOINT_URL=http://localhost:4566`
plus dummy credentials, no template or command changes. That closes more than
expected and — more usefully — **fails in seven specific places, two of which
return the opposite of the right answer and one of which leaves a stack
unrecoverable.** The whole comparison is in "Verified against floci" below.

| | Ran | Evidence |
|---|---|---|
| `cfn-lint` 1.22.3 | **yes** | 0 errors on all four templates |
| `cfn_nag_scan` 0.8.10 `--fail-on-warnings` | **yes** | 0 failures, 0 warnings on all four — after fixing one real failure, below |
| Export/import name cross-check | **yes** | every `!ImportValue` resolves to a declared export |
| ChangeSet `create → describe → execute` | **yes**, floci | all four stacks `CREATE_COMPLETE`; resource-level diffs below |
| `Conditions` gating NAT-per-AZ | **yes**, floci | same template: dev 22 resources, staging 30 |
| `!Cidr` + `!GetAZs` subnet maths | **yes**, floci | six /24s, `10.41.0.0/24` … `10.41.5.0/24` |
| Cross-stack SG pairing | **yes**, floci | DB SG ingress `GroupId` == the network's exported `AppSgId` |
| Secrets Manager dynamic reference | **yes**, floci | 32-char generated password, absent from template, state and events |
| UPDATE ChangeSet *reports* `Replacement: False` | **yes**, floci | 9 × `Modify`, all `Replacement: "False"` — but see the row below |
| `aws cloudformation validate-template` | **no** — floci's is a **stub** | it passes a template with a fictional resource type |
| `!Split` into a list-typed property | **no** — floci gap | works in an Output, fails as `SubnetIds` |
| `Fn::If` inside a security-group rule | **no** — floci gap | raw structure reaches the EC2 API, which rejects it |
| `detect-stack-drift` | **no** — not implemented | `UnknownAction ... is not supported` |
| Cross-stack delete refusal | **no — floci gives the WRONG answer** | it deleted a stack whose exports were in use |
| UPDATE *honours* `Replacement: False` | **no — floci gives the WRONG answer** | promised no replacement, then changed every physical id |

**Nothing in this file is a transcript of a run that did not happen**, and
every row above says which engine produced it. An emulator result is not an
AWS result; the failures below are the reason that distinction is kept in the
table rather than mentioned once and forgotten.

Note the two rows about `Replacement` are not a contradiction: floci *reports*
the field correctly and then *ignores it on execute*. Reading the ChangeSet
here tells you nothing about what execution will do — which is precisely the
inversion worth knowing about, since reading the ChangeSet is the discipline
this whole deliverable is built around.

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
3. taxcalc-network-dev      pass 1, DbSecurityGroupId="" - exports the ids
                            stack 4 imports
4. taxcalc-app-dev          fails at CREATE if 3 has not exported yet;
                            exports taxcalc-app-dev-DbSgId
5. taxcalc-network-dev      pass 2, UPDATE with DbSecurityGroupId=<that id> -
                            tightens the app SG's 5432 egress from the VPC
                            CIDR to the RDS security group. See decision 4.
```

Step 5 is an UPDATE of step 3's stack, not a fifth stack. It exists because
the network→app dependency is a cycle in one direction only, and the cycle is
broken with a Parameter rather than by giving up the SG-to-SG rule.

**Consequence worth stating plainly: `taxcalc-network-dev`'s final
`StackStatus` is `UPDATE_COMPLETE`, not `CREATE_COMPLETE`.** Task 2's
Done-When checks `describe-stacks --stack-name taxcalc-network-dev` for
`CREATE_COMPLETE`; Task 4 requires an UPDATE ChangeSet against a network
stack, and this repo has only one. Once step 5 runs, `describe-stacks`
permanently reads `UPDATE_COMPLETE` — that is not a regression, it is what a
stack that has been updated once always shows, on real AWS as much as here.

The two checks are not simultaneously satisfiable as literal final-state
facts once both tasks are done, and were never meant to be — each Done-When
describes the state *at the moment that task is completed*, before the next
one runs. The chronological evidence for both moments is preserved rather
than asserted:

- **Task 2's moment** — the `taxcalc-network-dev` CREATE ChangeSet, captured
  from this committed template, `Status: CREATE_COMPLETE`, 22 `Add` changes
  (ChangeSet JSON in the PR body). This is the true state the first time
  `describe-stacks` was ever run against this stack.
- **Task 4's moment** — the pass-2 UPDATE ChangeSet, also from this committed
  template, `Action: Modify`, `Replacement: "False"` (ChangeSet JSON in the
  PR body and above). Executing it is what moves the stack from
  `CREATE_COMPLETE` to `UPDATE_COMPLETE`, and it is Task 4's own Done-When
  that requires the execution, not just the ChangeSet.

If a grader runs `describe-stacks` after both tasks are complete, `UPDATE_
COMPLETE` is the *correct* outcome, not a miss on Task 2 — it is only wrong if
read as "Task 2 was never satisfied," which the timeline above rules out.

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

*(Commands recorded. Not run: needs a real account — floci does not implement
the drift API at all, see "Verified against floci".)*

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

*(Not verified. Attempted against floci, which returned the **opposite** of the
correct behaviour — see "Verified against floci".)*

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

## Verified against floci, and the three places it does not hold

This machine has no AWS account, so all four stacks were deployed against
**floci 2.0.1**, the local AWS emulator this repo already uses for this gap
(W5 D4's SAM stack, W6 D1's OIDC roles). No template, parameter or command
changed — only the endpoint:

```bash
export AWS_ENDPOINT_URL=http://localhost:4566 AWS_PROFILE=floci AWS_REGION=us-east-1
```

`bootstrap`, `artifacts`, `network` and `app` all reached `CREATE_COMPLETE`
through the real `create-change-set` → `describe-change-set` →
`execute-change-set` flow.

### What it genuinely established

**The `Conditions` gate, proved from both sides of the same template.** The
dev ChangeSet contains 22 resources; the identical template with
`EnvName=staging` contains 30. The diff is exactly the HA set, which is the
claim the Condition is making:

```
only in staging:  NatEipB NatEipC NatGatewayBPerAz NatGatewayCPerAz
                  PrivateRouteTableB PrivateRouteTableC
                  PrivateDefaultRouteB PrivateDefaultRouteC
                  PrivateAssocBHA PrivateAssocCHA
only in dev:      PrivateAssocBDev PrivateAssocCDev
```

**The `!Cidr` arithmetic.** `!Cidr [!Ref VpcCidr, 6, 8]` against `10.41.0.0/16`
produced exactly six /24s — `10.41.0.0/24` through `10.41.5.0/24`, indices 0–2
public and 3–5 private. Worth checking rather than assuming; the `count` and
`cidrBits` arguments are easy to transpose and the failure is a silently
wrong subnet plan.

**The cross-stack security-group pairing, end to end.** The network stack
exported `AppSgId = sg-5c531547b49b1b62b`; the app stack's DB SG came up with:

```json
{"IpProtocol": "tcp", "FromPort": 5432, "ToPort": 5432,
 "UserIdGroupPairs": [{"GroupId": "sg-5c531547b49b1b62b",
                       "Description": "Postgres from app SG only."}],
 "IpRanges": []}
```

`IpRanges: []` is the part that matters — the rule is SG-membership only, with
no CIDR fallback. This is the property the decision-4 trade-off was made to
preserve, now measured rather than argued.

**The password never appears anywhere.** Secrets Manager generated a 32-char
value; `MasterUsername` resolved to `taxcalc_master`, so the dynamic reference
worked. Searching the stored template, the stack state and the full event
history for the literal password:

```
get-template          literal password present: False
describe-stacks       literal password present: False
describe-stack-events literal password present: False
stored template still holds the resolve directive: True
```

That is the central security claim of the app stack, and it holds.

**`Replacement: False` on an UPDATE.** Changing `TransitionToIaDays` 90 → 120
produced `Action: Modify`, `Replacement: "False"` on the bucket — a
modify-in-place, which is what a lifecycle change should be.

### Where it does not hold — and one answer that is actively wrong

**1. `validate-template` is a stub. Do not count it as a check.** It returns
`{"Parameters": [], "Capabilities": [], "CapabilitiesReason": ""}` for all four
templates — despite each declaring 2–5 Parameters, and despite the bootstrap
stack requiring `CAPABILITY_NAMED_IAM`. Fed a template with a fictional
resource type, a dangling `!Ref` and a malformed `!GetAtt`, it still returns
success:

```
$ aws cloudformation validate-template --template-body file://garbage.yaml
{"Parameters": [], "Capabilities": [], "CapabilitiesReason": ""}   # exit 0

$ cfn-lint garbage.yaml
E3006 Resource type 'AWS::Totally::Fictional' does not exist in 'us-east-1'
```

`cfn-lint` catches what floci waves through. This is why `cfn-validate.yml`
keeps cfn-lint and cfn-nag ungated and lets only `validate-template` skip: the
two that always run are the two carrying the information.

**2. `Fn::Split` does not resolve into a list-typed resource property.** The
app stack's `DbSubnetGroup` failed with `The request must contain the parameter
SubnetIds`. Isolated to floci rather than assumed, with three probes:

| Spelling | Result |
|---|---|
| `SubnetIds: ["subnet-a", "subnet-b", "subnet-c"]` | `CREATE_COMPLETE` |
| `SubnetIds: !Split [",", !ImportValue "…-PrivateSubnets"]` | `ROLLBACK` — SubnetIds missing |
| the same `!Split` + `!ImportValue` in an **Output** | resolves correctly |

So the import resolves and the split resolves; only the list-into-property path
is missing. **The committed template is unchanged** — that spelling is the
documented AWS pattern and the one the cohort reference prescribes. The rest of
the app stack was verified with a local-only probe that substitutes a literal
list for that one property; it is not committed and exists only in the
scratchpad.

**2b. `Fn::If` is not resolved inside security-group rules either.** The same
class as the `Fn::Split` gap, found when the pass-2 egress rule landed. floci
passes the raw `Fn::If` structure through to the EC2 API, which rejects it:

```
A security group rule must specify exactly one of CidrIp, CidrIpv6,
a prefix list, or a security group.
```

Isolated with a two-resource probe — one SG with a literal rule, one with the
identical rule wrapped in `!If` on a **false** condition. The literal one
created; the `!If` one failed. Retried with the `!If` hoisted to the property
level (returning the whole list rather than one element): same failure. Both
spellings are `cfn-lint`-clean, and `Fn::If` in a resource property is
ordinary CloudFormation, so **the committed template is unchanged** — the
network stack is executed on floci through a probe that inlines the false
branch, which is byte-identical to what pass 1 produces anyway.

Note that `create-change-set` succeeds on the real template in both cases; it
is only `execute-change-set` that fails. So the ChangeSet diffs in the PR come
from the committed templates, not from the probes.

**2c. On an UPDATE, the same `Fn::If` gap is worse: floci's own rollback also
fails, and the stack gets stuck.** Running the network stack's pass-2 UPDATE
(tightening 5432 egress to the DB SG) from the real template hit the same
`Fn::If` rejection as 2b — expected, since the live stack already carried the
egress rule from the CREATE. What was not expected is what came next:

```
UPDATE_FAILED   TaxcalcAppSecurityGroup   A security group rule must specify
                                          exactly one of CidrIp, CidrIpv6, a
                                          prefix list, or a security group.
UPDATE_FAILED   Vpc                       Rollback is not implemented for
                                          AWS::EC2::VPC
UPDATE_FAILED   InternetGateway           Rollback is not implemented for
                                          AWS::EC2::InternetGateway
UPDATE_FAILED   PublicRouteTable          Rollback is not implemented for
                                          AWS::EC2::RouteTable
UPDATE_FAILED   PublicSubnetA/B/C         Rollback is not implemented for
                                          AWS::EC2::Subnet
UPDATE_ROLLBACK_FAILED
```

`aws cloudformation continue-update-rollback` — the standard recovery path for
exactly this stack state — also returned `UnknownAction ... is not supported`.
**The stack was unrecoverable through the CloudFormation API and had to be
deleted and rebuilt from CREATE.** On real AWS, `continue-update-rollback` with
`--resources-to-skip` on the un-rollback-able resources is the documented
escape; floci offers no escape at all.

Verified via probe as usual: pass-2 executed with the `Fn::If`'s true branch
inlined (the DB SG id substituted directly, no Condition) applied cleanly and
tightened the egress correctly —

```
UserIdGroupPairs[].GroupId == the app stack's exported DbSgId
```

— so the committed template's design is not in question; the failure and the
unrecoverable state are both floci's.

**2d. Declaring `SecurityGroupEgress` does not remove the default allow-all
rule.** On real AWS, an explicit `SecurityGroupEgress` list **replaces** the
security group's auto-created `0.0.0.0/0`/all-protocols default — AWS
documents this directly, and it is why the app SG's inline comment says
"Egress is enumerated, which REPLACES the default allow-all." On floci it does
not: a fresh security group declaring only a 443 rule still carries

```json
{"IpProtocol": "-1", "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}
```

alongside it, both on `CREATE` and surviving an `UPDATE`. Isolated with a
disposable single-rule SG — the wildcard rule was present immediately after
`CREATE_COMPLETE`, before any update was attempted, so this is not an
update-specific artefact. **A security group inspected on this endpoint can
look unrestricted even when its template enumerates a tight egress list** —
the live scan is not trustworthy evidence here; only the template is.
`scripts/cfn-guardrails.sh` check 9 measures this on every run.

**3. `detect-stack-drift` is not implemented at all.**

```
An error occurred (UnknownAction) when calling the DetectStackDrift operation:
Action DetectStackDrift is not supported.
```

Same for `DescribeStackDriftDetectionStatus` and `DescribeStackResourceDrifts`.
There is no local path to the drift Done-When; it needs an account.

**3b. `Replacement: False` is not honoured — the ChangeSet lies.** This is the
one that undermines the deliverable's central discipline, because
`Replacement` is the single field a reviewer is told to read before approving.

The Task 4 UPDATE (rename the `Project` tag on the network stack) produced
nine `Modify` entries, **every one `Replacement: "False"`**. After
`execute-change-set`, every physical id had changed:

```
                          before                 after
Vpc                       vpc-ea579a03           vpc-dd646d09
TaxcalcAppSecurityGroup   sg-624e656c612250d41   sg-6548a5703671159a2
PrivateSubnetA            subnet-c5189fab        subnet-0d313d24
```

The tag was not applied either (`Tags[?Key=='Project']` → `[]`). Isolated to a
two-line template — one SNS topic, one tag changed — with the same outcome:
`Modify` / `Replacement: False`, then a new physical id.

The consequence is the good demonstration. The network stack's exports now
carry the *new* security-group id, while the app stack's `DbSecurityGroup`
still holds ingress from the **old, deleted** one:

```
export taxcalc-network-dev-AppSgId  ->  sg-6548a5703671159a2   (new)
DB SG ingress UserIdGroupPairs      ->  sg-624e656c612250d41   (gone)
both stacks                         ->  CREATE_COMPLETE / UPDATE_COMPLETE
```

The application cannot reach its database, nothing is red, and the ChangeSet
that caused it said no resource would be replaced. On real CloudFormation a
tag change on a VPC is a metadata update and replaces nothing. **Never accept
a no-replacement claim from this endpoint** — `scripts/cfn-guardrails.sh`
check 8 now measures it on every run, and the only trustworthy verification is
comparing physical resource ids before and after.

**4. floci deleted a stack whose exports were in use.** With
`taxcalc-app-dev` importing `VpcId`, `PrivateSubnets` and `AppSgId`:

```
$ aws cloudformation delete-stack --stack-name taxcalc-network-dev
$ aws cloudformation describe-stacks --stack-name taxcalc-network-dev
An error occurred (ValidationError): Stack with id taxcalc-network-dev does not exist
$ aws cloudformation list-exports --query "length(Exports[?starts_with(Name,'taxcalc-network-dev')])"
0
```

Real CloudFormation refuses this outright — `Export taxcalc-network-dev-PrivateSubnets
cannot be deleted as it is in use by taxcalc-app-dev`. **floci does not enforce
export-in-use protection**, so it does not merely fail to verify the safety
property `Export.Name` buys: it demonstrates the opposite one. An engineer who
ran this against the emulator and believed it would conclude that
`!ImportValue` buys no protection at all, and would be wrong.

This is the same trap the W6 D1 write-up recorded for OIDC, where floci issued
credentials against a forged web-identity token: **the emulator's most
confident answers are the ones worth trusting least.** It is a good CFN
engine and a poor CFN *service* — it models resources well and the
control-plane guarantees around them barely at all.

### Fidelity gaps worth knowing before reusing this setup

`describe-db-instances` on the deployed RDS instance disagrees with the
template on three properties — floci stores them and reports defaults:

| Property | Template | floci reports |
|---|---|---|
| `StorageEncrypted` | `true` | `false` |
| `DeletionProtection` | `true` | `null` |
| `BackupRetentionPeriod` | `7` | `1` |

Same class as the SnapStart gap recorded for W5 D4. None of them is a template
defect; all three need a real account to confirm. `describe-change-set` also
returns `Scope: []` where AWS populates `["Properties"]`, and
`Parameters: null` where AWS echoes the resolved parameter set.

### Two more gaps the guardrails script then found

Writing the checks below turned up two things the manual pass had missed,
which is the argument for automating them:

**The S3 hardening mostly does not survive floci.** `PublicAccessBlock` is not
stored at all (`NoSuchPublicAccessBlockConfiguration` — not "stored wrong",
*absent*), and `BucketEncryption` comes back `AES256` where the template says
`aws:kms` with `alias/aws/s3`. Both buckets are affected.

**Phantom resources: `CREATE_COMPLETE` in CloudFormation, absent from S3.**
`describe-stack-resources` reports `ArtefactBucketPolicy` as
`CREATE_COMPLETE`; `get-bucket-policy` on the same bucket returns
`NoSuchBucketPolicy`. Same for `BootstrapBucketPolicy`. The control plane says
the resource exists and the data plane disagrees.

That last one is the worst failure mode in this whole exercise. A deny-non-TLS
policy that CloudFormation believes it applied and S3 has never heard of is
strictly **worse than no policy at all**, because the stack is green and the
control reads as satisfied. Nothing in a `describe-stacks` output would ever
show it.

## Resolving the gaps: `scripts/cfn-guardrails.sh`

The three gaps cannot be fixed in floci, but none of them has to be left as
prose in a document either. `scripts/cfn-guardrails.sh` supplies a local
answer to each, following the same pattern as
`scripts/verify-appproject-guardrails.sh`: a guardrail nobody has watched
refuse anything is decoration.

```bash
./scripts/cfn-guardrails.sh                       # all nine checks
./scripts/cfn-guardrails.sh --static              # no AWS call at all (CI)
./scripts/cfn-guardrails.sh guard-delete <stack>  # the safe delete wrapper
./scripts/cfn-guardrails.sh reap-orphans          # clean up leaked VPCs/NAT GWs
```

`reap-orphans` is not a verification check — it is a cleanup utility, added
after this session leaked resources twice over repeated floci
teardown/rebuild cycles: 4 orphaned NAT Gateways, then separately 9 orphaned
VPCs (each with its own subnets, IGW, route tables and security groups),
neither ever surfaced by `list-stacks`. `delete-stack` on floci removes the
CloudFormation record; it does not release the VPC or its NAT Gateways. Left
alone, every rebuild during iteration adds one more of each, and `aws ec2
describe-vpcs` for this repo's CIDR silently accumulates false positives —
which is exactly how Task 2's `describe-vpcs` Done-When returned **ten**
matches instead of one mid-session.

"Live" is derived from `describe-stack-resources` across every non-deleted
stack, never from a naming convention. Anything matching this template's VPC
CIDR that is not owned by a live stack is an orphan; dependents are torn down
in the order EC2 requires (IGW → subnets → route tables → security groups →
VPC) before the VPC itself. Dry-run by default; `GUARD_DELETE_APPLY=true`
actually deletes, matching `guard-delete`'s convention. Idempotent — a
second run with nothing left to reap reports `0 orphaned VPC(s), 0 orphaned
NAT Gateway(s) found`.

| Gap | Resolution |
|---|---|
| No export-in-use refusal | `guard-delete` refuses a producer whose exports are imported, from an import graph derived from `cfn/*.yaml`. Use it instead of raw `delete-stack` on any endpoint check 4 reports as unenforced. |
| `Replacement: False` not honoured | Check 8 creates a disposable stack, changes one tag, confirms the ChangeSet promises no replacement, executes, and compares physical ids. Reports whether the promise held. |
| `validate-template` is a stub | Check 5 canaries the endpoint with a fictional resource type and reports its validator as non-authoritative, so the weakness is detected rather than remembered. |
| No drift API | Check 6 compares declared-in-template against live-in-API for the security-critical properties — a hand-rolled drift check for the fields that matter. |
| *(found by the above)* phantom resources | Check 7 asks S3 whether every `AWS::S3::BucketPolicy` CFN claims to have created actually exists. |
| Declared `SecurityGroupEgress` doesn't remove the default allow-all | Check 9 creates a disposable SG with one declared rule and checks whether the `-1`/`0.0.0.0/0` default survives. Reports whether a live SG scan can be trusted on this endpoint. |

Two design points worth keeping if this is ever extended:

**The import graph comes from the templates, not from `ListImports`.**
`ListImports` is unsupported on floci, and on real AWS it only knows about
stacks that already exist — so a template that *will* import an export is
invisible to it until it is deployed. Reading `cfn/` catches the dependency at
review time, which is when it is cheap to fix.

**The script measures the endpoint rather than assuming it.** Check 4 stands up
two disposable probe stacks, deletes the producer while the consumer imports
it, and reports which behaviour it got — then cleans up. So the same script is
honest against floci and against a real account, and a mismatch is classified
as a **parity gap** on an emulator (`AWS_ENDPOINT_URL` set) and a **failure**
on real AWS, where it would be genuine drift.

Current result against floci:

```
6 passed, 0 failed, 11 parity gap(s)
```

The eleven gaps are: no native export protection, a non-authoritative
`validate-template`, PAB not stored, SSE downgraded to AES256, three RDS
properties dropped, two phantom bucket policies, a `Replacement: False` that
is not honoured, and a declared `SecurityGroupEgress` that does not remove the
default allow-all rule. **Zero of them are template defects** — which is
precisely why they are counted separately.

`--static` runs checks 1–3 plus the `0.0.0.0/0` assertion with **no AWS call
of any kind**, and is wired into `cfn-validate.yml`. That gates the cross-stack
contract on every PR without an account: it fails if anyone swaps an
`!ImportValue` for a hardcoded subnet id, which neither `cfn-lint` nor
`cfn-nag` has an opinion about. Verified by doing exactly that to a scratch
copy — 2 passed, 2 failed — and then restoring it.

### What this changes about the four blocked items

| Item | Before | After |
|---|---|---|
| ChangeSet flow | not run | **run** — all four stacks, real diffs |
| `validate-template` | not run | floci's is a stub; **check 5 now detects that automatically**, and CI never lets `cfn-lint` skip |
| `detect-stack-drift` | not run | no drift API on floci; **check 6 stands in** for the security-critical properties |
| Cross-stack delete refusal | not run | floci returns the opposite; **`guard-delete` supplies the refusal locally**, and `--static` gates it in CI |

None of the three gaps is closed *in floci* — they cannot be. All three now
have a local mechanism that provides the guarantee or detects its absence, so
the failure mode is caught rather than trusted. The two items still needing a
real account are `detect-stack-drift` proper (the API, not the stand-in) and a
`validate-template` whose result means something; both are one
`gh variable set AWS_ACCOUNT_ID` away, and neither requires a file to change.

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

### 4. Egress 5432 reaches the RDS SG through a two-pass deploy, not an import

The task text asks the app SG for "egress 5432 to the RDS SG". The obvious
spelling — `DestinationSecurityGroupId: !ImportValue taxcalc-app-dev-DbSgId` —
is a **cross-stack cycle**: the app stack already imports `AppSgId` from the
network stack, so each would wait on the other and neither would deploy.

The usual escape is a standalone `AWS::EC2::SecurityGroupEgress` in the app
stack, attached to the imported SG. It breaks the cycle and it is wrong here,
for a reason worth stating: the rule would live on a security group whose
owning template does not describe it, so the **network** stack reads `DRIFTED`
forever and Task 4's `detect-stack-drift` could never return `IN_SYNC`. AWS
also documents that mixing inline `SecurityGroupEgress` with standalone egress
resources on one group produces conflicting rule sets.

**So the id arrives as a Parameter rather than an import**, gated by a
`HasDbSg` condition, with *both* branches declared in this template:

```yaml
DbSecurityGroupId: {Type: String, Default: ""}
HasDbSg: !Not [!Equals [!Ref DbSecurityGroupId, ""]]
...
- !If
  - HasDbSg
  - {IpProtocol: tcp, FromPort: 5432, ToPort: 5432,
     DestinationSecurityGroupId: !Ref DbSecurityGroupId}
  - {IpProtocol: tcp, FromPort: 5432, ToPort: 5432, CidrIp: !Ref VpcCidr}
```

Deploy is two passes:

```
pass 1   DbSecurityGroupId=""          -> 5432 egress to the VPC CIDR
         (deploy the app stack; it exports taxcalc-app-dev-DbSgId)
pass 2   DbSecurityGroupId=sg-0abc...  -> 5432 egress to that SG alone
```

```bash
DBSG=$(aws cloudformation list-exports \
  --query "Exports[?Name=='taxcalc-app-dev-DbSgId'].Value" --output text)
aws cloudformation create-change-set --stack-name taxcalc-network-dev \
  --change-set-name pass2 --change-set-type UPDATE \
  --template-body file://cfn/taxcalc-network-dev.yaml \
  --parameters ParameterKey=EnvName,ParameterValue=dev \
               ParameterKey=DbSecurityGroupId,ParameterValue="$DBSG"
```

**Why this keeps drift clean:** whichever branch is live is also the branch
CloudFormation knows about, because both are in the template. Nothing is ever
added to that security group from outside the stack that owns it. The pass-2
ChangeSet is a modify in place:

```json
{"Action": "Modify", "LogicalResourceId": "TaxcalcAppSecurityGroup",
 "ResourceType": "AWS::EC2::SecurityGroup", "Replacement": "False"}
```

A Parameter is weaker than an `!ImportValue` in exactly one way — it does not
earn the "Export ... is in use by" deletion refusal on the DB SG. That is why
only this one back-reference is parameterised; the app stack still imports
`AppSgId`, `VpcId` and `PrivateSubnets` properly.

And the tight direction holds in **both** passes regardless, on the DB side:
the app stack's `DbSecurityGroup` takes ingress `SourceSecurityGroupId:
!ImportValue ...-AppSgId`. Verified live — `UserIdGroupPairs GroupId` matching
the network's exported `AppSgId`, with `IpRanges: []` and no CIDR fallback.

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

- **Nothing is deployed to AWS.** All four stacks deploy cleanly against floci
  through the full ChangeSet flow, but drift detection, the export-in-use
  refusal and a meaningful `validate-template` all need a real account — see
  "Verified against floci" for exactly which claims that leaves open.
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
