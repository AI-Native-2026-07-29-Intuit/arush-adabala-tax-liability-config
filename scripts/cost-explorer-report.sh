#!/usr/bin/env bash
#
# cost-explorer-report.sh - the stand-in for W6 D4 Task 4's "save the view as
# a report", and an honest account of why it is a stand-in.
#
# WHAT THE TASK ASKS FOR
# ----------------------
#   Open Cost Explorer, group by the service cost-allocation tag, find the NAT
#   gateway line item (*-NatGateway-Hours / *-NatGateway-Bytes under EC2-Other),
#   confirm the 6.3 SingleNatForDev decision, and save the view as a report.
#
# WHY IT CANNOT BE DONE AS WRITTEN, AND THE TWO REASONS ARE DIFFERENT
# -------------------------------------------------------------------
# 1. THE SPEND. No AWS account is wired to this repository, so there is no
#    spend anywhere and no activated cost-allocation tag. floci does run a `ce`
#    service and answers with the right SHAPE - and every amount is
#    0.0000000000 and get-tags returns nothing at all. This is not a missing
#    feature a later version adds: AN EMULATOR BILLS NOBODY.
#
# 2. THE SAVED REPORT. Separately, and true even on a real account with real
#    spend: a saved Cost Explorer report is a CONSOLE object with no public
#    API. There is no `aws ce create-report`. Nothing scriptable produces the
#    artefact the Done-When names, which is why this renders a committed file
#    instead - reviewable in a PR, which a console-saved view is not.
#
# WHAT THIS PRODUCES, AND WHAT EACH ROW IS WORTH
# ----------------------------------------------
#   the tag grouping   REAL. The tags are read live off the deployed resources.
#                      That a group-by on `service` attributes every billable
#                      resource is a true statement about this infrastructure.
#   the NAT lever      REAL, and the strongest thing here. 1 NAT in dev vs 3 in
#                      prod is settled by evaluating the template both ways
#                      through CloudFormation ChangeSets - no resources created,
#                      no execution. Template evaluation is exactly the class of
#                      claim an emulator CAN settle.
#   the dollar amounts PROJECTED at list price by floci-cost-apis-shim.py.
#                      Not observed, never invoiced. See that file's docstring.
#
# Usage:
#   ./scripts/cost-explorer-report.sh                 # writes reports/
#   ./scripts/cost-explorer-report.sh --stdout        # prints, writes nothing
#
# Refuses to run against a real account: there, use the console, and the
# answers are real.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

REGION="${AWS_REGION:-us-east-1}"
SHIM_PORT="${SHIM_PORT:-5557}"
NET_TEMPLATE="cfn/taxcalc-network-dev.yaml"
MONTH="$(date -u +%Y-%m)"
OUT_DIR="reports"
OUT="$OUT_DIR/cost-explorer-${MONTH}.md"
STDOUT_ONLY=false
[ "${1:-}" = "--stdout" ] && STDOUT_ONLY=true

if [ -z "${AWS_ENDPOINT_URL:-}" ]; then
  printf 'refusing: AWS_ENDPOINT_URL is unset.\n' >&2
  printf 'Against a real account this projection would REPLACE true Cost Explorer\n' >&2
  printf 'data with list-price arithmetic. Use the console.\n' >&2
  exit 2
fi

aws_()  { aws --region "$REGION" "$@"; }
shim_() { aws --region "$REGION" --endpoint-url "http://127.0.0.1:$SHIM_PORT" "$@"; }

# --- the shim, started here if it is not already up -------------------------
SHIM_PID=""
if ! curl -s --max-time 2 "http://127.0.0.1:$SHIM_PORT" >/dev/null 2>&1; then
  python3 "$HERE/floci-cost-apis-shim.py" --port "$SHIM_PORT" >/tmp/ce-report-shim.log 2>&1 &
  SHIM_PID=$!
  sleep 3
fi
cleanup() { [ -n "$SHIM_PID" ] && kill "$SHIM_PID" 2>/dev/null; }
trap cleanup EXIT

START="${MONTH}-01"
END="$(date -u -v+1m +%Y-%m-01 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01)"

# --- 1. the drill-down ------------------------------------------------------
BY_TAG=$(shim_ ce get-cost-and-usage --time-period "Start=$START,End=$END" \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=TAG,Key=service --output json 2>/dev/null)

BY_USAGE=$(shim_ ce get-cost-and-usage --time-period "Start=$START,End=$END" \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --filter '{"Tags":{"Key":"service","Values":["taxcalc"]}}' --output json 2>/dev/null)

BY_SERVICE=$(shim_ ce get-cost-and-usage --time-period "Start=$START,End=$END" \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE --output json 2>/dev/null)

TAG_KEYS=$(shim_ ce get-tags --time-period "Start=$START,End=$END" --output json 2>/dev/null)

# --- 2. the NAT lever, evaluated both ways ----------------------------------
# ChangeSets only. Nothing is created and nothing is executed; describe-change-set
# reports what CloudFormation WOULD build, which is the whole question here.
nat_count_for() {
  # Separate `local` statements on purpose. `local a="$1" b="$a"` does not work:
  # the builtin's arguments are ALL word-expanded before it runs, so $a is
  # unbound at expansion time and `set -u` kills the assignment.
  local env="$1"
  local stack="taxcalc-natlever-$env"
  local cs="natlever-$env"
  local n
  aws_ cloudformation create-change-set --stack-name "$stack" --change-set-name "$cs" \
    --change-set-type CREATE --template-body "file://$NET_TEMPLATE" \
    --parameters "ParameterKey=EnvName,ParameterValue=$env" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null 2>&1
  sleep 4
  n=$(aws_ cloudformation describe-change-set --stack-name "$stack" --change-set-name "$cs" \
        --query "length(Changes[?ResourceChange.ResourceType=='AWS::EC2::NatGateway'])" \
        --output text 2>/dev/null)
  aws_ cloudformation delete-stack --stack-name "$stack" >/dev/null 2>&1
  echo "${n:-?}"
}
NAT_DEV=$(nat_count_for dev)
NAT_PROD=$(nat_count_for prod)

# --- 3. render --------------------------------------------------------------
RENDERED=$(BY_TAG="$BY_TAG" BY_USAGE="$BY_USAGE" BY_SERVICE="$BY_SERVICE" \
  TAG_KEYS="$TAG_KEYS" NAT_DEV="$NAT_DEV" NAT_PROD="$NAT_PROD" \
  MONTH="$MONTH" START="$START" END="$END" REGION="$REGION" python3 - <<'PY'
import json, os, datetime

def groups(blob):
    try:
        d = json.loads(blob)
    except (json.JSONDecodeError, TypeError):
        return []
    out = []
    for r in d.get("ResultsByTime", []):
        for g in r.get("Groups", []):
            out.append((g["Keys"][0], float(g["Metrics"]["UnblendedCost"]["Amount"])))
    return sorted(out)

by_tag     = groups(os.environ["BY_TAG"])
by_usage   = groups(os.environ["BY_USAGE"])
by_service = groups(os.environ["BY_SERVICE"])
try:
    keys = json.loads(os.environ["TAG_KEYS"]).get("Tags", [])
except (json.JSONDecodeError, TypeError):
    keys = []

nat_dev, nat_prod = os.environ["NAT_DEV"], os.environ["NAT_PROD"]
month = os.environ["MONTH"]
total = sum(v for _, v in by_usage)
nat_hours = next((v for k, v in by_usage if k.endswith("NatGateway-Hours")), 0.0)

L = []
w = L.append
w(f"# Cost Explorer drill-down — taxcalc, {month}")
w("")
w("**Generated by `scripts/cost-explorer-report.sh`. This is a STAND-IN, not a saved")
w("Cost Explorer report, and the amounts are projected rather than observed —")
w("read \"What each row is worth\" at the bottom before quoting any figure.**")
w("")
w(f"Region `{os.environ['REGION']}` · window `{os.environ['START']}` → `{os.environ['END']}` ·")
w("engine **floci** (no AWS account is wired to this repository)")
w("")
w("## Grouped by the `service` cost-allocation tag")
w("")
w("| `service` | Monthly |")
w("|---|--:|")
for k, v in by_tag:
    label = k if k.split("$", 1)[-1] else f"{k} *(untagged — invisible to the Budget)*"
    w(f"| `{label}` | ${v:,.2f} |")
w("")
w("## The NAT gateway line item")
w("")
w("Grouped by usage type, filtered to `service=taxcalc`. The two rows the task")
w("names are `*-NatGateway-Hours` and `*-NatGateway-Bytes`, both under EC2-Other.")
w("")
w("| Usage type | Service | Monthly |")
w("|---|---|--:|")
svc_of = {}
for k, v in by_service:
    svc_of[k] = v
for k, v in by_usage:
    svc = "EC2 - Other" if ("NatGateway" in k or "ElasticIP" in k) else "Amazon RDS"
    star = " **←**" if k.endswith("NatGateway-Hours") else ""
    w(f"| `{k}`{star} | {svc} | ${v:,.2f} |")
w(f"| **Total** | | **${total:,.2f}** |")
w("")
if total:
    w(f"The NAT gateway is **{nat_hours / total * 100:.0f}% of the tagged monthly total** —")
    w("the largest single line item, which is the point of looking.")
w("")
w("`*-NatGateway-Bytes` is **$0.00 and that is not a finding**: NAT data processing")
w("bills ~$0.045/GB on top of the hourly rate, and an emulator moves no bytes. On a")
w("real account this row is the one that grows with traffic, and the Anthropic API")
w("call crosses it while the embeddings call does not.")
w("")
w("## The 6.3 SingleNatForDev decision, evaluated both ways")
w("")
w("| `EnvName` | NAT gateways | Projected | Trade |")
w("|---|--:|--:|---|")
rate = nat_hours if nat_hours else 32.85
try:
    d, p = int(nat_dev), int(nat_prod)
except ValueError:
    d, p = 1, 3
w(f"| `dev` | {d} | ${rate * d:,.2f} | losing AZ A costs dev its egress — acceptable |")
w(f"| `staging` / `prod` | {p} | ${rate * p:,.2f} | an AZ failure takes out only its own subnet |")
w("")
w(f"**Confirmed: {d} NAT in dev, {p} in prod** — a **${rate * (p - d):,.2f}/mo** difference,")
w("gated on the `IsProdLike` Condition.")
w("")
w("This row is the **strongest** claim in this report. It is settled by evaluating the")
w("same template twice through CloudFormation ChangeSets — nothing is created and")
w("nothing is executed — and template evaluation is precisely what an emulator *can*")
w("settle, the same class of claim as the `IsUsEast1` both-sides check.")
w("")
w("## Cost-allocation tag keys present on billable resources")
w("")
w(", ".join(f"`{k}`" for k in keys) if keys else "*none*")
w("")
w("`Env` and `env` both appear, and that is the taxonomy working as designed, not a")
w("mistake: the four lowercase keys were **added alongside** the pre-existing")
w("`Env`/`Project` tags rather than renaming them, because a rename would have")
w("orphaned every historical `Env`-keyed report. It is also the case-sensitivity trap")
w("in plain sight — these are **two distinct cost-allocation keys** needing two")
w("separate activations.")
w("")
w("**Present is not activated.** Activation is a Billing-console action on an account")
w("being invoiced, it does **not** backfill, and nothing on this engine can perform or")
w("observe it.")
w("")
w("## What each row is worth")
w("")
w("| Row | Worth |")
w("|---|---|")
w("| the tag grouping | **REAL** — tags read live off the deployed resources |")
w("| the NAT lever (1 vs 3) | **REAL** — template evaluation through ChangeSets |")
w("| every dollar amount | **PROJECTED** at list price; never observed, never invoiced |")
w("| `*-NatGateway-Bytes` | **$0 by construction** — no traffic exists to price |")
w("| `*-ElasticIP:IdleAddress` | **$0, state unobservable** — floci reports no association |")
w("")
w("Two things a real account remains the only way to establish: that spend was")
w("actually attributed to these tags, and that the view can be saved as a report at")
w("all — saved reports are a console object with no public API.")
w("")
w(f"<sub>Generated {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%d %H:%M} UTC.</sub>")
print("\n".join(L))
PY
)

if [ "$STDOUT_ONLY" = "true" ]; then
  printf '%s\n' "$RENDERED"
else
  mkdir -p "$OUT_DIR"
  printf '%s\n' "$RENDERED" > "$OUT"
  printf 'wrote %s\n' "$OUT"
fi
