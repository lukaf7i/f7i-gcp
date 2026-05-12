#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

ROOT = File.expand_path("../..", __dir__)
CONFIG = ENV.fetch("TERRAFORM_CONFIG") { File.join(ROOT, "config", "terraform-environments.yaml") }

def load_cfg
  abort "#{CONFIG}: file not found" unless File.file?(CONFIG)

  YAML.load_file(CONFIG).tap do |c|
    abort "#{CONFIG}: missing top-level 'environments'" unless c.is_a?(Hash) && c["environments"].is_a?(Hash)
  end
end

def find_env_by_git_branch(cfg, branch)
  cfg["environments"].each do |_name, env|
    next unless env.is_a?(Hash)

    return env if env["git_branch"] == branch
  end
  nil
end

def append_github_env(lines)
  path = ENV["GITHUB_ENV"]
  return if path.nil? || path.empty?

  File.open(path, "a") { |f| lines.each { |l| f.puts l } }
end

cfg = load_cfg

case ARGV[0]
when "gcp-resolve"
  branch = ARGV[1] or abort("usage: terraform-from-config.rb gcp-resolve <git_branch>")

  env = find_env_by_git_branch(cfg, branch)
  abort "#{CONFIG}: no environment with git_branch=#{branch.inspect}" unless env

  gcp = env["gcp"] || {}
  %w[project_id state_bucket].each do |k|
    abort "#{CONFIG}: missing gcp.#{k} for git_branch=#{branch.inspect}" if gcp[k].to_s.strip.empty?
  end

  tf_env = env["tf_environment"].to_s
  abort "#{CONFIG}: missing tf_environment for git_branch=#{branch.inspect}" if tf_env.empty?

  append_github_env(
    [
      "TF_ENV=#{tf_env}",
      "TF_VAR_project_id=#{gcp['project_id']}",
      "TF_VAR_environment=#{tf_env}",
      "GCP_TF_STATE_BUCKET=#{gcp['state_bucket']}"
    ]
  )

when "gcp-state-bucket"
  branch = ARGV[1] or abort("usage: terraform-from-config.rb gcp-state-bucket <git_branch>")

  env = find_env_by_git_branch(cfg, branch)
  abort "#{CONFIG}: no environment with git_branch=#{branch.inspect}" unless env

  gcp = env["gcp"] || {}
  bucket = gcp["state_bucket"].to_s
  abort "#{CONFIG}: missing gcp.state_bucket for git_branch=#{branch.inspect}" if bucket.empty?

  print bucket

when "aws-prod-matrix"
  rows = cfg.dig("aws", "prod_terraform_matrix")
  abort "#{CONFIG}: aws.prod_terraform_matrix must be a non-empty array" unless rows.is_a?(Array) && !rows.empty?

  rows.each do |r|
    abort "#{CONFIG}: matrix row missing key" if r["key"].to_s.strip.empty?
    abort "#{CONFIG}: matrix row missing role_arn" if r["role_arn"].to_s.strip.empty?
  end

  print JSON.generate("include" => rows)

when "aws-dev-role"
  dev = cfg.dig("environments", "dev")
  abort "#{CONFIG}: missing environments.dev" unless dev.is_a?(Hash)

  from_yaml = dev.dig("aws", "role_arn").to_s.strip
  role = from_yaml.empty? ? ENV["AWS_ROLE_ARN_DEV"].to_s.strip : from_yaml
  abort "#{CONFIG}: set environments.dev.aws.role_arn or GitHub variable AWS_ROLE_ARN_DEV" if role.empty?

  print role

else
  warn "usage:"
  warn "  terraform-from-config.rb gcp-resolve <git_branch>"
  warn "  terraform-from-config.rb gcp-state-bucket <git_branch>"
  warn "  terraform-from-config.rb aws-prod-matrix"
  warn "  terraform-from-config.rb aws-dev-role"
  exit 64
end
