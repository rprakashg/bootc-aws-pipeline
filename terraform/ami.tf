# Staging bucket for raw disks on their way into EBS snapshots.
resource "aws_s3_bucket" "ami_import" {
  count         = var.enable_ami ? 1 : 0
  bucket_prefix = "${var.name}-ami-import-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "ami_import" {
  count                   = var.enable_ami ? 1 : 0
  bucket                  = aws_s3_bucket.ami_import[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "ami_import" {
  count  = var.enable_ami ? 1 : 0
  bucket = aws_s3_bucket.ami_import[0].id

  # Builds delete their disk after import; this catches failed runs.
  rule {
    id     = "expire-disks"
    status = "Enabled"
    filter {}
    expiration {
      days = 3
    }
  }
}

# Service role that VM Import/Export assumes to read the disk and write the snapshot.
data "aws_iam_policy_document" "vmimport_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vmie.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = ["vmimport"]
    }
  }
}

data "aws_iam_policy_document" "vmimport" {
  count = var.enable_ami ? 1 : 0

  statement {
    actions = ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.ami_import[0].arn,
      "${aws_s3_bucket.ami_import[0].arn}/*",
    ]
  }
  statement {
    actions = [
      "ec2:ModifySnapshotAttribute",
      "ec2:CopySnapshot",
      "ec2:RegisterImage",
      "ec2:Describe*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "vmimport" {
  count              = var.enable_ami ? 1 : 0
  name               = "${var.name}-vmimport"
  assume_role_policy = data.aws_iam_policy_document.vmimport_trust.json
}

resource "aws_iam_role_policy" "vmimport" {
  count  = var.enable_ami ? 1 : 0
  role   = aws_iam_role.vmimport[0].id
  policy = data.aws_iam_policy_document.vmimport[0].json
}
