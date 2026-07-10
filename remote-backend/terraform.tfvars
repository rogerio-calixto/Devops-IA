project = {
  name        = "devops-ia"
  environment = "shared" # ver ADR-004, Premissa #4 — confirmado pelo solicitante em 2026-07-10 (infraestrutura cross-ambiente, não "dev")
  aws_region  = "us-east-1"
}

state_bucket = {
  # Nome globalmente único; inclui Account ID e região para evitar colisão de
  # namespace global do S3. Disponibilidade confirmada em 2026-07-10 via
  # `aws s3api head-bucket` (404 Not Found = nome livre) — ver ADR-004, Premissa #15.
  name                               = "devops-ia-tfstate-508591324807-us-east-1"
  force_destroy                      = false
  noncurrent_version_expiration_days = 90
}
