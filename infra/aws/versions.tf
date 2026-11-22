terraform {
  # Chạy được với Terraform >= 1.6 hoặc OpenTofu.
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State đang để local (terraform.tfstate, đã gitignore). Khi có nhiều người
  # cùng apply thì chuyển sang backend "s3" có bật lock.
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
