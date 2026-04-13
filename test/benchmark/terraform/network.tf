# Use the default VPC — no need for custom networking for a benchmark.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

resource "aws_security_group" "benchmark" {
  name        = "${local.name_prefix}-sg"
  description = "GSA benchmark: SSH in, all out"
  vpc_id      = data.aws_vpc.default.id

  tags = {
    Project = "gsa-benchmark"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.benchmark.id
  description       = "SSH from operator"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.ssh_cidr
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.benchmark.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}
