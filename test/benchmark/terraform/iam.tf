data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "benchmark" {
  name               = "${local.name_prefix}-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Project = "gsa-benchmark"
  }
}

data "aws_iam_policy_document" "s3_access" {
  statement {
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:HeadObject",
      "s3:HeadBucket",
    ]
    resources = [
      aws_s3_bucket.chunks.arn,
      "${aws_s3_bucket.chunks.arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "s3_access" {
  name   = "${local.name_prefix}-s3"
  role   = aws_iam_role.benchmark.id
  policy = data.aws_iam_policy_document.s3_access.json
}

resource "aws_iam_instance_profile" "benchmark" {
  name = "${local.name_prefix}-profile"
  role = aws_iam_role.benchmark.name
}
