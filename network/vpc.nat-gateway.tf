resource "aws_nat_gateway" "this" {
  count = var.nat_gateway.enabled ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[var.vpc.public_subnets[0].name].id

  tags = {
    Name = "${var.project.name}-${var.project.environment}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}
