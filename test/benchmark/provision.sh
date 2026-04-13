#!/usr/bin/env bash
#
# Provision AWS resources for the GSA benchmark.
#
# Creates an S3 bucket and an IAM role/instance profile that the EC2 instance
# will use to access S3. Run this from your local machine before launching
# the instance.
#
# Usage:
#   bash test/benchmark/provision.sh [BUCKET_NAME]
#
# Requirements:
#   - AWS CLI configured with sufficient IAM permissions
#   - jq

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
DATE_TAG="$(date +%Y%m%d)"
BUCKET="${1:-gsa-benchmark-mainnet-$DATE_TAG}"
ROLE_NAME="gsa-benchmark-role"
PROFILE_NAME="gsa-benchmark-profile"

echo "=== GSA Benchmark: Provision AWS Resources ==="
echo "  Region:  $REGION"
echo "  Bucket:  $BUCKET"
echo ""

# ── S3 bucket ───────────────────────────────────────────────────────────────

echo "--- Creating S3 bucket ---"

if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "  Bucket $BUCKET already exists"
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
  echo "  Created bucket $BUCKET"
fi

# Block public access.
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
echo "  Public access blocked"

# 30-day lifecycle rule for auto-cleanup.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "auto-expire-30d",
      "Status": "Enabled",
      "Filter": {"Prefix": ""},
      "Expiration": {"Days": 30}
    }]
  }'
echo "  30-day lifecycle rule set"

# ── IAM role + instance profile ─────────────────────────────────────────────

echo ""
echo "--- Creating IAM role ---"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "  Role $ROLE_NAME already exists"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "GSA benchmark: S3 access for chunk-uploader and GSA" \
    >/dev/null
  echo "  Created role $ROLE_NAME"
fi

# Inline policy granting S3 access to the benchmark bucket.
S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:HeadObject",
      "s3:HeadBucket"
    ],
    "Resource": [
      "arn:aws:s3:::${BUCKET}",
      "arn:aws:s3:::${BUCKET}/*"
    ]
  }]
}
EOF
)

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "gsa-benchmark-s3" \
  --policy-document "$S3_POLICY"
echo "  Attached S3 policy"

echo ""
echo "--- Creating instance profile ---"

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "  Instance profile $PROFILE_NAME already exists"
else
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME"
  echo "  Created instance profile $PROFILE_NAME with role $ROLE_NAME"
  echo "  (Wait ~10s for propagation before launching an instance)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "=== Provisioning complete ==="
echo ""
echo "Resources created:"
echo "  S3 bucket:         $BUCKET"
echo "  IAM role:          $ROLE_NAME"
echo "  Instance profile:  $PROFILE_NAME"
echo ""
echo "Next: launch an EC2 instance (r6i.2xlarge recommended) with:"
echo "  - Instance profile: $PROFILE_NAME"
echo "  - A 500 GB gp3 EBS volume (6000 IOPS, 400 MB/s) attached as /dev/sdf"
echo "  - Security group: all outbound, SSH inbound"
echo "  - Region: $REGION"
echo ""
echo "Then SSH in and run:"
echo "  BUCKET=$BUCKET bash test/benchmark/setup-instance.sh"
