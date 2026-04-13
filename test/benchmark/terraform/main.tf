terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Latest Amazon Linux 2023 AMI.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Random suffix for globally-unique bucket name.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.bucket_prefix}-${var.network}-${random_id.bucket_suffix.hex}"
  name_prefix = "gsa-benchmark"
}
