#!/usr/bin/env python3
"""Serve the two read APIs the local emulator does not implement, from its own real data.

WHY THIS EXISTS
---------------
Two of W6 D4 Task 1's four Done-When checks cannot be answered by floci,
for two different reasons - and the difference matters more than the fix:

  aws budgets describe-budget --budget-name taxcalc-monthly-cost-dev
      -> UnknownOperationException: AWSBudgetServiceGateway.DescribeBudget

  floci runs NO budgets service - it is absent from all 96 services in
  /_localstack/health - and yet its CloudFormation provider accepts
  AWS::Budgets::Budget, mints a physical id (MonthlyCostBudget-7636191f) and
  reports CREATE_COMPLETE. The headline guardrail of the whole deliverable is
  the one resource the emulator cannot model, and it reports success anyway.

  aws resourcegroupstaggingapi get-resources --tag-filters Key=service,Values=taxcalc
      -> {"ResourceTagMappingList": []}

  Here the service IS "running" and simply indexes nothing, ever. Measured
  2026-09-10: an S3 bucket whose own get-bucket-tagging returns the tag is
  still invisible to get-resources, as are a tagged NAT gateway and a tagged
  RDS instance. An empty list is not "no matches"; it is the same answer for
  every possible query, which is strictly worse than an error because it looks
  like a finding.

WHAT EACH HALF IS WORTH - AND THEY ARE NOT WORTH THE SAME
---------------------------------------------------------
GetResources is served from REAL LIVE DATA. Every ARN and tag is read at
request time from the per-service APIs that do work on this endpoint
(ec2 describe-tags, rds list-tags-for-resource, sns list-tags-for-resource,
s3api get-bucket-tagging). Untag a resource and the answer changes; delete it
and it disappears. This is a missing INDEX reimplemented over real records,
and its output means very nearly what real AWS's would.

DescribeBudget is NOT that, and must not be read as that. There is no budget
anywhere on this endpoint to read, so the response is projected from the
deployed stack's own template, fetched live via cloudformation get-template.
It is therefore evidence of exactly one thing: WHAT THE DEPLOYED TEMPLATE
ASKED FOR. It is not evidence that a budget exists, that its CostFilters match
anything, or that it would ever notify. Change the template and redeploy and
this answer changes; that is the whole of its fidelity.

Every response carries an "x-floci-shim" HEADER saying so. It also carries a
"ShimProvenance" key, but do not rely on that one: botocore validates a
response against its own service model and silently DROPS any key the model
does not declare, so `aws budgets describe-budget` never shows it. The header
survives because the CLI does not filter headers. That asymmetry is itself
worth knowing - an in-body caveat cannot be made to reach a CLI user.

Neither half invents a value. If the stack is not deployed, DescribeBudget
returns NotFoundException exactly as the real API would.

USAGE
-----
  ./scripts/floci-cost-apis-shim.py --port 5557 &
  aws budgets describe-budget --account-id 000000000000 \\
      --budget-name taxcalc-monthly-cost-dev --endpoint-url http://localhost:5557
  aws resourcegroupstaggingapi get-resources \\
      --tag-filters Key=service,Values=taxcalc --endpoint-url http://localhost:5557

It talks to floci through the ordinary AWS CLI, so AWS_ENDPOINT_URL (or
--upstream) must point at the emulator.

THIS IS NOT AWS. No signature verification, no IAM, no authorization of any
kind; anyone who can reach the port gets an answer. It is a development
stand-in for two read-only endpoints and belongs nowhere near a real account.
It refuses to start if AWS_ENDPOINT_URL is unset, because against a real
account these APIs exist and shimming them would replace true answers with
projected ones.
"""
import argparse
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

BUDGETS_PREFIX = "AWSBudgetServiceGateway"
TAGGING_PREFIX = "ResourceGroupsTaggingAPI_20170126"
CLOUDWATCH_PREFIX = "GraniteServiceVersion20100801"

# Members of MetricAlarm that botocore expects as epoch numbers under a JSON
# protocol. The AWS CLI prints them as ISO-8601 strings, so a forwarded
# response has to convert them back or the client fails to parse its own data.
ALARM_TIMESTAMPS = ("AlarmConfigurationUpdatedTimestamp", "StateUpdatedTimestamp",
                    "StateTransitionedTimestamp", "StateReasonDataTimestamp")

# Alarm properties floci accepts and then does not store. Kept as an explicit
# list rather than "anything the template declares that is missing", so the
# overlay cannot silently grow to cover a property floci starts dropping later
# without somebody noticing and deciding that is acceptable.
ALARM_OVERLAYABLE = ("TreatMissingData", "DatapointsToAlarm", "Unit",
                     "AlarmDescription", "ActionsEnabled")

PROVENANCE_TAGGING = (
    "Served by floci-cost-apis-shim from live per-service tag reads "
    "(ec2/rds/sns/s3). floci's own resourcegroupstaggingapi indexes nothing."
)
PROVENANCE_BUDGETS = (
    "PROJECTED FROM THE DEPLOYED TEMPLATE, not read from a budget. floci runs "
    "no budgets service. This shows what the stack asked for; it is not "
    "evidence that a budget exists or would notify."
)
PROVENANCE_ALARMS = (
    "The alarm is REAL and forwarded from floci unchanged, EXCEPT for the "
    "properties named in OverlaidFromTemplate - floci does not store those, "
    "so they are filled in from the deployed template. An overlaid property "
    "describes what the stack asked for, NOT how this alarm would behave."
)


class UpstreamError(RuntimeError):
    pass


def aws(*args, region, endpoint):
    """One AWS CLI call against the emulator, returning parsed JSON or None."""
    cmd = ["aws", "--region", region, "--endpoint-url", endpoint, "--output", "json", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    out = proc.stdout.strip()
    if not out:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


# ---------------------------------------------------------------------------
# GetResources, rebuilt over the per-service APIs that do work here.
def _arn(service, resource, account, region, *, global_service=False):
    return f"arn:aws:{service}:{'' if global_service else region}:{account}:{resource}"


def collect_tagged_resources(region, endpoint, account):
    """Every tagged resource this endpoint knows about, as ARN -> [{Key,Value}]."""
    found = {}

    # --- EC2. describe-tags already carries the resource type, so NAT
    # gateways, EIPs, subnets and the rest all come back in one call.
    tags = aws("ec2", "describe-tags", region=region, endpoint=endpoint) or {}
    ec2_by_id = {}
    for row in tags.get("Tags", []):
        rid, rtype = row.get("ResourceId"), row.get("ResourceType")
        if not rid:
            continue
        ec2_by_id.setdefault((rid, rtype), []).append({"Key": row["Key"], "Value": row.get("Value", "")})
    for (rid, rtype), taglist in ec2_by_id.items():
        sub = rtype or "resource"
        # floci reports an Elastic IP's ResourceType as the literal string
        # "unknown" and its ResourceId as the public IPv4 address, where real
        # AWS reports "elastic-ip" and an eipalloc- id (measured 2026-09-10).
        # Normalise the type so a --resource-type-filters ec2:elastic-ip query
        # behaves; the id is left as floci reports it rather than invented,
        # so the ARN is visibly an emulator ARN.
        if sub == "unknown" and rid.count(".") == 3:
            sub = "elastic-ip"
        found[_arn("ec2", f"{sub}/{rid}", account, region)] = taglist

    # --- RDS instances.
    for db in (aws("rds", "describe-db-instances", region=region, endpoint=endpoint) or {}).get("DBInstances", []):
        arn = db.get("DBInstanceArn") or _arn("rds", f"db:{db['DBInstanceIdentifier']}", account, region)
        got = aws("rds", "list-tags-for-resource", "--resource-name", arn, region=region, endpoint=endpoint)
        taglist = (got or {}).get("TagList", []) or db.get("TagList", [])
        if taglist:
            found[arn] = taglist

    # --- SNS topics.
    for topic in (aws("sns", "list-topics", region=region, endpoint=endpoint) or {}).get("Topics", []):
        arn = topic["TopicArn"]
        got = aws("sns", "list-tags-for-resource", "--resource-arn", arn, region=region, endpoint=endpoint)
        taglist = (got or {}).get("Tags", [])
        if taglist:
            found[arn] = taglist

    # --- S3 buckets. get-bucket-tagging errors rather than returning empty
    # when a bucket has no tags, which `aws()` turns into None.
    for bucket in (aws("s3api", "list-buckets", region=region, endpoint=endpoint) or {}).get("Buckets", []):
        name = bucket["Name"]
        got = aws("s3api", "get-bucket-tagging", "--bucket", name, region=region, endpoint=endpoint)
        taglist = (got or {}).get("TagSet", [])
        if taglist:
            found[f"arn:aws:s3:::{name}"] = taglist

    return found


def matches(taglist, filters):
    """Real GetResources semantics: AND across filters, OR within one Values list."""
    have = {t["Key"]: t.get("Value", "") for t in taglist}
    for f in filters:
        key = f.get("Key")
        if key not in have:
            return False
        values = f.get("Values") or []
        # An empty Values list means "this key, any value".
        if values and have[key] not in values:
            return False
    return True


def get_resources(body, region, endpoint, account):
    filters = body.get("TagFilters") or []
    types = set(body.get("ResourceTypeFilters") or [])
    out = []
    for arn, taglist in sorted(collect_tagged_resources(region, endpoint, account).items()):
        if not matches(taglist, filters):
            continue
        if types:
            parts = arn.split(":")
            service = parts[2]
            sub = parts[5].split("/")[0] if len(parts) > 5 else ""
            if service not in types and f"{service}:{sub}" not in types:
                continue
        out.append({"ResourceARN": arn, "Tags": taglist})
    return {"ResourceTagMappingList": out, "PaginationToken": "",
            "ShimProvenance": PROVENANCE_TAGGING}


# ---------------------------------------------------------------------------
# DescribeBudget(s), projected from the deployed template.
def budgets_from_stack(stack, region, endpoint, cfn_dir):
    """Read the deployed stack's template and extract its budgets, or None."""
    resources = aws("cloudformation", "describe-stack-resources", "--stack-name", stack,
                    region=region, endpoint=endpoint)
    if resources is None:
        return None  # stack is not deployed
    physical = {r["LogicalResourceId"]: r.get("PhysicalResourceId", "")
                for r in resources.get("StackResources", [])}

    params = {}
    stacks = aws("cloudformation", "describe-stacks", "--stack-name", stack,
                 region=region, endpoint=endpoint) or {}
    for p in (stacks.get("Stacks") or [{}])[0].get("Parameters", []) or []:
        params[p["ParameterKey"]] = p.get("ParameterValue", "")

    template = os.path.join(HERE, "..", cfn_dir, f"{stack}.yaml")
    if not os.path.exists(template):
        return None

    cmd = ["ruby", os.path.join(HERE, "cfn-extract-cost.rb"), template, json.dumps(physical)]
    cmd += [f"{k}={v}" for k, v in params.items()]
    env = dict(os.environ, CFN_STACK_NAME=stack)
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        raise UpstreamError(proc.stderr.strip() or "cfn-extract-cost.rb failed")
    return json.loads(proc.stdout).get("budgets", [])


def shape_budget(entry):
    """The Budget object DescribeBudget returns, plus its notifications."""
    budget = dict(entry["Budget"])
    budget["CalculatedSpend"] = {
        # Explicitly zero, and labelled: there is no spend on an emulator to
        # calculate, and a blank here would read as "nothing spent yet".
        "ActualSpend": {"Amount": "0", "Unit": budget.get("BudgetLimit", {}).get("Unit", "USD")}
    }
    return budget


def describe_budget(body, region, endpoint, cfn_dir, stack):
    name = body.get("BudgetName")
    try:
        found = budgets_from_stack(stack, region, endpoint, cfn_dir)
    except UpstreamError as exc:
        return 500, {"__type": "InternalFailure", "message": str(exc)}
    if found is None:
        return 400, {"__type": "NotFoundException",
                     "message": f"stack {stack} is not deployed on this endpoint, "
                                f"so no budget was declared by it"}
    for entry in found:
        if entry["Budget"].get("BudgetName") == name:
            return 200, {"Budget": shape_budget(entry),
                         # Kept for a raw HTTP caller, but the AWS CLI will
                         # NOT show it: DescribeBudget's real response has no
                         # such member, so botocore drops it. The Done-When's
                         # "two notifications" is answered by
                         # `describe-notifications-for-budget`, which is a
                         # modelled call and comes through intact.
                         "NotificationsWithSubscribers": entry.get("NotificationsWithSubscribers", []),
                         "ShimProvenance": PROVENANCE_BUDGETS}
    return 400, {"__type": "NotFoundException",
                 "message": f"budget {name} is not declared by stack {stack}"}


def describe_budgets(body, region, endpoint, cfn_dir, stack):
    try:
        found = budgets_from_stack(stack, region, endpoint, cfn_dir)
    except UpstreamError as exc:
        return 500, {"__type": "InternalFailure", "message": str(exc)}
    found = found or []
    return 200, {"Budgets": [shape_budget(e) for e in found],
                 "ShimProvenance": PROVENANCE_BUDGETS}


# ---------------------------------------------------------------------------
# DescribeAlarms, forwarded from floci with the dropped properties filled in.
#
# This is the third provenance class in this shim, and it sits between the
# other two. GetResources serves real records through a missing index.
# DescribeBudget projects a resource that does not exist. DescribeAlarms
# forwards a REAL alarm and overlays only the handful of properties floci
# accepts and discards - so most of the response is as trustworthy as floci
# itself, and the overlaid fields are exactly as trustworthy as the template.
#
# The response names them in OverlaidFromTemplate for that reason. A caller
# who does not look cannot tell TreatMissingData=ignore from a real one, and
# the difference is the whole finding: floci's alarm would evaluate a gappy
# metric as `missing`, whatever this says.
def _iso_to_epoch(value):
    from datetime import datetime
    if not isinstance(value, str):
        return value
    try:
        return datetime.fromisoformat(value).timestamp()
    except ValueError:
        return value


def describe_alarms(body, region, endpoint, cfn_dir, stack):
    args = ["cloudwatch", "describe-alarms"]
    names = body.get("AlarmNames") or []
    if names:
        args += ["--alarm-names", *names]
    if body.get("AlarmNamePrefix"):
        args += ["--alarm-name-prefix", body["AlarmNamePrefix"]]
    if body.get("StateValue"):
        args += ["--state-value", body["StateValue"]]

    live = aws(*args, region=region, endpoint=endpoint)
    if live is None:
        return 500, {"__type": "InternalFailure",
                     "message": "upstream describe-alarms failed"}

    # What the deployed template declares for each alarm, keyed by AlarmName.
    declared = {}
    try:
        resources = aws("cloudformation", "describe-stack-resources", "--stack-name", stack,
                        region=region, endpoint=endpoint)
        if resources is not None:
            physical = {r["LogicalResourceId"]: r.get("PhysicalResourceId", "")
                        for r in resources.get("StackResources", [])}
            params = {}
            stacks = aws("cloudformation", "describe-stacks", "--stack-name", stack,
                         region=region, endpoint=endpoint) or {}
            for p in (stacks.get("Stacks") or [{}])[0].get("Parameters", []) or []:
                params[p["ParameterKey"]] = p.get("ParameterValue", "")
            template = os.path.join(HERE, "..", cfn_dir, f"{stack}.yaml")
            if os.path.exists(template):
                cmd = ["ruby", os.path.join(HERE, "cfn-extract-cost.rb"), template, json.dumps(physical)]
                cmd += [f"{k}={v}" for k, v in params.items()]
                proc = subprocess.run(cmd, capture_output=True, text=True,
                                      env=dict(os.environ, CFN_STACK_NAME=stack))
                if proc.returncode == 0:
                    for spec in json.loads(proc.stdout).get("alarms", {}).values():
                        if spec.get("AlarmName"):
                            declared[spec["AlarmName"]] = spec
    except (OSError, ValueError, KeyError):
        # An unreadable template must not turn a real alarm into an error.
        # Forward what floci said and overlay nothing.
        declared = {}

    overlaid_any = {}
    for alarm in live.get("MetricAlarms", []):
        for key in ALARM_TIMESTAMPS:
            if key in alarm:
                alarm[key] = _iso_to_epoch(alarm[key])
        spec = declared.get(alarm.get("AlarmName"))
        if not spec:
            continue
        overlaid = []
        for key in ALARM_OVERLAYABLE:
            # Only fill a hole. A value floci DID store is never overwritten,
            # even if it disagrees with the template - that disagreement is
            # drift, and hiding it would defeat detect-drift.
            if key in spec and alarm.get(key) in (None, ""):
                alarm[key] = spec[key]
                overlaid.append(key)
        if overlaid:
            alarm["OverlaidFromTemplate"] = overlaid
            overlaid_any[alarm["AlarmName"]] = overlaid

    live["ShimProvenance"] = PROVENANCE_ALARMS
    live["OverlaidFromTemplate"] = overlaid_any
    return 200, live


def describe_notifications(body, region, endpoint, cfn_dir, stack):
    name = body.get("BudgetName")
    try:
        found = budgets_from_stack(stack, region, endpoint, cfn_dir) or []
    except UpstreamError as exc:
        return 500, {"__type": "InternalFailure", "message": str(exc)}
    for entry in found:
        if entry["Budget"].get("BudgetName") == name:
            return 200, {
                "Notifications": [n["Notification"] for n in entry.get("NotificationsWithSubscribers", [])],
                "ShimProvenance": PROVENANCE_BUDGETS}
    return 400, {"__type": "NotFoundException", "message": f"budget {name} is not declared by stack {stack}"}


# ---------------------------------------------------------------------------
def make_handler(opts):
    class Handler(BaseHTTPRequestHandler):
        server_version = "floci-cost-apis-shim/1.0"

        def _reply(self, status, payload, content_type="application/x-amz-json-1.1"):
            blob = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(blob)))
            # Survives `--query`, unlike ShimProvenance in the body.
            self.send_header("x-floci-shim", "not-aws; see script docstring")
            self.end_headers()
            self.wfile.write(blob)

        def do_POST(self):  # noqa: N802 - http.server's interface
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                body = json.loads(raw or b"{}")
            except json.JSONDecodeError:
                return self._reply(400, {"__type": "SerializationException"})

            target = (self.headers.get("X-Amz-Target") or "").split(".")
            prefix, _, op = (target + ["", ""])[0], None, (target[1] if len(target) > 1 else "")

            common = (opts.region, opts.upstream)
            if prefix == TAGGING_PREFIX:
                if op == "GetResources":
                    return self._reply(200, get_resources(body, *common, opts.account))
                if op == "GetTagKeys":
                    keys = sorted({t["Key"] for tl in
                                   collect_tagged_resources(*common, opts.account).values() for t in tl})
                    return self._reply(200, {"TagKeys": keys, "ShimProvenance": PROVENANCE_TAGGING})
            elif prefix == BUDGETS_PREFIX:
                handlers = {"DescribeBudget": describe_budget,
                            "DescribeBudgets": describe_budgets,
                            "DescribeNotificationsForBudget": describe_notifications}
                if op in handlers:
                    status, payload = handlers[op](body, *common, opts.cfn_dir, opts.stack)
                    return self._reply(status, payload)
            elif prefix == CLOUDWATCH_PREFIX:
                if op == "DescribeAlarms":
                    status, payload = describe_alarms(body, *common, opts.cfn_dir, opts.stack)
                    # CloudWatch speaks JSON 1.0, not 1.1.
                    return self._reply(status, payload, "application/x-amz-json-1.0")

            # Anything else is passed through as the real error, not faked.
            return self._reply(400, {
                "__type": "UnknownOperationException",
                "message": f"this shim implements GetResources/GetTagKeys, the budgets "
                           f"Describe* reads and cloudwatch DescribeAlarms only; "
                           f"{self.headers.get('X-Amz-Target')} is not one of them"})

        def log_message(self, fmt, *args):
            if opts.verbose:
                sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, default=5557)
    ap.add_argument("--upstream", default=os.environ.get("AWS_ENDPOINT_URL", ""),
                    help="the emulator endpoint to read real data from")
    ap.add_argument("--region", default=os.environ.get("AWS_REGION", "us-east-1"))
    ap.add_argument("--account", default=os.environ.get("AWS_ACCOUNT_ID", "000000000000"))
    ap.add_argument("--stack", default="taxcalc-cost-dev",
                    help="stack whose template declares the budgets")
    ap.add_argument("--cfn-dir", default="cfn")
    ap.add_argument("--verbose", action="store_true")
    opts = ap.parse_args()

    if not opts.upstream:
        sys.exit("refusing: --upstream (or AWS_ENDPOINT_URL) is unset.\n"
                 "Against a real account both of these APIs exist, and shimming them "
                 "would replace true answers with projected ones.")

    httpd = HTTPServer(("127.0.0.1", opts.port), make_handler(opts))
    sys.stderr.write(
        f"floci-cost-apis-shim on http://127.0.0.1:{opts.port} -> {opts.upstream}\n"
        f"  GetResources     live per-service tag reads\n"
        f"  DescribeBudget   PROJECTED from {opts.cfn_dir}/{opts.stack}.yaml as deployed\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
