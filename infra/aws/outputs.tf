output "instance_id" {
  value = aws_instance.host.id
}

output "private_ip" {
  value = aws_instance.host.private_ip
}

output "shell" {
  description = "Mở shell trên host (cần AWS CLI + session-manager-plugin)."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.host.id}"
}

output "port_forward_example" {
  description = "Ví dụ mở Metabase (127.0.0.1:3000 trên host) tại http://localhost:3000. Đổi port cho UI khác."
  value       = "aws ssm start-session --region ${var.region} --target ${aws_instance.host.id} --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"3000\"]}'"
}
