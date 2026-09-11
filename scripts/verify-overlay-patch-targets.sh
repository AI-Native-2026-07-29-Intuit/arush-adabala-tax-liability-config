#!/usr/bin/env bash
#
# verify-overlay-patch-targets.sh - assert that every overlay's patches actually
# LAND, by checking the rendered value rather than the build's exit code.
#
# WHY THIS EXISTS, AND THE BUG THAT CAUSED IT
#
# W6 D5 renamed the HorizontalPodAutoscaler in k8s/taxcalc-api/hpa.yaml from
# `taxcalc-api` to `taxcalc-api-hpa`, so the deliverable's own verification
# command (`kubectl -n taxcalc-dev get hpa taxcalc-api-hpa`) resolves. Each of
# overlays/{dev,staging,prod} patches that object's minReplicas:
#
#   - target: { kind: HorizontalPodAutoscaler, name: taxcalc-api }
#     patch: |
#       - op: replace
#         path: /spec/minReplicas
#         value: 3
#
# After the rename those targets matched nothing. Kustomize DOES NOT ERROR on a
# `patches` entry whose target selects no resource - it drops the patch and
# exits 0. Measured on the half-finished rename, with kubectl 1.37's embedded
# kustomize:
#
#   $ kubectl kustomize overlays/prod | grep minReplicas
#     minReplicas: 2          # the base value; prod asks for 3
#   $ echo $?
#   0
#
# So prod's availability floor silently reverted from 3 to 2, every `op:
# replace` on a nonexistent target notwithstanding - and `op: replace` against
# a missing path is normally the strictest JSON-Patch operation there is. It is
# not strict here because the patch is never applied to anything; the target
# selector fails first, and that failure is not an error.
#
# That is the worst shape a GitOps bug can take. `kustomize build` is green,
# the diff under review is a filename change, Argo CD reports Synced against
# the manifest it actually rendered, and the only trace is a production
# namespace running two replicas where Git says three. Nothing in the pipeline
# compares Git's INTENT to the render.
#
# WHAT THIS CHECKS
#
# For each overlay, the rendered value of the things an overlay exists to set.
# Not "does it build" - the failure above builds - but "does the rendered
# manifest carry the number this overlay asks for". The expected values are
# duplicated here on purpose: a check that reads its expectation out of the
# same file it is checking cannot fail.
#
#   overlays/dev       HPA floor 2   (raised from 1 on W6 D5 - see the overlay;
#                                     a PDB minAvailable of 2 over a 1-replica
#                                     Deployment pins allowed disruptions at 0
#                                     and hangs every node drain)
#   overlays/staging   HPA floor 2
#   overlays/prod      HPA floor 3
#   overlays/loadtest  HPA floor 2   (base value, deliberately unpatched)
#
# It also asserts the HPA object's NAME in every overlay, because the name is
# what the deliverable's verification command addresses and what the patch
# targets select on. A resource whose documented name does not resolve is
# indistinguishable from a missing resource.
#
# Usage:  ./scripts/verify-overlay-patch-targets.sh
# Exit:   0 = every check passed; 1 = at least one FAIL.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() {
  printf 'FAIL  %s\n' "$1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  FAILED=1
}

# kubectl's embedded kustomize is preferred over a standalone binary: it is the
# renderer this repo is verified with elsewhere, and Argo CD's bundled version
# tracks it far more closely than whatever `brew install kustomize` last put on
# a laptop.
if command -v kustomize >/dev/null 2>&1; then
  render() { kustomize build "$1"; }
elif command -v kubectl >/dev/null 2>&1; then
  render() { kubectl kustomize "$1"; }
else
  echo "SKIP  neither kustomize nor kubectl on PATH"
  exit 0
fi

# The HPA object name every overlay must render. One value, not a per-overlay
# expectation: the name is set in the base and no overlay has any business
# changing it.
readonly EXPECTED_HPA_NAME='taxcalc-api-hpa'
readonly EXPECTED_PDB_NAME='taxcalc-api-pdb'

# overlay:expected-minReplicas
readonly EXPECTED_FLOORS='dev:2 staging:2 prod:3 loadtest:2'

for spec in $EXPECTED_FLOORS; do
  env=${spec%%:*}
  want=${spec##*:}

  RENDERED=$(render "$REPO_ROOT/overlays/$env" 2>&1) || {
    fail "overlays/$env does not build" "$RENDERED"
    continue
  }

  # Extract every field in ONE pass. `yq` and PyYAML are both absent on a
  # stock macOS box, so this is regex over the rendered stream - but scoped to
  # the single matching document, because a grep over the whole multi-document
  # render would happily read minReplicas off the HPA and `name` off the
  # ServiceMonitor that follows it.
  #
  # The metric name is matched RELATIVE to its `metric:` parent rather than at
  # a fixed indentation. Kustomize re-emits YAML from its own internal model
  # and does not preserve the input's indentation - hpa.yaml writes the metric
  # name six levels deep under a `- type: Pods` list item; the render puts it
  # four levels deep under `- pods:`. A check keyed on column position passes
  # on the source file and fails on the render, which is the wrong way round.
  FIELDS=$(printf '%s\n' "$RENDERED" | python3 -c '
import sys, re

stream = sys.stdin.read()
docs = re.split(r"(?m)^---$", stream)

def doc_for(kind):
    for d in docs:
        if re.search(r"(?m)^kind: %s$" % kind, d):
            return d
    return ""

def top(doc, key):
    # A top-level key of the document body is at exactly two spaces under
    # `spec:`/`metadata:`; both are unique enough in these two objects.
    m = re.search(r"(?m)^  %s:[ ]+(\S+)$" % key, doc)
    return m.group(1) if m else ""

hpa = doc_for("HorizontalPodAutoscaler")
pdb = doc_for("PodDisruptionBudget")

metric = ""
if hpa:
    # `metric:` then the first `name:` more deeply indented than it.
    m = re.search(r"(?m)^(\s*)metric:\s*$\n((?:\1\s+.*\n)+)", hpa)
    if m:
        n = re.search(r"(?m)^\s*name:\s+(\S+)\s*$", m.group(2))
        metric = n.group(1) if n else ""

print("\t".join([
    "yes" if hpa else "no",
    top(hpa, "name"),
    top(hpa, "minReplicas"),
    top(hpa, "maxReplicas"),
    metric,
    "yes" if pdb else "no",
    top(pdb, "name"),
    top(pdb, "minAvailable"),
]))
')

  IFS=$'\t' read -r HAS_HPA GOT_NAME GOT_FLOOR GOT_MAX GOT_METRIC \
                   HAS_PDB PDB_NAME MINAVAIL <<< "$FIELDS"

  if [ "$HAS_HPA" != "yes" ]; then
    fail "overlays/$env renders no HorizontalPodAutoscaler" \
         "the base lists hpa.yaml in resources; check k8s/taxcalc-api/kustomization.yaml"
    continue
  fi

  if [ "$GOT_NAME" = "$EXPECTED_HPA_NAME" ]; then
    pass "overlays/$env HPA is named $EXPECTED_HPA_NAME"
  else
    fail "overlays/$env HPA is named '$GOT_NAME', expected '$EXPECTED_HPA_NAME'" \
         "the deliverable's check is 'kubectl get hpa $EXPECTED_HPA_NAME'; any other name returns NotFound"
  fi

  if [ "$GOT_FLOOR" = "$want" ]; then
    pass "overlays/$env renders minReplicas: $want"
  else
    fail "overlays/$env renders minReplicas: '$GOT_FLOOR', expected '$want'" \
         "a 'patches' target that matches nothing is DROPPED SILENTLY with exit 0 - check that the target's name matches the HPA's actual name"
  fi

  # These two come from the base and are the Task 2 deliverable's own numbers.
  # Checked per overlay rather than once, because an overlay is free to patch
  # them and a patch that changes them is a change to the SLO-derived target.
  if [ "$GOT_MAX" = "20" ]; then
    pass "overlays/$env renders maxReplicas: 20"
  else
    fail "overlays/$env renders maxReplicas: '$GOT_MAX', expected '20'"
  fi

  if [ "$GOT_METRIC" = "taxcalc_inflight_requests" ]; then
    pass "overlays/$env HPA scales on taxcalc_inflight_requests"
  else
    fail "overlays/$env HPA metric is '$GOT_METRIC', expected 'taxcalc_inflight_requests'" \
         "all three spellings must agree: Micrometer's taxcalc.inflight.requests, the Adapter's 'as:', and this"
  fi

  # The PDB floor must not exceed the HPA floor. Both directions of mismatch
  # are bugs and the unsatisfiable one is silent: at minReplicas below
  # minAvailable, allowed disruptions pins at 0 and `kubectl drain` retries
  # forever without erroring.
  if [ "$HAS_PDB" != "yes" ]; then
    fail "overlays/$env renders no PodDisruptionBudget" \
         "the base lists pdb.yaml in resources; check k8s/taxcalc-api/kustomization.yaml"
  elif [ "$PDB_NAME" != "$EXPECTED_PDB_NAME" ]; then
    fail "overlays/$env PDB is named '$PDB_NAME', expected '$EXPECTED_PDB_NAME'"
  elif [ -z "$MINAVAIL" ]; then
    fail "overlays/$env PDB renders no minAvailable" \
         "maxUnavailable is not equivalent: it is evaluated against the CURRENT replica count, so the floor moves with the load"
  elif [ "$MINAVAIL" -le "$GOT_FLOOR" ]; then
    pass "overlays/$env PDB minAvailable ($MINAVAIL) <= HPA floor ($GOT_FLOOR)"
  else
    fail "overlays/$env PDB minAvailable ($MINAVAIL) EXCEEDS the HPA floor ($GOT_FLOOR)" \
         "unsatisfiable at rest: allowed disruptions pins at 0 and every node drain on a pod-holding node hangs indefinitely"
  fi
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "All overlay patch-target checks passed."
else
  echo "At least one check FAILED - see above."
fi
exit "$FAILED"
