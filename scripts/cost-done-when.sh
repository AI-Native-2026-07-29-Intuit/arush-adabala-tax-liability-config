#!/usr/bin/env bash
#
# cost-done-when.sh - run W6 D4 Task 1's four acceptance checks, and label each
# result with what it is actually worth on the engine that produced it.
#
# The four checks, as the brief states them:
#
#   1  describe-stacks --stack-name taxcalc-cost-dev            -> CREATE_COMPLETE
#   2  budgets describe-budget --budget-name taxcalc-monthly-cost-dev
#                                                -> BudgetLimit 100 USD, 2 notifications
#   3  cloudwatch describe-alarms --alarm-names taxcalc/estimated-charges-dev
#                                                -> AWS/Billing, EstimatedCharges
#   4  resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc
#                                                -> the NAT gateway(s) and the RDS instance
#
# WHY THIS SCRIPT EXISTS AS WELL AS THE COMMANDS
# ----------------------------------------------
# No AWS account is wired to this repository, so all four run against floci -
# and floci answers two of them wrongly in OPPOSITE directions. Check 1 passes
# for a stack containing a resource type the emulator cannot model at all, and
# check 4 fails for tags that are genuinely applied. Running the raw commands
# and reading the exit statuses would therefore produce one false pass and one
# false failure. Each result below is printed with the engine and the
# provenance that produced it, so the output cannot be pasted anywhere as a
# clean sweep.
#
# Three verdicts, and the distinction is the point:
#
#   PASS  the check is satisfied and the evidence means what it says
#   SHIM  the check is satisfied, but only through a local stand-in for an API
#         floci does not implement - read the provenance line before believing it
#   GAP   not satisfiable on this engine at all, and why
#
# Usage:
#   export AWS_ENDPOINT_URL=http://localhost:4566     # floci
#   ./scripts/cost-done-when.sh
#
#   unset AWS_ENDPOINT_URL                            # a real account
#   ./scripts/cost-done-when.sh                       # no shims, no reconciles
#
# Against real AWS it runs the four commands unmodified and every satisfied
# check is a PASS, because none of the workarounds is used or needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${AWS_REGION:-us-east-1}"
COST_STACK="${COST_STACK:-taxcalc-cost-dev}"
BUDGET_NAME="${BUDGET_NAME:-taxcalc-monthly-cost-dev}"
ALARM_NAME="${ALARM_NAME:-taxcalc/estimated-charges-dev}"
SHIM_PORT="${SHIM_PORT:-5557}"

PASS=0; SHIM=0; GAP=0; FAIL=0
SHIM_PID=""

is_emulator() { [ -n "${AWS_ENDPOINT_URL:-}" ]; }
aws_()  { aws --region "$REGION" "$@"; }
# Calls that must go to the local shim rather than to floci.
awss_() { aws --region "$REGION" --endpoint-url "http://127.0.0.1:$SHIM_PORT" "$@"; }

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
shim() { printf '  \033[36mSHIM\033[0m  %s\n' "$1"; SHIM=$((SHIM+1)); }
gap()  { printf '  \033[33mGAP \033[0m  %s\n' "$1"; GAP=$((GAP+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
note() { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() { [ -n "$SHIM_PID" ] && kill "$SHIM_PID" 2>/dev/null; }
trap cleanup EXIT

ACCOUNT=$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT" ]; then
  echo "refusing: sts get-caller-identity returned nothing." >&2
  echo "Set AWS_ENDPOINT_URL for floci, or configure real credentials." >&2
  exit 2
fi

printf '\033[1mW6 D4 Task 1 - Done When\033[0m\n'
if is_emulator; then
  printf 'engine: floci at %s   account: %s   region: %s\n' "$AWS_ENDPOINT_URL" "$ACCOUNT" "$REGION"
  printf 'NOT AWS. Read every SHIM and GAP line before quoting any of this.\n'
else
  printf 'engine: real AWS   account: %s   region: %s\n' "$ACCOUNT" "$REGION"
fi

# Start the shim only on an emulator, and only if the two APIs are really
# missing. Probing rather than assuming keeps this correct if a later floci
# implements one of them.
if is_emulator; then
  need_shim=0
  aws_ budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" >/dev/null 2>&1 || need_shim=1
  if [ "$(aws_ resourcegroupstaggingapi get-resources --query 'length(ResourceTagMappingList)' --output text 2>/dev/null || echo 0)" = "0" ]; then
    need_shim=1
  fi
  # Also needed when the alarm exists but this endpoint dropped a property it
  # declared - the shim forwards the real alarm and overlays only those.
  if [ "$(aws_ cloudwatch describe-alarms --alarm-names "$ALARM_NAME" \
          --query 'MetricAlarms[0].TreatMissingData' --output text 2>/dev/null)" != "ignore" ]; then
    need_shim=1
  fi
  if [ "$need_shim" = "1" ]; then
    "$HERE/floci-cost-apis-shim.py" --port "$SHIM_PORT" --stack "$COST_STACK" >/dev/null 2>&1 &
    SHIM_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      curl -s -m 1 -o /dev/null "http://127.0.0.1:$SHIM_PORT" && break
      sleep 0.3
    done
  fi
fi

# ---------------------------------------------------------------------------
head_ '1  describe-stacks taxcalc-cost-dev -> CREATE_COMPLETE'
STATUS=$(aws_ cloudformation describe-stacks --stack-name "$COST_STACK" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
case "$STATUS" in
  CREATE_COMPLETE|UPDATE_COMPLETE)
    if is_emulator; then
      # Reported as satisfied, and immediately qualified: the budget resource
      # inside this stack is CREATE_COMPLETE against a service floci does not
      # run. The status is true about the template and says nothing about the
      # resources.
      ok "$COST_STACK is $STATUS"
      note "Qualified: MonthlyCostBudget reports CREATE_COMPLETE with a physical"
      note "id, and floci runs no budgets service at all. CREATE_COMPLETE here"
      note "means the template parsed, not that the guardrail exists."
    else
      ok "$COST_STACK is $STATUS"
    fi
    ;;
  "" ) bad "$COST_STACK is not deployed" ;;
  *  ) bad "$COST_STACK is $STATUS" ;;
esac

# ---------------------------------------------------------------------------
head_ '2  budgets describe-budget -> BudgetLimit 100 USD, two notifications'
BUDGET_JSON=$(aws_ budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" 2>/dev/null)
VIA="floci"
if [ -z "$BUDGET_JSON" ] && [ -n "$SHIM_PID" ]; then
  BUDGET_JSON=$(awss_ budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" 2>/dev/null)
  VIA="shim"
fi

if [ -z "$BUDGET_JSON" ]; then
  gap "describe-budget is unavailable and the shim did not answer"
  note "floci implements no budgets service; start floci-cost-apis-shim.py."
else
  AMOUNT=$(echo "$BUDGET_JSON" | jq -r '.Budget.BudgetLimit.Amount // empty')
  UNIT=$(echo "$BUDGET_JSON" | jq -r '.Budget.BudgetLimit.Unit // empty')
  BTYPE=$(echo "$BUDGET_JSON" | jq -r '.Budget.BudgetType // empty')
  TUNIT=$(echo "$BUDGET_JSON" | jq -r '.Budget.TimeUnit // empty')
  FILTERS=$(echo "$BUDGET_JSON" | jq -r '[.Budget.CostFilters.TagKeyValue[]?] | join(", ")')

  if [ "$VIA" = "shim" ]; then
    NOTIFS=$(awss_ budgets describe-notifications-for-budget --account-id "$ACCOUNT" \
      --budget-name "$BUDGET_NAME" --query 'length(Notifications)' --output text 2>/dev/null)
    NKINDS=$(awss_ budgets describe-notifications-for-budget --account-id "$ACCOUNT" \
      --budget-name "$BUDGET_NAME" \
      --query 'Notifications[].[NotificationType,Threshold]' --output text 2>/dev/null | tr '\n' ' ')
  else
    NOTIFS=$(aws_ budgets describe-notifications-for-budget --account-id "$ACCOUNT" \
      --budget-name "$BUDGET_NAME" --query 'length(Notifications)' --output text 2>/dev/null)
    NKINDS=$(aws_ budgets describe-notifications-for-budget --account-id "$ACCOUNT" \
      --budget-name "$BUDGET_NAME" \
      --query 'Notifications[].[NotificationType,Threshold]' --output text 2>/dev/null | tr '\n' ' ')
  fi

  DESC="BudgetLimit ${AMOUNT} ${UNIT}, ${BTYPE}/${TUNIT}, ${NOTIFS:-0} notification(s): ${NKINDS}"
  if [ "$AMOUNT" = "100" ] && [ "$UNIT" = "USD" ] && [ "${NOTIFS:-0}" = "2" ]; then
    if [ "$VIA" = "shim" ]; then
      shim "$DESC"
      note "Provenance: PROJECTED from $COST_STACK's deployed template, not read"
      note "from a budget - there is no budget on this endpoint to read. This is"
      note "evidence of what the stack ASKED FOR. It is not evidence that a"
      note "budget exists, that its CostFilters match anything, or that it would"
      note "ever notify. Only a real account can establish those."
      note "CostFilters: $FILTERS"
    else
      ok "$DESC"
      note "CostFilters: $FILTERS"
    fi
  else
    bad "$DESC (expected BudgetLimit 100 USD and 2 notifications)"
  fi
fi

# ---------------------------------------------------------------------------
head_ '3  describe-alarms -> Namespace AWS/Billing, MetricName EstimatedCharges'
read -r A_NS A_METRIC A_THRESH A_TMD <<EOF_ALARM
$(aws_ cloudwatch describe-alarms --alarm-names "$ALARM_NAME" \
   --query 'MetricAlarms[0].[Namespace,MetricName,Threshold,TreatMissingData]' --output text 2>/dev/null)
EOF_ALARM

if [ "$A_NS" = "AWS/Billing" ] && [ "$A_METRIC" = "EstimatedCharges" ]; then
  # The Done-When itself - namespace and metric name - is genuinely satisfied
  # on floci with nothing standing in for it. This stays a PASS.
  ok "$ALARM_NAME - $A_NS / $A_METRIC, threshold $A_THRESH"
  if is_emulator && [ "$A_TMD" != "ignore" ]; then
    A_TMD_SHIM=""
    if [ -n "$SHIM_PID" ]; then
      A_TMD_SHIM=$(awss_ cloudwatch describe-alarms --alarm-names "$ALARM_NAME" \
        --query 'MetricAlarms[0].TreatMissingData' --output text 2>/dev/null)
    fi
    note "Beyond the Done-When: floci stores no TreatMissingData for this alarm"
    note "(the property is absent from the record, not defaulted)."
    if [ "$A_TMD_SHIM" = "ignore" ]; then
      note "Through the shim it reads '$A_TMD_SHIM', overlaid from the template and"
      note "named in the response's OverlaidFromTemplate. That fixes what you can"
      note "READ, not how the alarm BEHAVES: floci's alarm still evaluates a gappy"
      note "metric as 'missing', so its firing behaviour cannot be tested here."
    else
      note "It reads '${A_TMD}'. No API call closes this - floci's CloudWatch drops"
      note "it over put-metric-alarm too. Start floci-cost-apis-shim.py to read the"
      note "declared value; see cfn-guardrails.sh reconcile-cloudwatch."
    fi
  fi
elif [ -z "$A_NS" ] || [ "$A_NS" = "None" ]; then
  if [ "$REGION" != "us-east-1" ]; then
    gap "no alarm in $REGION - correct: IsUsEast1 gates it, EstimatedCharges is us-east-1 only"
  else
    bad "$ALARM_NAME does not exist in $REGION"
  fi
else
  bad "$ALARM_NAME is $A_NS / $A_METRIC, expected AWS/Billing / EstimatedCharges"
fi

# ---------------------------------------------------------------------------
head_ '4  get-resources Key=service,Values=taxcalc -> the NAT gateway(s) and the RDS instance'
TAGGED=$(aws_ resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)
VIA="floci"
if [ -z "$TAGGED" ] && [ -n "$SHIM_PID" ]; then
  TAGGED=$(awss_ resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null)
  VIA="shim"
fi

NATS=$(echo "$TAGGED" | tr '\t' '\n' | grep -c 'natgateway/' || true)
DBS=$(echo "$TAGGED" | tr '\t' '\n' | grep -c ':rds:.*:db:' || true)

if [ "$NATS" -ge 1 ] && [ "$DBS" -ge 1 ]; then
  DESC="$NATS NAT gateway(s) and $DBS RDS instance(s) carry service=taxcalc"
  if [ "$VIA" = "shim" ]; then
    shim "$DESC"
    note "Provenance: the TAGS are real - read live from ec2 describe-tags and"
    note "rds list-tags-for-resource at request time. Only the INDEX is stood"
    note "in for: floci's resourcegroupstaggingapi is 'running' and returns an"
    note "empty list for every query, including for an S3 bucket whose own"
    note "get-bucket-tagging shows the tag."
    note "Also real, and applied by cfn-guardrails.sh reconcile-tags rather than"
    note "by CloudFormation, which drops every declared tag on this endpoint."
    note "Still NOT established: cost attribution. floci bills nobody, so no tag"
    note "key is activated and no Cost Explorer report can group by one."
  else
    ok "$DESC"
  fi
  echo "$TAGGED" | tr '\t' '\n' | sed 's/^/        /'
elif [ -z "$TAGGED" ]; then
  gap "no resource carries service=taxcalc"
  note "Deploy taxcalc-network-dev and taxcalc-app-dev, then run"
  note "'cfn-guardrails.sh reconcile-tags'. On floci the network stack needs"
  note "'cfn-resolve-if.rb' first - see that script for why."
else
  bad "found $NATS NAT gateway(s) and $DBS RDS instance(s); expected at least one of each"
fi

# ---------------------------------------------------------------------------
head_ 'Result'
printf '%d passed, %d satisfied via a local shim, %d gap(s), %d failed\n' "$PASS" "$SHIM" "$GAP" "$FAIL"
if [ "$SHIM" -gt 0 ] || [ "$GAP" -gt 0 ]; then
  cat <<'EOF_CAVEAT'

SHIM and GAP are not passes and must not be reported as any. The one check
that is fully established on this engine is the alarm's namespace and metric
name. The Budget's existence, its notification delivery and the tag-scoped
cost attribution all need a real account, and no local workaround can supply
them - see taxcalc-api/COST.md.
EOF_CAVEAT
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
