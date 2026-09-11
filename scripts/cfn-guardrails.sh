#!/usr/bin/env bash
#
# cfn-guardrails.sh - backfill the three CloudFormation guarantees the local
# emulator does not provide, and prove which of them the current endpoint
# actually enforces.
#
# W6 D3 deployed all four stacks against floci because this machine has no AWS
# account. floci turned out to be a good CFN *engine* and a poor CFN *service*:
# it models resources well and the control-plane guarantees around them barely
# at all. Three gaps, in descending order of how much damage they do:
#
#   1. NO EXPORT-IN-USE PROTECTION. Real CloudFormation refuses to delete a
#      stack whose exports another stack imports ("Export ... is in use by").
#      floci performs the delete. That is worse than an unimplemented feature:
#      an engineer who tests here and believes the result concludes that
#      !ImportValue protects nothing, which is the opposite of the truth.
#      MEASURED: taxcalc-network-dev was deleted while taxcalc-app-dev held
#      three of its exports, and list-exports then returned 0.
#
#   2. validate-template IS A STUB. It returns empty Parameters for templates
#      declaring five of them, and passes a template whose resource type does
#      not exist. A green validate-template here carries no information.
#
#   3. NO DRIFT API AT ALL. detect-stack-drift,
#      describe-stack-drift-detection-status and describe-stack-resource-drifts
#      all return UnknownAction, so "does the live world still match the
#      template" has no local answer.
#
# This script supplies a local answer to all three, and - the part that matters
# - it does not assume which endpoint it is talking to. It MEASURES whether the
# endpoint enforces export protection using two disposable probe stacks, so the
# same script reports honestly against floci and against real AWS.
#
# Six checks:
#
#   1  import graph      derived from cfn/*.yaml, not from an API - ListImports
#                        is itself unsupported on floci. Engine-independent.
#   2  guard-delete      refuses to delete a stack whose exports are imported
#   3  positive control  guard-delete ALLOWS deleting a stack nobody imports
#                        (without this, check 2 passes by refusing everything)
#   4  engine probe      does THIS endpoint enforce export-in-use natively?
#                        Two disposable stacks, then cleaned up.
#   5  validate-template canary: is this endpoint's validator authoritative?
#   6  property parity   declared-in-template vs live-in-API, for the
#                        security-critical properties (stands in for drift)
#
# Usage:
#   ./scripts/cfn-guardrails.sh                    # run all six checks
#   ./scripts/cfn-guardrails.sh guard-delete NAME  # the safe delete wrapper
#
# Against floci:     export AWS_ENDPOINT_URL=http://localhost:4566
# Against real AWS:  leave AWS_ENDPOINT_URL unset.
#
# Property-parity mismatches are reported as FAILURES against real AWS (where
# they would be genuine drift) and as PARITY GAPS against an emulator (where
# they are the emulator dropping a property it accepted). The distinction is
# made from AWS_ENDPOINT_URL rather than assumed either way.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFN_DIR="${CFN_DIR:-cfn}"
REGION="${AWS_REGION:-us-east-1}"
PASS=0; FAIL=0; GAP=0

is_emulator() { [ -n "${AWS_ENDPOINT_URL:-}" ]; }
aws_() { aws --region "$REGION" "$@"; }

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
gap()  { printf '  \033[33mGAP \033[0m  %s\n' "$1"; GAP=$((GAP+1)); }
note() { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Import graph, derived from the templates rather than from the API.
#
# ListImports is unsupported on floci, and on real AWS it only knows about
# stacks that already exist - so a template that WILL import an export is
# invisible to it until it is deployed. Reading the templates catches the
# dependency at review time, which is when it is cheap.
#
# Emits one "CONSUMER<TAB>PRODUCER<TAB>EXPORT" line per import.
# ---------------------------------------------------------------------------
import_graph() {
  local tpl base param suffix producer tok
  for tpl in "$CFN_DIR"/*.yaml; do
    [ -e "$tpl" ] || continue
    base=$(basename "$tpl" .yaml)
    # Import targets are written "${SomeStackNameParam}-ExportSuffix".
    for tok in $(grep -oE '\$\{[A-Za-z0-9]+\}-[A-Za-z0-9]+' "$tpl" | sort -u); do
      param=$(printf '%s' "$tok" | sed -E 's/^\$\{([A-Za-z0-9]+)\}-.*/\1/')
      suffix=$(printf '%s' "$tok" | sed -E 's/^\$\{[A-Za-z0-9]+\}-//')
      # AWS::StackName is the stack exporting, not importing - skip it.
      [ "$param" = "AWS" ] && continue
      case "$param" in *StackName*) : ;; *) continue ;; esac
      # Resolve the parameter's Default from the Parameters block.
      producer=$(awk -v p="$param" '
        $0 ~ "^  " p ":" {inp=1; next}
        inp && /^  [A-Za-z]/ {inp=0}
        inp && /Default:/ {gsub(/^ *Default: */,""); gsub(/[" ]/,""); print; exit}
      ' "$tpl")
      [ -n "$producer" ] && printf '%s\t%s\t%s-%s\n' "$base" "$producer" "$producer" "$suffix"
    done
  done | sort -u
}

# Who imports from STACK? (consumers, one per line)
importers_of() {
  import_graph | awk -F'\t' -v s="$1" '$2==s {print $1}' | sort -u
}

# ---------------------------------------------------------------------------
# guard-delete - the safe wrapper. Use this instead of `aws cloudformation
# delete-stack` on any endpoint that does not enforce export protection
# natively (check 4 tells you whether yours does).
# ---------------------------------------------------------------------------
guard_delete() {
  local stack="$1" consumers
  consumers=$(importers_of "$stack")
  if [ -n "$consumers" ]; then
    printf 'REFUSED: %s exports values imported by:\n' "$stack" >&2
    printf '  %s\n' $consumers >&2
    printf 'Real CloudFormation refuses this too ("Export ... is in use by").\n' >&2
    printf 'Delete the consumer(s) first, or remove the !ImportValue.\n' >&2
    return 1
  fi
  printf 'No stack imports from %s. Safe to delete.\n' "$stack"
  if [ "${GUARD_DELETE_APPLY:-false}" = "true" ]; then
    aws_ cloudformation delete-stack --stack-name "$stack"
    printf 'delete-stack submitted.\n'
  else
    printf '(dry run - set GUARD_DELETE_APPLY=true to actually delete)\n'
  fi
  return 0
}

if [ "${1:-}" = "guard-delete" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 guard-delete <stack-name>" >&2; exit 2; }
  guard_delete "$2"; exit $?
fi

# ---------------------------------------------------------------------------
# reap-orphans - clean up resources floci's delete-stack leaks.
#
# MEASURED this session, twice: deleting a taxcalc-network-dev stack on floci
# removes the CloudFormation stack record but leaves the underlying VPC and
# its NAT Gateways running. Every rebuild during iteration therefore adds one
# more orphaned VPC (with its own subnets, IGW, route tables, SGs) and one
# more orphaned NAT Gateway to the account - nothing this repo's templates
# create, so `aws ec2 describe-vpcs` for this CIDR silently accumulates
# false positives across a session. Nine orphaned VPCs and four orphaned NAT
# Gateways were found and removed by hand before this existed.
#
# "Live" is defined as "owned by a CloudFormation stack that is not
# DELETE_COMPLETE" - read from describe-stack-resources across every stack,
# never assumed from a naming convention. Anything matching this repo's VPC
# CIDR or carrying Tags Project=taxcalc that is NOT in that live set is an
# orphan. Dependents (IGW, subnets, non-main route tables, non-default SGs)
# are torn down before the VPC itself, in the order EC2 requires.
reap_orphans() {
  local vpc_cidr="${1:-10.41.0.0/16}"
  echo "Live VPCs and NAT Gateways (owned by a non-deleted stack):"
  local live_vpcs="" live_nats=""
  for stk in $(aws_ cloudformation list-stacks \
      --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
      --query 'StackSummaries[].StackName' --output text 2>/dev/null); do
    for v in $(aws_ cloudformation describe-stack-resources --stack-name "$stk" \
        --query "StackResources[?ResourceType=='AWS::EC2::VPC'].PhysicalResourceId" --output text 2>/dev/null); do
      live_vpcs="$live_vpcs $v"; note "$stk owns VPC $v"
    done
    for n in $(aws_ cloudformation describe-stack-resources --stack-name "$stk" \
        --query "StackResources[?ResourceType=='AWS::EC2::NatGateway'].PhysicalResourceId" --output text 2>/dev/null); do
      live_nats="$live_nats $n"; note "$stk owns NAT Gateway $n"
    done
  done

  echo
  echo "Orphaned VPCs (CIDR $vpc_cidr, not owned by any live stack):"
  local orphan_vpcs
  orphan_vpcs=$(aws_ ec2 describe-vpcs --filters "Name=cidr,Values=$vpc_cidr" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null)
  local removed_vpcs=0
  for v in $orphan_vpcs; do
    case " $live_vpcs " in *" $v "*) continue ;; esac
    removed_vpcs=$((removed_vpcs+1))
    if [ "${GUARD_DELETE_APPLY:-false}" != "true" ]; then
      note "would delete $v and its dependents (dry run)"
      continue
    fi
    for igw in $(aws_ ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$v" \
        --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null); do
      aws_ ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$v" >/dev/null 2>&1
      aws_ ec2 delete-internet-gateway --internet-gateway-id "$igw" >/dev/null 2>&1
    done
    for sn in $(aws_ ec2 describe-subnets --filters "Name=vpc-id,Values=$v" \
        --query 'Subnets[].SubnetId' --output text 2>/dev/null); do
      aws_ ec2 delete-subnet --subnet-id "$sn" >/dev/null 2>&1
    done
    for rt in $(aws_ ec2 describe-route-tables --filters "Name=vpc-id,Values=$v" \
        --query 'RouteTables[?Associations[0].Main!=`true`].RouteTableId' --output text 2>/dev/null); do
      aws_ ec2 delete-route-table --route-table-id "$rt" >/dev/null 2>&1
    done
    for sg in $(aws_ ec2 describe-security-groups --filters "Name=vpc-id,Values=$v" \
        --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); do
      aws_ ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1
    done
    aws_ ec2 delete-vpc --vpc-id "$v" >/dev/null 2>&1
    note "deleted $v"
  done
  [ "$removed_vpcs" -eq 0 ] && note "none"

  echo
  echo "Orphaned NAT Gateways (available, not owned by any live stack):"
  local removed_nats=0
  for n in $(aws_ ec2 describe-nat-gateways --filter Name=state,Values=available \
      --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null); do
    case " $live_nats " in *" $n "*) continue ;; esac
    removed_nats=$((removed_nats+1))
    if [ "${GUARD_DELETE_APPLY:-false}" != "true" ]; then
      note "would delete $n (dry run)"
      continue
    fi
    aws_ ec2 delete-nat-gateway --nat-gateway-id "$n" >/dev/null 2>&1
    note "deleted $n"
  done
  [ "$removed_nats" -eq 0 ] && note "none"

  echo
  if [ "${GUARD_DELETE_APPLY:-false}" = "true" ]; then
    printf 'Removed %d orphaned VPC(s), %d orphaned NAT Gateway(s).\n' "$removed_vpcs" "$removed_nats"
  else
    printf '%d orphaned VPC(s), %d orphaned NAT Gateway(s) found.\n' "$removed_vpcs" "$removed_nats"
    printf '(dry run - set GUARD_DELETE_APPLY=true to actually delete)\n'
  fi
}

if [ "${1:-}" = "reap-orphans" ]; then
  reap_orphans "${2:-}"; exit 0
fi

# ---------------------------------------------------------------------------
# reconcile-s3 - apply the S3 hardening that this endpoint's CloudFormation
# accepted and then dropped.
#
# floci's CFN provider for AWS::S3::Bucket and AWS::S3::BucketPolicy is a
# no-op for four properties: PublicAccessBlockConfiguration, BucketEncryption,
# LifecycleConfiguration and the bucket policy. All four report CREATE_COMPLETE
# - the policy even gets a fabricated physical id like bucket-policy-80a48155 -
# and none of them reaches S3. That is the worst failure mode in this whole
# exercise: the stack is green, describe-stacks agrees, and the deny-non-TLS
# rule S3 is supposed to be enforcing does not exist.
#
# floci's S3 accepts all four over the S3 API (measured), so this reads them
# out of the template and PUTs them, then reads them back to prove it.
#
# It REFUSES to run against real AWS. There, CloudFormation applies these
# itself, and reaching around it with put-bucket-policy would create exactly
# the drift that Task 4's detect-stack-drift is meant to catch. This is an
# emulator-parity shim, and it is scoped to emulators on purpose.
reconcile_s3() {
  if ! is_emulator; then
    printf 'refusing: reconcile-s3 is an emulator-parity shim.\n' >&2
    printf 'Against real AWS, CloudFormation applies these properties itself;\n' >&2
    printf 'applying them out of band here would register as stack drift.\n' >&2
    return 2
  fi
  command -v ruby >/dev/null 2>&1 || { printf 'refusing: ruby not found.\n' >&2; return 2; }

  local here stacks stack tpl bucket extracted rc=0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  stacks="${1:-taxcalc-artifacts-dev taxcalc-bootstrap-dev}"

  for stack in $stacks; do
    head_ "reconcile-s3: $stack"
    tpl="$here/../cfn/$stack.yaml"
    if [ ! -f "$tpl" ]; then note "no template at cfn/$stack.yaml; skipped"; continue; fi

    bucket=$(aws_ cloudformation describe-stack-resources --stack-name "$stack" \
      --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" \
      --output text 2>/dev/null)
    if [ -z "$bucket" ] || [ "$bucket" = "None" ]; then
      note "$stack is not deployed, or declares no bucket; skipped"; continue
    fi
    note "bucket: $bucket"

    extracted=$(ruby "$here/cfn-extract-s3.rb" "$tpl" "$bucket" 2>/dev/null) || {
      bad "could not read S3 settings out of $(basename "$tpl")"; rc=1; continue; }

    # --- public access block
    if echo "$extracted" | jq -e '.pab != null' >/dev/null; then
      aws_ s3api put-public-access-block --bucket "$bucket" \
        --public-access-block-configuration "$(echo "$extracted" | jq -c .pab)" >/dev/null 2>&1
      if [ "$(aws_ s3api get-public-access-block --bucket "$bucket" \
              --query "PublicAccessBlockConfiguration.[BlockPublicAcls,BlockPublicPolicy,IgnorePublicAcls,RestrictPublicBuckets]" \
              --output text 2>/dev/null)" = "True	True	True	True" ]; then
        ok "public access block - all four toggles true"
      else
        bad "public access block did not stick"; rc=1
      fi
    fi

    # --- default encryption
    if echo "$extracted" | jq -e '.sse != null' >/dev/null; then
      aws_ s3api put-bucket-encryption --bucket "$bucket" \
        --server-side-encryption-configuration "$(echo "$extracted" | jq -c .sse)" >/dev/null 2>&1
      local alg
      alg=$(aws_ s3api get-bucket-encryption --bucket "$bucket" \
        --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" \
        --output text 2>/dev/null)
      if [ "$alg" = "aws:kms" ]; then ok "default encryption - aws:kms"
      else bad "default encryption is ${alg:-unset}, expected aws:kms"; rc=1; fi
    fi

    # --- bucket policy
    if echo "$extracted" | jq -e '.policy != null' >/dev/null; then
      aws_ s3api put-bucket-policy --bucket "$bucket" \
        --policy "$(echo "$extracted" | jq -c .policy)" >/dev/null 2>&1
      if aws_ s3api get-bucket-policy --bucket "$bucket" --query Policy --output text 2>/dev/null |
           jq -e '[.Statement[] | select(.Effect=="Deny" and .Condition.Bool."aws:SecureTransport"=="false")] | length > 0' >/dev/null 2>&1; then
        ok "bucket policy - aws:SecureTransport false => Deny"
      else
        bad "deny-non-TLS statement is not present after put"; rc=1
      fi
    fi

    # --- lifecycle configuration
    if echo "$extracted" | jq -e '.lifecycle != null' >/dev/null; then
      aws_ s3api put-bucket-lifecycle-configuration --bucket "$bucket" \
        --lifecycle-configuration "$(echo "$extracted" | jq -c .lifecycle)" >/dev/null 2>&1
      local live_ia
      live_ia=$(aws_ s3api get-bucket-lifecycle-configuration --bucket "$bucket" \
        --query "Rules[].Transitions[?StorageClass=='STANDARD_IA'].Days" --output text 2>/dev/null)
      declared_ia=$(echo "$extracted" | jq -r '.lifecycle.Rules[].Transitions[]? | select(.StorageClass=="STANDARD_IA") | .Days' 2>/dev/null)
      if [ -n "$declared_ia" ]; then
        if [ "$live_ia" = "$declared_ia" ]; then
          ok "lifecycle - STANDARD_IA transition at ${live_ia}d, matches template"
        else
          bad "lifecycle STANDARD_IA transition: template says ${declared_ia}d, live is ${live_ia:-unset}"; rc=1
        fi
      else
        # e.g. taxcalc-bootstrap-dev, which has only NoncurrentVersionExpiration
        if aws_ s3api get-bucket-lifecycle-configuration --bucket "$bucket" \
             --query 'Rules[0].ID' --output text >/dev/null 2>&1; then
          ok "lifecycle - rule present"
        else
          bad "lifecycle configuration did not stick"; rc=1
        fi
      fi
    fi
  done

  echo
  if [ "$rc" -eq 0 ]; then
    printf 'Reconciled. These settings now live in S3, applied from the template\n'
    printf 'by this script - NOT by CloudFormation, which dropped them. Any\n'
    printf 'evidence taken from them must say so.\n'
  fi
  return $rc
}

if [ "${1:-}" = "reconcile-s3" ]; then
  reconcile_s3 "${2:-}"; exit $?
fi

# ---------------------------------------------------------------------------
# Shared helper for the W6 D4 cost reconciles: the logical->physical id map a
# deployed stack exposes, as the JSON object cfn-extract-cost.rb expects.
_physical_map() {
  aws_ cloudformation describe-stack-resources --stack-name "$1" \
    --query 'StackResources[].[LogicalResourceId,PhysicalResourceId]' --output json 2>/dev/null |
    ruby -rjson -e 'begin; puts JSON.dump(JSON.parse(STDIN.read).to_h); rescue; puts "{}"; end'
}

_cost_extract() {  # stack, template, [Key=Value ...]
  local stack="$1" tpl="$2"; shift 2
  CFN_STACK_NAME="$stack" ruby "$HERE/cfn-extract-cost.rb" "$tpl" "$(_physical_map "$stack")" "$@"
}

# ---------------------------------------------------------------------------
# reconcile-cloudwatch - re-PUT the billing alarm so the properties this
# endpoint's CloudFormation dropped are actually live.
#
# floci accepts AWS::CloudWatch::Alarm and creates a real, readable alarm with
# the right namespace, metric, threshold and actions - and then reports
# `TreatMissingData: None`. That is the subtlest of the three cost-stack parity
# gaps, because the alarm looks correct in every field a reviewer skims, and
# the single property it loses is the one that decides whether the alarm fires
# correctly on a metric with routine gaps. AWS/Billing refreshes about every
# six hours, so gaps ARE the normal case here.
#
# UNLIKE reconcile-s3, THIS ONE CANNOT ALWAYS CLOSE THE GAP, and saying so is
# the point of the script. reconcile-s3 works because floci's S3 stores the
# properties correctly when they arrive over the S3 API, so only the
# CFN-to-S3 wiring is broken. TreatMissingData is dropped by floci's
# CloudWatch itself: a direct put-metric-alarm --treat-missing-data ignore on
# a throwaway alarm reads back `None` too. So the reconcile re-PUTs the
# template's properties and then MEASURES, with that same probe, whether the
# endpoint is capable of storing the value at all:
#
#   stored      -> PASS. The CFN wiring was the only problem, and it is fixed.
#   not stored  -> GAP, not FAIL. The template is correct and the endpoint
#                  cannot represent it. Reporting this as a template failure
#                  would be the inverse error of reporting it as a pass.
#
# Note what is NOT affected: the deliverable's own Done-When for this alarm is
# namespace + metric name, and those are live and correct without any of this.
# TreatMissingData is the property COST.md flags as lost, and it stays lost.
#
# Refuses against real AWS: there CloudFormation applies TreatMissingData
# itself, and a put-metric-alarm around it is exactly the out-of-band change
# detect-drift exists to catch.
reconcile_cloudwatch() {
  if ! is_emulator; then
    printf 'refusing: reconcile-cloudwatch is an emulator-parity shim.\n' >&2
    printf 'Against real AWS, CloudFormation applies TreatMissingData itself;\n' >&2
    printf 'a put-metric-alarm around it would register as stack drift.\n' >&2
    return 2
  fi
  command -v ruby >/dev/null 2>&1 || { printf 'refusing: ruby not found.\n' >&2; return 2; }

  local stack="${1:-taxcalc-cost-dev}" tpl extracted count rc=0
  tpl="$HERE/../$CFN_DIR/$stack.yaml"
  head_ "reconcile-cloudwatch: $stack"
  [ -f "$tpl" ] || { note "no template at $CFN_DIR/$stack.yaml; skipped"; return 0; }

  extracted=$(_cost_extract "$stack" "$tpl" "${@:2}") || {
    bad "could not read alarm settings out of $(basename "$tpl")"; return 1; }

  count=$(echo "$extracted" | jq '.alarms | length')
  if [ "$count" = "0" ]; then
    note "template declares no AWS::CloudWatch::Alarm; nothing to reconcile"
    return 0
  fi

  local lid name declared live
  for lid in $(echo "$extracted" | jq -r '.alarms | keys[]'); do
    name=$(echo "$extracted" | jq -r ".alarms[\"$lid\"].AlarmName")

    # Only reconcile an alarm the stack actually created. An alarm gated off by
    # a Condition (EstimatedChargesAlarm outside us-east-1) must stay absent -
    # creating it here would manufacture exactly the alarm-that-cannot-fire the
    # Condition exists to prevent.
    if ! aws_ cloudwatch describe-alarms --alarm-names "$name" \
         --query 'MetricAlarms[0].AlarmName' --output text 2>/dev/null | grep -q .; then
      note "$lid ($name) is not deployed in $REGION; skipped"
      continue
    fi

    aws_ cloudwatch put-metric-alarm --cli-input-json "$(echo "$extracted" | jq -c ".alarms[\"$lid\"]")" \
      >/dev/null 2>&1 || { bad "$lid: put-metric-alarm was rejected"; rc=1; continue; }

    declared=$(echo "$extracted" | jq -r ".alarms[\"$lid\"].TreatMissingData // \"unset\"")
    live=$(aws_ cloudwatch describe-alarms --alarm-names "$name" \
      --query 'MetricAlarms[0].TreatMissingData' --output text 2>/dev/null)
    if [ "$live" = "$declared" ]; then
      ok "$lid - TreatMissingData is live as '$live'"
    elif _cw_stores_treat_missing_data; then
      # The endpoint CAN store it and this alarm still does not have it: that
      # is a genuine failure of the reconcile, not an emulator limitation.
      bad "$lid - TreatMissingData is '${live:-unset}' after a successful PUT, template declares '$declared'"
      rc=1
    else
      gap "$lid - TreatMissingData stays '${live:-None}'; this endpoint drops it"
      note "Measured, not assumed: a direct put-metric-alarm --treat-missing-data"
      note "ignore on a throwaway alarm also reads back None, and the property is"
      note "absent from the stored record entirely rather than set to a default."
      note "The loss is in this CloudWatch, not in the CFN wiring and not in the"
      note "template, so NO API CALL CLOSES IT. The template declares 'ignore'"
      note "and real CloudWatch would apply it."
      note ""
      note "To READ the declared value through the normal API, run"
      note "floci-cost-apis-shim.py and point describe-alarms at it: the alarm is"
      note "forwarded from floci unchanged and this one property is overlaid from"
      note "the template, named in the response's OverlaidFromTemplate."
      note "That changes what you can READ, not how the alarm BEHAVES. floci's"
      note "alarm still evaluates a gappy metric as 'missing', so this alarm's"
      note "firing behaviour cannot be tested on this engine by any means."
    fi

    # notBreaching on a metric with routine gaps erases a real breach; assert
    # the reconcile did not introduce it, whatever the template says.
    if [ "$live" = "notBreaching" ]; then
      bad "$lid - notBreaching on a gappy metric silently resets a real ALARM to OK"; rc=1
    fi
  done

  echo
  [ "$rc" -eq 0 ] && {
    printf 'Reconciled as far as this endpoint allows. Whatever is live is live\n'
    printf 'because THIS SCRIPT PUT it, not because CloudFormation applied it,\n'
    printf 'and evidence taken from describe-alarms must say so.\n'
  }
  return $rc
}

# Does this endpoint's CloudWatch persist TreatMissingData through its own
# native API? Answered with a disposable alarm rather than assumed, so the
# same script reports honestly against floci and against real AWS.
_cw_stores_treat_missing_data() {
  local probe="cfn-guardrails-tmd-probe-$$" got
  aws_ cloudwatch put-metric-alarm --alarm-name "$probe" \
    --namespace CfnGuardrailsProbe --metric-name Probe --statistic Maximum \
    --period 300 --evaluation-periods 1 --threshold 1 \
    --comparison-operator GreaterThanThreshold --treat-missing-data ignore >/dev/null 2>&1 || return 1
  got=$(aws_ cloudwatch describe-alarms --alarm-names "$probe" \
    --query 'MetricAlarms[0].TreatMissingData' --output text 2>/dev/null)
  aws_ cloudwatch delete-alarms --alarm-names "$probe" >/dev/null 2>&1
  [ "$got" = "ignore" ]
}

if [ "${1:-}" = "reconcile-cloudwatch" ]; then
  shift; reconcile_cloudwatch "$@"; exit $?
fi

# ---------------------------------------------------------------------------
# reconcile-tags - apply the four cost-allocation keys this endpoint's
# CloudFormation accepted and dropped.
#
# floci's CFN provider applies NO declared tag to ANY resource type measured
# here - EC2, RDS, SNS, IAM all come back with an empty tag set - while
# reporting CREATE_COMPLETE. The per-service tagging APIs (ec2 create-tags,
# rds add-tags-to-resource, sns tag-resource) all work, so this reads each
# resource's declared Tags out of its template and applies them there.
#
# This matters more than the other reconciles rather than less: a resource
# missing `service` or `env` is INVISIBLE to the tag-scoped Budget. Untagged,
# the Budget still reports healthy while guarding nothing - and the NAT Gateway
# is the single largest line item it is meant to be guarding.
#
# Refuses against real AWS for the usual reason: there CloudFormation owns
# these tags, and setting them out of band is drift.
reconcile_tags() {
  if ! is_emulator; then
    printf 'refusing: reconcile-tags is an emulator-parity shim.\n' >&2
    printf 'Against real AWS, CloudFormation applies resource tags itself;\n' >&2
    printf 'setting them out of band would register as stack drift.\n' >&2
    return 2
  fi
  command -v ruby >/dev/null 2>&1 || { printf 'refusing: ruby not found.\n' >&2; return 2; }

  local stacks stack tpl extracted rc=0
  stacks="${1:-taxcalc-network-dev taxcalc-app-dev taxcalc-cost-dev}"

  for stack in $stacks; do
    head_ "reconcile-tags: $stack"
    tpl="$HERE/../$CFN_DIR/$stack.yaml"
    if [ ! -f "$tpl" ]; then note "no template at $CFN_DIR/$stack.yaml; skipped"; continue; fi
    if ! aws_ cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
      note "$stack is not deployed; skipped"; continue
    fi

    extracted=$(_cost_extract "$stack" "$tpl") || {
      bad "could not read tags out of $(basename "$tpl")"; rc=1; continue; }

    # --- Pass 1: apply every tag set the template declares.
    local lid type phys tagjson
    for lid in $(echo "$extracted" | jq -r '.tags | keys[]'); do
      type=$(echo "$extracted" | jq -r ".tags[\"$lid\"].type")
      phys=$(_physical_id "$stack" "$lid")
      # A Condition-gated resource (the per-AZ NAT gateways outside prod) is
      # absent by design, not missing.
      [ -n "$phys" ] && [ "$phys" != "None" ] || continue
      tagjson=$(echo "$extracted" | jq -c ".tags[\"$lid\"].tags | map({Key,Value})")
      _apply_tags "$type" "$phys" "$tagjson"
    done

    # --- Pass 2: verify the four cost-allocation keys are LIVE, and do it by
    # reading them back rather than by trusting the write.
    #
    # Reading back is not belt-and-braces here, it is the only reliable
    # signal: floci's `sns tag-resource` stores the tags correctly and then
    # returns a response botocore cannot parse ("'TagResourceResult'"), so the
    # CLI exits non-zero on a write that succeeded. Trusting exit status
    # reports a false failure; trusting neither and re-reading reports what is
    # actually there.
    #
    # The four-key requirement is scoped to BILLABLE types. A VPC, subnet,
    # route table or security group is free, carries no line item, and can
    # never appear in a cost report - demanding the taxonomy there would
    # produce a wall of findings that are not cost-governance problems and
    # would bury the one case that is. The billable set is what the Budget's
    # CostFilters can actually match.
    local billable
    billable=$(aws_ cloudformation describe-stack-resources --stack-name "$stack" \
      --query "StackResources[?contains(['AWS::EC2::NatGateway','AWS::EC2::EIP','AWS::RDS::DBInstance','AWS::RDS::DBCluster','AWS::S3::Bucket','AWS::EC2::Instance','AWS::EC2::Volume','AWS::ElasticLoadBalancingV2::LoadBalancer'], ResourceType)].[LogicalResourceId,ResourceType,PhysicalResourceId]" \
      --output text 2>/dev/null)

    if [ -z "$billable" ]; then
      note "no billable resource types in this stack; nothing the Budget can see"
    fi

    while IFS=$'\t' read -r lid type phys; do
      [ -n "$lid" ] || continue
      local live missing=""
      live=$(_live_tag_keys "$type" "$phys")
      for k in service env tenant feature; do
        echo "$live" | grep -qx "$k" || missing="$missing $k"
      done
      if [ -z "$missing" ]; then
        ok "$lid ($type) - service/env/tenant/feature live on $phys"
      else
        # This is the finding that matters. A billable resource missing
        # `service` or `env` is invisible to the tag-scoped Budget, which then
        # keeps reporting healthy while guarding less than it claims to.
        bad "$lid ($type) - not live:$missing - invisible to the tag-scoped Budget"
        rc=1
      fi
    done <<EOF_BILLABLE
$billable
EOF_BILLABLE
  done

  echo
  if [ "$rc" -eq 0 ]; then
    printf 'Reconciled. These tags are live because THIS SCRIPT applied them over\n'
    printf 'the per-service APIs, not because CloudFormation did - floci applies\n'
    printf 'no declared tag to any resource type measured here.\n\n'
    printf 'And note what it still does NOT buy: floci bills nobody, so no\n'
    printf 'cost-allocation tag key is activated and no Cost Explorer report can\n'
    printf 'group by one. The tags are real; the attribution they exist for\n'
    printf 'remains unverifiable on this engine.\n'
  fi
  return $rc
}

_physical_id() {  # stack, logical id
  aws_ cloudformation describe-stack-resources --stack-name "$1" \
    --query "StackResources[?LogicalResourceId=='$2'].PhysicalResourceId" --output text 2>/dev/null
}

# RDS tagging is ARN-addressed. A DBInstance's physical id is its identifier
# and floci happens to accept that, but a DBSubnetGroup's is rejected
# (DBSubnetGroupNotFoundFault), so build the ARN rather than relying on which
# of the two a given endpoint tolerates.
_rds_arn() {  # type, physical id
  case "$1" in
    *DBInstance)    printf 'arn:aws:rds:%s:%s:db:%s' "$REGION" "$(_account_id)" "$2" ;;
    *DBCluster)     printf 'arn:aws:rds:%s:%s:cluster:%s' "$REGION" "$(_account_id)" "$2" ;;
    *DBSubnetGroup) printf 'arn:aws:rds:%s:%s:subgrp:%s' "$REGION" "$(_account_id)" "$2" ;;
    *)              printf '%s' "$2" ;;
  esac
}

_account_id() {
  [ -n "${_ACCT_CACHE:-}" ] || _ACCT_CACHE=$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null)
  printf '%s' "${_ACCT_CACHE:-000000000000}"
}

_apply_tags() {  # type, physical id, tags JSON array
  local type="$1" phys="$2" tags="$3"
  case "$type" in
    AWS::EC2::*)
      aws_ ec2 create-tags --resources "$phys" --tags "$tags" >/dev/null 2>&1 ;;
    AWS::RDS::*)
      aws_ rds add-tags-to-resource --resource-name "$(_rds_arn "$type" "$phys")" \
        --tags "$tags" >/dev/null 2>&1 ;;
    AWS::SNS::Topic)
      aws_ sns tag-resource --resource-arn "$phys" --tags "$tags" >/dev/null 2>&1 ;;
    AWS::S3::Bucket)
      aws_ s3api put-bucket-tagging --bucket "$phys" \
        --tagging "$(echo "$tags" | jq -c '{TagSet: .}')" >/dev/null 2>&1 ;;
    *)
      note "$phys ($type) - no tagging API wired for this type; skipped"; return 0 ;;
  esac
  # Deliberately no error branch: the write's exit status is not trustworthy
  # on this endpoint (see pass 2), so the read-back is the verdict.
  return 0
}

_live_tag_keys() {  # type, physical id -> one tag key per line
  case "$1" in
    AWS::EC2::EIP)
      aws_ ec2 describe-tags --filters "Name=resource-id,Values=$2" \
        --query 'Tags[].Key' --output text 2>/dev/null | tr '\t' '\n' ;;
    AWS::EC2::*)
      aws_ ec2 describe-tags --filters "Name=resource-id,Values=$2" \
        --query 'Tags[].Key' --output text 2>/dev/null | tr '\t' '\n' ;;
    AWS::RDS::*)
      aws_ rds list-tags-for-resource --resource-name "$(_rds_arn "$1" "$2")" \
        --query 'TagList[].Key' --output text 2>/dev/null | tr '\t' '\n' ;;
    AWS::SNS::Topic)
      aws_ sns list-tags-for-resource --resource-arn "$2" \
        --query 'Tags[].Key' --output text 2>/dev/null | tr '\t' '\n' ;;
    AWS::S3::Bucket)
      aws_ s3api get-bucket-tagging --bucket "$2" \
        --query 'TagSet[].Key' --output text 2>/dev/null | tr '\t' '\n' ;;
    *) : ;;
  esac
}

# ---------------------------------------------------------------------------
# guard-update - run an UPDATE ChangeSet, and refuse to execute it on an
# endpoint whose execution does not honour the plan.
#
# THE PLAN AND THE EXECUTION DISAGREE ON floci, AND THE PLAN IS THE CORRECT
# ONE. Measured with a four-resource probe stack whose update changes exactly
# one resource's tags:
#
#   describe-change-set   Modify  Vpc  Replacement: False        <- correct
#   execute-change-set    Sec UPDATE_IN_PROGRESS -> UPDATE_FAILED
#                         "A secret with the name ... already exists."
#
# `Sec` is not in the change set. floci's update path iterates EVERY resource
# in the template instead of the plan's change list, and its update handler
# for several types is implemented as create. It aborts on the first one, so
# `Vpc` - the only planned change - is never reached and the stack lands in
# UPDATE_ROLLBACK_COMPLETE.
#
# Why it usually looks like it works: most create APIs are idempotent.
# CreateTopic and CreateBucket on an existing name return the existing
# resource, so re-creating them is invisible. CreateSecret is NOT idempotent
# and throws. So the blast radius is not "Secrets Manager is special" - it is
# "every resource is re-created on every update, and you only find out where
# the create API happens to object". A template of purely idempotent types
# would update green while silently re-creating everything in it.
#
# What this does about it:
#   1. create-change-set + describe-change-set ALWAYS. The plan is the
#      artefact the review is actually about - "tags changed, Replacement:
#      False" - and it is correct on this endpoint.
#   2. Probes THIS endpoint with a disposable stack to find out whether
#      execution honours the plan. Measured, not assumed, so the same command
#      is correct against real AWS.
#   3. Honoured    -> execute-change-set, normally.
#      Not honoured -> REFUSES to execute, because executing would roll the
#      stack back and leave it in UPDATE_ROLLBACK_COMPLETE - strictly worse
#      than not trying. It then names the planned changes so they can be
#      applied deliberately (for a tag-only change: reconcile-tags).
#
# Usage:
#   ./scripts/cfn-guardrails.sh guard-update taxcalc-app-dev EnvName=dev
guard_update() {
  local stack="${1:-}"; shift || true
  [ -n "$stack" ] || { printf 'usage: cfn-guardrails.sh guard-update STACK [Key=Value ...]\n' >&2; return 2; }

  local tpl="$HERE/../$CFN_DIR/$stack.yaml"
  [ -f "$tpl" ] || { printf 'refusing: no template at %s/%s.yaml\n' "$CFN_DIR" "$stack" >&2; return 2; }

  local csname="guard-update-$$" params=()
  local p
  for p in "$@"; do
    params+=("ParameterKey=${p%%=*},ParameterValue=${p#*=}")
  done

  head_ "guard-update: $stack"

  if ! aws_ cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
    bad "$stack is not deployed; an UPDATE ChangeSet needs an existing stack"
    return 1
  fi

  # --- 1. the plan
  if ! aws_ cloudformation create-change-set --stack-name "$stack" --change-set-name "$csname" \
        --change-set-type UPDATE --template-body "file://$tpl" \
        ${params[@]+"${params[@]/#/--parameters=}"} \
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM >/dev/null 2>&1; then
    bad "create-change-set was rejected"
    return 1
  fi
  # No wait API worth trusting here; poll for a terminal ChangeSet status.
  local cstatus=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    cstatus=$(aws_ cloudformation describe-change-set --stack-name "$stack" \
      --change-set-name "$csname" --query Status --output text 2>/dev/null)
    case "$cstatus" in CREATE_COMPLETE|FAILED) break ;; esac
    sleep 1
  done

  if [ "$cstatus" = "FAILED" ]; then
    local reason
    reason=$(aws_ cloudformation describe-change-set --stack-name "$stack" \
      --change-set-name "$csname" --query StatusReason --output text 2>/dev/null)
    case "$reason" in
      *"didn't contain changes"*|*"No updates"*|*"no updates"*)
        ok "no changes - the deployed stack already matches the template"
        aws_ cloudformation delete-change-set --stack-name "$stack" --change-set-name "$csname" >/dev/null 2>&1
        return 0 ;;
      *) bad "change set failed: $reason"
         aws_ cloudformation delete-change-set --stack-name "$stack" --change-set-name "$csname" >/dev/null 2>&1
         return 1 ;;
    esac
  fi

  # Real CloudFormation FAILS a no-op change set ("didn't contain changes");
  # floci reports CREATE_COMPLETE with an empty Changes list instead. Handle
  # both, or an empty plan reads as "nothing is replaced" - which is true and
  # completely uninformative.
  local nchanges
  nchanges=$(aws_ cloudformation describe-change-set --stack-name "$stack" \
    --change-set-name "$csname" --query 'length(Changes)' --output text 2>/dev/null)
  if [ "${nchanges:-0}" = "0" ]; then
    ok "no changes - the deployed stack already matches the template"
    note "This endpoint returned an empty change set rather than failing it;"
    note "real CloudFormation fails a no-op change set outright."
    aws_ cloudformation delete-change-set --stack-name "$stack" --change-set-name "$csname" >/dev/null 2>&1
    return 0
  fi

  printf '\n  \033[1mPlan\033[0m (this is the artefact the review is about)\n'
  aws_ cloudformation describe-change-set --stack-name "$stack" --change-set-name "$csname" \
    --query 'Changes[].ResourceChange.[Action,LogicalResourceId,ResourceType,Replacement]' \
    --output text 2>/dev/null | sed 's/^/    /'

  # `Replacement: True` on a data resource is destroy-and-recreate. Flag it
  # here rather than leaving it to be noticed in the diff.
  local replacing
  replacing=$(aws_ cloudformation describe-change-set --stack-name "$stack" --change-set-name "$csname" \
    --query "Changes[?ResourceChange.Replacement=='True'].ResourceChange.LogicalResourceId" \
    --output text 2>/dev/null)
  if [ -n "$replacing" ] && [ "$replacing" != "None" ]; then
    printf '\n'
    bad "Replacement: True on:$(printf ' %s' $replacing)"
    note "Destroy-and-recreate. On a data resource that is data loss unless"
    note "UpdateReplacePolicy: Retain is set. Not executing."
    aws_ cloudformation delete-change-set --stack-name "$stack" --change-set-name "$csname" >/dev/null 2>&1
    return 1
  fi
  ok "no resource is replaced by this change set"

  # --- 2. does THIS endpoint's execution honour the plan?
  printf '\n'
  if _update_honours_plan; then
    ok "this endpoint's execute-change-set honours the change set"
    # --- 3a. execute
    aws_ cloudformation execute-change-set --stack-name "$stack" --change-set-name "$csname" >/dev/null 2>&1
    local s=""
    for _ in $(seq 1 60); do
      s=$(aws_ cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
      case "$s" in *COMPLETE|*FAILED) break ;; esac
      sleep 1
    done
    if [ "$s" = "UPDATE_COMPLETE" ]; then ok "$stack is $s"; return 0; fi
    bad "$stack is $s after execute"
    aws_ cloudformation describe-stack-events --stack-name "$stack" \
      --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
      --output text 2>/dev/null | head -3 | sed 's/^/        /'
    return 1
  fi

  # --- 3b. refuse
  gap "this endpoint's execute-change-set does NOT honour the change set"
  note "Probed with a disposable stack: the plan named one resource and the"
  note "execution touched a different one that the plan said was unchanged."
  note "floci iterates every resource in the template rather than the plan's"
  note "change list, and implements several update handlers as create."
  note ""
  note "NOT EXECUTING. Executing would fail on the first non-idempotent create"
  note "and leave $stack in UPDATE_ROLLBACK_COMPLETE - worse than not trying."
  note "The plan above is still valid evidence, and is the correct answer to"
  note "'does this change replace anything'."
  note ""
  note "To apply the planned change on this endpoint, do it deliberately over"
  note "the per-service APIs. For a tag-only change that is:"
  note "    ./scripts/cfn-guardrails.sh reconcile-tags $stack"
  aws_ cloudformation delete-change-set --stack-name "$stack" --change-set-name "$csname" >/dev/null 2>&1
  return 0
}

# Probe: does execute-change-set act on the plan, or on the whole template?
#
# A four-resource stack updated so that exactly ONE resource changes. If the
# endpoint honours the plan, the update completes. If it re-creates
# everything, it dies on the non-idempotent CreateSecret - which is the
# canary, not the bug.
_update_honours_plan() {
  local probe="cfn-guardrails-updateprobe-$$" secret="cfn-guardrails-probe-secret-$$" tmp verdict=1
  tmp=$(mktemp -t cfnguardrails)
  cat > "$tmp" <<EOF_PROBE
AWSTemplateFormatVersion: "2010-09-09"
Parameters:
  TagValue: {Type: String, Default: one}
Resources:
  Sec:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: $secret
      SecretString: '{"probe":"1"}'
  Topic:
    Type: AWS::SNS::Topic
    Properties: {TopicName: $probe-topic}
  Net:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.253.0.0/16
      Tags: [{Key: probe, Value: !Ref TagValue}]
EOF_PROBE

  _update_probe_cleanup() {
    aws_ cloudformation delete-stack --stack-name "$probe" >/dev/null 2>&1
    aws_ secretsmanager delete-secret --secret-id "$secret" --force-delete-without-recovery >/dev/null 2>&1
    rm -f "$tmp"
  }

  if aws_ cloudformation create-stack --stack-name "$probe" --template-body "file://$tmp" >/dev/null 2>&1; then
    local s=""
    for _ in $(seq 1 40); do
      s=$(aws_ cloudformation describe-stacks --stack-name "$probe" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
      case "$s" in *COMPLETE|*FAILED) break ;; esac
      sleep 1
    done
    if [ "$s" = "CREATE_COMPLETE" ]; then
      aws_ cloudformation update-stack --stack-name "$probe" --template-body "file://$tmp" \
        --parameters ParameterKey=TagValue,ParameterValue=two >/dev/null 2>&1
      for _ in $(seq 1 40); do
        s=$(aws_ cloudformation describe-stacks --stack-name "$probe" --query 'Stacks[0].StackStatus' --output text 2>/dev/null)
        case "$s" in UPDATE_COMPLETE|*ROLLBACK_COMPLETE|*FAILED) break ;; esac
        sleep 1
      done
      [ "$s" = "UPDATE_COMPLETE" ] && verdict=0
    fi
  fi
  _update_probe_cleanup
  return $verdict
}

if [ "${1:-}" = "guard-update" ]; then
  shift; guard_update "$@"; exit $?
fi

if [ "${1:-}" = "reconcile-tags" ]; then
  shift; reconcile_tags "$@"; exit $?
fi

# ---------------------------------------------------------------------------
# detect-drift - the console-edit / detect / revert exercise, worked around.
#
# detect-stack-drift is UnknownAction on floci (verified; see
# taxcalc-api/INFRA.md "Drift detection"). Tags are the obvious property to
# mutate for the exercise, but floci's CloudFormation provider does not apply
# ANY declared tag to ANY resource type measured in this repo - EC2 (VPC,
# subnet, SG), IAM (role) and RDS all come back with an empty tag set
# regardless of what the template declares. Comparing tags would report every
# resource "drifted" from the moment it is created, which is not the exercise
# and would prove nothing.
#
# VersioningConfiguration on the artefact bucket is different: check 6 above
# already shows floci applies and reports it correctly (a PASS, not a GAP),
# so it starts from a genuine IN_SYNC baseline - the same kind of property
# real detect-stack-drift would check on real AWS. Mutating it with
# put-bucket-versioning is the closest floci analogue to a console edit on
# this endpoint: a real S3 API call this script does not control, checked
# against what the template declares.
#
# Output is shaped like describe-stack-resource-drifts on purpose, so it
# pastes directly into a PR body in place of the real command's output.
#
# Usage:
#   ./scripts/cfn-guardrails.sh detect-drift [stack-name]     # default: taxcalc-artifacts-dev
#   # simulate the console edit:
#   aws s3api put-bucket-versioning --bucket <bucket> --versioning-configuration Status=Suspended
#   ./scripts/cfn-guardrails.sh detect-drift   # -> MODIFIED
#   # revert:
#   aws s3api put-bucket-versioning --bucket <bucket> --versioning-configuration Status=Enabled
#   ./scripts/cfn-guardrails.sh detect-drift   # -> IN_SYNC
detect_drift() {
  local stack="${1:-taxcalc-artifacts-dev}"
  local bucket declared live status stackid rid diffs

  bucket=$(aws_ cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].Outputs[?OutputKey=='ArtefactBucketName'].OutputValue" --output text 2>/dev/null)
  if [ -z "$bucket" ] || [ "$bucket" = "None" ]; then
    printf 'refusing: %s has no ArtefactBucketName output; not deployed?\n' "$stack" >&2
    return 2
  fi

  declared=$(grep -A1 'VersioningConfiguration:' "$CFN_DIR/$stack.yaml" 2>/dev/null \
    | grep -oE 'Status: *[A-Za-z]+' | awk '{print $2}')
  live=$(aws_ s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null)
  [ -z "$live" ] || [ "$live" = "None" ] && live="<unset>"

  stackid=$(aws_ cloudformation describe-stacks --stack-name "$stack" \
    --query "Stacks[0].StackId" --output text 2>/dev/null)
  rid=$(aws_ cloudformation describe-stack-resources --stack-name "$stack" \
    --query "StackResources[?ResourceType=='AWS::S3::Bucket'].LogicalResourceId" --output text 2>/dev/null)

  head_ "detect-drift (workaround): $stack"
  note "detect-stack-drift itself: UnknownAction on this endpoint - see INFRA.md."
  note "Substitute measures VersioningConfiguration.Status, the one property"
  note "check 6 already confirms floci applies and reports correctly."

  if [ "$declared" = "$live" ]; then
    status=IN_SYNC
    diffs='[]'
    ok "declared '$declared' == live '$live'"
  else
    status=MODIFIED
    diffs=$(printf '[{"PropertyPath": "/VersioningConfiguration/Status", "ExpectedValue": "%s", "ActualValue": "%s", "DifferenceType": "NOT_EQUAL"}]' \
      "$declared" "$live")
    gap "declared '$declared' != live '$live' - DRIFTED"
  fi

  printf '\n'
  cat <<JSON
[
  {
    "StackId": "$stackid",
    "LogicalResourceId": "$rid",
    "PhysicalResourceId": "$bucket",
    "ResourceType": "AWS::S3::Bucket",
    "StackResourceDriftStatus": "$status",
    "PropertyDifferences": $diffs
  }
]
JSON
}

if [ "${1:-}" = "detect-drift" ]; then
  detect_drift "${2:-}"; exit 0
fi

# --static runs only the checks derived from the templates themselves - no AWS
# call, no endpoint, no credentials. That is checks 1-3 and the 0.0.0.0/0
# assertion, which between them catch the mistake most likely to be made in
# good faith: replacing an !ImportValue with a hardcoded subnet id because the
# import was inconvenient. cfn-validate.yml runs this on every PR, so the
# cross-stack contract is gated even though the account that would enforce it
# does not exist yet.
STATIC=false
[ "${1:-}" = "--static" ] && STATIC=true

# ===========================================================================
printf '\033[1mcfn-guardrails\033[0m  endpoint=%s  region=%s\n' \
  "${AWS_ENDPOINT_URL:-<real AWS>}" "$REGION"

head_ '1. Import graph (from cfn/, not from ListImports)'
GRAPH=$(import_graph)
if [ -z "$GRAPH" ]; then
  bad "no cross-stack imports found in $CFN_DIR/ - expected at least one"
else
  printf '%s\n' "$GRAPH" | while IFS=$'\t' read -r c p e; do
    note "$c  imports  $e  from  $p"
  done
  # The app stack must consume the network stack. If this edge ever disappears
  # somebody has hardcoded a subnet id, which is the failure !ImportValue exists
  # to prevent.
  if printf '%s\n' "$GRAPH" | grep -q '^taxcalc-app-dev	taxcalc-network-dev	'; then
    n=$(printf '%s\n' "$GRAPH" | grep -c '^taxcalc-app-dev	taxcalc-network-dev	')
    ok "taxcalc-app-dev imports $n export(s) from taxcalc-network-dev"
  else
    bad "taxcalc-app-dev no longer imports from taxcalc-network-dev (hardcoded ids?)"
  fi
fi

head_ '2. guard-delete REFUSES a producer whose exports are in use'
if guard_delete taxcalc-network-dev >/dev/null 2>&1; then
  bad "guard-delete allowed deleting taxcalc-network-dev while it is imported"
else
  ok "guard-delete refused taxcalc-network-dev (imported by taxcalc-app-dev)"
fi

head_ '3. Positive control - guard-delete ALLOWS an unimported stack'
# Without this, check 2 could pass by refusing everything unconditionally.
if guard_delete taxcalc-artifacts-dev >/dev/null 2>&1; then
  ok "guard-delete allowed taxcalc-artifacts-dev (nothing imports it)"
else
  bad "guard-delete refused taxcalc-artifacts-dev, which nothing imports"
fi

if [ "$STATIC" = "true" ]; then
  # The one live-free security assertion, hoisted so --static still makes it.
  head_ '4. App SG ingress (static)'
  if grep -A3 'SecurityGroupIngress:' "$CFN_DIR/taxcalc-network-dev.yaml" | grep -q '0\.0\.0\.0/0'; then
    bad "app SG template has 0.0.0.0/0 on ingress"
  else
    ok "app SG template has no 0.0.0.0/0 ingress"
  fi
  # ---------------------------------------------------------------------
  # W6 D4 Task 1. Both checks below are template-derived, so they gate every
  # PR whether or not an AWS account is wired - which matters more here than
  # elsewhere, because both failures are INVISIBLE at deploy time. An
  # untagged NAT Gateway and an alarm set to notBreaching both reach
  # CREATE_COMPLETE and both look correct in the console.
  head_ '5. Cost-allocation tag coverage on billable resources (static)'
  # A tag-scoped Budget filters on service AND env; a resource missing either
  # key contributes spend the Budget cannot see. That is not a cosmetic gap -
  # it silently shrinks what the guardrail guards, while the guardrail keeps
  # reporting green. So the four keys are asserted here rather than left to
  # a convention nobody re-checks.
  #
  # Scoped to the resource types that actually carry a recurring charge; a
  # route table has no line item and demanding tags on it would train people
  # to ignore this check.
  BILLABLE_TYPES='AWS::EC2::NatGateway|AWS::EC2::EIP|AWS::RDS::DBInstance'
  TAG_MISSING=0
  while IFS= read -r block; do
    tpl=${block%%$'\t'*}; rest=${block#*$'\t'}
    lid=${rest%%$'\t'*}; body=${rest#*$'\t'}
    for k in service env tenant feature; do
      case "$body" in
        *"Key: $k,"*|*"Key: $k}"*|*"Key: $k "*) ;;
        *) bad "$tpl: $lid is billable but has no '$k' cost-allocation tag"
           TAG_MISSING=$((TAG_MISSING+1)) ;;
      esac
    done
  done <<EOF
$(awk -v types="$BILLABLE_TYPES" '
    FILENAME != prevfile { prevfile = FILENAME; lid = ""; body = ""; billable = 0 }
    # A top-level resource starts at exactly two spaces of indent.
    /^  [A-Za-z0-9]+:[ \t]*$/ {
      if (lid != "" && billable) printf "%s\t%s\t%s\n", FILENAME, lid, body
      lid = $1; sub(/:$/, "", lid); body = ""; billable = 0; next
    }
    # ANCHORED to a four-space "    Type:" and not a bare "Type:" substring.
    # Unanchored, `TargetType: AWS::RDS::DBInstance` on the
    # SecretTargetAttachment matched, and the check demanded cost-allocation
    # tags on a resource that has no charge and cannot carry tags at all - a
    # red check nobody can make green, which gets the check deleted rather
    # than the template fixed.
    { body = body " " $0; if ($0 ~ ("^    Type: (" types ")[ \t]*$")) billable = 1 }
    END { if (lid != "" && billable) printf "%s\t%s\t%s\n", FILENAME, lid, body }
  ' "$CFN_DIR"/*.yaml)
EOF
  [ "$TAG_MISSING" -eq 0 ] && ok "every billable resource in $CFN_DIR/ carries all four cost-allocation tags"

  head_ '6. Billing alarm does not use TreatMissingData: notBreaching (static)'
  # On AWS/Billing EstimatedCharges - a metric that publishes roughly every 6h
  # - notBreaching reads every routine gap as "fine" and resets a real breach
  # to OK. `ignore` holds the last state instead. The two spellings are one
  # word apart and the wrong one produces an alarm that never usefully fires.
  # Matches the PROPERTY ASSIGNMENT, not the bare word. The first spelling of
  # this check was `grep -RIn 'notBreaching' cfn/` - exactly what the task
  # text asks for - and it failed on the paragraph in taxcalc-cost-dev.yaml
  # that explains why notBreaching is wrong. A negative grep that its own
  # documentation trips is worse than no check: it is red for a reason that
  # can only be fixed by deleting the explanation, so the next person deletes
  # the check instead and the real setting goes ungated.
  NB_RE='^[[:space:]]*TreatMissingData:[[:space:]]*notBreaching'
  if grep -RInE "$NB_RE" "$CFN_DIR"/ >/dev/null 2>&1; then
    bad "TreatMissingData: notBreaching found in $CFN_DIR/ - see cfn/taxcalc-cost-dev.yaml for why it is wrong on a billing metric"
    grep -RInE "$NB_RE" "$CFN_DIR"/ | while read -r l; do note "$l"; done
  else
    ok "no 'TreatMissingData: notBreaching' in $CFN_DIR/ (billing alarm uses ignore)"
  fi

  head_ 'Result (static mode - no AWS calls made)'
  printf '%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
fi

head_ '4. Does THIS endpoint enforce export-in-use natively?'
# Measured with two disposable stacks, never the real ones.
PROD=cfn-guard-probe-producer
CONS=cfn-guard-probe-consumer
TMPD=$(mktemp -d)
cat > "$TMPD/producer.yaml" <<'YAML'
AWSTemplateFormatVersion: "2010-09-09"
Description: disposable probe - exports one value
Resources:
  Topic: {Type: AWS::SNS::Topic}
Outputs:
  ProbeValue:
    Value: probe
    Export: {Name: cfn-guard-probe-value}
YAML
cat > "$TMPD/consumer.yaml" <<'YAML'
AWSTemplateFormatVersion: "2010-09-09"
Description: disposable probe - imports the producer's export
Resources:
  Topic:
    Type: AWS::SNS::Topic
    Properties:
      DisplayName: !ImportValue cfn-guard-probe-value
YAML
probe_cleanup() {
  aws_ cloudformation delete-stack --stack-name "$CONS" >/dev/null 2>&1
  aws_ cloudformation wait stack-delete-complete --stack-name "$CONS" >/dev/null 2>&1
  aws_ cloudformation delete-stack --stack-name "$PROD" >/dev/null 2>&1
  aws_ cloudformation wait stack-delete-complete --stack-name "$PROD" >/dev/null 2>&1
  rm -rf "$TMPD"
}
trap probe_cleanup EXIT

if aws_ cloudformation create-stack --stack-name "$PROD" \
      --template-body "file://$TMPD/producer.yaml" >/dev/null 2>&1 &&
   aws_ cloudformation wait stack-create-complete --stack-name "$PROD" >/dev/null 2>&1 &&
   aws_ cloudformation create-stack --stack-name "$CONS" \
      --template-body "file://$TMPD/consumer.yaml" >/dev/null 2>&1 &&
   aws_ cloudformation wait stack-create-complete --stack-name "$CONS" >/dev/null 2>&1; then
  aws_ cloudformation delete-stack --stack-name "$PROD" >/dev/null 2>&1
  sleep 2
  if aws_ cloudformation describe-stacks --stack-name "$PROD" >/dev/null 2>&1; then
    ok "endpoint refused the delete natively - guard-delete is belt-and-braces here"
  else
    if is_emulator; then
      gap "endpoint did NOT enforce export-in-use: the probe producer was deleted"
      note "This is the floci gap. guard-delete above is the ONLY protection on"
      note "this endpoint - use it instead of raw delete-stack."
    else
      bad "real AWS deleted a stack whose export was in use - investigate"
    fi
  fi
else
  gap "probe stacks could not be created; native enforcement not measured"
fi
trap - EXIT; probe_cleanup

head_ '5. Is validate-template authoritative on this endpoint?'
cat > /tmp/cfn-guard-canary.yaml <<'YAML'
AWSTemplateFormatVersion: "2010-09-09"
Description: canary - deliberately invalid
Resources:
  NotAThing:
    Type: AWS::Totally::Fictional
    Properties:
      Whatever: !Ref NoSuchParameter
YAML
if aws_ cloudformation validate-template \
     --template-body file:///tmp/cfn-guard-canary.yaml >/dev/null 2>&1; then
  if is_emulator; then
    gap "validate-template PASSED a template with a fictional resource type"
    note "Its result carries no information here. cfn-lint is the real gate -"
    note "it rejects the same file with E3006. This is why cfn-validate.yml"
    note "lets validate-template skip but never lets cfn-lint skip."
  else
    bad "real AWS validate-template passed a fictional resource type"
  fi
else
  ok "validate-template rejected the canary - it is authoritative here"
fi
rm -f /tmp/cfn-guard-canary.yaml

head_ '6. Property parity - declared in template vs live in API (stands in for drift)'
if aws_ cloudformation detect-stack-drift --stack-name taxcalc-artifacts-dev >/dev/null 2>&1; then
  ok "detect-stack-drift is supported - use it directly, this check is a fallback"
else
  note "detect-stack-drift unsupported here; comparing declared vs live by hand."
fi

check_prop() { # label  expected  actual
  if [ "$2" = "$3" ]; then
    ok "$1 = $2"
  elif is_emulator; then
    gap "$1: template declares '$2', endpoint reports '$3'"
  else
    bad "$1: template declares '$2', live is '$3' - DRIFT"
  fi
}

BUCKET=$(aws_ cloudformation describe-stacks --stack-name taxcalc-artifacts-dev \
  --query "Stacks[0].Outputs[?OutputKey=='ArtefactBucketName'].OutputValue" \
  --output text 2>/dev/null)
if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  PAB=$(aws_ s3api get-public-access-block --bucket "$BUCKET" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,BlockPublicPolicy,IgnorePublicAcls,RestrictPublicBuckets]' \
    --output text 2>/dev/null | tr '\t' ',')
  # An absent PAB configuration reads as empty. Say so explicitly rather than
  # letting it look like a value mismatch - "not stored at all" and "stored
  # wrong" are different problems.
  [ -z "$PAB" ] && PAB="<not stored>"
  check_prop "artifacts bucket PublicAccessBlock (all four)" "True,True,True,True" "$PAB"
  VER=$(aws_ s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)
  check_prop "artifacts bucket versioning" "Enabled" "$VER"
  ALG=$(aws_ s3api get-bucket-encryption --bucket "$BUCKET" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>/dev/null)
  check_prop "artifacts bucket SSE algorithm" "aws:kms" "${ALG:-<not stored>}"
else
  note "taxcalc-artifacts-dev not deployed; skipping bucket parity."
fi

if aws_ rds describe-db-instances --db-instance-identifier taxcalc-dev >/dev/null 2>&1; then
  RDS=$(aws_ rds describe-db-instances --db-instance-identifier taxcalc-dev \
    --query 'DBInstances[0].[PubliclyAccessible,StorageEncrypted,DeletionProtection,BackupRetentionPeriod]' \
    --output text 2>/dev/null)
  set -- $RDS
  check_prop "rds PubliclyAccessible"   "False" "${1:-}"
  check_prop "rds StorageEncrypted"     "True"  "${2:-}"
  check_prop "rds DeletionProtection"   "True"  "${3:-}"
  check_prop "rds BackupRetentionPeriod" "7"    "${4:-}"
else
  note "taxcalc-dev RDS instance not deployed; skipping RDS parity."
fi

# The one property whose absence is a security bug rather than a parity gap:
# the app SG must never accept 0.0.0.0/0 on its ingress. Checked against the
# TEMPLATE as well as live, so it holds even when nothing is deployed.
if grep -A3 'SecurityGroupIngress:' "$CFN_DIR/taxcalc-network-dev.yaml" | grep -q '0\.0\.0\.0/0'; then
  bad "app SG template has 0.0.0.0/0 on ingress"
else
  ok "app SG template has no 0.0.0.0/0 ingress"
fi

head_ '7. Phantom resources - CREATE_COMPLETE in CFN, absent from the data plane'
# The sharpest failure mode found on floci, and the one most likely to be
# believed: describe-stack-resources reports ArtefactBucketPolicy as
# CREATE_COMPLETE while get-bucket-policy returns NoSuchBucketPolicy. The
# control plane says the resource exists; the data plane disagrees. A deny-
# non-TLS policy that CFN thinks it applied and S3 has never heard of is
# strictly worse than no policy at all, because the stack looks compliant.
#
# Generalised: for every AWS::S3::BucketPolicy the stacks claim to have
# created, go and ask S3 whether it is actually there.
PHANTOM=0; CHECKED=0; RECONCILED=0
for stk in taxcalc-bootstrap-dev taxcalc-artifacts-dev; do
  aws_ cloudformation describe-stack-resources --stack-name "$stk" \
    --query "StackResources[?ResourceType=='AWS::S3::BucketPolicy'].LogicalResourceId" \
    --output text 2>/dev/null | tr '\t' '\n' | while read -r lid; do
      [ -n "$lid" ] || continue
      printf '%s\t%s\n' "$stk" "$lid"
    done
done > /tmp/cfn-guard-policies.txt 2>/dev/null

BKT_BOOT=$(aws_ cloudformation describe-stacks --stack-name taxcalc-bootstrap-dev \
  --query "Stacks[0].Outputs[?OutputKey=='BootstrapBucketName'].OutputValue" --output text 2>/dev/null)
for pair in "taxcalc-bootstrap-dev:$BKT_BOOT" "taxcalc-artifacts-dev:$BUCKET"; do
  stk=${pair%%:*}; bkt=${pair#*:}
  [ -n "$bkt" ] && [ "$bkt" != "None" ] || continue
  grep -q "^$stk	" /tmp/cfn-guard-policies.txt 2>/dev/null || continue
  CHECKED=$((CHECKED+1))
  if aws_ s3api get-bucket-policy --bucket "$bkt" --query Policy --output text >/tmp/cfn-guard-pol 2>/dev/null; then
    if grep -q 'SecureTransport' /tmp/cfn-guard-pol; then
      ok "$stk bucket policy is live and denies non-TLS"
      RECONCILED=$((RECONCILED+1))
    else
      bad "$stk bucket policy exists but has no aws:SecureTransport condition"
    fi
  else
    PHANTOM=$((PHANTOM+1))
    if is_emulator; then
      gap "$stk: BucketPolicy is CREATE_COMPLETE in CFN but absent from S3"
    else
      bad "$stk: BucketPolicy is CREATE_COMPLETE in CFN but absent from S3"
    fi
  fi
done
rm -f /tmp/cfn-guard-policies.txt /tmp/cfn-guard-pol
[ "$CHECKED" -eq 0 ] && note "no deployed BucketPolicy resources to check."
if [ "$PHANTOM" -gt 0 ]; then
  note "$PHANTOM phantom resource(s). On this endpoint a green stack does NOT"
  note "mean the hardening is applied - re-assert bucket policies out of band,"
  note "or verify them on real AWS before believing them."
fi
# A PASS here says the policy is in S3. It does NOT say CloudFormation put it
# there. On an emulator whose CFN provider is a known no-op for this resource,
# the likeliest reason the policy is live is that `reconcile-s3` applied it -
# so this check cannot be cited as evidence that the CFN path works.
if [ "$RECONCILED" -gt 0 ] && is_emulator; then
  note "NOTE: on this endpoint a live policy is most likely the work of"
  note "'cfn-guardrails.sh reconcile-s3', not of CloudFormation. This check"
  note "proves the data plane holds the rule, not that CFN applied it."
fi

head_ '8. Does this endpoint HONOUR Replacement: False?'
# The most dangerous gap found on floci, because it contradicts the exact
# field the whole ChangeSet review discipline rests on. describe-change-set
# reported Action: Modify / Replacement: False on a pure tag change - and
# execute-change-set then replaced the resource anyway, changing its physical
# id (and not applying the tag). A reviewer who reads "Replacement: False" on
# an RDS instance and approves would lose the database.
#
# Measured on a disposable stack: create, change one tag, confirm the
# ChangeSet promises no replacement, execute, compare physical ids.
UPD=cfn-guard-replace-probe
TMPU=$(mktemp -d)
cat > "$TMPU/v1.yaml" <<'YAML'
AWSTemplateFormatVersion: "2010-09-09"
Description: disposable probe - Replacement:False honoured?
Resources:
  Topic:
    Type: AWS::SNS::Topic
    Properties:
      Tags: [{Key: Probe, Value: before}]
YAML
sed 's/Value: before/Value: after/' "$TMPU/v1.yaml" > "$TMPU/v2.yaml"
upd_cleanup() {
  aws_ cloudformation delete-stack --stack-name "$UPD" >/dev/null 2>&1
  aws_ cloudformation wait stack-delete-complete --stack-name "$UPD" >/dev/null 2>&1
  rm -rf "$TMPU"
}
trap upd_cleanup EXIT
if aws_ cloudformation create-stack --stack-name "$UPD" \
      --template-body "file://$TMPU/v1.yaml" >/dev/null 2>&1 &&
   aws_ cloudformation wait stack-create-complete --stack-name "$UPD" >/dev/null 2>&1; then
  BEFORE=$(aws_ cloudformation describe-stack-resources --stack-name "$UPD" \
    --query 'StackResources[0].PhysicalResourceId' --output text 2>/dev/null)
  aws_ cloudformation create-change-set --stack-name "$UPD" --change-set-name t \
    --change-set-type UPDATE --template-body "file://$TMPU/v2.yaml" >/dev/null 2>&1
  aws_ cloudformation wait change-set-create-complete --stack-name "$UPD" --change-set-name t >/dev/null 2>&1
  PROMISE=$(aws_ cloudformation describe-change-set --stack-name "$UPD" --change-set-name t \
    --query 'Changes[0].ResourceChange.Replacement' --output text 2>/dev/null)
  aws_ cloudformation execute-change-set --stack-name "$UPD" --change-set-name t >/dev/null 2>&1
  aws_ cloudformation wait stack-update-complete --stack-name "$UPD" >/dev/null 2>&1
  AFTER=$(aws_ cloudformation describe-stack-resources --stack-name "$UPD" \
    --query 'StackResources[0].PhysicalResourceId' --output text 2>/dev/null)
  if [ "$PROMISE" = "False" ] && [ "$BEFORE" = "$AFTER" ]; then
    ok "promised Replacement: False and kept it (physical id unchanged)"
  elif [ "$PROMISE" = "False" ]; then
    if is_emulator; then
      gap "promised Replacement: False then REPLACED the resource"
      note "before: $BEFORE"
      note "after:  $AFTER"
      note "Replacement: False cannot be trusted on this endpoint. Any"
      note "no-replacement claim has to be re-checked by comparing physical"
      note "ids before and after, not by reading the ChangeSet."
    else
      bad "real AWS promised Replacement: False then replaced the resource"
    fi
  else
    note "ChangeSet reported Replacement=$PROMISE; not a no-replacement case."
  fi
else
  gap "replacement probe stack could not be created; not measured"
fi
trap - EXIT; upd_cleanup

head_ '9. Does this endpoint REMOVE the default egress rule when SecurityGroupEgress is declared?'
# On real AWS, an explicit SecurityGroupEgress list REPLACES the security
# group's auto-created "allow all, 0.0.0.0/0" default - AWS documents this
# directly. It is why every enumerated-egress SG in this repo's templates is
# commented "REPLACES the default allow-all". Measured with a disposable SG
# declaring only 443: if the -1/0.0.0.0/0 rule is still present after create,
# the enumerated list is being treated as ADDITIVE on this endpoint, and any
# "no unrestricted egress" claim about a deployed SG cannot be trusted here -
# only the template is trustworthy, not what got deployed from it.
EGP=cfn-guard-egress-probe
TMPE=$(mktemp -d)
cat > "$TMPE/sg.yaml" <<'YAML'
AWSTemplateFormatVersion: "2010-09-09"
Resources:
  Vpc: {Type: AWS::EC2::VPC, Properties: {CidrBlock: 10.95.0.0/16}}
  Sg:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: disposable probe - only 443 declared
      VpcId: !Ref Vpc
      SecurityGroupEgress:
        - {IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0}
YAML
egress_cleanup() {
  aws_ cloudformation delete-stack --stack-name "$EGP" >/dev/null 2>&1
  aws_ cloudformation wait stack-delete-complete --stack-name "$EGP" >/dev/null 2>&1
  rm -rf "$TMPE"
}
trap egress_cleanup EXIT
if aws_ cloudformation create-stack --stack-name "$EGP" --template-body "file://$TMPE/sg.yaml" >/dev/null 2>&1 &&
   aws_ cloudformation wait stack-create-complete --stack-name "$EGP" >/dev/null 2>&1; then
  SGID=$(aws_ cloudformation describe-stack-resources --stack-name "$EGP" \
    --query "StackResources[?LogicalResourceId=='Sg'].PhysicalResourceId" --output text 2>/dev/null)
  HASWILD=$(aws_ ec2 describe-security-groups --group-ids "$SGID" \
    --query "length(SecurityGroups[0].IpPermissionsEgress[?IpProtocol=='-1'])" --output text 2>/dev/null)
  if [ "${HASWILD:-0}" = "0" ]; then
    ok "default allow-all egress removed once SecurityGroupEgress was declared"
  else
    if is_emulator; then
      gap "the -1/0.0.0.0/0 default egress rule survived a declared SecurityGroupEgress"
      note "the enumerated list is ADDITIVE here, not a replacement. A security"
      note "group inspected on this endpoint can look far more permissive than"
      note "its template - trust the template's egress list, not a live scan."
    else
      bad "real AWS left the default allow-all egress rule in place - investigate"
    fi
  fi
else
  gap "egress-replace probe stack could not be created; not measured"
fi
trap - EXIT; egress_cleanup

head_ 'Result'
printf '%d passed, %d failed, %d parity gap(s)\n' "$PASS" "$FAIL" "$GAP"
if [ "$GAP" -gt 0 ]; then
  printf '\nParity gaps are endpoint limitations, not template defects - they are\n'
  printf 'reported separately for that reason. Against real AWS the same\n'
  printf 'mismatches would count as failures. See taxcalc-api/INFRA.md.\n'
fi
[ "$FAIL" -eq 0 ] || exit 1
exit 0
