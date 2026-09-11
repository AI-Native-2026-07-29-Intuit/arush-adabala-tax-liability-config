#!/usr/bin/env bash
#
# pricebook-verify.sh - check every rate in floci-cost-apis-shim.py's PRICEBOOK
# against AWS's own published price list, and fail if any has drifted.
#
# THE PROBLEM THIS SOLVES
# -----------------------
# COST.md says of the LLM price table: "a stale price book makes every cost
# figure wrong while every test still passes - the arithmetic is correct, the
# log line is well-formed, and the number simply is not what the invoice will
# say. Nothing in the process can detect it."
#
# That was true of the AWS price book too, and it was stated as an unavoidable
# property rather than a missing check. It is not unavoidable. The AWS Price
# List Bulk API is PUBLIC and UNAUTHENTICATED - no account, no credentials, no
# signature - so the rates can be fetched and compared on every CI run:
#
#   https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/<service>/current/<region>/index.csv
#
# This turns "the highest-maintenance file here" into a file with a gate.
#
# IT FOUND A REAL ERROR ON ITS FIRST RUN. PRICEBOOK had RDS gp3 storage at
# $0.08/GB-mo, which is the EBS gp3 rate. RDS gp3 in us-east-1 is $0.115 -
# the same as gp2, not the discount the EBS number implies. The deployed
# volume reports gp2 so the live projection was unaffected, but the template
# declares gp3, and the moment that took effect the storage line would have
# understated by $0.70/mo with nothing failing.
#
# WHAT THIS DOES *NOT* DO. It verifies the RATES, not the quantities, and not
# that anything was billed. A projection with perfect prices is still a
# projection. See the shim's docstring.
#
# Usage:
#   ./scripts/pricebook-verify.sh            # verify, exit 1 on drift
#   ./scripts/pricebook-verify.sh --refresh  # re-download the cached price lists
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

REGION="${PRICE_REGION:-us-east-1}"
CACHE="${PRICE_CACHE:-/tmp/aws-pricelist-cache}"
BASE="https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws"
SHIM="$HERE/floci-cost-apis-shim.py"
PASS=0; FAIL=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ "${1:-}" = "--refresh" ] && rm -rf "$CACHE"
mkdir -p "$CACHE"

fetch() {  # service, extension -> path on stdout
  # Separate `local` statements: the builtin word-expands ALL its arguments
  # before assigning any, so `local a="$1" b="$a"` leaves b empty and trips
  # `set -u`. Third time this has bitten in this repo; see cost-done-when.sh.
  local svc="$1"
  local ext="$2"
  local out="$CACHE/$svc.$ext"
  if [ ! -s "$out" ]; then
    curl -sS --max-time 300 "$BASE/$svc/current/$REGION/index.$ext" -o "$out" || return 1
  fi
  printf '%s' "$out"
}

printf '\033[1mpricebook-verify\033[0m  region=%s  source=AWS Price List Bulk API (public, unauthenticated)\n' "$REGION"

EC2=$(fetch AmazonEC2 csv) || { echo "could not fetch EC2 price list" >&2; exit 2; }
RDS=$(fetch AmazonRDS csv) || { echo "could not fetch RDS price list" >&2; exit 2; }
VPC=$(fetch AmazonVPC json) || { echo "could not fetch VPC price list" >&2; exit 2; }

head_ 'Published rates, read from the AWS price list'
ACTUAL=$(EC2="$EC2" RDS="$RDS" VPC="$VPC" python3 - <<'PY'
import csv, json, os, sys
out = {}

# --- EC2: NAT gateway. Matched on the price DESCRIPTION rather than usagetype,
# because the same file carries a Provisioned-Bandwidth Gbps-hour row that also
# says NatGateway and is 24x the price.
with open(os.environ["EC2"], newline="") as f:
    hdr = None
    for row in csv.reader(f):
        if row and row[0] == "SKU":
            hdr = row; continue
        if not hdr or len(row) < len(hdr):
            continue
        d = dict(zip(hdr, row))
        if d.get("Group") != "NGW:NatGateway" or d.get("TermType") != "OnDemand":
            continue
        if d.get("Unit") == "Hrs" and "nat_gateway_hour" not in out:
            out["nat_gateway_hour"] = float(d["PricePerUnit"])
        if d.get("Unit") == "GB" and "nat_gateway_gb" not in out:
            out["nat_gateway_gb"] = float(d["PricePerUnit"])

# --- VPC: the idle Elastic IP charge.
v = json.load(open(os.environ["VPC"]))
for sku, p in v["products"].items():
    if p.get("attributes", {}).get("usagetype") == "USE1-PublicIPv4:IdleAddress":
        for t in v["terms"]["OnDemand"][sku].values():
            for dim in t["priceDimensions"].values():
                out["eip_idle_hour"] = float(dim["pricePerUnit"]["USD"])

# --- RDS: instance classes and storage, PostgreSQL Single-AZ.
classes = {"db.t4g.micro", "db.t4g.small", "db.t4g.medium", "db.m6g.large"}
inst, store = {}, {}
with open(os.environ["RDS"], newline="") as f:
    hdr = None
    for row in csv.reader(f):
        if row and row[0] == "SKU":
            hdr = row; continue
        if not hdr or len(row) < len(hdr):
            continue
        d = dict(zip(hdr, row))
        if d.get("TermType") != "OnDemand" or d.get("Deployment Option") != "Single-AZ":
            continue
        it = d.get("Instance Type")
        if it in classes and d.get("Database Engine") == "PostgreSQL" and it not in inst:
            inst[it] = float(d["PricePerUnit"])
        if d.get("Product Family") == "Database Storage":
            vt = d.get("Volume Type")
            key = {"General Purpose": "gp2", "General Purpose-GP3": "gp3"}.get(vt)
            if key and key not in store:
                store[key] = float(d["PricePerUnit"])
out["rds_instance_hour"] = inst
out["rds_storage_gb_month"] = store
json.dump(out, sys.stdout)
PY
) || { echo "price extraction failed" >&2; exit 2; }

echo "$ACTUAL" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for k,v in d.items():
    if isinstance(v,dict):
        for k2,v2 in sorted(v.items()): print(f'        {k}.{k2:<18} \${v2}')
    else: print(f'        {k:<28} \${v}')
"

head_ 'PRICEBOOK vs published'
DECLARED=$(SHIM="$SHIM" python3 - <<'PY'
import ast, json, os, sys
src = open(os.environ["SHIM"]).read()
tree = ast.parse(src)
for node in tree.body:
    if isinstance(node, ast.Assign) and getattr(node.targets[0], "id", "") == "PRICEBOOK":
        json.dump(ast.literal_eval(node.value), sys.stdout); break
PY
)

DRIFT=$(ACTUAL="$ACTUAL" DECLARED="$DECLARED" python3 - <<'PY'
import json, os
a = json.loads(os.environ["ACTUAL"]); d = json.loads(os.environ["DECLARED"])
lines = []
def cmp(label, have, want):
    if want is None:
        lines.append(f"SKIP|{label}|{have}|not published in this region file")
    elif abs(float(have) - float(want)) < 1e-9:
        lines.append(f"OK|{label}|{have}|")
    else:
        lines.append(f"DRIFT|{label}|{have}|published {want}")
for k in ("nat_gateway_hour", "nat_gateway_gb", "eip_idle_hour"):
    cmp(k, d.get(k), a.get(k))
for k, v in sorted(d.get("rds_instance_hour", {}).items()):
    cmp(f"rds_instance_hour.{k}", v, a.get("rds_instance_hour", {}).get(k))
for k, v in sorted(d.get("rds_storage_gb_month", {}).items()):
    cmp(f"rds_storage_gb_month.{k}", v, a.get("rds_storage_gb_month", {}).get(k))
print("\n".join(lines))
PY
)

while IFS='|' read -r verdict label have why; do
  case "$verdict" in
    OK)    ok    "$(printf '%-32s $%s' "$label" "$have")" ;;
    DRIFT) bad   "$(printf '%-32s $%s  <- %s' "$label" "$have" "$why")" ;;
    SKIP)  note  "$(printf 'skip %-27s $%s  (%s)' "$label" "$have" "$why")" ;;
  esac
done <<< "$DRIFT"

head_ 'Result'
printf '%d verified, %d drifted\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  cat <<'EOF'

A drifted rate does not break anything visibly - the arithmetic stays correct,
the response stays well-formed, and the number simply stops matching an
invoice. Fix PRICEBOOK in scripts/floci-cost-apis-shim.py, then re-run.
EOF
  exit 1
fi
printf 'Rates only. This says nothing about quantities, and nothing was billed.\n'
exit 0
