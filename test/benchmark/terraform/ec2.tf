resource "aws_instance" "benchmark" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  key_name               = var.ssh_key_name
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.benchmark.id]
  iam_instance_profile   = aws_iam_instance_profile.benchmark.name

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    bucket_name   = local.bucket_name
    region        = var.region
    network       = var.network
    instance_type = var.instance_type
    repo_url      = var.repo_url
    repo_branch   = var.repo_branch
  })

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  tags = {
    Name    = "${local.name_prefix}-${var.network}"
    Project = "gsa-benchmark"
    Network = var.network
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = aws_instance.benchmark.availability_zone
  size              = var.volume_size_gb
  type              = "gp3"
  iops              = var.volume_iops
  throughput        = var.volume_throughput

  tags = {
    Name    = "${local.name_prefix}-data"
    Project = "gsa-benchmark"
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.benchmark.id
}
