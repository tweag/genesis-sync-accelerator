resource "aws_s3_bucket" "chunks" {
  bucket        = local.bucket_name
  force_destroy = true # Allow terraform destroy to remove non-empty bucket.

  tags = {
    Project = "gsa-benchmark"
    Network = var.network
  }
}

resource "aws_s3_bucket_public_access_block" "chunks" {
  bucket = aws_s3_bucket.chunks.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "chunks" {
  bucket = aws_s3_bucket.chunks.id

  rule {
    id     = "auto-expire-30d"
    status = "Enabled"

    expiration {
      days = 30
    }
  }
}
