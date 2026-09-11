#!/usr/bin/env ruby
#
# cfn-extract-cost.rb - read the cost stack's guardrails out of the templates
# and print them as the JSON the individual AWS APIs expect.
#
# Used by `cfn-guardrails.sh reconcile-cloudwatch` / `reconcile-tags` and by
# `floci-cost-apis-shim.py`, all three of which exist because floci accepts
# these properties, reports CREATE_COMPLETE, and then does not apply them:
#
#   TreatMissingData   accepted on AWS::CloudWatch::Alarm, reported back as
#                      `None` by describe-alarms. The one property that decides
#                      whether a gappy metric alarms correctly is the one that
#                      does not survive.
#   Tags               not applied to ANY resource type measured in this repo -
#                      EC2, RDS, SNS and IAM all come back with an empty tag
#                      set whatever the template declares.
#   AWS::Budgets::Budget
#                      accepted and given a plausible physical id by a CFN
#                      provider for a service floci does not run at all.
#
# Everything printed here is read FROM THE TEMPLATE, never typed into the
# script, for the same reason cfn-extract-s3.rb does it: a hand-maintained copy
# drifts silently, and a guardrail reconciled to an unreviewed value is worse
# than one that is simply missing, because it looks correct.
#
#   ARGV[0]  template path
#   ARGV[1]  JSON map of logical id -> physical id (from
#            describe-stack-resources), so `!Ref CostAlarmsTopic` resolves to
#            the live topic ARN. Pass {} if the stack is not deployed.
#   ARGV[2:] Key=Value parameter overrides; declared Defaults fill the rest.
#
# Output:
#   { "alarms":  { "<LogicalId>": {<put-metric-alarm arguments>} },
#     "budgets": [ {<DescribeBudget-shaped Budget + Notifications>} ],
#     "tags":    { "<LogicalId>": { "type": "...", "tags": [{Key,Value}] } } }
#
# An intrinsic this script cannot resolve is left in the output as a visible
# {"Fn::..."} object rather than being dropped or guessed, so it fails loudly
# at the API instead of being applied as something nobody chose.
require 'yaml'
require 'json'

TAGS = %w[Sub GetAtt Ref Join Select Split ImportValue Cidr GetAZs If Equals
          Not And Or Base64 FindInMap Condition].freeze
TAGS.each { |t| Psych.add_domain_type('', t) { |_, v| { "Fn::#{t}" => v } } }

def tag_to_key(tag)
  name = tag[1..]
  %w[Ref Condition].include?(name) ? name : "Fn::#{name}"
end

def to_ruby(node)
  case node
  when Psych::Nodes::Scalar
    if node.tag&.start_with?('!')
      v = node.value
      v = v.split('.', 2) if node.tag[1..] == 'GetAtt'
      return { tag_to_key(node.tag) => v }
    end
    return node.value if node.quoted

    case node.value
    when /\A(true|false)\z/i then node.value.downcase == 'true'
    when /\A-?\d+\z/         then node.value.to_i
    when /\A-?\d*\.\d+\z/    then node.value.to_f
    else node.value
    end
  when Psych::Nodes::Sequence
    v = node.children.map { |c| to_ruby(c) }
    node.tag&.start_with?('!') ? { tag_to_key(node.tag) => v } : v
  when Psych::Nodes::Mapping
    h = {}
    node.children.each_slice(2) { |k, v| h[to_ruby(k)] = to_ruby(v) }
    node.tag&.start_with?('!') ? { tag_to_key(node.tag) => h } : h
  else
    node.children ? to_ruby(node.children.first) : nil
  end
end

# ---------------------------------------------------------------------------
tpl      = to_ruby(Psych.parse(File.read(ARGV[0])))
physical = ARGV[1].nil? || ARGV[1].empty? ? {} : JSON.parse(ARGV[1])
over     = ARGV[2..].to_a.each_with_object({}) { |p, h| k, v = p.split('=', 2); h[k] = v }

params = {}
(tpl['Parameters'] || {}).each do |name, spec|
  if over.key?(name)
    # A Number parameter overridden on the command line arrives as a string;
    # BudgetLimit.Amount and Threshold must stay numeric for the APIs.
    raw = over[name]
    params[name] = spec.is_a?(Hash) && spec['Type'] == 'Number' ? (raw.include?('.') ? raw.to_f : raw.to_i) : raw
  elsif spec.is_a?(Hash) && spec.key?('Default')
    params[name] = spec['Default']
  end
end

PSEUDO = {
  'AWS::Region'    => ENV.fetch('AWS_REGION', 'us-east-1'),
  'AWS::AccountId' => ENV.fetch('AWS_ACCOUNT_ID', '000000000000'),
  'AWS::Partition' => 'aws',
  'AWS::StackName' => ENV.fetch('CFN_STACK_NAME', '')
}.freeze

# Live cross-stack exports, for Fn::ImportValue. Empty unless the caller
# supplies them, which keeps this usable on a template with no imports.
EXPORTS = begin
  JSON.parse(ENV.fetch('CFN_EXPORTS', '{}'))
rescue JSON::ParserError
  {}
end.freeze

# Resolve the intrinsics that actually occur in these properties, and nothing
# else. `Ref` to a resource resolves through the live physical-id map, which is
# how AlarmActions picks up the real SNS topic ARN rather than a logical name.
def resolve(node, params, physical)
  case node
  when Array then node.map { |n| resolve(n, params, physical) }
  when Hash
    if node.size == 1
      fn, arg = node.first
      case fn
      when 'Ref'
        key = arg
        return params[key] if params.key?(key)
        return PSEUDO[key] if PSEUDO.key?(key)
        return physical[key] if physical.key?(key)
      when 'Fn::Sub'
        return sub(arg, params, physical) if arg.is_a?(String)
      when 'Fn::GetAtt'
        # e.g. !GetAtt Topic.TopicName - only the physical id is knowable here.
        return physical[arg.first] if arg.is_a?(Array) && physical.key?(arg.first)
      when 'Fn::ImportValue'
        # Resolved through the LIVE export table (cloudformation list-exports),
        # passed in as CFN_EXPORTS. An unresolvable import is left as the node
        # rather than blanked, so a caller sees an unresolved intrinsic instead
        # of an empty string that looks like a legitimate value.
        return EXPORTS[arg] if arg.is_a?(String) && EXPORTS.key?(arg)
      end
    end
    node.transform_values { |v| resolve(v, params, physical) }
  else node
  end
end

def sub(str, params, physical)
  str.gsub(/\$\{([^}]+)\}/) do
    key = Regexp.last_match(1)
    if key.start_with?('!')            then "${#{key[1..]}}"  # ${!Literal}
    elsif params.key?(key)             then params[key].to_s
    elsif PSEUDO.key?(key)             then PSEUDO[key]
    elsif physical.key?(key)           then physical[key]
    elsif physical.key?(key.split('.').first) then physical[key.split('.').first]
    else "${#{key}}"                   # left visible rather than blanked
    end
  end
end

# ---------------------------------------------------------------------------
out = { 'alarms' => {}, 'budgets' => [], 'tags' => {}, 'cur' => [] }

(tpl['Resources'] || {}).each do |lid, res|
  type  = res['Type']
  props = resolve(res['Properties'] || {}, params, physical)

  case type
  when 'AWS::CloudWatch::Alarm'
    # Shaped for `aws cloudwatch put-metric-alarm --cli-input-json`. Only the
    # properties the template actually sets are emitted, so a re-PUT cannot
    # invent a setting that was never reviewed.
    a = {}
    {
      'AlarmName' => 'AlarmName', 'AlarmDescription' => 'AlarmDescription',
      'Namespace' => 'Namespace', 'MetricName' => 'MetricName',
      'Statistic' => 'Statistic', 'Period' => 'Period',
      'EvaluationPeriods' => 'EvaluationPeriods', 'Threshold' => 'Threshold',
      'ComparisonOperator' => 'ComparisonOperator',
      'TreatMissingData' => 'TreatMissingData', 'ActionsEnabled' => 'ActionsEnabled',
      'Unit' => 'Unit', 'DatapointsToAlarm' => 'DatapointsToAlarm'
    }.each { |k, v| a[v] = props[k] if props.key?(k) }
    a['Dimensions']  = props['Dimensions'] if props['Dimensions']
    a['AlarmActions'] = Array(props['AlarmActions']) if props['AlarmActions']
    a['OKActions']    = Array(props['OKActions'])    if props['OKActions']
    a['InsufficientDataActions'] = Array(props['InsufficientDataActions']) if props['InsufficientDataActions']
    out['alarms'][lid] = a

  when 'AWS::Budgets::Budget'
    b  = props['Budget'] || {}
    nf = props['NotificationsWithSubscribers'] || []
    # DescribeBudget's own response shape, so the shim can serve it verbatim.
    out['budgets'] << {
      'LogicalId' => lid,
      'Budget' => {
        'BudgetName'  => b['BudgetName'],
        'BudgetType'  => b['BudgetType'],
        'TimeUnit'    => b['TimeUnit'],
        'BudgetLimit' => b['BudgetLimit'] && {
          # The Budgets API returns Amount as a decimal STRING, not a number.
          'Amount' => b['BudgetLimit']['Amount'].to_s,
          'Unit'   => b['BudgetLimit']['Unit']
        },
        'CostFilters' => b['CostFilters'],
        'CostTypes'   => b['CostTypes']
      }.compact,
      'NotificationsWithSubscribers' => nf
    }

  when 'AWS::CUR::ReportDefinition'
    # Shaped for `aws cur put-report-definition --report-definition`, so the
    # reconcile can apply the template's own declaration verbatim rather than
    # a hand-written copy of it that drifts.
    out['cur'] << {
      'LogicalId' => lid,
      'ReportDefinition' => {
        'ReportName'               => props['ReportName'],
        'TimeUnit'                 => props['TimeUnit'],
        'Format'                   => props['Format'],
        'Compression'              => props['Compression'],
        'AdditionalSchemaElements' => props['AdditionalSchemaElements'] || [],
        'S3Bucket'                 => props['S3Bucket'],
        'S3Prefix'                 => props['S3Prefix'],
        'S3Region'                 => props['S3Region'],
        'AdditionalArtifacts'      => props['AdditionalArtifacts'],
        'RefreshClosedReports'     => props['RefreshClosedReports'],
        'ReportVersioning'         => props['ReportVersioning']
      }.compact
    }
  end

  # Tags, for every resource that declares them. `tags` is keyed by logical id
  # so the reconcile can map each set onto the right physical resource.
  next unless props['Tags'].is_a?(Array)

  out['tags'][lid] = {
    'type' => type,
    'tags' => props['Tags'].map { |t| { 'Key' => t['Key'], 'Value' => t['Value'].to_s } }
  }
end

puts JSON.pretty_generate(out)
