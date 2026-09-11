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

THE COST EXPLORER HALF IS WEAKER STILL - READ THIS BEFORE QUOTING A FIGURE
--------------------------------------------------------------------------
GetCostAndUsage and GetTags were added for W6 D4 Task 4, whose Done-When asks
for a Cost Explorer drill-down grouped by the `service` tag with the NAT
gateway line item visible. floci DOES run a `ce` service and it answers the
API with the correct SHAPE - and every amount is 0.0000000000, every tag group
key is "", and GetTags returns {"Tags": [], "TotalSize": 0}.

That is not a gap a later floci version closes. AN EMULATOR BILLS NOBODY.
There is no spend to report and no cost-allocation tag activated, because
activation is a Billing-console action against an account that is being
invoiced. Unlike the budgets gap - a provider bug, fixable - this one is
structural.

So this half does NOT read cost. It PROJECTS what the live, deployed, tagged
resources would bill over a STEADY-STATE MONTH at published list price. Two
inputs, worth two different things:

  live       which resources exist, their instance class, their storage type
             and size, and their tags - all read from floci at request time.
             Untag or delete a resource and the projection changes.
  list price PRICEBOOK below. A hand-maintained table, dated, us-east-1 only.
             Stale prices produce confidently wrong money.

A steady-state month (730h for everything) and NOT month-to-date. The
month-to-date version was written first and withdrawn: floci returns a real
CreateTime for a NAT gateway, null for an RDS instance and nothing at all for
an EIP, so resources without a timestamp fell back to the month start and were
billed ~245h against the NAT's ~4.5h. That rendered the NAT gateway - the line
item this exists to look at - as the SMALLEST row in the table. A uniform
stated basis cannot be wrong in that direction.

TWO THINGS IT REFUSES TO GUESS, and both are reported as zero with a reason:

  *-NatGateway-Bytes         the emulator moves no bytes through a gateway, so
                             there is no volume to price. A made-up GiB figure
                             would be the number here most likely to be quoted
                             at somebody.
  *-ElasticIP:IdleAddress    describe-addresses returns neither AssociationId
                             nor NetworkInterfaceId for an EIP that IS attached
                             to a live NAT, so attached and detached are
                             indistinguishable here. Reading "no association
                             field" as detached invented a $1.22 charge against
                             an attached address. The detached case is the one
                             the taxonomy tags EIPs FOR, and it is the one this
                             engine cannot see: a GAP to report, not a number.

Read the output as "what this shape of infrastructure costs at list price",
never as "what was spent". No dollar figure from this shim has ever been on an
invoice.

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
import datetime
import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

BUDGETS_PREFIX = "AWSBudgetServiceGateway"
TAGGING_PREFIX = "ResourceGroupsTaggingAPI_20170126"
CLOUDWATCH_PREFIX = "GraniteServiceVersion20100801"
CE_PREFIX = "AWSInsightsIndexService"

# --- The price book. -------------------------------------------------------
# us-east-1 on-demand list price, USD. THIS IS THE HIGHEST-MAINTENANCE THING
# IN THIS FILE, for exactly the reason COST.md gives for the LLM PriceBook: a
# stale rate makes every figure wrong while nothing fails. The arithmetic
# stays correct, the response stays well-formed, and the number simply is not
# what an invoice would say. Nothing here can detect that.
#
# NO LONGER RE-CHECKED BY HAND. scripts/pricebook-verify.sh compares every rate
# below against AWS's own published price list - the Price List Bulk API is
# public and UNAUTHENTICATED, so it works with no account - and fails on drift.
#
# It found two wrong rates on its first run, both hand-typed and both silent:
#   rds_storage_gb_month.gp3   0.08  -> 0.115   (0.08 is the EBS gp3 rate; RDS
#                                                gp3 is priced like gp2 here)
#   rds_instance_hour.m6g.large 0.171 -> 0.159
# Neither would ever have failed a test. That is the whole argument for the
# gate: this table's failure mode is confident, well-formed, wrong money.
PRICEBOOK_DATE = "2026-09-11"
PRICEBOOK_REGION = "us-east-1"
PRICEBOOK = {
    "nat_gateway_hour": 0.045,
    # Charged per GB processed, on top of the hourly rate. Deliberately unused
    # for a volume: see the docstring. Kept so the rate is documented where
    # anyone reading the zero will look for it.
    "nat_gateway_gb": 0.045,
    # An EIP costs nothing while attached and ~$0.005/h detached. That gap is
    # why the taxonomy tags EIPs at all.
    "eip_idle_hour": 0.005,
    "rds_instance_hour": {
        "db.t4g.micro": 0.016, "db.t4g.small": 0.032,
        "db.t4g.medium": 0.065, "db.m6g.large": 0.159,
    },
    # gp3 is NOT cheaper than gp2 for RDS in us-east-1, unlike EBS. Verified.
    "rds_storage_gb_month": {"gp2": 0.115, "gp3": 0.115},
    "s3_storage_gb_month": 0.023,
}

PROVENANCE_CE = (
    "PROJECTED AT LIST PRICE from live deployed resources - NOT read cost. "
    f"floci bills nobody: its own ce returns all-zero amounts and no activated "
    f"tag keys. Prices are {PRICEBOOK_REGION} list as of {PRICEBOOK_DATE}. "
    "No figure here has ever been on an invoice."
)

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


def _same_number(a, b):
    try:
        return abs(float(a) - float(b)) < 1e-9
    except (TypeError, ValueError):
        return a == b


def describe_subscribers(body, region, endpoint, cfn_dir, stack):
    """The call that actually proves a notification points AT THE SNS TOPIC.

    DescribeBudget and DescribeNotificationsForBudget both omit subscribers, so
    neither can answer the Done-When's "two notifications wired to the SNS
    topic" - they show the thresholds and stop. This is the modelled call that
    carries the Address, which is why the task's evidence needs it.

    The thresholds here are projected from the template like every other budget
    field. The ADDRESS IS NOT: it is the physical id CloudFormation assigned to
    the topic, read live from describe-stack-resources, and it is cross-checked
    against `sns list-topics` before being returned. A subscriber pointing at a
    topic that does not exist is the single most likely way this wiring is
    wrong in practice, and it is the one part of the budget an emulator can
    still refute.
    """
    name = body.get("BudgetName")
    want = body.get("Notification") or {}
    try:
        found = budgets_from_stack(stack, region, endpoint, cfn_dir) or []
    except UpstreamError as exc:
        return 500, {"__type": "InternalFailure", "message": str(exc)}

    live_topics = {t["TopicArn"] for t in
                   (aws("sns", "list-topics", region=region, endpoint=endpoint) or {}).get("Topics", [])}

    for entry in found:
        if entry["Budget"].get("BudgetName") != name:
            continue
        for pair in entry.get("NotificationsWithSubscribers", []):
            got = pair.get("Notification", {})
            # Compare the threshold NUMERICALLY. The template carries 80 and
            # botocore sends 80.0 (the model types Threshold as a double), so a
            # string compare misses every real match.
            if want and (got.get("NotificationType") != want.get("NotificationType")
                         or not _same_number(got.get("Threshold"), want.get("Threshold"))):
                continue
            subs = pair.get("Subscribers", [])
            # An Address that is not a string is an intrinsic the extractor
            # could not resolve - {"Ref": "SomeTopic"} when the logical id is
            # not in the deployed stack. Found by the negative control, which
            # crashed here with a TypeError before this line existed. A crash
            # is not a refusal: it reads as "the shim is broken" when the
            # actual finding is "this budget cannot notify anybody".
            unresolved = [s.get("Address") for s in subs
                          if s.get("SubscriptionType") == "SNS"
                          and (not isinstance(s.get("Address"), str)
                               or s["Address"] not in live_topics)]
            if unresolved:
                # Louder than a quiet pass. A subscriber aimed at a topic that
                # is not there is a budget that cannot notify, and that is a
                # real failure the emulator CAN see.
                return 400, {"__type": "NotFoundException",
                             "message": f"subscriber topic(s) not present on this endpoint: {unresolved}"}
            return 200, {"Subscribers": subs, "ShimProvenance": PROVENANCE_BUDGETS}
        return 400, {"__type": "NotFoundException",
                     "message": f"no notification matching {want} on budget {name}"}
    return 400, {"__type": "NotFoundException", "message": f"budget {name} is not declared by stack {stack}"}


# ---------------------------------------------------------------------------
# Cost Explorer, PROJECTED. Read the docstring before quoting any figure.
def _month_bounds(time_period):
    """(start, end, now) as naive UTC datetimes, defaulting to this month."""
    now = datetime.datetime.utcnow()
    start = datetime.datetime(now.year, now.month, 1)
    end = (datetime.datetime(now.year + (now.month == 12), (now.month % 12) + 1, 1))
    if time_period:
        try:
            start = datetime.datetime.strptime(time_period["Start"], "%Y-%m-%d")
            end = datetime.datetime.strptime(time_period["End"], "%Y-%m-%d")
        except (KeyError, ValueError):
            pass
    return start, end, now


# A FULL MONTH, for every hourly resource, always. This is a steady-state
# monthly projection - "what does this shape of infrastructure cost to run for
# a month at list price" - and NOT a month-to-date view.
#
# The first version did compute month-to-date from each resource's real
# creation timestamp, and it had to be abandoned because floci supplies that
# timestamp inconsistently: describe-nat-gateways returns a real CreateTime,
# describe-db-instances returns InstanceCreateTime: null, and
# describe-addresses returns no creation time at all. Resources with no
# timestamp fell back to the month start and were charged ~245 hours while the
# NAT was charged ~4.5, which rendered THE NAT GATEWAY - the line item this
# whole exercise exists to look at - as the smallest row in the table.
#
# That is worse than useless: it is a plausible-looking table that inverts the
# finding. A uniform, stated basis cannot be subtly wrong in that way, and it
# is also the basis the Budget's own $100 limit was derived on and the basis
# the 1-NAT-vs-3 comparison needs.
HOURS_PER_MONTH = 730


def project_line_items(region, endpoint, account):
    """One row per (service, usage type, tagged resource), at list price.

    Every structural fact - which resources exist, their class, their storage,
    their tags, when they were created - is read live. Only the RATE comes from
    the price book, and only the elapsed hours are computed.
    """
    rows = []
    tagged = collect_tagged_resources(region, endpoint, account)

    def tags_for(*candidates):
        for arn in candidates:
            if arn in tagged:
                return {t["Key"]: t.get("Value", "") for t in tagged[arn]}
        return {}

    # --- NAT gateways. The line item the Done-When asks for by name.
    for nat in (aws("ec2", "describe-nat-gateways", region=region, endpoint=endpoint) or {}).get("NatGateways", []):
        nid = nat.get("NatGatewayId", "")
        tags = {t["Key"]: t.get("Value", "") for t in nat.get("Tags", [])} or tags_for(
            _arn("ec2", f"natgateway/{nid}", account, region), _arn("ec2", f"nat-gateway/{nid}", account, region))
        rows.append({"service": "EC2 - Other", "usage_type": "USE1-NatGateway-Hours",
                     "resource": nid, "tags": tags, "qty": HOURS_PER_MONTH, "unit": "Hrs",
                     "amount": HOURS_PER_MONTH * PRICEBOOK["nat_gateway_hour"]})
        # Emitted at zero ON PURPOSE - see the docstring. The line item has to
        # be visible (it is half the answer to "find the NAT line item"), and
        # its value has to not be fiction.
        rows.append({"service": "EC2 - Other", "usage_type": "USE1-NatGateway-Bytes",
                     "resource": nid, "tags": tags, "qty": 0.0, "unit": "GB",
                     "amount": 0.0, "note": "no traffic observable: the emulator moves no bytes"})

    # --- Elastic IPs. Reported at ZERO, with the reason attached.
    #
    # An EIP is free while attached and ~$3.65/mo while detached, and the
    # detached case is the entire reason the taxonomy tags EIPs at all. This
    # endpoint cannot tell the two apart: describe-addresses returns neither
    # AssociationId nor NetworkInterfaceId for an EIP that IS attached to a
    # live NAT gateway (measured 2026-09-10). Treating "no association field"
    # as detached invented a $1.22 charge against a resource that is attached.
    #
    # So the line item is emitted, and its value is zero, and the note says
    # the state could not be observed. The one case worth catching is the one
    # case this engine cannot see, and that is a GAP to report - not a number
    # to guess.
    for addr in (aws("ec2", "describe-addresses", region=region, endpoint=endpoint) or {}).get("Addresses", []):
        pub = addr.get("PublicIp", "")
        observable = "AssociationId" in addr or "NetworkInterfaceId" in addr
        attached = bool(addr.get("AssociationId") or addr.get("NetworkInterfaceId"))
        tags = {t["Key"]: t.get("Value", "") for t in addr.get("Tags", [])} or tags_for(
            _arn("ec2", f"elastic-ip/{pub}", account, region))
        hours = HOURS_PER_MONTH if (observable and not attached) else 0.0
        note = ("attached: no charge" if attached else
                "DETACHED and billing" if observable else
                "attachment state NOT reported by this endpoint - "
                "reported as 0; a detached EIP would bill ~$3.65/mo")
        rows.append({"service": "EC2 - Other", "usage_type": "USE1-ElasticIP:IdleAddress",
                     "resource": pub, "tags": tags, "qty": hours, "unit": "Hrs",
                     "amount": hours * PRICEBOOK["eip_idle_hour"], "note": note})

    # --- RDS. Class and storage are read live, not taken from the template,
    # because the deployed value is the one that bills.
    for db in (aws("rds", "describe-db-instances", region=region, endpoint=endpoint) or {}).get("DBInstances", []):
        arn = db.get("DBInstanceArn") or _arn("rds", f"db:{db['DBInstanceIdentifier']}", account, region)
        klass = db.get("DBInstanceClass", "")
        rate = PRICEBOOK["rds_instance_hour"].get(klass)
        tags = tags_for(arn)
        rows.append({"service": "Amazon Relational Database Service",
                     "usage_type": f"USE1-InstanceUsage:{klass}", "resource": db["DBInstanceIdentifier"],
                     "tags": tags, "qty": HOURS_PER_MONTH, "unit": "Hrs",
                     "amount": (HOURS_PER_MONTH * rate) if rate else 0.0,
                     # A class absent from the price book reports 0 and says so,
                     # rather than picking a neighbouring rate. A wrong number
                     # that looks right is the failure mode here.
                     "note": None if rate else f"no list price for {klass} in PRICEBOOK - reported as 0"})
        stype = (db.get("StorageType") or "gp3").lower()
        gb = float(db.get("AllocatedStorage") or 0)
        srate = PRICEBOOK["rds_storage_gb_month"].get(stype, 0.0)
        rows.append({"service": "Amazon Relational Database Service",
                     "usage_type": f"USE1-RDS:{stype.upper()}-Storage", "resource": db["DBInstanceIdentifier"],
                     "tags": tags, "qty": gb, "unit": "GB-Mo", "amount": gb * srate})

    return rows


def _group_key(row, definition):
    gtype, key = definition.get("Type"), definition.get("Key")
    if gtype == "TAG":
        value = row["tags"].get(key)
        # Real Cost Explorer renders an untagged resource as `key$` with an
        # empty value, and that row is the whole point of a tag-scoped view:
        # it is the spend the Budget cannot see.
        return f"{key}${value}" if value else f"{key}$"
    if key == "SERVICE":
        return row["service"]
    if key == "USAGE_TYPE":
        return row["usage_type"]
    if key == "RESOURCE_ID":
        return row["resource"]
    return row["service"]


def _money(value):
    return f"{value:.10f}"


def get_cost_and_usage(body, region, endpoint, account):
    start, end, now = _month_bounds(body.get("TimePeriod"))
    groups_def = body.get("GroupBy") or []
    rows = project_line_items(region, endpoint, account)

    tag_filter = ((body.get("Filter") or {}).get("Tags") or {})
    if tag_filter.get("Key"):
        want = set(tag_filter.get("Values") or [])
        rows = [r for r in rows if r["tags"].get(tag_filter["Key"]) in want]

    total = sum(r["amount"] for r in rows)
    buckets = {}
    for row in rows:
        key = tuple(_group_key(row, d) for d in groups_def) if groups_def else ()
        buckets.setdefault(key, 0.0)
        buckets[key] += row["amount"]

    grouped = [{"Keys": list(k), "Metrics": {"UnblendedCost": {"Amount": _money(v), "Unit": "USD"}}}
               for k, v in sorted(buckets.items())] if groups_def else []

    return 200, {
        "GroupDefinitions": groups_def,
        "ResultsByTime": [{
            "TimePeriod": {"Start": start.strftime("%Y-%m-%d"), "End": end.strftime("%Y-%m-%d")},
            "Total": {} if groups_def else {"UnblendedCost": {"Amount": _money(total), "Unit": "USD"}},
            "Groups": grouped,
            "Estimated": True,
        }],
        "DimensionValueAttributes": [],
        "ShimProvenance": PROVENANCE_CE,
    }


def get_tags(body, region, endpoint, account):
    """The cost-allocation tag keys/values actually present on billable things.

    NOT the same as "activated". Activation is a Billing-console action on an
    account being invoiced, it does not backfill, and nothing on this endpoint
    can perform or observe it. This answers the weaker question the emulator
    can answer: would a group-by on this key have anything to group?
    """
    start, end, now = _month_bounds(body.get("TimePeriod"))
    rows = project_line_items(region, endpoint, account)
    key = body.get("TagKey")
    if key:
        values = sorted({r["tags"][key] for r in rows if r["tags"].get(key)})
    else:
        values = sorted({k for r in rows for k in r["tags"]})
    return 200, {"Tags": values, "ReturnSize": len(values), "TotalSize": len(values),
                 "ShimProvenance": PROVENANCE_CE}


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
                            "DescribeNotificationsForBudget": describe_notifications,
                            "DescribeSubscribersForNotification": describe_subscribers}
                if op in handlers:
                    status, payload = handlers[op](body, *common, opts.cfn_dir, opts.stack)
                    return self._reply(status, payload)
            elif prefix == CE_PREFIX:
                handlers = {"GetCostAndUsage": get_cost_and_usage, "GetTags": get_tags}
                if op in handlers:
                    status, payload = handlers[op](body, *common, opts.account)
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
