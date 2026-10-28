resource "aws_ecr_repository" "image" {
  name = local.image_repo_name
  # Channel tags (latest, stable) move, so tags must be mutable.
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_repository" "builder" {
  name                 = "${var.name}-builder"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Only untagged images expire. Tagged builds and cosign signatures and
# attestations (sha256-*.sig, *.att) are all tagged and kept.
resource "aws_ecr_lifecycle_policy" "image" {
  repository = aws_ecr_repository.image.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.untagged_image_expiry_days
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_ecr_lifecycle_policy" "builder" {
  repository = aws_ecr_repository.builder.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the 10 newest builder images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# Attach this to whatever pulls the image: an EC2 instance profile, or an IAM
# user/role whose credentials an edge device uses to refresh its auth.json.
data "aws_iam_policy_document" "image_pull" {
  statement {
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = [aws_ecr_repository.image.arn]
  }
}

resource "aws_iam_policy" "image_pull" {
  name        = "${var.name}-bootc-image-pull"
  description = "Read-only pull access to the ${local.image_repo_name} bootc image"
  policy      = data.aws_iam_policy_document.image_pull.json
}
