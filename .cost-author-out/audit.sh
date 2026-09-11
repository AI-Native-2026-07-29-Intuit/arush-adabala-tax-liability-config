#!/usr/bin/env bash
#
# audit.sh - demonstrate the three rejections W6 D4 Task 4 names, by running
# them against a candidate that actually contains the three defects.
#
# WHY THIS EXISTS
# ---------------
# The first cost-author pass (recorded in COST.md) reported the three named
# failure modes as "not observed" - it reviewed artefacts that never contained
# them. That is a true statement and worthless evidence: a rejection rule that
# has never fired is indistinguishable from one that is not wired. The task
# asks for three REJECTIONS, so this run supplies inputs that earn them.
#
# `candidate/` holds three templates carrying exactly the three defects:
#
#   1. untagged NAT Gateway + EIP (network) and untagged RDS instance (app)
#   2. TreatMissingData: notBreaching on the AWS/Billing alarm
#   3. an AWS::Budgets::Budget created to cap Anthropic/LLM spend
#
# Checks 1 and 2 are delegated to the repo's own tracked gate,
# scripts/cfn-guardrails.sh --static checks 5 and 6, pointed at the candidate
# via CFN_DIR. Reusing the real gate rather than reimplementing it is the
# point: it proves the SHIPPING check catches these, not that this script can.
#
# Check 3 has no counterpart in the tracked gate, because no static rule in
# this repo has ever needed one. It is implemented here and the audit records
# that asymmetry rather than papering over it.
#
# The script then re-runs all three against the real cfn/ and requires them to
# pass, so a green result cannot come from a broken detector.
#
# Usage:  ./.cost-author-out/audit.sh          (from the repo root)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

CAND=".cost-author-out/candidate"
REAL="cfn"
RC=0

red()   { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
head_() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
# Rejection 3's detector. Not in cfn-guardrails.sh - see the header.
#
# BEDROCK IS DELIBERATELY NOT MATCHED. Amazon Bedrock is a hosted model AND
# AWS-resident spend, so a Bedrock-scoped Budget is legitimate and a detector
# that keyed on "is this about an LLM?" would reject a correct template. The
# question is never "is it AI?" - it is "who is the merchant?".
# ---------------------------------------------------------------------------
NON_AWS_MERCHANT='anthropic|openai|claude|gpt-|llm-spend|llm_spend'

llm_budget_scan() { # dir -> prints offending "file:resource"; returns count
  local dir="$1" n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '  %s\n' "$line"
    n=$((n + 1))
  done < <(awk -v pat="$NON_AWS_MERCHANT" '
      FILENAME != prevfile { prevfile = FILENAME; lid = ""; body = ""; isbudget = 0 }
      /^  [A-Za-z0-9]+:[ \t]*$/ {
        if (lid != "" && isbudget && tolower(body) ~ pat)
          printf "%s: %s\n", FILENAME, lid
        lid = $1; sub(/:$/, "", lid); body = ""; isbudget = 0; next
      }
      {
        # Comments explaining why an LLM budget is wrong must not trip this.
        stripped = $0; sub(/#.*$/, "", stripped)
        body = body " " stripped
        if ($0 ~ /^    Type: AWS::Budgets::Budget[ \t]*$/) isbudget = 1
      }
      END {
        if (lid != "" && isbudget && tolower(body) ~ pat)
          printf "%s: %s\n", FILENAME, lid
      }
    ' "$dir"/*.yaml)
  return "$n"
}

# ---------------------------------------------------------------------------
head_ "Phase 1 - the candidate MUST be rejected on all three"
# ---------------------------------------------------------------------------

printf '\n-- rejections 1 and 2, via the tracked gate --\n'
CFN_DIR="$CAND" ./scripts/cfn-guardrails.sh --static
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then
  red "FAIL: cfn-guardrails.sh --static passed a candidate with planted defects"
  RC=1
else
  green "OK: the tracked gate rejected the candidate (exit $GATE_RC)"
fi

printf '\n-- rejection 3, an AWS Budget aimed at non-AWS spend --\n'
llm_budget_scan "$CAND"
if [ "$?" -gt 0 ]; then
  green "OK: rejected - AWS Budgets cannot see spend AWS does not bill"
else
  red "FAIL: the LLM-budget detector found nothing in the candidate"
  RC=1
fi

# ---------------------------------------------------------------------------
head_ "Phase 2 - the real cfn/ MUST pass all three"
# ---------------------------------------------------------------------------
# Without this half, a detector that matched everything would look like a
# working audit.

printf '\n-- rejections 1 and 2, via the tracked gate --\n'
CFN_DIR="$REAL" ./scripts/cfn-guardrails.sh --static
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then
  green "OK: the tracked gate passed the committed templates"
else
  red "FAIL: cfn-guardrails.sh --static rejected the committed cfn/ (exit $GATE_RC)"
  RC=1
fi

printf '\n-- rejection 3 --\n'
llm_budget_scan "$REAL"
if [ "$?" -eq 0 ]; then
  green "OK: no AWS Budget in cfn/ targets non-AWS spend"
else
  red "FAIL: an LLM-targeted Budget is present in the committed cfn/"
  RC=1
fi

head_ "Result"
if [ "$RC" -eq 0 ]; then
  green "all three rejections fire on the candidate and stay silent on cfn/"
else
  red "audit did not behave as specified"
fi
exit "$RC"
