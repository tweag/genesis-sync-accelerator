output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.benchmark.id
}

output "public_ip" {
  description = "Public IP of the benchmark instance"
  value       = aws_instance.benchmark.public_ip
}

output "bucket_name" {
  description = "S3 bucket for chunk storage"
  value       = aws_s3_bucket.chunks.bucket
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -i <your-key.pem> ec2-user@${aws_instance.benchmark.public_ip}"
}

output "next_steps" {
  description = "What to do after terraform apply"
  value       = <<-EOT
    1. SSH in:  ssh -i <key.pem> ec2-user@${aws_instance.benchmark.public_ip}
    2. Wait:    while [ ! -f /data/.cloud-init-done ]; do sleep 5; done
    3. Build:   cd gsa && nix develop .#integration-test
    4. Phase 1: BUCKET=${aws_s3_bucket.chunks.bucket} bash test/benchmark/run-phase1.sh
    5. Validate: BUCKET=${aws_s3_bucket.chunks.bucket} bash test/benchmark/validate.sh
    6. Phase 2: BUCKET=${aws_s3_bucket.chunks.bucket} bash test/benchmark/run-phase2.sh
    7. Report:  BUCKET=${aws_s3_bucket.chunks.bucket} bash test/benchmark/report.sh
    8. Done:    exit, then: terraform destroy
  EOT
}
