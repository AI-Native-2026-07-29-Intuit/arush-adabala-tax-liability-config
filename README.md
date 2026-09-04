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
  40-taxcalc-api.secret.yaml
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

## Three things that are deliberately not here

**No `Namespace` object in `base/`.** The AppProject sets `clusterResourceWhitelist: []` — a full deny on every cluster-scoped kind. Argo CD classifies a resource as cluster- or namespace-scoped from the API server's discovery data, not from whether the manifest happens to carry a `namespace:` field, so a `Namespace` in the manifest set is rejected regardless of what `namespaceResourceWhitelist` says. The Applications carry `CreateNamespace=true` instead, which creates the destination namespace as part of the sync *operation* rather than as a managed resource.

**No `ResourceQuota` or `LimitRange` in `base/`.** Both are named in the AppProject's `namespaceResourceBlacklist`. A team that can edit its own quota does not have a quota.

Both live in `platform/00-namespaces.yaml` and are applied out-of-band by the platform team:

```bash
kubectl apply -f platform/00-namespaces.yaml
# Secret SHAPE (placeholder) - then overwrite with a real value, see that file
kubectl apply -f platform/secret/40-taxcalc-api.secret.yaml
```

**No secrets.** `base/40-taxcalc-api.secret.yaml` carries the W5 D3 placeholder (`replace-at-apply-time-from-secrets-manager`). The Slack webhook that `argocd-system/notifications-cm.yaml` references lives in the `argocd-notifications-secret`, created out-of-band with `kubectl create secret generic` and never committed. W6 D3 replaces the placeholder with External Secrets Operator + IRSA.

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

## Full write-up

The reasoning, the measurements and the things that did not work the first time are in the application repo:

- [`taxcalc-api/GITOPS.md`](https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability/blob/main/taxcalc-api/GITOPS.md) — repo layout, reconcile loop, drift behaviour, project-scoped RBAC, what this layer does not do yet, and the `argocd-author` Skill audit notes.
- The application repo's `README.md`, Week 6 Day 2 section.
