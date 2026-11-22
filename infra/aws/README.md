# Hạ tầng AWS

Một EC2 (Ubuntu 24.04, Docker) chạy toàn bộ compose stack, trong VPC riêng ở Singapore.

**Không có port nào mở chiều vào**, kể cả SSH. Shell và truy cập UI đều qua [SSM Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html), xác thực bằng IAM. Các service vẫn bind `127.0.0.1` như ở local (`BIND_ADDR=127.0.0.1`), port-forward qua SSM tới thẳng `127.0.0.1` trên host.

| File | Nội dung |
|---|---|
| [main.tf](main.tf) | VPC, subnet, security group (không inbound), IAM role cho SSM, EC2 |
| [cloud-init.yaml](cloud-init.yaml) | Cài Docker + compose plugin, tạo `/opt/mobile-events` |
| [budget.tf](budget.tf) | Cảnh báo chi phí qua email (tuỳ chọn) |
| [variables.tf](variables.tf) | Region, loại EC2, bật/tắt EC2, budget |

Giải thích từng thành phần Terraform và danh sách câu lệnh: [TERRAFORM.md](TERRAFORM.md).

## Cần có trên máy

- Terraform >= 1.6 (hoặc OpenTofu), AWS CLI v2 đã cấu hình credentials (`aws sts get-caller-identity` chạy được).
- [session-manager-plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) cho AWS CLI.

## Dựng

```bash
cd infra/aws
cp terraform.tfvars.example terraform.tfvars   # sửa instance_type, budget_email
terraform init
terraform plan
terraform apply
```

Sau khoảng 2–3 phút (cloud-init cài Docker xong):

```bash
eval "$(terraform output -raw shell)"   # mở shell, vào user ssm-user
sudo -iu ubuntu                         # user có quyền docker
docker version && docker compose version
```

[.terraform.lock.hcl](.terraform.lock.hcl) khoá phiên bản provider (AWS 6.73.0), cần commit cùng code.

## Deploy stack lên host

Trong shell trên host, user `ubuntu`:

```bash
cd /opt/mobile-events
git clone https://github.com/<owner>/<repo>.git .   # hoặc chỉ copy docker-compose.yml + compose/ + config/ + ddl/
cp .env.example .env && chmod 600 .env             # điền password thật, ENV=prod
make postgres-up                                   # tự sinh secrets/pg_superuser_password
```

Repo/package private thì cần `docker login ghcr.io` (PAT quyền `read:packages`) và deploy key để clone. `.env` và `secrets/` chỉ nằm trên host, không đi qua GitHub.

## Mở UI

Port-forward một port trên host về máy mình, ví dụ Metabase:

```bash
eval "$(terraform output -raw port_forward_example)"   # rồi mở http://localhost:3000
```

Đổi `3000` thành port khác trong bảng [Port và truy cập](../../README.md#port-và-truy-cập) (Kafka UI 8086, Spark UI 7070, Trino 8050...).

## Tiết kiệm chi phí

- **Tắt khi không dùng:** đặt `instance_state = "stopped"` rồi `terraform apply`. Chỉ còn trả tiền ổ đĩa, dữ liệu giữ nguyên. Bật lại bằng `"running"`.
- **Đổi cỡ máy:** sửa `instance_type` rồi `apply`; EC2 tự stop, đổi loại, start lại, dữ liệu giữ nguyên.
- **Xoá hết:** `terraform destroy` (mất toàn bộ dữ liệu trên host).

Chi phí tham khảo ở Singapore (kiểm tra lại trên trang giá AWS): `t3.medium` khoảng $0.05/giờ, `m6i.xlarge` khoảng $0.24/giờ, cộng ổ gp3 40 GB khoảng $4/tháng và public IPv4 khoảng $3.6/tháng (chỉ tính khi EC2 đang chạy; IP đổi mỗi lần bật lại, không sao vì không có kết nối chiều vào).
