output "vpc_id" {
  description = "ID da VPC provisionada."
  value       = aws_vpc.main.id
}

output "vpc_arn" {
  description = "ARN da VPC provisionada."
  value       = aws_vpc.main.arn
}

output "vpc_cidr_block" {
  description = "Bloco CIDR IPv4 da VPC."
  value       = aws_vpc.main.cidr_block
}

output "default_security_group_id" {
  description = "ID do security group default criado automaticamente pela VPC."
  value       = aws_vpc.main.default_security_group_id
}

output "default_route_table_id" {
  description = "ID da route table default criada automaticamente pela VPC."
  value       = aws_vpc.main.default_route_table_id
}

output "default_network_acl_id" {
  description = "ID da network ACL default criada automaticamente pela VPC."
  value       = aws_vpc.main.default_network_acl_id
}
