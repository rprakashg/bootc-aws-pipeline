variable "name" {
  description = "Prefix for every resource name. Lowercase letters, digits and hyphens."
  type        = string
  default     = "bootc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.name))
    error_message = "name must be 2-21 chars of lowercase letters, digits and hyphens (CodeStar connection names are capped at 32)."
  }
}

variable "aws_region" {
  description = "Region for the pipeline, registry and AMIs."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Extra tags applied to every resource."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- source repo

variable "repository_id" {
  description = "Git repository holding the bootc Containerfile, as owner/repo."
  type        = string
}

variable "branch" {
  description = "Branch whose pushes trigger a build."
  type        = string
  default     = "main"
}

variable "trigger_file_paths" {
  description = "Only start the pipeline when a push touches one of these globs. Empty = any change."
  type        = list(string)
  default     = []
}

variable "connection_arn" {
  description = "Existing CodeConnections/CodeStar connection ARN. Leave empty to create one (it must then be approved once in the console)."
  type        = string
  default     = ""
}

variable "connection_provider" {
  description = "Provider for a newly created connection: GitHub, GitLab or Bitbucket."
  type        = string
  default     = "GitHub"
}

variable "containerfile" {
  description = "Path to the Containerfile, relative to the repo root."
  type        = string
  default     = "Containerfile"
}

variable "build_context" {
  description = "Build context directory, relative to the repo root."
  type        = string
  default     = "."
}

variable "build_args" {
  description = "Extra --build-arg values passed to podman build."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------- image + tags

variable "image_repository_name" {
  description = "ECR repository for the bootc image. Defaults to var.name."
  type        = string
  default     = ""
}

variable "channel_tag" {
  description = "Moving tag updated on every successful build. Hosts that track it get every build."
  type        = string
  default     = "latest"
}

variable "enable_promotion" {
  description = "Add a manual approval stage that retags the build as var.promotion_tag."
  type        = bool
  default     = true
}

variable "promotion_tag" {
  description = "Tag applied after manual approval. Production hosts track this one."
  type        = string
  default     = "stable"
}

variable "untagged_image_expiry_days" {
  description = "Days before untagged images in ECR are expired."
  type        = number
  default     = 14
}

variable "rebuild_schedule" {
  description = "EventBridge schedule that reruns the pipeline to pick up base image updates without a commit. Empty disables it."
  type        = string
  default     = "cron(0 6 ? * MON *)"
}

# ---------------------------------------------------------------- registries + signing

variable "redhat_registry_secret_arn" {
  description = "Secrets Manager secret with JSON keys \"username\" and \"password\" for registry.redhat.io. Needed only for RHEL base images."
  type        = string
  default     = ""
}

variable "enable_signing" {
  description = "Sign each published image with cosign using a KMS key created here."
  type        = bool
  default     = true
}

variable "enable_sbom" {
  description = "Generate an SPDX SBOM with syft and attach it as a cosign attestation signed by the same KMS key. Requires enable_signing."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------- AMIs

variable "enable_ami" {
  description = "Add a stage that converts each build into an AMI with bootc-image-builder."
  type        = bool
  default     = false
}

variable "bib_image" {
  description = "bootc-image-builder image. Use registry.redhat.io/rhel9/bootc-image-builder:latest (or rhel10) for RHEL bases."
  type        = string
  default     = "quay.io/centos-bootc/bootc-image-builder:latest"
}

variable "bib_config_path" {
  description = "Optional bootc-image-builder config.toml, relative to the repo root (users, SSH keys, filesystems)."
  type        = string
  default     = ""
}

variable "ami_root_volume_gb" {
  description = "Root volume size for registered AMIs."
  type        = number
  default     = 20
}

# ---------------------------------------------------------------- CodeBuild sizing

variable "build_compute_type" {
  description = "Compute type for image builds and AMI builds."
  type        = string
  default     = "BUILD_GENERAL1_LARGE"
}

variable "codebuild_base_image" {
  description = "Curated CodeBuild image used only to build the podman builder image."
  type        = string
  default     = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
}

variable "log_retention_days" {
  description = "CloudWatch log retention for build logs."
  type        = number
  default     = 30
}
