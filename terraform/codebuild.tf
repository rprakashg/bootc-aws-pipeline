locals {
  # Variables shared by every project that runs on the podman builder image.
  podman_env = {
    REGISTRY        = local.registry
    IMAGE_REPO_URL  = aws_ecr_repository.image.repository_url
    IMAGE_REPO_NAME = aws_ecr_repository.image.name
    ARCHITECTURES   = join(" ", var.architectures)
    REPO_ID         = var.repository_id
  }

  rh_secret_env = local.use_rh_registry ? {
    RH_REGISTRY_USERNAME = "${var.redhat_registry_secret_arn}:username"
    RH_REGISTRY_PASSWORD = "${var.redhat_registry_secret_arn}:password"
  } : {}

  builder_image = { for a in var.architectures : a => "${aws_ecr_repository.builder.repository_url}:${local.builder_tag}-${a}" }

  all_project_arns = concat(
    [for p in aws_codebuild_project.builder : p.arn],
    [for p in aws_codebuild_project.build : p.arn],
    [aws_codebuild_project.publish.arn],
    [for p in aws_codebuild_project.promote : p.arn],
    [for p in aws_codebuild_project.ami : p.arn],
  )
}

# ---------------------------------------------------------------- builder image
# Runs on the curated AWS image with Docker and produces the podman image that
# every other project runs on. Skips itself when the tag already exists.

resource "aws_codebuild_project" "builder" {
  for_each      = local.archs
  name          = "${var.name}-builder-${each.key}"
  description   = "Builds the podman/skopeo/cosign builder image (${each.key})"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${local.buildspec_dir}/builder.yml")
  }

  environment {
    type                        = local.arch[each.key].codebuild_type
    image                       = var.codebuild_base_images[each.key]
    compute_type                = "BUILD_GENERAL1_SMALL"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "REGISTRY"
      value = local.registry
    }
    environment_variable {
      name  = "BUILDER_REPO_NAME"
      value = aws_ecr_repository.builder.name
    }
    environment_variable {
      name  = "BUILDER_IMAGE"
      value = local.builder_image[each.key]
    }
    environment_variable {
      name  = "BUILDER_TAG"
      value = "${local.builder_tag}-${each.key}"
    }
    environment_variable {
      name  = "BUILDER_CONTAINERFILE_B64"
      value = filebase64(local.builder_containerfile)
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = "builder-${each.key}"
    }
  }
}

# ---------------------------------------------------------------- bootc image, per arch

resource "aws_codebuild_project" "build" {
  for_each      = local.archs
  name          = "${var.name}-build-${each.key}"
  description   = "Builds and lints the bootc image natively on ${each.key}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 90

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${local.buildspec_dir}/build.yml")
  }

  environment {
    type                        = local.arch[each.key].codebuild_type
    image                       = local.builder_image[each.key]
    compute_type                = var.build_compute_type[each.key]
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = true

    dynamic "environment_variable" {
      for_each = { for k, v in merge(local.podman_env, {
        ARCH          = each.key
        CONTAINERFILE = var.containerfile
        BUILD_CONTEXT = var.build_context
        BUILD_ARGS    = local.build_args
      }) : k => v if v != "" }
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }

    dynamic "environment_variable" {
      for_each = local.rh_secret_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "SECRETS_MANAGER"
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = "build-${each.key}"
    }
  }
}

# ---------------------------------------------------------------- multi-arch index + signature

resource "aws_codebuild_project" "publish" {
  name          = "${var.name}-publish"
  description   = "Joins per-arch images into one index, signs it, moves the channel tag"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 30

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${local.buildspec_dir}/publish.yml")
  }

  environment {
    type                        = local.arch[local.primary_arch].codebuild_type
    image                       = local.builder_image[local.primary_arch]
    compute_type                = "BUILD_GENERAL1_SMALL"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = true

    dynamic "environment_variable" {
      for_each = { for k, v in merge(local.podman_env, {
        CHANNEL_TAG     = var.channel_tag
        SIGNING_KEY_ARN = var.enable_signing ? aws_kms_key.signing[0].arn : ""
      }) : k => v if v != "" }
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = "publish"
    }
  }
}

# ---------------------------------------------------------------- promotion after approval

resource "aws_codebuild_project" "promote" {
  count         = var.enable_promotion ? 1 : 0
  name          = "${var.name}-promote"
  description   = "Retags an approved build as ${var.promotion_tag}"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 15

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${local.buildspec_dir}/promote.yml")
  }

  environment {
    type                        = local.arch[local.primary_arch].codebuild_type
    image                       = local.builder_image[local.primary_arch]
    compute_type                = "BUILD_GENERAL1_SMALL"
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = true

    dynamic "environment_variable" {
      for_each = { for k, v in merge(local.podman_env, { PROMOTION_TAG = var.promotion_tag }) : k => v if v != "" }
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = "promote"
    }
  }
}

# ---------------------------------------------------------------- AMIs, per arch

resource "aws_codebuild_project" "ami" {
  for_each      = var.enable_ami ? local.archs : toset([])
  name          = "${var.name}-ami-${each.key}"
  description   = "Converts the bootc image into an AMI with bootc-image-builder (${each.key})"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 180

  artifacts {
    type = "CODEPIPELINE"
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = file("${local.buildspec_dir}/ami.yml")
  }

  environment {
    type                        = local.arch[each.key].codebuild_type
    image                       = local.builder_image[each.key]
    compute_type                = var.build_compute_type[each.key]
    image_pull_credentials_type = "SERVICE_ROLE"
    privileged_mode             = true

    dynamic "environment_variable" {
      for_each = { for k, v in merge(local.podman_env, {
        ARCH             = each.key
        EC2_ARCH         = local.arch[each.key].ec2_arch
        BOOT_MODE        = local.arch[each.key].boot_mode
        BIB_IMAGE        = var.bib_image
        BIB_CONFIG       = var.bib_config_path
        IMPORT_BUCKET    = aws_s3_bucket.ami_import[0].bucket
        VMIMPORT_ROLE    = aws_iam_role.vmimport[0].name
        AMI_NAME_PREFIX  = "${var.name}-bootc"
        ROOT_VOLUME_SIZE = tostring(var.ami_root_volume_gb)
        AMI_PARAMETER    = "/${var.name}/bootc/ami/${each.key}"
      }) : k => v if v != "" }
      content {
        name  = environment_variable.key
        value = environment_variable.value
      }
    }

    dynamic "environment_variable" {
      for_each = local.rh_secret_env
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "SECRETS_MANAGER"
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.builds.name
      stream_name = "ami-${each.key}"
    }
  }
}
