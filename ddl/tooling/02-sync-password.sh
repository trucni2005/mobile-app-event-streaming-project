#!/bin/bash
# Đồng bộ password superuser của tooling-db theo TOOLING_DB_PASSWORD (.env).
# POSTGRES_PASSWORD chỉ áp dụng lúc initdb, nên đổi password trên DB đã có thì
# recreate container (để nhận env mới) rồi chạy `make tooling-db-roles`.
# Idempotent: cũng tự chạy lúc initdb (docker-entrypoint-initdb.d).
set -euo pipefail

psql -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  -v su_user="$POSTGRES_USER" \
  -v su_password="$POSTGRES_PASSWORD" \
  <<'EOSQL'
ALTER ROLE :"su_user" PASSWORD :'su_password';
EOSQL
