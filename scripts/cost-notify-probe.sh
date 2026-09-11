#!/usr/bin/env bash
#
# cost-notify-probe.sh - answer "would the Budget actually notify?" as far as
# it CAN be answered without an account, and say exactly where that stops.
#
# THE CLAIM THIS ATTACKS
# ----------------------
# COST.md has said, correctly, that a template projection establishes only
# "what the stack asked for" - not that a budget exists or would notify. That
# sentence covers two very different things, and lumping them together
# concedes more than is true:
#
#   (a) would the THRESHOLD LOGIC fire on this stack's shape?
#   (b) would the NOTIFICATION REACH ANYBODY once it fired?
#
# Neither needs a real budget to answer. (a) is arithmetic over a cost figure
# and two declared thresholds. (b) is an SNS publish/subscribe round trip, and
# SNS is REAL on this endpoint - not emulated away, not projected.
#
# What stays unanswerable is the join between them: that AWS Budgets itself,
# the service, would evaluate and publish. floci runs no budgets service, so
# nothing here can establish that. This probe is explicit about which of the
# three it is testing at each step.
#
# WHAT IT DOES
#   1. reads the two declared notifications out of the deployed template
#   2. evaluates them against the projected monthly spend for TWO shapes -
#      dev (1 NAT) and prod-like (3 NATs) - and requires them to DISAGREE.
#      A threshold check that fires for both, or neither, has tested nothing.
#   3. subscribes a throwaway SQS queue to the REAL SNS topic, publishes the
#      breach message each firing notification would carry, and asserts it
#      arrives - end to end, through the topic the template actually created.
#   4. tears the queue and subscription down.
#
# Usage:  ./scripts/cost-notify-probe.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

REGION="${AWS_REGION:-us-east-1}"
COST_STACK="${COST_STACK:-taxcalc-cost-dev}"
SHIM_PORT="${SHIM_PORT:-5557}"
BUDGET_LIMIT="${BUDGET_LIMIT:-100}"
QUEUE="cost-notify-probe-$$"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
gap()  { printf '  \033[33mGAP \033[0m  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ -z "${AWS_ENDPOINT_URL:-}" ]; then
  printf 'refusing: AWS_ENDPOINT_URL is unset.\n' >&2
  printf 'Against a real account the Budget evaluates and publishes by itself;\n' >&2
  printf 'publishing a fake breach to the live topic would page a real human.\n' >&2
  exit 2
fi

aws_()  { aws --region "$REGION" "$@"; }
shim_() { aws --region "$REGION" --endpoint-url "http://127.0.0.1:$SHIM_PORT" "$@"; }

SHIM_PID=""; QURL=""; SUBARN=""
cleanup() {
  [ -n "$SUBARN" ] && aws_ sns unsubscribe --subscription-arn "$SUBARN" >/dev/null 2>&1
  [ -n "$QURL" ]   && aws_ sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1
  [ -n "$SHIM_PID" ] && kill "$SHIM_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

if ! curl -s --max-time 2 "http://127.0.0.1:$SHIM_PORT" >/dev/null 2>&1; then
  python3 "$HERE/floci-cost-apis-shim.py" --port "$SHIM_PORT" >/tmp/notify-probe-shim.log 2>&1 &
  SHIM_PID=$!
  sleep 3
fi

printf '\033[1mcost-notify-probe\033[0m  engine: floci at %s\n' "$AWS_ENDPOINT_URL"

# ---------------------------------------------------------------------------
head_ '1  The two declared notifications'
NOTIFS=$(shim_ budgets describe-notifications-for-budget --account-id 000000000000 \
  --budget-name "taxcalc-monthly-cost-${COST_STACK##*-}" \
  --query 'Notifications[].[NotificationType,Threshold]' --output text 2>/dev/null)
if [ -z "$NOTIFS" ]; then
  bad "could not read the notifications out of $COST_STACK"
  exit 1
fi
echo "$NOTIFS" | while read -r t th; do note "$t > ${th%.*}% of \$$BUDGET_LIMIT"; done
ok "two notifications declared"

# ---------------------------------------------------------------------------
head_ '2  Threshold evaluation - dev shape vs prod shape'
# The dev figure is the live projection. The prod figure is the same projection
# with the NAT count the template produces for EnvName=prod, which the
# ChangeSet A/B in cost-done-when.sh establishes independently as 3.
SPEND_DEV=$(shim_ ce get-cost-and-usage \
  --time-period "Start=$(date -u +%Y-%m)-01,End=$(date -u -v+1m +%Y-%m-01 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01)" \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter '{"Tags":{"Key":"service","Values":["taxcalc"]}}' \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null)
NAT_ONE=$(shim_ ce get-cost-and-usage \
  --time-period "Start=$(date -u +%Y-%m)-01,End=$(date -u -v+1m +%Y-%m-01 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01)" \
  --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=USAGE_TYPE \
  --filter '{"Tags":{"Key":"service","Values":["taxcalc"]}}' \
  --query "ResultsByTime[0].Groups[?contains(Keys[0],'NatGateway-Hours')].Metrics.UnblendedCost.Amount" \
  --output text 2>/dev/null)

EVAL=$(SPEND_DEV="$SPEND_DEV" NAT_ONE="$NAT_ONE" LIMIT="$BUDGET_LIMIT" python3 - <<'PY'
import os
dev  = float(os.environ["SPEND_DEV"] or 0)
nat  = float(os.environ["NAT_ONE"] or 0)
lim  = float(os.environ["LIMIT"])
prod = dev + 2 * nat          # prod-like = the same stack with 3 NATs, not 1
rows = []
for label, spend in (("dev", dev), ("prod-like", prod)):
    f80  = spend > 0.80 * lim
    a100 = spend > 1.00 * lim
    rows.append(f"{label}|{spend:.2f}|{'BREACH' if f80 else 'ok'}|{'BREACH' if a100 else 'ok'}")
print("\n".join(rows))
PY
)
printf '  %-12s %10s  %-14s %-14s\n' "shape" "projected" "FORECASTED>80%" "ACTUAL>100%"
echo "$EVAL" | while IFS='|' read -r l s f a; do printf '  %-12s %10s  %-14s %-14s\n' "$l" "\$$s" "$f" "$a"; done

DEV_F=$(echo "$EVAL" | awk -F'|' '/^dev\|/{print $3}')
PROD_F=$(echo "$EVAL" | awk -F'|' '/^prod-like\|/{print $3}')
if [ "$DEV_F" = "ok" ] && [ "$PROD_F" = "BREACH" ]; then
  ok "the thresholds DISCRIMINATE: dev stays under, prod-like breaches"
  note "A check that fired for both shapes, or neither, would have tested"
  note "nothing. The difference is the 2 extra NAT gateways IsProdLike adds."
else
  bad "thresholds did not discriminate (dev=$DEV_F prod=$PROD_F)"
fi

# ---------------------------------------------------------------------------
head_ '3  Delivery - does the topic actually reach a subscriber?'
TOPIC=$(aws_ sns list-topics --query "Topics[?contains(TopicArn,'cost-alarms')].TopicArn" --output text | head -1)
if [ -z "$TOPIC" ]; then
  bad "no cost-alarms topic on this endpoint"
else
  QURL=$(aws_ sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text 2>/dev/null)
  QARN=$(aws_ sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn \
         --query 'Attributes.QueueArn' --output text 2>/dev/null)
  SUBARN=$(aws_ sns subscribe --topic-arn "$TOPIC" --protocol sqs \
           --notification-endpoint "$QARN" --query SubscriptionArn --output text 2>/dev/null)
  SUBJ="AWS Budgets: taxcalc-monthly-cost-dev FORECASTED > 80%"
  aws_ sns publish --topic-arn "$TOPIC" --subject "$SUBJ" \
    --message "{\"budgetName\":\"taxcalc-monthly-cost-dev\",\"notificationType\":\"FORECASTED\",\"threshold\":80}" \
    >/dev/null 2>&1
  sleep 2
  GOT=$(aws_ sqs receive-message --queue-url "$QURL" --max-number-of-messages 1 \
        --query 'Messages[0].Body' --output text 2>/dev/null \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('Subject',''))" 2>/dev/null)
  if [ "$GOT" = "$SUBJ" ]; then
    ok "a message published to the topic reached a subscriber"
    note "Topic: $TOPIC"
    note "This is REAL: floci's SNS is not projected. The topic the template"
    note "created does deliver to the endpoints subscribed to it."
  else
    bad "published to the topic but nothing arrived at the subscriber"
  fi
fi

# ---------------------------------------------------------------------------
head_ '4  What this does NOT establish'
gap "that AWS Budgets, the service, would evaluate and publish"
note "floci runs no budgets service at all, so the JOIN between steps 2 and 3"
note "- a real budget noticing a real breach and calling SNS itself - has no"
note "local proof. Step 2 shows the thresholds are right for this stack's"
note "shape; step 3 shows the topic delivers. Nothing here shows AWS wiring"
note "the one to the other."
gap "that the TopicPolicy permits budgets.amazonaws.com to publish"
note "floci drops the TopicPolicy entirely and leaves the topic on its default"
note "open policy, so the publish in step 3 succeeded WITHOUT the policy being"
note "in force. On a real account that policy is load-bearing and this probe"
note "would not detect its absence. Read that as a limit of the probe."

head_ 'Result'
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
