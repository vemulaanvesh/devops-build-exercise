output "endpoint" {
  description = "RDS endpoint host."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_name" {
  value = aws_db_instance.this.db_name
}

output "instance_arn" {
  value = aws_db_instance.this.arn
}

output "instance_id" {
  value = aws_db_instance.this.id
}

output "connection_url_template" {
  description = <<-EOT
    SQLAlchemy-style connection URL with a placeholder for the password.
    The agent fetches the password from Secrets Manager at startup and
    substitutes it; do NOT embed the password in this output.
  EOT
  value = format(
    "postgresql+psycopg://%s:__PASSWORD__@%s:%d/%s",
    aws_db_instance.this.username,
    aws_db_instance.this.address,
    aws_db_instance.this.port,
    aws_db_instance.this.db_name,
  )
  sensitive = false
}
