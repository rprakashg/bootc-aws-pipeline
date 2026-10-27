data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  registry   = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  image_repo_name = var.image_repository_name != "" ? var.image_repository_name : var.name

  connection_arn = var.connection_arn != "" ? var.connection_arn : aws_codestarconnections_connection.source[0].arn

  # Rebuilt (and every build project repointed) only when the builder Containerfile changes.
  builder_containerfile = "${path.module}/../builder/Containerfile"
  builder_tag           = substr(filesha256(local.builder_containerfile), 0, 12)

  buildspec_dir = "${path.module}/../buildspecs"

  arch = {
    amd64 = { codebuild_type = "LINUX_CONTAINER", ec2_arch = "x86_64", boot_mode = "uefi-preferred" }
    arm64 = { codebuild_type = "ARM_CONTAINER", ec2_arch = "arm64", boot_mode = "uefi" }
  }
  archs = toset(var.architectures)

  # The publish/promote stages run on whichever architecture is listed first.
  primary_arch = var.architectures[0]

  use_rh_registry = var.redhat_registry_secret_arn != ""

  build_args = join(" ", [for k, v in var.build_args : "--build-arg ${k}=${v}"])
}

resource "aws_codestarconnections_connection" "source" {
  count         = var.connection_arn == "" ? 1 : 0
  name          = "${var.name}-src"
  provider_type = var.connection_provider
}

resource "aws_s3_bucket" "artifacts" {
  bucket_prefix = "${var.name}-pipeline-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

resource "aws_cloudwatch_log_group" "builds" {
  name              = "/codebuild/${var.name}"
  retention_in_days = var.log_retention_days
}
