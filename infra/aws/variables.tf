variable "region" {
  description = "Region AWS. Mặc định Singapore, gần Việt Nam nhất."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Tiền tố đặt tên và tag cho mọi resource."
  type        = string
  default     = "mobile-events"
}

variable "instance_type" {
  description = <<-EOT
    Loại EC2. t3.medium (2 vCPU / 4 GB) đủ cho backend platform.
    Full stack cần ~16 GB: m6i.xlarge (4 vCPU / 16 GB). Tránh dòng t3 cho full
    stack: Kafka + Spark chạy CPU liên tục, t3 (mặc định unlimited) sẽ tính thêm
    tiền CPU credit. Đổi giá trị này rồi apply là EC2 tự stop, đổi loại, start lại.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Dung lượng ổ gốc (GB, gp3, có mã hoá): OS, Docker image, volume Postgres/Kafka/MinIO."
  type        = number
  default     = 40
}

variable "instance_state" {
  description = "running hoặc stopped. Không dùng thì để stopped: chỉ trả tiền ổ đĩa, dữ liệu vẫn còn."
  type        = string
  default     = "running"

  validation {
    condition     = contains(["running", "stopped"], var.instance_state)
    error_message = "instance_state phải là running hoặc stopped."
  }
}

variable "vpc_cidr" {
  description = "Dải IP của VPC riêng cho project."
  type        = string
  default     = "10.20.0.0/16"
}

variable "budget_email" {
  description = "Email nhận cảnh báo chi phí. Để trống thì không tạo budget."
  type        = string
  default     = ""
}

variable "budget_monthly_usd" {
  description = "Ngưỡng chi phí hằng tháng (USD) của cả account: báo khi dự báo vượt 80% và khi thực tế vượt 100%."
  type        = number
  default     = 50
}
