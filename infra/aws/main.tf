# Một EC2 chạy toàn bộ docker compose stack (backend + data platform).
#
# Truy cập: KHÔNG có rule inbound nào, kể cả SSH. Shell và port-forward tới các UI
# (bind 127.0.0.1 trên host) đều đi qua SSM Session Manager, xác thực bằng IAM.
# Host vẫn cần đi ra internet (apt, GHCR, Maven, endpoint SSM) nên có public IP,
# nhưng không có port nào mở chiều vào.

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------- Network ----------

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.project }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.project }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Xoá hết rule của security group mặc định để không resource nào vô tình dùng nó.
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

resource "aws_security_group" "host" {
  name        = "${var.project}-host"
  description = "Host stack: khong co inbound, truy cap qua SSM"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project}-host" }
}

resource "aws_vpc_security_group_egress_rule" "host_all" {
  security_group_id = aws_security_group.host.id
  description       = "Ra internet: apt, GHCR, Maven, SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ---------- IAM: chỉ đủ quyền cho SSM agent ----------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${var.project}-host"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "host_ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.project}-host"
  role = aws_iam_role.host.name
}

# ---------- EC2 ----------

resource "aws_instance" "host" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = true
  user_data                   = file("${path.module}/cloud-init.yaml")

  # IMDSv2 bắt buộc; hop limit 1 để container trên host không lấy được
  # credential của instance role qua metadata.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
  }

  lifecycle {
    # AMI Ubuntu mới ra hằng tuần; không để apply tự thay (xoá) host vì AMI đổi.
    ignore_changes = [ami]
  }

  tags = { Name = "${var.project}-host" }
}

resource "aws_ec2_instance_state" "host" {
  instance_id = aws_instance.host.id
  state       = var.instance_state
}
