terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# An empty aws_profile falls back to the ambient credential chain
# (AWS_PROFILE, env vars, or an instance role on a deploy server).
locals {
  aws_profile = var.aws_profile != "" ? var.aws_profile : null
}

provider "aws" {
  profile             = local.aws_profile
  allowed_account_ids = [var.aws_account_id]
}

provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  profile             = local.aws_profile
  allowed_account_ids = [var.aws_account_id]
}