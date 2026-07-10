resource "aws_s3_bucket" "this" {
  bucket        = var.state_bucket.name
  force_destroy = var.state_bucket.force_destroy

  tags = {
    Name = var.state_bucket.name
  }
}
