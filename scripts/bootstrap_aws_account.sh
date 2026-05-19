#!/usr/bin/env bash
# Bootstrap an AWS account for f7i-gcp Terraform CI.
#
# Creates two resources Terraform itself cannot create (chicken-and-egg):
#   1. GitHub Actions OIDC provider (token.actions.githubusercontent.com)
#   2. IAM role `f7i-gcp-github-terraform` with AdministratorAccess,
#      trust policy matching terraform/github_actions_ci.tf
#
# Idempotent: safe to re-run; existing resources are detected and skipped.
# After this runs, terraform-prod.yml's import step picks the role up into TF
# state and TF manages it going forward.
#
# Usage:
#   AWS_PROFILE=... ./bootstrap_aws_account.sh
#   # or source an .env with AWS_ACCESS_KEY_ID / SECRET / SESSION_TOKEN first
#
# Requires: aws cli v2, admin creds in the target account (PowerUser is NOT enough).
set -euo pipefail

ROLE_NAME="f7i-gcp-github-terraform"
OIDC_URL="https://token.actions.githubusercontent.com"
OIDC_AUDIENCE="sts.amazonaws.com"
# GitHub Actions' OIDC IdP thumbprint — AWS now validates the cert chain
# against its own trust store, so this value is effectively unused, but the
# API still requires one. Using GitHub's documented value.
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"
REPO="f7i-ai/f7i-gcp"

log() { printf '[bootstrap] %s\n' "$*" >&2; }
die() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null || die "aws cli not found in PATH"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
log "Target account: ${ACCOUNT_ID}"
log "Caller:         ${CALLER_ARN}"

# ── 1. GitHub OIDC provider ──────────────────────────────────────────────────
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" >/dev/null 2>&1; then
  log "OIDC provider already exists: ${OIDC_ARN}"
else
  log "Creating GitHub OIDC provider..."
  aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --client-id-list "${OIDC_AUDIENCE}" \
    --thumbprint-list "${OIDC_THUMBPRINT}" >/dev/null
  log "OIDC provider created: ${OIDC_ARN}"
fi

# ── 2. IAM role ──────────────────────────────────────────────────────────────
# Trust policy mirrors terraform/github_actions_ci.tf — sts:AssumeRoleWithWebIdentity
# scoped to this repo's branches, PRs, and the terraform-apply-{dev,prod} GitHub
# Environments. Once TF imports the role, this trust policy is managed by TF.
TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GitHubOIDC",
      "Effect": "Allow",
      "Principal": { "Federated": "${OIDC_ARN}" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "${OIDC_AUDIENCE}"
        },
        "ForAnyValue:StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${REPO}:ref:refs/heads/dev",
            "repo:${REPO}:ref:refs/heads/main",
            "repo:${REPO}:pull_request",
            "repo:${REPO}:environment:terraform-apply-dev",
            "repo:${REPO}:environment:terraform-apply-prod"
          ]
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  log "Role already exists: ${ROLE_NAME} — updating trust policy to match."
  aws iam update-assume-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-document "${TRUST_POLICY}" >/dev/null
else
  log "Creating role ${ROLE_NAME}..."
  aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --assume-role-policy-document "${TRUST_POLICY}" \
    --description "Assumed by GitHub Actions OIDC for f7i-gcp Terraform applies." >/dev/null
  log "Role created."
fi

# AdministratorAccess attachment — matches github_actions_ci.tf:54-58.
# Bootstrap parity: TF expects this exact attachment on import.
ADMIN_POLICY_ARN="arn:aws:iam::aws:policy/AdministratorAccess"
if aws iam list-attached-role-policies --role-name "${ROLE_NAME}" \
    --query "AttachedPolicies[?PolicyArn=='${ADMIN_POLICY_ARN}'] | length(@)" \
    --output text | grep -q '^1$'; then
  log "AdministratorAccess already attached."
else
  log "Attaching AdministratorAccess..."
  aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${ADMIN_POLICY_ARN}"
fi

ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)
log "Done."
log ""
log "Role ARN:       ${ROLE_ARN}"
log "OIDC provider:  ${OIDC_ARN}"
log ""
log "Next: set AWS_ROLE_ARN_PROD (or the per-account equivalent) in the"
log "      f7i-gcp GitHub repo's terraform-apply-prod Environment vars to:"
log "      ${ROLE_ARN}"
