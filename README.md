# arush-adabala-tax-liability-config

The GitOps desired state for [`arush-adabala-tax-liability`](https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability) (the `taxcalc-api` capstone). Argo CD lives *inside* the cluster, watches this repository, and pulls; nothing outside the cluster holds credentials that can write to it.

This is the **config** half of a two-repo split created on W6 D2. The application repo holds Java source, the Dockerfile and CI; it no longer holds cluster credentials, and its pipeline's last step is *"open a PR here"* rather than *"`kubectl apply`"*.

## Repo layout

```
k8s/taxcalc-api/                   the manifest set every environment shares. Named for the
                                   W6 D5 deliverable's own paths; was `base/` with NN- ordering
                                   prefixes until the prefixes turned out to order nothing -
                                   apply order is the sync-wave patches in kustomization.yaml
  kustomization.yaml               resource list + intra-Application sync waves (stores first)
  dev-dependencies.yaml            postgres / redis / mongo Deployments + Services
  kafka.yaml                       W6 D5 - a REAL KRaft broker; W5 D3 shipped a DNS placeholder
  kafka-bootstrap.job.yaml         W6 D5 - wave-0 hook: creates the topic and seeds the consumer
                                   group's offset, so a FRESH deploy rests at 0/0 instead of at
                                   1 replica on an invalid offset
  taxcalc-api.deployment.yaml
  taxcalc-api.service.yaml
  taxcalc-worker.deployment.yaml       W6 D5 - the KEDA scale target (same image, worker profile)
  taxcalc-worker-scaledobject.yaml     W6 D5 - KEDA on taxpayers.events consumer-group lag
  taxcalc-api.configmap.yaml
  hpa.yaml                         W6 D5 - now on taxcalc_inflight_requests, no longer on CPU.
                                   Object renamed taxcalc-api -> taxcalc-api-hpa: the old name made
                                   the deliverable's own `get hpa taxcalc-api-hpa` return NotFound
  pdb.yaml                         W6 D5 - minAvailable 2, paired with the HPA floor
  taxcalc-api.ingress.yaml
  taxcalc-api.servicemonitor.yaml
  prometheus-adapter-values.yaml   W6 D5 - Helm VALUES, not a manifest; the rule the HPA reads
overlays/
  dev/kustomization.yaml           namespace + replicas + image tag + Spring profile + log level + host
  loadtest/kustomization.yaml      W6 D5 - applied by hand for a k6 run; NOT in the ApplicationSet
  staging/kustomization.yaml
  prod/kustomization.yaml
aws-authored/                      W6 D5 - AUTHOR-AND-DEFEND. Never applied to k3d; each file
  karpenter-nodepool.yaml          says why it cannot run here.
  adot-collector.yaml
  taxcalc-worker-scaledobject.sqs.yaml
  cfn/taxcalc-observability-dev.yaml
argocd/
  projects/taxcalc.yaml            AppProject: the four allow-lists, syncWindows, two RBAC roles
  applications/taxcalc-api-dev.yaml        the dev anchor Application (documentation once the
                                           ApplicationSet owns dev - see below)
  applicationsets/taxcalc-api-envs.yaml    matrix generator: list(env) x clusters(tier=workload)
argocd-system/
  notifications-cm.yaml            on-sync-failed + on-health-degraded -> #taxcalc-deploys
platform/
  00-namespaces.yaml               Namespaces + ResourceQuota + LimitRange - NOT synced by Argo CD
  secret/40-taxcalc-api.secret.yaml  Secret SHAPE only; real value seeded out-of-band
cfn/                               W6 D3 - the AWS substrate everything above runs on
  taxcalc-bootstrap-dev.yaml       artefact bucket + the OIDC role CI assumes to deploy
  taxcalc-network-dev.yaml         3-AZ VPC, 6 subnets, Conditions-gated NAT, app SG
  taxcalc-app-dev.yaml             RDS + Secrets Manager; consumes the network by !ImportValue
  taxcalc-artifacts-dev.yaml       hardened S3 artefact bucket
.github/workflows/
  cfn-validate.yml                 cfn-lint + cfn-nag + validate-template on every cfn/ PR
taxcalc-api/
  INFRA.md                         the substrate write-up - stacks, ordering, ChangeSets, drift
```

## W6 D5 — two autoscalers, and the one that is only as big as the quota

`k8s/taxcalc-api/` gains a real Kafka broker, a worker Deployment, a KEDA `ScaledObject` on consumer-group
lag, a `PodDisruptionBudget`, and an HPA that no longer scales on CPU. Measured on k3d: KEDA drove
the worker `0 → 7 → 0` on 60,000 synthetic records, and the HPA logged
`SuccessfulRescale … New size: 10`.

**The api Deployment stops consuming `taxcalc-read-model-builder`, and that one env var is the
load-bearing change here.** Lag is a property of a consumer group, not of a Deployment. The api
runs the same image as the worker, so once a real broker existed the api pods drained the very lag
KEDA scales the worker on — and two or three of them keep a dev-rate topic at zero however much is
produced. The ScaledObject stays `READY=True`, the trigger is valid, the read model *is* updated by
the wrong pods, and the worker simply never leaves `minReplicaCount: 0`.

**The HPA scaled to 10 and got 2, and the reason is in `platform/00-namespaces.yaml`.** The
ReplicaSet was refused with `exceeded quota: requested: limits.cpu=500m, used: limits.cpu=8`. No
container in `k8s/taxcalc-api/` declares `limits.cpu` — W5 D3 omitted it on purpose to avoid CFS throttling —
so that 500m is the LimitRange's `default` applied at admission. Every pod spends 500m of an 8-CPU
quota, the namespace tops out near sixteen pods across all workloads, and `maxReplicas: 20` is
unreachable by a factor of five. The HPA reports success, the Deployment reports `2/10` forever,
and the only trace is a ReplicaSet event. An autoscaler's maximum is a request; the quota is the
answer.

`prometheus-adapter-values.yaml` is a Helm values file and is deliberately **not** in
`k8s/taxcalc-api/kustomization.yaml`'s `resources` — the adapter is cluster infrastructure, but the *rule* is
application-specific, and separating the rule from the HPA that reads it is how the two drift into
naming different metrics.

`overlays/loadtest/` is applied by hand for the duration of a k6 run and is deliberately not wired
into the ApplicationSet: an environment Argo CD reconciles is one that can be left switched on by
accident.

`aws-authored/` is written and reviewed, never deployed. The full defence is in the application
repo's [`SRE-CAPSTONE.md`](https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability/blob/main/SRE-CAPSTONE.md).

## The reconcile loop

1. CI in the application repo builds and pushes `uptimecrew/taxcalc-api:<sha>`.
2. Its `_bump-config` job opens a PR **here**, bumping `overlays/dev/kustomization.yaml`'s image tag.
3. A human merges that PR.
4. Argo CD's `application-controller` polls this repo roughly every 3 minutes and sees the new SHA on `main`.
5. It renders `overlays/dev` with Kustomize, diffs against live cluster state, and applies the difference server-side.
6. If the sync phase ever goes `Failed`, or health goes `Degraded`, the `argocd-notifications-controller` posts to `#taxcalc-deploys`. There is deliberately **no** `on-sync-succeeded` trigger.

A rollback is `git revert` on this repo. A drifted cluster is a controller alarm, not a discovery.

```
scripts/
  verify-appproject-guardrails.sh  asserts the project actually refuses what it claims to
  cfn-guardrails.sh                backfills the CFN guarantees the emulator does not provide
  cfn-extract-s3.rb                reads S3 hardening out of a template, for reconcile-s3
  cfn-extract-cost.rb              reads alarms/budgets/tags out of a template, for the W6 D4 reconciles
  cfn-resolve-if.rb                collapses list-positioned Fn::If, which the emulator hands over raw
  floci-cost-apis-shim.py          serves the budgets + tagging reads the emulator does not implement
  cost-done-when.sh                runs W6 D4 Task 1's four acceptance checks, labelled by what each is worth
```

## The AWS substrate under all of this (W6 D3)

Everything above assumes an account, a network and a bucket to deploy into. `cfn/` describes them as raw-YAML CloudFormation — four stacks, split along blast-radius lines rather than by convenience, so that the thing which changes weekly does not share a stack with the thing deployed once.

```
1. taxcalc-bootstrap-dev    role/taxcalc-api-cfn-deploy + the package bucket
2. taxcalc-artifacts-dev    hardened artefact bucket; imports nothing
3. taxcalc-network-dev      exports VpcId, VpcCidr, {Public,Private}Subnets, AppSgId
4. taxcalc-app-dev          imports 3 by !ImportValue; fails at CREATE if 3 is absent
```

Only edge 3 → 4 is enforced by CloudFormation itself, and that is the point of `!ImportValue` over copied subnet ids: an export in use cannot be deleted, and neither can the stack that owns it. A hardcoded id gives no such protection — it just goes stale when the network is rebuilt.

**Every stack deploys through `create-change-set` → `describe-change-set` → `execute-change-set`, never `aws cloudformation deploy`** (which creates a ChangeSet and immediately executes it, removing the review that is the whole point). The field to read in the diff is `Replacement` on each `ResourceChange`: `True` on an RDS instance or an S3 bucket means destroy-and-recreate, which is data loss unless `UpdateReplacePolicy: Retain` is set — which is why every data resource here carries both Retain policies rather than just `DeletionPolicy`.

**Nothing is deployed to AWS** — no account is wired to this repo. All four stacks *were* deployed against the **floci** emulator (`AWS_ENDPOINT_URL=http://localhost:4566`, no template or command changes), and all four reached `CREATE_COMPLETE` through the full ChangeSet flow. [`taxcalc-api/INFRA.md`](taxcalc-api/INFRA.md) says which engine produced every row of evidence, because floci closes two of the four open items and gets a third **actively wrong**: it will delete a stack whose exports are still in use, where real CloudFormation refuses. Read that section before trusting an emulator run of this substrate. What has run on all four templates regardless: `cfn-lint` **0 errors**, `cfn_nag_scan --fail-on-warnings` **0 failures, 0 warnings**.

```bash
pip install cfn-lint==1.22.3 && cfn-lint cfn/*.yaml
# Ruby 3.3 specifically - cfn-nag 0.8.10 pulls kwalify 0.7.2, which calls
# StringScanner#peep, removed in Ruby 4.0. On 4.x the scan dies in the require
# chain before it reads a template.
gem install cfn-nag -v 0.8.10 && cfn_nag_scan --input-path cfn --fail-on-warnings
```

**The drift asymmetry is worth knowing before trusting this layer.** The Kubernetes half of this repo self-heals: a drifted ConfigMap in `taxcalc-dev` is reverted in about 10 seconds, measured. The AWS half has no equivalent — `detect-stack-drift` is a point-in-time poll somebody runs, nothing schedules it, and unsupported resource types come back `NOT_CHECKED` rather than failing loudly. **This layer does not even alarm on drift, let alone correct it.** A scheduled detection job is on the W6 D5 list.

## Four things that are deliberately not in `k8s/taxcalc-api/`

**No `Namespace` object in `k8s/taxcalc-api/`.** The AppProject sets `clusterResourceWhitelist: []` — a full deny on every cluster-scoped kind. Argo CD classifies a resource as cluster- or namespace-scoped from the API server's discovery data, not from whether the manifest happens to carry a `namespace:` field, so a `Namespace` in the manifest set is rejected regardless of what `namespaceResourceWhitelist` says.

**And `CreateNamespace=true` does not rescue that — it is denied by the same list.** Argo CD implements the option by injecting a Namespace into the sync task list, and the injected resource is checked against `clusterResourceWhitelist` like any other. Measured with a scratch project carrying the identical `[]` deny, pointed at a namespace that did not exist:

```
Namespace  taxcalc-nsproof  SyncFailed  resource :Namespace is not permitted in project taxcalc-nsproof
Phase: Failed
$ kubectl get ns taxcalc-nsproof
Error from server (NotFound): namespaces "taxcalc-nsproof" not found
```

So **namespaces here are strictly platform-provisioned**: a new environment must be added to `platform/00-namespaces.yaml` *before* it is added to the ApplicationSet's element list, or its first sync fails. `CreateNamespace=true` stays in the syncOptions because it is the correct setting the moment the project is granted the `Namespace` kind — but nothing depends on it today.

**No `ResourceQuota` or `LimitRange` in `k8s/taxcalc-api/`.** Both are named in the AppProject's `namespaceResourceBlacklist`. A team that can edit its own quota does not have a quota.

Both live in `platform/00-namespaces.yaml` and are applied out-of-band by the platform team:

```bash
kubectl apply -f platform/00-namespaces.yaml
# Secret SHAPE (placeholder) - then overwrite with a real value, see that file
kubectl apply -f platform/secret/40-taxcalc-api.secret.yaml
```

**No `Secret` in `k8s/taxcalc-api/`, and this one was learned the hard way.** The W5 D3 file carried a placeholder password. Under `kubectl apply -f manifests/` that placeholder was *inert* — CI reseeded the Secret from a real store after applying, so the last writer held a real value. Continuous reconciliation removes that ordering: on the first sync Argo CD wrote the placeholder over the seeded password and every api pod started failing `FATAL: password authentication failed for user "taxcalc_dev"`. With `selfHeal: true` a hand re-seed survives exactly one reconcile interval, so the failure returns a few minutes later — strictly harder to debug than failing outright. A placeholder secret inside a continuously-reconciled manifest set is worse than no secret in the set at all. The shape lives in `platform/secret/40-taxcalc-api.secret.yaml`; the value is seeded out-of-band with **`delete` then `create`, never `apply`** (see that file for why the tracking label matters).

The Slack webhook that `argocd-system/notifications-cm.yaml` references lives in `argocd-notifications-secret`, created out-of-band and never committed. W6 D3 replaces both with External Secrets Operator + IRSA.

## Verifying the guardrails

```bash
./scripts/verify-appproject-guardrails.sh     # 6 passed, 0 failed
```

Five deny paths (`destinations`, `sourceRepos`, `clusterResourceWhitelist: []` vs `Namespace`, and the `ResourceQuota`/`LimitRange` blacklist) plus a positive control — the real dev Application must still be `Synced`, which is what stops the script from passing by refusing everything. It is validated against a deliberately permissive scratch AppProject; see the script header.

### The W6 D4 cost stack on floci

```bash
export AWS_ENDPOINT_URL=http://localhost:4566

# taxcalc-network-dev rolls back on floci for one reason: it does not evaluate
# Fn::If in a LIST position and hands the raw mapping to EC2. Resolve only
# those, then deploy through the ordinary ChangeSet flow.
./scripts/cfn-resolve-if.rb cfn/taxcalc-network-dev.yaml EnvName=dev > /tmp/network.json
#   -> resolved Fn::If [HasDbSg] -> false branch
# taxcalc-app-dev exits 3 ("none found") and deploys from the committed file.

./scripts/cfn-guardrails.sh reconcile-tags          # 3 passed - CFN drops every tag here
./scripts/cfn-guardrails.sh reconcile-cloudwatch    # 1 GAP - and it explains why it cannot close
./scripts/cost-done-when.sh                         # 2 passed, 2 via a local shim, 0 failed

# An UPDATE ChangeSet, with the plan produced and the execution guarded.
./scripts/cfn-guardrails.sh guard-update taxcalc-app-dev EnvName=dev
```

**`guard-update` refuses to execute on floci, and the refusal is the right answer.** floci's
update path iterates every resource in the template rather than the change set's change list, and
implements several update handlers as create — so it dies on the first non-idempotent one
(`CreateSecret`) and never reaches the resource the plan actually named. The plan itself is
correct (`Modify DbInstance … Replacement: False`) and is produced either way; executing it would
only leave the stack in `UPDATE_ROLLBACK_COMPLETE`. The script probes the endpoint with a
disposable stack rather than assuming, so against real AWS it executes normally.

This usually goes unnoticed because `CreateTopic` and `CreateBucket` are idempotent: a template of
purely idempotent types would update green while silently re-creating everything in it.

**`SHIM` is not `PASS`.** `cost-done-when.sh` prints three verdicts rather than an exit status,
because the four raw acceptance commands produce **one false pass and one false failure** on this
engine: `describe-stacks` reports `CREATE_COMPLETE` for a stack containing an
`AWS::Budgets::Budget` against a service floci does not run at all, and `get-resources` returns an
empty list for tags that are genuinely applied. Of the two shimmed checks, the tagging one serves
**real tags** through a reimplemented index; the budgets one is a **projection of the deployed
template** and is not evidence that a budget exists. Every workaround refuses to run with
`AWS_ENDPOINT_URL` unset. Full accounting in [`taxcalc-api/COST.md`](taxcalc-api/COST.md).

## Bootstrapping this into a cluster

```bash
# Namespaces + quotas (platform team, out-of-band)
kubectl apply -f platform/00-namespaces.yaml
# Secret SHAPE (placeholder) - then overwrite with a real value, see that file
kubectl apply -f platform/secret/40-taxcalc-api.secret.yaml

# The guardrail first - an Application applied before its project is rejected
kubectl apply -f argocd/projects/taxcalc.yaml -n argocd

# Then either the single dev Application ...
kubectl apply -f argocd/applications/taxcalc-api-dev.yaml -n argocd
# ... or the ApplicationSet that generates all three (and NOT both - see below)
kubectl apply -f argocd/applicationsets/taxcalc-api-envs.yaml -n argocd

# Notifications
kubectl apply -f argocd-system/notifications-cm.yaml -n argocd
kubectl -n argocd rollout restart deploy/argocd-notifications-controller
```

`argocd/applications/taxcalc-api-dev.yaml` and the ApplicationSet both produce an Application named `taxcalc-api-dev`. Applying both puts two controllers in charge of one object. The standalone Application is the Task 1 anchor and is kept in the repo as the one concrete, non-templated Application a new contributor can read; once the ApplicationSet is applied, delete it from the cluster (`argocd app delete taxcalc-api-dev`) and leave the file.

## Operating notes worth knowing before you touch this repo

**A change freeze freezes self-healing too.** The AppProject's `syncWindows` deny block (Fri 17:00 → Mon 05:00 UTC) stops *all* automated sync to `taxcalc-api-prod`, `selfHeal` included. Patching a ConfigMap in `taxcalc-prod` during the window left the drift in place for 240 s with the controller logging `Sync prevented by sync window`; the identical patch in `taxcalc-dev` was reverted in **10 seconds**. That is not a bug, but it is a trade-off nobody mentions when adding a freeze: for its duration prod is unprotected against drift as well as against deploys, and only a human `manualSync` closes the gap.

**`Deployment.spec.replicas` is in `ignoreDifferences`, so scaling is not drift here.** `k8s/taxcalc-api/hpa.yaml` sets `minReplicas: 2` while the overlays set 1 / 2 / 3 — Git owns the value the Deployment is *created* with, the HPA owns it thereafter. `kubectl scale` is therefore *not* reverted, and that is correct; use a ConfigMap value if you want to watch `selfHeal` work.

**Never add `finalizers:` to the ApplicationSet template.** It silently defeats `preserveResourcesOnDeletion: true` — dropping an env from the list generator would then take its whole workload with it. See that file's header.

**Everything directly under `platform/` must be safe to apply to a live cluster**, because `scripts/verify-appproject-guardrails.sh` syncs a scratch Application at that path. The one destructive file lives in `platform/secret/` for exactly that reason.

**`service.slack` takes a bot token, not an incoming-webhook URL.** The controller sends it as a bearer credential to `chat.postMessage`; a webhook URL put there is never requested as a URL at all. An incoming webhook needs `service.webhook.<name>`.

## Full write-up

The reasoning, the measurements and the things that did not work the first time are in the application repo:

- [`taxcalc-api/GITOPS.md`](https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability/blob/main/taxcalc-api/GITOPS.md) — repo layout, reconcile loop, drift behaviour, project-scoped RBAC, what this layer does not do yet, and the `argocd-author` Skill audit notes.
- The application repo's `README.md`, Week 6 Day 2 section.

The AWS substrate write-up lives **here**, because the templates do:

- [`taxcalc-api/INFRA.md`](taxcalc-api/INFRA.md) — the four stacks, deploy ordering, the ChangeSet flow and what to read in `describe-change-set`, export naming, drift detection, the cross-stack delete refusal, six decisions that departed from the reference layout, every `cfn-nag` suppression with its reasoning, and the `cfn-author` Skill audit.
- [`taxcalc-api/COST.md`](taxcalc-api/COST.md) — the cost-governance runbook: the two spending planes and why only one is visible to AWS billing, the four-key tag taxonomy and its manual activation (which does **not** backfill), the Budget and billing-alarm runbooks, the NAT cost lever, the LLM plane's per-request attribution and where its cap actually sits, and the `cost-author` Skill audit. Moved here on W6 D4 for the same reason INFRA.md is here — the Budget, the alarm, the topic and the tags are all in `cfn/`, and so are the three static checks that enforce them.
- The application repo's `README.md`, Week 6 Day 3 and Day 4 sections.
