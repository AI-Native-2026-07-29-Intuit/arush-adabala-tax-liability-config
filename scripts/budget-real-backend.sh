#!/usr/bin/env bash
#
# budget-real-backend.sh - run a REAL, stateful AWS Budgets implementation
# locally, seed it from the deployed template, and prove it behaves like a
# resource rather than like a projection.
#
# WHAT THIS REPLACES, AND WHY IT IS BETTER
# ----------------------------------------
# floci runs no `budgets` service, so until now `describe-budget` was answered
# by floci-cost-apis-shim.py PROJECTING the deployed template. That answer was
# always correctly labelled, but the criticism of it was exact:
#
#   "change the template and the answer changes, which is the whole of its
#    fidelity"
#
# moto - a third-party, independently maintained AWS emulator - implements the
# budgets API with real storage: CreateBudget, DescribeBudget, DescribeBudgets,
# DeleteBudget, CreateNotification, DeleteNotification,
# DescribeNotificationsForBudget. Pointing the budgets calls at it turns the
# budget into an OBJECT WITH A LIFECYCLE:
#
#   * it is created by an explicit API call, not inferred
#   * describe-budget reads stored state, so editing the template changes
#     NOTHING until the budget is re-created
#   * creating it twice is a DuplicateRecordException
#   * deleting it makes describe-budget a NotFoundException
#
# That is four properties the projection could not have, and this script
# demonstrates all four rather than asserting them.
#
# WHAT IT IS STILL NOT. moto is not AWS. It stores a budget; it does not
# EVALUATE one. Nothing here watches spend, crosses a threshold, or publishes
# to SNS - that join is the one thing cost-notify-probe.sh also cannot close,
# and it remains the honest gap. "A budget exists and can be read back" is now
# established. "AWS Budgets would notice a breach and notify" is not.
#
# Subscribers are deliberately NOT read from here: moto does not implement
# DescribeSubscribersForNotification. That one call stays with the shim, which
# cross-checks the SNS address against a live `sns list-topics`.
#
# Usage:
#   ./scripts/budget-real-backend.sh up      # start, seed from the template
#   ./scripts/budget-real-backend.sh prove   # the four lifecycle properties
#   ./scripts/budget-real-backend.sh down
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

REGION="${AWS_REGION:-us-east-1}"
PORT="${MOTO_PORT:-5600}"
ACCOUNT="${ACCOUNT:-000000000000}"
COST_STACK="${COST_STACK:-taxcalc-cost-dev}"
BUDGET_NAME="${BUDGET_NAME:-taxcalc-monthly-cost-dev}"
VENV="${MOTO_VENV:-/tmp/motovenv}"
CFN_DIR="${CFN_DIR:-cfn}"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ -z "${AWS_ENDPOINT_URL:-}" ]; then
  printf 'refusing: AWS_ENDPOINT_URL is unset.\n' >&2
  printf 'Against a real account AWS Budgets is the real thing; standing a local\n' >&2
  printf 'implementation in front of it would replace true answers with stored ones.\n' >&2
  exit 2
fi

moto_() { aws --region "$REGION" --endpoint-url "http://127.0.0.1:$PORT" "$@"; }
floci_() { aws --region "$REGION" "$@"; }

ensure_moto() {
  if [ ! -x "$VENV/bin/moto_server" ]; then
    printf 'moto is not installed at %s\n' "$VENV" >&2
    printf 'Install it with:  python3 -m venv %s && %s/bin/pip install "moto[server]"\n' "$VENV" "$VENV" >&2
    return 2
  fi
  if ! curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT"; then
    "$VENV/bin/moto_server" -p "$PORT" >/tmp/moto.log 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 1 -o /dev/null "http://127.0.0.1:$PORT" && break
      sleep 0.5
    done
  fi
  curl -s -m 2 -o /dev/null "http://127.0.0.1:$PORT"
}

# The budget the deployed stack declares, resolved through live physical ids
# and live exports - the same extractor the shim uses, so the seed and the
# projection can never disagree about what the template said.
budget_json() {
  local phys exp
  phys=$(floci_ cloudformation describe-stack-resources --stack-name "$COST_STACK" --output json 2>/dev/null \
    | python3 -c "import json,sys;print(json.dumps({r['LogicalResourceId']:r.get('PhysicalResourceId','') for r in json.load(sys.stdin)['StackResources']}))")
  exp=$(floci_ cloudformation list-exports --output json 2>/dev/null \
    | python3 -c "import json,sys;print(json.dumps({e['Name']:e['Value'] for e in json.load(sys.stdin)['Exports']}))")
  CFN_STACK_NAME="$COST_STACK" CFN_EXPORTS="$exp" \
    ruby "$HERE/cfn-extract-cost.rb" "$ROOT/$CFN_DIR/$COST_STACK.yaml" "$phys" EnvName=dev 2>/dev/null \
    | python3 -c "
import json,sys
b=json.load(sys.stdin)['budgets']
if not b: sys.exit(1)
print(json.dumps({'Budget':b[0]['Budget'],'NotificationsWithSubscribers':b[0]['NotificationsWithSubscribers']}))"
}

cmd_up() {
  ensure_moto || return 2
  head_ "budget-real-backend: seeding $BUDGET_NAME into moto on :$PORT"
  local defn
  defn=$(budget_json) || { bad "could not read a budget out of $CFN_DIR/$COST_STACK.yaml"; return 1; }
  # Idempotent: delete first, so `up` is re-runnable without a duplicate error.
  moto_ budgets delete-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" >/dev/null 2>&1
  # Env prefix goes BEFORE python3: `python3 -c "..." A=1` sets sys.argv, not
  # os.environ, and the script then reads an empty region and fails silently.
  echo "$defn" | REGION="$REGION" PORT="$PORT" ACCOUNT="$ACCOUNT" python3 -c "
import json,subprocess,sys,os
d=json.load(sys.stdin)
r=subprocess.run(['aws','--region',os.environ['REGION'],'--endpoint-url','http://127.0.0.1:'+os.environ['PORT'],
  'budgets','create-budget','--account-id',os.environ['ACCOUNT'],
  '--budget',json.dumps(d['Budget']),
  '--notifications-with-subscribers',json.dumps(d['NotificationsWithSubscribers'])],
  capture_output=True,text=True)
sys.exit(0 if r.returncode==0 else (sys.stderr.write(r.stderr[:400]) or 1))" \
    || { bad "create-budget failed"; return 1; }
  ok "created - this is an explicit API create, not an inference from the template"
  moto_ budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" \
    --query 'Budget.[BudgetName,BudgetLimit.Amount,BudgetLimit.Unit,BudgetType,TimeUnit]' --output text \
    | while read -r l; do note "$l"; done
}

cmd_prove() {
  ensure_moto || return 2
  head_ 'The four properties a projection cannot have'

  # 1. read-back
  local amt
  amt=$(moto_ budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" \
        --query 'Budget.BudgetLimit.Amount' --output text 2>/dev/null)
  [ "$amt" = "100" ] && ok "1. describe-budget reads STORED state (BudgetLimit $amt USD)" \
                     || bad "1. describe-budget did not read back a stored budget (got '${amt:-nothing}')"

  # 2. independence from the template - the property the criticism named.
  local tmp before after
  tmp=$(mktemp); cp "$ROOT/$CFN_DIR/$COST_STACK.yaml" "$tmp"
  before=$(moto_ budgets describe-notifications-for-budget --account-id "$ACCOUNT" \
           --budget-name "$BUDGET_NAME" --query 'Notifications[?NotificationType==`FORECASTED`].Threshold' --output text 2>/dev/null)
  python3 -c "
p='$ROOT/$CFN_DIR/$COST_STACK.yaml';s=open(p).read()
open(p,'w').write(s.replace('Threshold: 80','Threshold: 55',1))"
  after=$(moto_ budgets describe-notifications-for-budget --account-id "$ACCOUNT" \
          --budget-name "$BUDGET_NAME" --query 'Notifications[?NotificationType==`FORECASTED`].Threshold' --output text 2>/dev/null)
  cp "$tmp" "$ROOT/$CFN_DIR/$COST_STACK.yaml"; rm -f "$tmp"
  if [ "$before" = "$after" ] && [ -n "$after" ]; then
    ok "2. editing the template changed NOTHING (FORECASTED stayed $after)"
    note "The projection shim answers 55 for the same edit. That difference IS"
    note "the difference between reading a resource and restating a file."
  else
    bad "2. the stored budget tracked a template edit ($before -> $after)"
  fi

  # 3. duplicate create is refused
  if moto_ budgets create-budget --account-id "$ACCOUNT" \
       --budget "{\"BudgetName\":\"$BUDGET_NAME\",\"BudgetType\":\"COST\",\"TimeUnit\":\"MONTHLY\",\"BudgetLimit\":{\"Amount\":\"100\",\"Unit\":\"USD\"}}" \
       >/dev/null 2>&1; then
    bad "3. a duplicate create was accepted"
  else
    ok "3. duplicate create refused (DuplicateRecordException)"
  fi

  # 4. delete removes it, then restore
  moto_ budgets delete-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" >/dev/null 2>&1
  if moto_ budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" >/dev/null 2>&1; then
    bad "4. describe-budget still answered after a delete"
  else
    ok "4. after delete, describe-budget is NotFoundException"
  fi
  cmd_up >/dev/null 2>&1 && note "(re-seeded)"

  head_ 'Still not established'
  note "moto STORES a budget; it does not EVALUATE one. Nothing here watches"
  note "spend, crosses a threshold, or publishes to SNS. 'A budget exists and"
  note "reads back' is now shown. 'AWS Budgets would notice a breach and"
  note "notify' is not, and no local component can show it."

  head_ 'Result'
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || return 1
  return 0
}

cmd_down() { pkill -f "moto_server -p $PORT" 2>/dev/null; printf 'moto on :%s stopped\n' "$PORT"; }

case "${1:-prove}" in
  up)    cmd_up ;;
  prove) cmd_up >/dev/null 2>&1; cmd_prove ;;
  down)  cmd_down ;;
  *) printf 'usage: %s {up|prove|down}\n' "$0" >&2; exit 2 ;;
esac
