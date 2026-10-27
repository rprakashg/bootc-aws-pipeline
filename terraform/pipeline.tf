locals {
  # Every CodeBuild action gets the commit and execution id; image tags are
  # <commit12>-<execution8> so scheduled rebuilds of the same commit never collide.
  run_env = [
    { name = "COMMIT_ID", value = "#{SourceVariables.CommitId}", type = "PLAINTEXT" },
    { name = "EXECUTION_ID", value = "#{codepipeline.PipelineExecutionId}", type = "PLAINTEXT" },
  ]

  published_env = concat(local.run_env, [
    { name = "IMAGE_TAG", value = "#{PublishVariables.IMAGE_TAG}", type = "PLAINTEXT" },
    { name = "IMAGE_DIGEST", value = "#{PublishVariables.IMAGE_DIGEST}", type = "PLAINTEXT" },
  ])
}

resource "aws_codepipeline" "bootc" {
  name          = "${var.name}-bootc"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"

  artifact_store {
    type     = "S3"
    location = aws_s3_bucket.artifacts.bucket
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches {
          includes = [var.branch]
        }
        dynamic "file_paths" {
          for_each = length(var.trigger_file_paths) > 0 ? [1] : []
          content {
            includes = var.trigger_file_paths
          }
        }
      }
    }
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      namespace        = "SourceVariables"
      output_artifacts = ["src"]
      configuration = {
        ConnectionArn        = local.connection_arn
        FullRepositoryId     = var.repository_id
        BranchName           = var.branch
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Builder"
    dynamic "action" {
      for_each = local.archs
      content {
        name            = "builder-${action.value}"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        input_artifacts = ["src"]
        configuration = {
          ProjectName = aws_codebuild_project.builder[action.value].name
        }
      }
    }
  }

  stage {
    name = "Build"
    dynamic "action" {
      for_each = local.archs
      content {
        name            = "bootc-${action.value}"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        input_artifacts = ["src"]
        configuration = {
          ProjectName          = aws_codebuild_project.build[action.value].name
          EnvironmentVariables = jsonencode(local.run_env)
        }
      }
    }
  }

  stage {
    name = "Publish"
    action {
      name            = "index-sign-tag"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      namespace       = "PublishVariables"
      input_artifacts = ["src"]
      configuration = {
        ProjectName          = aws_codebuild_project.publish.name
        EnvironmentVariables = jsonencode(local.run_env)
      }
    }
  }

  dynamic "stage" {
    for_each = var.enable_ami ? [1] : []
    content {
      name = "AMI"
      dynamic "action" {
        for_each = local.archs
        content {
          name            = "ami-${action.value}"
          category        = "Build"
          owner           = "AWS"
          provider        = "CodeBuild"
          version         = "1"
          input_artifacts = ["src"]
          configuration = {
            ProjectName          = aws_codebuild_project.ami[action.value].name
            EnvironmentVariables = jsonencode(local.published_env)
          }
        }
      }
    }
  }

  dynamic "stage" {
    for_each = var.enable_promotion ? [1] : []
    content {
      name = "Promote"
      action {
        name      = "approve"
        category  = "Approval"
        owner     = "AWS"
        provider  = "Manual"
        version   = "1"
        run_order = 1
        configuration = {
          CustomData = "Promote ${aws_ecr_repository.image.repository_url}:#{PublishVariables.IMAGE_TAG} to :${var.promotion_tag}?"
        }
      }
      action {
        name            = "tag-${var.promotion_tag}"
        category        = "Build"
        owner           = "AWS"
        provider        = "CodeBuild"
        version         = "1"
        run_order       = 2
        input_artifacts = ["src"]
        configuration = {
          ProjectName          = aws_codebuild_project.promote[0].name
          EnvironmentVariables = jsonencode(local.published_env)
        }
      }
    }
  }
}

# ---------------------------------------------------------------- scheduled rebuilds
# bootc images inherit CVE fixes from their base image; a rebuild with no commit
# is how those reach hosts.

resource "aws_cloudwatch_event_rule" "rebuild" {
  count               = var.rebuild_schedule != "" ? 1 : 0
  name                = "${var.name}-bootc-rebuild"
  description         = "Periodic rebuild of the bootc image to pick up base image updates"
  schedule_expression = var.rebuild_schedule
}

resource "aws_cloudwatch_event_target" "rebuild" {
  count    = var.rebuild_schedule != "" ? 1 : 0
  rule     = aws_cloudwatch_event_rule.rebuild[0].name
  arn      = aws_codepipeline.bootc.arn
  role_arn = aws_iam_role.events[0].arn
}
