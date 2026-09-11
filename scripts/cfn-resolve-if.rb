#!/usr/bin/env ruby
#
# cfn-resolve-if.rb - collapse the `Fn::If` nodes that this endpoint's
# CloudFormation hands to the service unevaluated.
#
# WHY THIS EXISTS
# ---------------
# floci's CFN engine does not evaluate `Fn::If` when it appears as an ELEMENT
# OF A LIST rather than as the value of a property. Measured 2026-09-10 with a
# two-resource probe stack that isolates it to exactly that position:
#
#   SgPlain  SecurityGroupEgress: [ {IpProtocol,FromPort,ToPort,CidrIp} ]
#            -> CREATE_COMPLETE
#
#   SgIf     SecurityGroupEgress: [ {...CidrIp}, !If [C, {...SgId}, {...Cidr}] ]
#            -> CREATE_FAILED: "A security group rule must specify exactly one
#               of CidrIp, CidrIpv6, a prefix list, or a security group."
#
# The rejected rule has neither a CIDR nor a group id because it is still the
# literal mapping {"Fn::If" => [...]}; the intrinsic was never evaluated. Real
# CloudFormation evaluates it, which is why cfn-lint is clean and why
# cfn/taxcalc-network-dev.yaml is correct exactly as committed.
#
# This is the sole reason that stack rolls back on floci, and it is load
# bearing for the cost deliverable: the network and app stacks are where the
# four cost-allocation tags live, so while they cannot deploy,
# `resourcegroupstaggingapi get-resources --tag-filters Key=service` has
# nothing to find and the tag-coverage evidence cannot be taken at all.
#
# WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT
# -----------------------------------------------
# It evaluates the template's own `Conditions` from the parameter values it is
# given, and rewrites ONLY `Fn::If` nodes sitting in a list position - the one
# place floci gets wrong. Everything else is passed through untouched: `Ref`,
# `Fn::Sub`, `Fn::GetAtt`, `Fn::ImportValue`, resource-level `Condition:` keys,
# and `Fn::If` in ordinary property positions all still reach the engine
# unevaluated, because floci handles those correctly and doing their work here
# would hide it if that ever stopped being true.
#
# It is therefore NOT a template renderer and its output is NOT a second source
# of truth. The committed YAML remains the only reviewed artefact; this emits a
# throwaway JSON body for one emulator deploy. Anything deployed through it
# must say so when it is offered as evidence - see the banner it prints.
#
# Conditions are evaluated over parameters and pseudo-parameters only, which is
# the same information CloudFormation itself allows a condition to depend on.
# So this cannot take a branch the real engine would not have taken. A
# parameter with no override and no Default is left UNRESOLVED and the script
# refuses, rather than guessing a value and silently picking a branch.
#
# USAGE
#   ./scripts/cfn-resolve-if.rb cfn/taxcalc-network-dev.yaml EnvName=dev > rendered.json
#
# EXIT STATUS
#   0  rewrote at least one list-positioned Fn::If; JSON is on stdout
#   3  none found - this template does not need the shim, deploy it directly
#   2  refused (unresolvable condition, bad argument)
require 'yaml'
require 'json'

TAGS = %w[Sub GetAtt Ref Join Select Split ImportValue Cidr GetAZs If Equals
          Not And Or Base64 FindInMap Condition Transform Length ToJsonString].freeze
TAGS.each { |t| Psych.add_domain_type('', t) { |_, v| { "Fn::#{t}" => v } } }

# `Ref` and `Condition` are the two intrinsics with no `Fn::` prefix. Emitting
# {"Fn::Ref" => ...} would be silently wrong - CloudFormation treats an unknown
# key as a literal map, so the wrong spelling deploys a resource property whose
# value is the JSON of the intrinsic rather than failing.
def tag_to_key(tag)
  name = tag[1..]
  %w[Ref Condition].include?(name) ? name : "Fn::#{name}"
end

def to_ruby(node)
  case node
  when Psych::Nodes::Scalar
    if node.tag&.start_with?('!')
      v = node.value
      # !GetAtt A.B is sugar for {"Fn::GetAtt" => ["A","B"]}.
      v = v.split('.', 2) if node.tag[1..] == 'GetAtt'
      return { tag_to_key(node.tag) => v }
    end
    return node.value if node.quoted
    case node.value
    when /\A(true|false)\z/i then node.value.downcase == 'true'
    when /\A-?\d+\z/         then node.value.to_i
    when /\A~\z|\Anull\z/i   then nil
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

class Unresolvable < StandardError; end

# ---------------------------------------------------------------------------
# Condition evaluation. Only the operand forms that can legally appear inside a
# Conditions block are handled; anything else raises rather than being guessed.
def scalar(node, params, pseudo)
  return node unless node.is_a?(Hash)
  raise Unresolvable, "cannot evaluate #{node.inspect}" unless node.size == 1

  fn, arg = node.first
  case fn
  when 'Ref'
    return params[arg] if params.key?(arg)
    return pseudo[arg] if pseudo.key?(arg)

    raise Unresolvable, "Ref to #{arg}, which is not a parameter with a value"
  when 'Fn::Select' then scalar(arg[1], params, pseudo)[arg[0].to_i]
  when 'Fn::Join'   then arg[1].map { |i| scalar(i, params, pseudo).to_s }.join(arg[0].to_s)
  else raise Unresolvable, "cannot evaluate #{fn} outside the engine"
  end
end

def evaluate(expr, conditions, params, pseudo, seen = [])
  raise Unresolvable, "not a condition: #{expr.inspect}" unless expr.is_a?(Hash) && expr.size == 1

  fn, arg = expr.first
  case fn
  # CloudFormation compares Fn::Equals operands as strings.
  when 'Fn::Equals' then scalar(arg[0], params, pseudo).to_s == scalar(arg[1], params, pseudo).to_s
  when 'Fn::Not'    then !evaluate(arg[0], conditions, params, pseudo, seen)
  when 'Fn::And'    then arg.all? { |a| evaluate(a, conditions, params, pseudo, seen) }
  when 'Fn::Or'     then arg.any?  { |a| evaluate(a, conditions, params, pseudo, seen) }
  when 'Condition'
    raise Unresolvable, "condition cycle through #{arg}" if seen.include?(arg)
    raise Unresolvable, "undeclared condition #{arg}" unless conditions.key?(arg)

    evaluate(conditions[arg], conditions, params, pseudo, seen + [arg])
  else raise Unresolvable, "unsupported condition function #{fn}"
  end
end

# ---------------------------------------------------------------------------
# The rewrite. `in_list` is the whole point: an Fn::If is only collapsed when
# it is an element of a sequence, because that is the only position floci
# mishandles.
def resolve(node, conditions, params, pseudo, stats, in_list = false)
  case node
  when Array
    node.each_with_object([]) do |item, out|
      r = resolve(item, conditions, params, pseudo, stats, true)
      # {"Ref" => "AWS::NoValue"} in a list position means "drop this element".
      if r == { 'Ref' => 'AWS::NoValue' }
        stats[:omitted] += 1
        next
      end
      out << r
    end
  when Hash
    if in_list && node.size == 1 && node.key?('Fn::If')
      name, if_true, if_false = node['Fn::If']
      raise Unresolvable, "Fn::If names undeclared condition #{name}" unless conditions.key?(name)

      truthy = evaluate(conditions[name], conditions, params, pseudo)
      stats[:decisions] << [name, truthy]
      stats[:resolved] += 1
      # The chosen branch is still in the same list slot, so a nested Fn::If
      # there is also list-positioned and also needs collapsing.
      resolve(truthy ? if_true : if_false, conditions, params, pseudo, stats, true)
    else
      node.transform_values { |v| resolve(v, conditions, params, pseudo, stats, false) }
    end
  else
    node
  end
end

# ---------------------------------------------------------------------------
path = ARGV.shift
abort "usage: cfn-resolve-if.rb TEMPLATE [Key=Value ...]" if path.nil?

overrides = {}
ARGV.each do |pair|
  abort "refusing: parameter #{pair.inspect} is not Key=Value" unless pair.include?('=')

  k, v = pair.split('=', 2)
  overrides[k] = v
end

tpl = to_ruby(Psych.parse(File.read(path)))

# Overrides win; declared Defaults fill in. A parameter with neither is simply
# absent, and any condition that needs it makes the script refuse.
params = {}
(tpl['Parameters'] || {}).each do |name, spec|
  if overrides.key?(name)
    params[name] = overrides[name]
  elsif spec.is_a?(Hash) && spec.key?('Default')
    params[name] = spec['Default']
  end
end

pseudo = {
  'AWS::Region'     => overrides.fetch('AWS::Region', ENV.fetch('AWS_REGION', 'us-east-1')),
  'AWS::AccountId'  => overrides.fetch('AWS::AccountId', '000000000000'),
  'AWS::Partition'  => 'aws',
  'AWS::URLSuffix'  => 'amazonaws.com'
}

stats = { resolved: 0, omitted: 0, decisions: [] }
begin
  tpl['Resources'] = resolve(tpl['Resources'] || {}, tpl['Conditions'] || {}, params, pseudo, stats)
rescue Unresolvable => e
  warn "refusing: #{e.message}"
  exit 2
end

stats[:decisions].uniq.each do |name, truthy|
  warn "  resolved Fn::If [#{name}] -> #{truthy ? 'true' : 'false'} branch"
end
warn "  omitted #{stats[:omitted]} AWS::NoValue list element(s)" if stats[:omitted].positive?

if stats[:resolved].zero?
  warn 'no list-positioned Fn::If found; deploy the committed template directly'
  exit 3
end

warn "  #{stats[:resolved]} node(s) rewritten - this JSON is an EMULATOR-ONLY body,"
warn '  not a reviewed artefact; evidence taken from it must say so.'
puts JSON.pretty_generate(tpl)
