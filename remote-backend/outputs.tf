output "state_bucket_id" {
  description = "Nome (ID) do bucket S3 usado como backend remoto de state Terraform."
  value       = aws_s3_bucket.this.id
}

output "state_bucket_arn" {
  description = "ARN do bucket S3 usado como backend remoto de state Terraform."
  value       = aws_s3_bucket.this.arn
}

output "state_bucket_region" {
  description = "Região AWS onde o bucket de state reside."
  value       = aws_s3_bucket.this.bucket_region
}
