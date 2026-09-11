#!/usr/bin/env bash
#
# cost-done-when.sh - run W6 D4's acceptance checks, and label each result with
# what it is actually worth on the engine that produced it.
#
# Tasks 1 and 4, as the briefs state them:
#
#   1  describe-stacks --stack-name taxcalc-cost-dev            -> CREATE_COMPLETE
#   2  budgets describe-budget --budget-name taxcalc-monthly-cost-dev
#                                                -> BudgetLimit 100 USD, 2 notifications
#                                                   WIRED TO THE SNS TOPIC
#   3  cloudwatch describe-alarms --alarm-names taxcalc/estimated-charges-dev
#                                                -> AWS/Billing, EstimatedCharges
#   4  resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc
#                                                -> the NAT gateway(s) and the RDS instance
#   5  Cost Explorer grouped by the service tag  -> the NAT line item, and the
#                                                   1-NAT-dev vs 3-NAT-prod decision
#
# Check 2's "wired to the SNS topic" is a separate finding from its thresholds
# and is reported as one. DescribeBudget and DescribeNotificationsForBudget
# both OMIT subscribers, so neither can answer it; DescribeSubscribersForNotification
# is the modelled call that carries the Address. A budget with two perfectly
# shaped notifications and no subscriber is configured, green and silent.
#
# Check 5 splits into three findings worth three different things - floci's own
# all-zero ce (a structural GAP), the NAT lever (a real PASS, because it is
# template evaluation rather than spend), and a projected drill-down (a SHIM).
# Collapsing those into one verdict is exactly the laundering this script exists
# to prevent.
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

# How many NAT gateways would this template build for a given EnvName?
#
# Answered with a CREATE ChangeSet and describe-change-set: CloudFormation
# evaluates the Conditions and reports what it WOULD build, without building
# it. Nothing is executed and the throwaway stack is deleted either way, so
# this costs nothing and cannot leave a NAT gateway behind - which on a real
# account would be a $32/mo way to verify a $32/mo decision.
#
# Separate `local` statements are deliberate: `local a="$1" b="$a"` does not
# work, because the builtin's arguments are all word-expanded before it runs.
nat_count_for_env() {
  local env="$1"
  local stack="taxcalc-natlever-$env"
  local cs="natlever-$env"
  local n
  aws_ cloudformation create-change-set --stack-name "$stack" --change-set-name "$cs" \
    --change-set-type CREATE --template-body "file://$HERE/../cfn/taxcalc-network-dev.yaml" \
    --parameters "ParameterKey=EnvName,ParameterValue=$env" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null 2>&1
  sleep 4
  n=$(aws_ cloudformation describe-change-set --stack-name "$stack" --change-set-name "$cs" \
        --query "length(Changes[?ResourceChange.ResourceType=='AWS::EC2::NatGateway'])" \
        --output text 2>/dev/null)
  aws_ cloudformation delete-stack --stack-name "$stack" >/dev/null 2>&1
  echo "${n:-?}"
}
trap cleanup EXIT

ACCOUNT=$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT" ]; then
  echo "refusing: sts get-caller-identity returned nothing." >&2
  echo "Set AWS_ENDPOINT_URL for floci, or configure real credentials." >&2
  exit 2
fi

printf '\033[1mW6 D4 Tasks 1 and 4 - Done When\033[0m\n'
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

  # --- Do the two notifications actually point AT THE SNS TOPIC? ------------
  # The Done-When says "two notifications wired to the SNS topic", and neither
  # DescribeBudget nor DescribeNotificationsForBudget can answer the second
  # half: both omit subscribers and stop at the thresholds. A budget with two
  # perfectly-shaped notifications and no subscriber is configured, green, and
  # silent - the exact "deployed but cannot fire" shape this stack exists to
  # prevent. DescribeSubscribersForNotification is the modelled call that
  # carries the Address, so it is the one the evidence needs.
  SUBS_OK=0
  SUBS_SEEN=""
  # Pick the caller by NAME. `{ cond && a || b ; } args` is not valid shell -
  # a brace group cannot take a command's arguments - and bash -n does not
  # catch it because the error only surfaces inside the command substitution.
  if [ "$VIA" = "shim" ]; then RUN_BUDGETS=awss_; else RUN_BUDGETS=aws_; fi
  for PAIR in "FORECASTED 80" "ACTUAL 100"; do
    set -- $PAIR
    ADDR=$("$RUN_BUDGETS" budgets describe-subscribers-for-notification \
      --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" \
      --notification "NotificationType=$1,ComparisonOperator=GREATER_THAN,Threshold=$2,ThresholdType=PERCENTAGE" \
      --query 'Subscribers[?SubscriptionType==`SNS`].Address' --output text 2>/dev/null)
    if [ -n "$ADDR" ]; then
      SUBS_OK=$((SUBS_OK + 1))
      SUBS_SEEN="$SUBS_SEEN $1>$ADDR"
    fi
  done

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
    # The subscriber half is reported separately, because it is worth more than
    # the thresholds beside it: the topic ARN is a live physical id, and the
    # shim cross-checks it against `sns list-topics` before answering. A
    # subscriber aimed at a topic that is not there is the most likely way this
    # wiring is wrong in practice, and it is the one part of the budget an
    # emulator can still refute.
    if [ "$SUBS_OK" = "2" ]; then
      note "both notifications subscribe an SNS topic:$SUBS_SEEN"
      note "The ARN is a LIVE physical id, cross-checked against sns list-topics -"
      note "stronger than the thresholds above, which are template projection."
    else
      bad "only $SUBS_OK of 2 notifications resolve to an SNS subscriber"
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
head_ '5  Cost Explorer drill-down: group by the service tag, find the NAT line item'
# W6 D4 Task 4's first Done-When. This check splits into three findings that
# are worth three different things, and collapsing them into one verdict is
# exactly the laundering this script exists to avoid.
CE_ZERO=$(aws_ ce get-cost-and-usage --time-period "Start=$(date -u +%Y-%m)-01,End=$(date -u -v+1m +%Y-%m-01 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01)" \
  --granularity MONTHLY --metrics UnblendedCost --group-by Type=TAG,Key=service \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null)
CE_TAGS=$(aws_ ce get-tags --time-period "Start=$(date -u +%Y-%m)-01,End=$(date -u -v+1m +%Y-%m-01 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01)" \
  --query 'TotalSize' --output text 2>/dev/null)

if is_emulator; then
  # (a) floci's OWN ce, unshimmed. Reported first so the gap is on the record
  #     before any workaround is mentioned.
  gap "floci ce answers the API and reports ${CE_ZERO:-0} spend across ${CE_TAGS:-0} tag keys"
  note "AN EMULATOR BILLS NOBODY. This is not a missing feature a later version"
  note "adds - there is no spend to report and no tag key activated, because"
  note "activation is a Billing-console action on an account being invoiced."
  note "Unlike the budgets gap (a provider bug), this one is structural."

  # (b) the NAT lever, which IS settleable here - template evaluation, not spend.
  NAT_DEV=$(nat_count_for_env dev)
  NAT_PROD=$(nat_count_for_env prod)
  if [ "$NAT_DEV" = "1" ] && [ "$NAT_PROD" = "3" ]; then
    ok "SingleNatForDev confirmed from both sides: $NAT_DEV NAT in dev, $NAT_PROD in prod"
    note "Evaluated through CREATE ChangeSets on cfn/taxcalc-network-dev.yaml -"
    note "nothing created, nothing executed. Template evaluation is precisely"
    note "what an emulator CAN settle; this is a real PASS, not a shim."
  else
    bad "expected 1 NAT in dev and 3 in prod; got ${NAT_DEV:-?} and ${NAT_PROD:-?}"
  fi

  # (c) the projected drill-down, clearly labelled as the weakest of the three.
  if [ -n "$SHIM_PID" ]; then
    NAT_USD=$(awss_ ce get-cost-and-usage --time-period "Start=$(date -u +%Y-%m)-01,End=$(date -u -v+1m +%Y-%m-01 2>/dev/null || date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-01)" \
      --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=USAGE_TYPE \
      --filter '{"Tags":{"Key":"service","Values":["taxcalc"]}}' \
      --query "ResultsByTime[0].Groups[?contains(Keys[0],'NatGateway-Hours')].Metrics.UnblendedCost.Amount" \
      --output text 2>/dev/null)
    if [ -n "$NAT_USD" ]; then
      shim "NatGateway-Hours line item visible at \$$NAT_USD/mo, grouped by the service tag"
      note "Provenance: PROJECTED at list price from live deployed resources, NOT"
      note "read cost. The TAGS are real; the DOLLARS have never been invoiced."
      note "Render the full view: ./scripts/cost-explorer-report.sh"
    else
      gap "the projection produced no NatGateway line item"
    fi
  fi

  # (d) the saved report - a REAL resource, not a stand-in.
  #
  # "Saved reports have no public API" is true of a Cost Explorer SAVED VIEW
  # and was being treated as if it were true of saved cost reports generally.
  # AWS::CUR::ReportDefinition is declarable, creatable and readable back.
  CUR_NAME=$(aws_ cur describe-report-definitions \
    --query "ReportDefinitions[?ReportName=='taxcalc-cost-${COST_STACK##*-}'].ReportName" \
    --output text 2>/dev/null)
  if [ -n "$CUR_NAME" ]; then
    ok "saved cost report '$CUR_NAME' exists and is readable back"
    note "AWS::CUR::ReportDefinition, declared in cfn/taxcalc-cost-dev.yaml and"
    note "applied by 'cfn-guardrails.sh reconcile-cur' because this endpoint's"
    note "execute-change-set will not (guard-update plans it, then refuses)."
    note "AdditionalSchemaElements: [RESOURCES] puts the resource id AND its"
    note "cost-allocation tags on every line - more than a group-by shows."
  else
    gap "no saved cost report; run 'cfn-guardrails.sh reconcile-cur $COST_STACK EnvName=dev'"
  fi
  note "Still out of reach: an INTERACTIVE Cost Explorer view saved in the"
  note "console. That specific object has no public API. It is a much narrower"
  note "gap than 'no saved report is possible', which is what this said before."
else
  if [ "${CE_TAGS:-0}" = "0" ]; then
    bad "real account, but ce get-tags returns no cost-allocation keys - activate them in Billing"
  else
    ok "ce reports $CE_TAGS activated tag key(s); open Cost Explorer and group by 'service'"
  fi
fi

# ---------------------------------------------------------------------------
head_ 'Result'
printf '%d passed, %d satisfied via a local shim, %d gap(s), %d failed\n' "$PASS" "$SHIM" "$GAP" "$FAIL"
if [ "$SHIM" -gt 0 ] || [ "$GAP" -gt 0 ]; then
  cat <<'EOF_CAVEAT'

SHIM and GAP are not passes and must not be reported as any.

Fully established on this engine, and only these: the alarm's namespace and
metric name, and the 1-NAT-dev vs 3-NAT-prod decision. Both are questions
about what a template evaluates to, which is the class of question an
emulator answers honestly.

Needing a real account, and no local workaround supplies them: that the
Budget exists at all, that a notification would be DELIVERED (the topic ARN
is live and cross-checked, but delivery never happens here), that spend was
attributed to the tags, and that a Cost Explorer view can be saved as a
report - saved reports are a console object with no public API, so that last
one is unscriptable even on real AWS.

See taxcalc-api/COST.md.
EOF_CAVEAT
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
