resource "aws_subnet" "private" {
  for_each = { for s in var.vpc.private_subnets : s.name => s }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr_block
  availability_zone = each.value.availability_zone

  tags = {
    Name = "${var.project.name}-${var.project.environment}-${each.value.name}"
    Tier = "private"
  }
}
