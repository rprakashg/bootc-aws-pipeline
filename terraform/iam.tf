# ---------------------------------------------------------------- CodeBuild

data "aws_iam_policy_document" "codebuild_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

data "aws_iam_policy_document" "codebuild" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.builds.arn}:*"]
  }

  statement {
    sid       = "Artifacts"
    actions   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.image.arn, aws_ecr_repository.builder.arn]
  }

  dynamic "statement" {
    for_each = local.use_rh_registry ? [1] : []
    content {
      sid       = "RedHatRegistrySecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [var.redhat_registry_secret_arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_signing ? [1] : []
    content {
      sid       = "CosignKms"
      actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
      resources = [aws_kms_key.signing[0].arn]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ami ? [1] : []
    content {
      sid       = "AmiStaging"
      actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListBucket"]
      resources = [aws_s3_bucket.ami_import[0].arn, "${aws_s3_bucket.ami_import[0].arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ami ? [1] : []
    content {
      sid = "AmiImport"
      actions = [
        "ec2:ImportSnapshot",
        "ec2:DescribeImportSnapshotTasks",
        "ec2:DescribeSnapshots",
        "ec2:RegisterImage",
        "ec2:DescribeImages",
        "ec2:CreateTags",
      ]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ami ? [1] : []
    content {
      sid       = "AmiParameter"
      actions   = ["ssm:PutParameter", "ssm:GetParameter"]
      resources = ["arn:${local.partition}:ssm:${var.aws_region}:${local.account_id}:parameter/${var.name}/bootc/ami"]
    }
  }

  dynamic "statement" {
    for_each = var.enable_ami ? [1] : []
    content {
      sid       = "PassVmImportRole"
      actions   = ["iam:PassRole"]
      resources = [aws_iam_role.vmimport[0].arn]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name}-codebuild"
  assume_role_policy = data.aws_iam_policy_document.codebuild_trust.json
}

resource "aws_iam_role_policy" "codebuild" {
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

# ---------------------------------------------------------------- CodePipeline

data "aws_iam_policy_document" "pipeline_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pipeline" {
  statement {
    actions = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    actions   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
    resources = local.all_project_arns
  }

  # The service prefix was renamed; grant both so either connection ARN style works.
  statement {
    actions   = ["codestar-connections:UseConnection", "codeconnections:UseConnection"]
    resources = [local.connection_arn]
  }
}

resource "aws_iam_role" "pipeline" {
  name               = "${var.name}-codepipeline"
  assume_role_policy = data.aws_iam_policy_document.pipeline_trust.json
}

resource "aws_iam_role_policy" "pipeline" {
  role   = aws_iam_role.pipeline.id
  policy = data.aws_iam_policy_document.pipeline.json
}

# ---------------------------------------------------------------- scheduled rebuilds

data "aws_iam_policy_document" "events_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events" {
  count              = var.rebuild_schedule != "" ? 1 : 0
  name               = "${var.name}-pipeline-schedule"
  assume_role_policy = data.aws_iam_policy_document.events_trust.json
}

resource "aws_iam_role_policy" "events" {
  count = var.rebuild_schedule != "" ? 1 : 0
  role  = aws_iam_role.events[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "codepipeline:StartPipelineExecution"
      Resource = aws_codepipeline.bootc.arn
    }]
  })
}
