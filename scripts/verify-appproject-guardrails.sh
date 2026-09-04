#!/usr/bin/env bash
#
# verify-appproject-guardrails.sh - assert that the four allow-lists in
# argocd/projects/taxcalc.yaml actually deny what they claim to deny.
#
# A guardrail nobody has watched refuse anything is decoration. `kubectl get
# appproject taxcalc -o yaml` proves the YAML says the right words; it does not
# prove the controller enforces them, and the two are different claims - Argo
# CD evaluates destinations and sourceRepos when an Application spec is
# validated, but the resource allow-lists only at SYNC time, so a project can
# look correct in the dashboard and still fail closed (or open) at the moment
# it matters.
#
# Nine checks. Five are DENY paths - each creates a deliberately-illegal
# Application and asserts the specific refusal. The sixth is the positive
# control that stops this script from passing by refusing everything. The last
# three are static and run offline: they assert that nobody has put a denied
# kind back into base/, which is the mistake most likely to be made in good
# faith, since this deliverable's own reference layout puts 00-namespace.yaml
# there.
#
#   1  destination        namespace not in `destinations`          -> denied
#   2  sourceRepos        a repo not on the allow-list             -> denied
#   3  clusterResource    Namespace, under clusterResourceWhitelist: []
#                                                                  -> denied
#   4  namespaceBlacklist ResourceQuota                            -> denied
#   5  namespaceBlacklist LimitRange                               -> denied
#   6  POSITIVE CONTROL   the real dev Application                 -> Synced
#   7-9 STATIC           each overlay renders no denied kind       -> clean
#
# Checks 3-5 are driven from ONE scratch Application pointed at platform/,
# which is exactly the set of objects deliberately excluded from base/. That
# is the point: platform/ is not an arbitrary bad input, it is the real
# manifest set the project is supposed to refuse, so this script fails the
# moment somebody "helpfully" moves those files back into base/.
#
# WHY platform/secret/ IS A SUBDIRECTORY, AND WHY THAT MATTERS HERE.
# Checks 3-5 work by asking Argo CD to SYNC that Application and reading the
# per-resource refusals. When the project denies the kinds - the case this
# script exists to assert - nothing is applied and the sync fails closed. When
# it does NOT deny them, the sync SUCCEEDS and every object under the source
# path is really written to the cluster.
#
# That is not hypothetical. Running this script against a deliberately
# permissive project (the negative control below) synced platform/ for real
# and overwrote the out-of-band taxcalc-api-secrets with the committed
# placeholder, breaking Postgres auth in taxcalc-dev - a verification script
# damaging the thing it was verifying. Everything directly under platform/ is
# now idempotent: applying 00-namespaces.yaml re-writes Namespaces,
# ResourceQuotas and LimitRanges that already hold exactly those values, so a
# permitted sync is a no-op. The one destructive file, the Secret SHAPE with
# its placeholder password, lives in platform/secret/ and is excluded by
# `directory: { recurse: false }` below.
#
# Keep that property. If you add a file directly under platform/, it must be
# safe to apply to a live cluster; anything else belongs in a subdirectory.
#
# VALIDATED AGAINST A KNOWN-BAD INPUT, rather than trusted because it printed
# green. Create a scratch AppProject with '*' for sourceRepos, destinations
# and clusterResourceWhitelist and an empty blacklist - referenced by no
# Application, so it grants nothing - then run:
#
#   kubectl apply -f /tmp/negative-control-project.yaml
#   PROJECT=taxcalc-negctl ./scripts/verify-appproject-guardrails.sh
#   kubectl -n argocd delete appproject taxcalc-negctl
#
# Checks 1-5 must all FAIL and the positive control must still pass (1 passed,
# 5 failed). Never widen the REAL taxcalc project to run this - a guardrail
# that is routinely disabled to test it is not a guardrail.
#
# Requires: kubectl with a context on the cluster running Argo CD, and the
# argocd CLI logged in (ARGOCD_CLI, default `argocd`).
#
# Usage:  ./scripts/verify-appproject-guardrails.sh
# Exit:   0 = every check passed; 1 = at least one FAIL.

set -uo pipefail

ARGOCD_CLI="${ARGOCD_CLI:-argocd}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
PROJECT="${PROJECT:-taxcalc}"
REPO_URL="${REPO_URL:-https://github.com/AI-Native-2026-07-29-Intuit/arush-adabala-tax-liability-config.git}"
REVISION="${REVISION:-main}"
DEV_APP="${DEV_APP:-taxcalc-api-dev}"

PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; printf '      %s\n' "$2"; FAIL=$((FAIL + 1)); }

# Delete a scratch Application WITHOUT cascading. These Applications are never
# meant to have synced anything; a cascading delete on a misbehaving one would
# prune resources in a real namespace, which is precisely the failure mode this
# project exists to prevent.
cleanup_app() {
  kubectl -n "$ARGOCD_NS" delete application "$1" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$ARGOCD_NS" patch application "$1" --type=merge \
    -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1
}

trap 'cleanup_app taxcalc-guardrail-dest; cleanup_app taxcalc-guardrail-kinds' EXIT

echo "==> AppProject guardrail verification: project '$PROJECT'"
echo

# ---------------------------------------------------------------------------
# 1. destinations - a namespace that is not on the list.
#
# Applied with kubectl rather than `argocd app create`, deliberately: the CLI
# validates client-side and refuses to submit, which would test the CLI. Going
# through the API server proves the CONTROLLER refuses it, which is the thing
# an attacker with kubectl access would actually be up against.
# ---------------------------------------------------------------------------
cleanup_app taxcalc-guardrail-dest
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: taxcalc-guardrail-dest, namespace: $ARGOCD_NS }
spec:
  project: $PROJECT
  source: { repoURL: $REPO_URL, path: overlays/dev, targetRevision: $REVISION }
  destination: { server: https://kubernetes.default.svc, namespace: kube-system }
EOF

DEST_MSG=""
for _ in $(seq 1 20); do
  sleep 3
  DEST_MSG=$(kubectl -n "$ARGOCD_NS" get application taxcalc-guardrail-dest \
    -o jsonpath='{.status.conditions[?(@.type=="InvalidSpecError")].message}' 2>/dev/null)
  [ -n "$DEST_MSG" ] && break
done
case "$DEST_MSG" in
  *"do not match any of the allowed destinations in project '$PROJECT'"*)
    pass "destinations: kube-system refused -> $DEST_MSG" ;;
  "") fail "destinations: kube-system was NOT refused" \
           "no InvalidSpecError condition appeared within 60s" ;;
  *)  fail "destinations: refused for the wrong reason" "$DEST_MSG" ;;
esac
cleanup_app taxcalc-guardrail-dest

# ---------------------------------------------------------------------------
# 2. sourceRepos - a repository that is not on the list.
#
# Here the CLI IS the right tool: it surfaces the API server's validation
# error verbatim on stderr, which is what a human sees.
# ---------------------------------------------------------------------------
REPO_OUT=$("$ARGOCD_CLI" app create taxcalc-guardrail-repo --grpc-web \
  --project "$PROJECT" \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook --revision HEAD \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace taxcalc-dev 2>&1)
case "$REPO_OUT" in
  *"is not permitted in project '$PROJECT'"*)
    pass "sourceRepos: argocd-example-apps refused" ;;
  *)  fail "sourceRepos: a repo outside the allow-list was ACCEPTED" "$REPO_OUT"
      "$ARGOCD_CLI" app delete taxcalc-guardrail-repo --cascade=false --yes --grpc-web >/dev/null 2>&1 ;;
esac

# ---------------------------------------------------------------------------
# 3-5. Resource allow-lists, all from one scratch Application pointed at
# platform/ - Namespace (cluster-scoped, denied by clusterResourceWhitelist:
# []), ResourceQuota and LimitRange (both on namespaceResourceBlacklist).
#
# The destination is a LEGAL namespace on purpose: if it were illegal too, the
# destination check would fire first and these three would never be reached,
# and the script would report three passes it never actually made.
# ---------------------------------------------------------------------------
cleanup_app taxcalc-guardrail-kinds
kubectl apply -f - >/dev/null 2>&1 <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: taxcalc-guardrail-kinds, namespace: $ARGOCD_NS }
spec:
  project: $PROJECT
  source:
    repoURL: $REPO_URL
    path: platform
    targetRevision: $REVISION
    directory: { recurse: false }
  destination: { server: https://kubernetes.default.svc, namespace: taxcalc-dev }
EOF
sleep 20
SYNC_OUT=$("$ARGOCD_CLI" app sync taxcalc-guardrail-kinds --grpc-web --timeout 90 2>&1)

for kind in Namespace ResourceQuota LimitRange; do
  case "$SYNC_OUT" in
    *"$kind is not permitted in project $PROJECT"*)
      pass "resource allow-list: $kind refused" ;;
    *) fail "resource allow-list: $kind was NOT refused" \
            "sync output did not contain '$kind is not permitted in project $PROJECT'" ;;
  esac
done
cleanup_app taxcalc-guardrail-kinds

# ---------------------------------------------------------------------------
# 6. POSITIVE CONTROL.
#
# Without this, a project that denied absolutely everything - a typo in
# sourceRepos, an empty destinations list, a deleted AppProject - would score
# 5/5 and look perfect. The real dev Application must still be Synced.
# ---------------------------------------------------------------------------
DEV_STATE=$(kubectl -n "$ARGOCD_NS" get application "$DEV_APP" \
  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
case "$DEV_STATE" in
  Synced/Healthy)     pass "positive control: $DEV_APP is $DEV_STATE" ;;
  Synced/*)           pass "positive control: $DEV_APP is $DEV_STATE (synced; health is a workload concern)" ;;
  *) fail "positive control: $DEV_APP is not Synced" \
          "state='$DEV_STATE' - the project may be denying legitimate traffic too" ;;
esac

# ---------------------------------------------------------------------------
# 7. STATIC CHECK - the overlays must not render a kind this project denies.
#
# Checks 1-5 prove the project refuses those kinds. This one proves nobody has
# quietly put them back into base/, which is a different failure and a much
# easier mistake to make: the reference layout for this deliverable puts
# 00-namespace.yaml in base/, so "restoring" it looks like fixing a deviation
# rather than breaking the sync.
#
# It runs offline against `kustomize build`, so it catches the mistake in
# review rather than at the next sync - which matters because the sync failure
# it prevents is total: a denied resource fails the whole operation, not just
# itself.
#
# Secret is on the project's whitelist and would sync happily, so it is checked
# here rather than above: a placeholder Secret in the manifest set overwrites
# the real out-of-band password on the next reconcile. See
# platform/secret/40-taxcalc-api.secret.yaml.
# ---------------------------------------------------------------------------
if command -v kustomize >/dev/null 2>&1; then
  REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
  for env in dev staging prod; do
    RENDERED=$(kustomize build "$REPO_ROOT/overlays/$env" 2>&1) || {
      fail "static: overlays/$env does not build" "$RENDERED"; continue; }
    BAD=$(printf '%s\n' "$RENDERED" \
      | grep -E '^kind: (Namespace|ResourceQuota|LimitRange|Secret)$' | sort -u | tr '\n' ' ')
    if [ -z "$BAD" ]; then
      pass "static: overlays/$env renders no denied or out-of-band kind"
    else
      fail "static: overlays/$env renders a kind that must not be synced" \
           "found: ${BAD}- Namespace/ResourceQuota/LimitRange are denied by the project; Secret would overwrite the out-of-band password. All belong in platform/."
    fi
  done
else
  echo "SKIP  static overlay check: kustomize not on PATH"
fi

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
