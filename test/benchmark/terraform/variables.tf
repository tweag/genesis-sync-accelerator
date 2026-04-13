variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type (r6i.2xlarge for mainnet, r6i.large for preprod)"
  type        = string
  default     = "r6i.2xlarge"
}

variable "volume_size_gb" {
  description = "Data EBS volume size in GB"
  type        = number
  default     = 500
}

variable "volume_iops" {
  description = "gp3 IOPS for data volume"
  type        = number
  default     = 6000
}

variable "volume_throughput" {
  description = "gp3 throughput in MB/s for data volume"
  type        = number
  default     = 400
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "ssh_cidr" {
  description = "CIDR block allowed to SSH in (e.g. 1.2.3.4/32)"
  type        = string
}

variable "repo_url" {
  description = "Git repository URL to clone on the instance"
  type        = string
  default     = "https://github.com/tweag/gsa.git"
}

variable "repo_branch" {
  description = "Git branch to check out"
  type        = string
  default     = "tf-benchmarking"
}

variable "bucket_prefix" {
  description = "Prefix for the S3 bucket name (a random suffix is appended)"
  type        = string
  default     = "gsa-benchmark"
}

variable "network" {
  description = "Cardano network: mainnet or preprod"
  type        = string
  default     = "mainnet"

  validation {
    condition     = contains(["mainnet", "preprod"], var.network)
    error_message = "network must be 'mainnet' or 'preprod'"
  }
}
