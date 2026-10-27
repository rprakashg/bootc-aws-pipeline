resource "aws_kms_key" "signing" {
  count                    = var.enable_signing ? 1 : 0
  description              = "cosign signing key for ${local.image_repo_name} bootc images"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 30
}

resource "aws_kms_alias" "signing" {
  count         = var.enable_signing ? 1 : 0
  name          = "alias/${var.name}-cosign"
  target_key_id = aws_kms_key.signing[0].key_id
}

data "aws_kms_public_key" "signing" {
  count  = var.enable_signing ? 1 : 0
  key_id = aws_kms_key.signing[0].arn
}
