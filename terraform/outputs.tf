output "image_repository_url" {
  description = "Point hosts here: bootc switch <url>:<tag>"
  value       = aws_ecr_repository.image.repository_url
}

output "pipeline_name" {
  value = aws_codepipeline.bootc.name
}

output "pipeline_console_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/codesuite/codepipeline/pipelines/${aws_codepipeline.bootc.name}/view?region=${var.aws_region}"
}

output "connection_arn" {
  description = "Source connection. If Terraform created it, approve it once in the console before the first run."
  value       = local.connection_arn
}

output "connection_status" {
  value = var.connection_arn == "" ? aws_codestarconnections_connection.source[0].connection_status : "managed outside this module"
}

output "image_pull_policy_arn" {
  description = "Read-only pull policy for instance profiles or device credentials."
  value       = aws_iam_policy.image_pull.arn
}

output "cosign_public_key" {
  description = "Verify with: cosign verify --key cosign.pub --insecure-ignore-tlog <image>"
  value       = var.enable_signing ? data.aws_kms_public_key.signing[0].public_key_pem : null
}

output "cosign_key_ref" {
  value = var.enable_signing ? "awskms:///${aws_kms_key.signing[0].arn}" : null
}

output "ami_parameter" {
  description = "SSM parameter holding the newest AMI; reference as resolve:ssm:<name> in launch templates."
  value       = var.enable_ami ? "/${var.name}/bootc/ami" : null
}
