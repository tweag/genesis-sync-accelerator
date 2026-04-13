#!/usr/bin/env bash
#
# Tear down AWS resources created by provision.sh.
#
# Usage:
#   bash test/benchmark/teardown.sh [BUCKET_NAME]
#
# This will:
#   1. Empty and delete the S3 bucket
#   2. Remove the IAM instance profile, role, and inline policy
#
# It does NOT terminate the EC2 instance — do that manually or via the console.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
DATE_TAG="$(date +%Y%m%d)"
BUCKET="${1:-gsa-benchmark-mainnet-$DATE_TAG}"
ROLE_NAME="gsa-benchmark-role"
PROFILE_NAME="gsa-benchmark-profile"

echo "=== GSA Benchmark: Teardown ==="
echo "  Region:  $REGION"
echo "  Bucket:  $BUCKET"
echo ""

read -rp "This will DELETE the S3 bucket and all its contents. Continue? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
  echo "Aborted."
  exit 0
fi

# ── S3 bucket ───────────────────────────────────────────────────────────────

echo ""
echo "--- Removing S3 bucket ---"

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  Emptying bucket..."
  aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null || true
  echo "  Deleting bucket..."
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"
  echo "  Deleted bucket $BUCKET"
else
  echo "  Bucket $BUCKET does not exist (already deleted?)"
fi

# ── IAM ─────────────────────────────────────────────────────────────────────

echo ""
echo "--- Removing IAM resources ---"

# Remove role from instance profile.
if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE_NAME"
  echo "  Deleted instance profile $PROFILE_NAME"
else
  echo "  Instance profile $PROFILE_NAME not found"
fi

# Delete inline policy and role.
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "gsa-benchmark-s3" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE_NAME"
  echo "  Deleted role $ROLE_NAME"
else
  echo "  Role $ROLE_NAME not found"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "=== Teardown complete ==="
echo ""
echo "Remember to also:"
echo "  - Terminate the EC2 instance"
echo "  - Delete any EBS volumes"
echo "  - Remove any CloudFront distributions (if created)"
