# arush-adabala-tax-liability-config

The GitOps desired state for [`arush-adabala-tax-liability`](https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability) (the `taxcalc-api` capstone). Argo CD lives *inside* the cluster, watches this repository, and pulls; nothing outside the cluster holds credentials that can write to it.

This is the **config** half of a two-repo split created on W6 D2. The application repo holds Java source, the Dockerfile and CI; it no longer holds cluster credentials, and its pipeline's last step is *"open a PR here"* rather than *"`kubectl apply`"*.

## Repo layout

```
base/                              W5 D3 manifests, copied verbatim, identical in every env
  kustomization.yaml               + intra-Application sync waves (config/stores before workload)
  05-dev-dependencies.yaml         postgres / redis / mongo Deployments + Services
  10-taxcalc-api.deployment.yaml
  20-taxcalc-api.service.yaml
  30-taxcalc-api.configmap.yaml
  50-taxcalc-api.hpa.yaml
  60-taxcalc-api.ingress.yaml
  70-taxcalc-api.servicemonitor.yaml
overlays/
  dev/kustomization.yaml           namespace + replicas + image tag + Spring profile + log level + host
  staging/kustomization.yaml
  prod/kustomization.yaml
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
```

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
```

## Four things that are deliberately not in `base/`

**No `Namespace` object in `base/`.** The AppProject sets `clusterResourceWhitelist: []` — a full deny on every cluster-scoped kind. Argo CD classifies a resource as cluster- or namespace-scoped from the API server's discovery data, not from whether the manifest happens to carry a `namespace:` field, so a `Namespace` in the manifest set is rejected regardless of what `namespaceResourceWhitelist` says. The Applications carry `CreateNamespace=true` instead, which creates the destination namespace as part of the sync *operation* rather than as a managed resource.

**No `ResourceQuota` or `LimitRange` in `base/`.** Both are named in the AppProject's `namespaceResourceBlacklist`. A team that can edit its own quota does not have a quota.

Both live in `platform/00-namespaces.yaml` and are applied out-of-band by the platform team:

```bash
kubectl apply -f platform/00-namespaces.yaml
# Secret SHAPE (placeholder) - then overwrite with a real value, see that file
kubectl apply -f platform/secret/40-taxcalc-api.secret.yaml
```

**No `Secret` in `base/`, and this one was learned the hard way.** The W5 D3 file carried a placeholder password. Under `kubectl apply -f manifests/` that placeholder was *inert* — CI reseeded the Secret from a real store after applying, so the last writer held a real value. Continuous reconciliation removes that ordering: on the first sync Argo CD wrote the placeholder over the seeded password and every api pod started failing `FATAL: password authentication failed for user "taxcalc_dev"`. With `selfHeal: true` a hand re-seed survives exactly one reconcile interval, so the failure returns a few minutes later — strictly harder to debug than failing outright. A placeholder secret inside a continuously-reconciled manifest set is worse than no secret in the set at all. The shape lives in `platform/secret/40-taxcalc-api.secret.yaml`; the value is seeded out-of-band with **`delete` then `create`, never `apply`** (see that file for why the tracking label matters).

The Slack webhook that `argocd-system/notifications-cm.yaml` references lives in `argocd-notifications-secret`, created out-of-band and never committed. W6 D3 replaces both with External Secrets Operator + IRSA.

## Verifying the guardrails

```bash
./scripts/verify-appproject-guardrails.sh     # 6 passed, 0 failed
```

Five deny paths (`destinations`, `sourceRepos`, `clusterResourceWhitelist: []` vs `Namespace`, and the `ResourceQuota`/`LimitRange` blacklist) plus a positive control — the real dev Application must still be `Synced`, which is what stops the script from passing by refusing everything. It is validated against a deliberately permissive scratch AppProject; see the script header.

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

**`Deployment.spec.replicas` is in `ignoreDifferences`, so scaling is not drift here.** `base/50-taxcalc-api.hpa.yaml` sets `minReplicas: 2` while the overlays set 1 / 2 / 3 — Git owns the value the Deployment is *created* with, the HPA owns it thereafter. `kubectl scale` is therefore *not* reverted, and that is correct; use a ConfigMap value if you want to watch `selfHeal` work.

**Never add `finalizers:` to the ApplicationSet template.** It silently defeats `preserveResourcesOnDeletion: true` — dropping an env from the list generator would then take its whole workload with it. See that file's header.

**Everything directly under `platform/` must be safe to apply to a live cluster**, because `scripts/verify-appproject-guardrails.sh` syncs a scratch Application at that path. The one destructive file lives in `platform/secret/` for exactly that reason.

**`service.slack` takes a bot token, not an incoming-webhook URL.** The controller sends it as a bearer credential to `chat.postMessage`; a webhook URL put there is never requested as a URL at all. An incoming webhook needs `service.webhook.<name>`.

## Full write-up

The reasoning, the measurements and the things that did not work the first time are in the application repo:

- [`taxcalc-api/GITOPS.md`](https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability/blob/main/taxcalc-api/GITOPS.md) — repo layout, reconcile loop, drift behaviour, project-scoped RBAC, what this layer does not do yet, and the `argocd-author` Skill audit notes.
- The application repo's `README.md`, Week 6 Day 2 section.
