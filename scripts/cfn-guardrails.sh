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
PHANTOM=0; CHECKED=0
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
