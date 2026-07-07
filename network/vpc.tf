# Renomeado de aws_vpc.main para aws_vpc.this (convenção .claude/rules/terraform-naming.md)
# preservando o recurso já aplicado (vpc-0f312e3252e7b82fe) sem destroy/recreate.
moved {
  from = aws_vpc.main
  to   = aws_vpc.this
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc.cidr_block
  instance_tenancy     = "default"
  enable_dns_support   = var.vpc.enable_dns_support
  enable_dns_hostnames = var.vpc.enable_dns_hostnames

  tags = {
    Name = "${var.project.name}-${var.project.environment}-vpc"
  }
}
