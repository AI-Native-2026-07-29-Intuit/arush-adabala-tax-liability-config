#!/usr/bin/env ruby
#
# cfn-extract-s3.rb - read the three S3 hardening settings out of a
# CloudFormation template and print them as the JSON the S3 API expects.
#
# Used by `cfn-guardrails.sh reconcile-s3`, which exists because floci's
# CloudFormation provider for S3 ACCEPTS PublicAccessBlockConfiguration,
# BucketEncryption and AWS::S3::BucketPolicy, reports CREATE_COMPLETE, and
# then never applies any of them to its own S3 backend. floci's S3 stores all
# three correctly when they arrive over the S3 API - measured - so the gap is
# in the CFN-to-S3 wiring, not in S3.
#
# The values are read FROM THE TEMPLATE rather than typed into the script, so
# what gets applied is the template's own configuration. A hand-maintained
# copy would drift from the template silently, which would make the reconcile
# worse than useless: the bucket would look hardened and be hardened to
# something nobody reviewed.
#
# Only the intrinsics that actually occur inside these three properties are
# resolved - !GetAtt <Bucket>.Arn and !Sub "${<Bucket>.Arn}/*". Anything else
# is passed through untouched, so an unhandled intrinsic shows up as a visible
# {"Fn::..."} object in the output and fails loudly at the S3 API rather than
# being silently applied as a wrong value.
#
# ARGV[0] = template path, ARGV[1] = physical bucket name
require 'yaml'
require 'json'

TAGS = %w[Sub GetAtt Ref Join Select Split ImportValue Cidr GetAZs If Equals Not And Or Base64 FindInMap Condition]
TAGS.each do |t|
  Psych.add_domain_type('', t) { |_, v| { "Fn::#{t}" => v } }
end

def to_ruby(node)
  case node
  when Psych::Nodes::Scalar
    return { "Fn::#{node.tag[1..]}" => node.value } if node.tag&.start_with?('!')
    # Unquoted true/false/integers must survive as real JSON types - the S3
    # API rejects "true" as a string for PublicAccessBlockConfiguration.
    return node.value if node.quoted
    case node.value
    when /\A(true|false)\z/i then node.value.downcase == 'true'
    when /\A-?\d+\z/         then node.value.to_i
    else node.value
    end
  when Psych::Nodes::Sequence
    v = node.children.map { |c| to_ruby(c) }
    node.tag&.start_with?('!') ? { "Fn::#{node.tag[1..]}" => v } : v
  when Psych::Nodes::Mapping
    h = {}
    node.children.each_slice(2) { |k, v| h[to_ruby(k)] = to_ruby(v) }
    node.tag&.start_with?('!') ? { "Fn::#{node.tag[1..]}" => h } : h
  else
    node.children ? to_ruby(node.children.first) : nil
  end
end

tpl    = to_ruby(Psych.parse(File.read(ARGV[0])))
bucket = ARGV[1]
arn    = "arn:aws:s3:::#{bucket}"

# Resolve only the intrinsics that actually occur inside these properties:
# !GetAtt <Bucket>.Arn and !Sub "${<Bucket>.Arn}/*". Anything else is left
# alone and will surface as a visible non-string rather than a wrong value.
def resolve(o, arn)
  case o
  when Hash
    if o.size == 1
      k, v = o.first
      case k
      when 'Fn::GetAtt'
        parts = v.is_a?(String) ? v.split('.') : v
        return arn if parts.last == 'Arn'
      when 'Fn::Sub'
        return v.gsub(/\$\{[A-Za-z0-9:]+\.Arn\}/, arn) if v.is_a?(String)
      end
    end
    o.transform_values { |x| resolve(x, arn) }
  when Array then o.map { |x| resolve(x, arn) }
  else o
  end
end

res    = tpl['Resources'] || {}
bkt    = res.values.find { |r| r['Type'] == 'AWS::S3::Bucket' } || {}
pol    = res.values.find { |r| r['Type'] == 'AWS::S3::BucketPolicy' } || {}
props  = bkt['Properties'] || {}

# CloudFormation and the S3 API disagree on one key name: the template says
# ServerSideEncryptionByDefault, PutBucketEncryption wants
# ApplyServerSideEncryptionByDefault. Emit the API spelling, and emit the
# rules under the "Rules" wrapper the API expects, so the caller can pass the
# value through unchanged.
sse = props['BucketEncryption']
if sse.is_a?(Hash) && sse['ServerSideEncryptionConfiguration'].is_a?(Array)
  sse = { 'Rules' => sse['ServerSideEncryptionConfiguration'].map { |r|
    r.each_with_object({}) do |(k, v), h|
      h[k == 'ServerSideEncryptionByDefault' ? 'ApplyServerSideEncryptionByDefault' : k] = v
    end
  } }
end

out = {
  'pab'    => props['PublicAccessBlockConfiguration'],
  'sse'    => sse,
  'policy' => resolve((pol['Properties'] || {})['PolicyDocument'], arn)
}
puts JSON.pretty_generate(out)
