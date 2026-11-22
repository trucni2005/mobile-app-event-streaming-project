# Plan: viết lại adjust-streaming-project theo chuẩn production (trọng tâm Ops · Security · Docs)

## Context

Stack đang chạy là Postgres → Debezium → Kafka (3 broker KRaft) → Spark Structured Streaming → Iceberg (MinIO + iceberg-rest) → Trino/Metabase. Tất cả chạy bằng docker compose trên **1 host production, admin chỉ truy cập qua VPN**. Postgres và Kafka đã được harden một phần, các phần còn lại vẫn ở mức dev: port mở ra `0.0.0.0` (Docker bỏ qua ufw), credential hardcode `admin/admin`, image `latest`, chưa có backup và monitoring, job Spark chạy bằng `docker compose exec` nên không ai giám sát, docs lệch với code.

Mục tiêu: viết lại theo từng phase, phase nào cũng ship được và rollback được. Sau khi xong, stack an toàn khi đặt trên host thật, vận hành được (deploy, backup/restore, alert, runbook) và có tài liệu đủ để người mới tự chạy được.

**Những gì đã chốt với user:** giữ Compose trên 1 host · làm observability đầy đủ (Prometheus/Grafana/Alertmanager/Loki) · **giữ `tabulario/iceberg-rest`** (pin version, tách DB/user riêng, chấp nhận rủi ro bằng ADR) · secret là file 0600 do `make secrets` sinh ra, `.env` chỉ còn config không nhạy cảm.

## Phát hiện chính (lý do cần rewrite)

| Mức | Vấn đề | Vị trí |
|---|---|---|
| 🔴 | Spark master `7077` mở `0.0.0.0` và không có auth, nên ai vào được mạng cũng submit được code (RCE). Spark UI `4040/7070/8091/8092/18080` cũng mở và có nút kill job | [compose/spark.yml](compose/spark.yml) |
| 🔴 | tooling-db `5435` mở `0.0.0.0`, superuser `admin/admin` hardcode. DB này chứa Metabase **và** Iceberg catalog (iceberg-rest đang ghi thẳng vào DB `metabase` bằng admin) | [compose/tooling-db.yml](compose/tooling-db.yml), [compose/storage.yml](compose/storage.yml) |
| 🔴 | iceberg-rest `8181` mở `0.0.0.0` và không có auth, nên ai cũng drop được bảng. MinIO `9000/9001`, Trino `8050`, Metabase `3000` cũng mở, simulator `8000` có `POST` không auth ghi thẳng vào DB | compose/*.yml |
| 🔴 | Không có backup nào. Mất tooling-db là mất catalog, mọi bảng Iceberg thành mồ côi | — |
| 🟠 | Mọi service dùng **root credential của MinIO**. `.env.example` để `admin/admin`. Kafka dùng PLAINTEXT, không có auth/ACL. Kafka UI có full quyền ghi | [.env.example](.env.example), [compose/kafka.yml](compose/kafka.yml) |
| 🟠 | Job Spark chạy bằng `exec`, chết là không có gì restart. `make spark-submit` thiếu `ICEBERG_REST_URI`/`AWS_REGION` nên job fail. History server đọc một thư mục trống vì chưa bật eventLog | [Makefile](Makefile), [spark/spark_builder.py](spark/spark_builder.py) |
| 🟠 | Avro được decode bằng schema `latest` sau khi cắt 5 byte, nên vỡ ngay khi schema đổi. `requests.get` không có timeout | [spark/bronze/sink_to_bronze.py](spark/bronze/sink_to_bronze.py) |
| 🟠 | Debezium 1.9 đã EOL. Connector đăng ký bằng `POST` nên không idempotent, config nhét trong Makefile. Dòng `value.subject.name.strategy` là config chết. Delete bị drop âm thầm, không có heartbeat | [Makefile](Makefile) |
| 🟠 | Image `latest` (trino, metabase, mc, iceberg-rest, postgres:16). Jar tải về không verify checksum. Image Spark chạy root. **Không có `.dockerignore`** nên `.env`, `secrets/` và volumes bị gửi vào build context | [docker/](docker/) |
| 🟠 | Simulator chạy `--reload` và bind-mount code ở prod. psycopg2 sync chặn event loop async. Mỗi event mở một connection mới. Log bằng `print`. Mặc định `postgres/postgres`. Image có cả dev deps (pytest, ruff, pandas, kafka-python) | [simulator/main.py](simulator/main.py), [requirements.txt](requirements.txt) |
| 🟠 | Không có metric hay alert cho replication slot lag, under-replicated partitions, streaming lag hay disk | — |
| 🟡 | Cột `TIMESTAMP` không có tz lưu giờ VN, nên `event_date` ở bronze lệch 7h. `id SERIAL` là int4. Bảng Iceberg được tạo ngầm, chưa có compaction/expire snapshot (trigger 1 phút sinh rất nhiều file nhỏ) | [ddl/postgresql/01-schema.sql](ddl/postgresql/01-schema.sql) |
| 🟡 | Integration test Postgres **luôn bị skip trong CI** vì không có DB. Không có secret scan hay image scan. Action chưa pin SHA. Chưa có CD | [.github/workflows/](.github/workflows/) |
| 🟡 | Docs lệch code: README nhắc `make up` nhưng target này không tồn tại, ghi sai tên bảng (`bronze_catalog.<env>.bronze_events` trong khi thực tế là `catalog.bronze.adjust_events`), `SPARK_LAYER/SPARK_JOB` bị bỏ qua, bảng port thiếu service. `schema/adjust-event.avsc` và `register-schema` là code chết. Notebook vẫn dùng hadoop catalog và đã commit output | [README.md](README.md), [notebooks/](notebooks/) |

**Giữ lại và tái sử dụng:** [config/postgres/postgresql.conf](config/postgres/postgresql.conf), các role least-privilege trong [ddl/postgresql/02-roles.sh](ddl/postgresql/02-roles.sh) (đã idempotent), bộ test [tests/postgres/](tests/postgres/) (test roles/config/CDC rất tốt), config Kafka (RF3, min ISR 2, unclean=false, rotate log), cách tách `backend-net`/`kafka-net`, `FileConfigProvider` của Debezium, tách CI theo paths, các hàm sinh dữ liệu và `EVENT_COLUMNS`/`insert_event` của simulator.

## Kiến trúc đích

**Layout repo**
```
compose/      common.yml (service mẫu "hardened" để extends) · postgres · tooling-db · kafka · storage
              spark · bi · simulator · observability · backup · dev.yml (override dev)
docker/       simulator/ · spark/ (Dockerfile + jars.lock có sha256) · kconnect/ (Debezium 2.7 + Confluent Avro)
              common/entrypoint-secrets.sh  (export X từ /run/secrets/X cho image không hỗ trợ *_FILE)
config/       postgres/ · kafka/ (jaas, acl) · connect/connectors/*.json · trino/ · minio/policies/
              prometheus/ (rules + tests) · alertmanager/ · grafana/ (provisioning) · loki/ · alloy/
db/           migrations/ (Flyway V*.sql) · roles/ · tooling/
simulator/    src/simulator/{config,db,generator,api,metrics}.py · tests/
spark/        jobs/bronze/ · jobs/maintenance/ · common/{session,config,schema_registry,metrics}.py · tests/
scripts/      secrets.sh · deploy.sh · rollback.sh · connect-apply.sh · minio-bootstrap.sh · kafka-acl.sh
              backup-*.sh · restore-*.sh · restore-test.sh · check-exposure.sh · init-data-dirs.sh
ops/systemd/  adjust-streaming.service · backup.timer · iceberg-maintenance.timer · restore-test.timer
docs/         xem P6
```

**Chính sách expose port** (theo policy VPN): mọi `ports:` có dạng `${BIND_ADDR:-127.0.0.1}:host:container`.
- Service có auth (Grafana, Metabase, Kafka UI, MinIO console) bind vào IP của interface VPN (`BIND_ADDR`).
- Service không có auth (Spark UI, Trino, Prometheus, Alertmanager, Connect REST, Schema Registry) chỉ bind `127.0.0.1` và truy cập bằng SSH tunnel qua VPN.
- Không publish: Kafka, iceberg-rest, tooling-db, MinIO API, Spark RPC.
- `scripts/check-exposure.sh` parse `docker compose config --format json` và fail nếu có port nào bind ngoài `127.0.0.1` hoặc `$VPN_IP`. Script chạy trong CI.

**Phân vùng mạng**

| Network | Service |
|---|---|
| `backend-net` | postgres, simulator, kconnect |
| `stream-net` | kafka×3, schema-registry, kconnect, kafka-ui, spark |
| `lake-net` | minio, iceberg-rest, tooling-db, spark, trino |
| `bi-net` | trino, metabase, tooling-db |
| `obs-net` | prometheus và các exporter (exporter join thêm network của target) |

Metabase/Trino không còn với tới Kafka hay Postgres OLTP (Metabase từng có CVE RCE).

**Secrets:** `scripts/secrets.sh` sinh toàn bộ secret vào `secrets/` (0600). Có `--import-env` để lấy password đang dùng trong `.env` cũ, tránh tự khoá mình khỏi DB đang chạy, và `--rotate <name>`.
- Danh sách: các password PG (superuser/app/debezium), tooling superuser, user `metabase`, user `iceberg`, `MB_ENCRYPTION_SECRET_KEY`, MinIO root và 3 user dịch vụ (spark/trino/iceberg-rest), SCRAM Kafka theo từng client, Kafka UI, `spark.authenticate.secret`, Trino (admin/metabase), Grafana admin, webhook Alertmanager, token API simulator, credential đích backup.
- Service nào hỗ trợ `*_FILE` thì dùng (postgres, minio, grafana), còn lại dùng `entrypoint-secrets.sh`. Không truyền secret qua `-e` hay Spark conf nữa.

## Các phase

Mỗi phase gồm 1–4 PR. **Definition of Done chung:** CI xanh, `check-exposure` pass, docs của phần đã đổi được cập nhật ngay trong cùng PR.

### P0: Quick wins bảo mật (1 PR, làm ngay trên host đang chạy)
- Bind mọi port vào `127.0.0.1`. Bỏ publish `7077`, `8181`, `5435`, `9000`.
- Đổi password `admin/admin` của tooling-db, Metabase và MinIO (tạm thời vẫn qua `.env`).
- Thêm `.dockerignore`. Bỏ `--reload` và bind-mount `./simulator` khỏi compose mặc định. Bật `KAFKA_CLUSTERS_0_READONLY=true` cho Kafka UI. Đặt `spark.ui.killEnabled=false`.
- Sửa `make spark-submit` để truyền đủ env.
- **Verify:** `ss -tlnp` trên host không còn listener `0.0.0.0` nào ngoài SSH/VPN. Quét từ máy ngoài VPN thấy toàn bộ port đóng.

### P1: Nền tảng (config, secrets, compose, deps, CI gates)
- Dựng layout mới (di chuyển `ddl/` → `db/`, `trino/` → `config/trino/`, `KAFKA_LEARNING.md` → `docs/learning/`). Xoá `schema/adjust-event.avsc` và target `register-schema` vì Debezium là nơi sở hữu schema.
- Thêm `scripts/secrets.sh` và `entrypoint-secrets.sh`. `.env.example` chỉ còn config, có comment cho từng biến (required/default).
- `compose/common.yml`: `restart: unless-stopped`, `init: true`, rotate log json-file, `security_opt: [no-new-privileges:true]`, `cap_drop: [ALL]` (cấp thêm capability cho từng service khi cần), `read_only` nếu được, healthcheck và `deploy.resources.limits` cho **mọi** service. Pin mọi image theo tag kèm digest.
- `DATA_DIR` (prod `/srv/adjust-streaming`, dev `./.data`) thay cho `./*-volumes`. `scripts/init-data-dirs.sh` thay cho trick `chown` trong `kafka-up`.
- Chọn dev/prod bằng `COMPOSE_FILE` trong `.env`: dev là `docker-compose.yml:compose/dev.yml`, prod chỉ dùng `docker-compose.yml`. Không dùng `docker-compose.override.yml` tự load vì dễ vô tình áp lên prod.
- Viết lại Makefile thành wrapper mỏng gọi `scripts/`: có `help`, `up` (đúng thứ tự, `--wait`), `down`, `secrets`, `deploy`, `backup`, `restore-test`, `e2e`. Script dùng `set -euo pipefail`, không còn interpolate password trong shell (sửa lỗi injection ở `kconnect-secret`).
- Mỗi component Python có `pyproject.toml` riêng, lockfile có hash (`pip install --require-hashes`), tách deps runtime và dev, bỏ `kafka-python`/`pandas` không dùng.
- CI gates: ruff check + format, shellcheck, hadolint, `docker compose config` cho cả dev và prod, `check-exposure.sh`, gitleaks, trivy (fs/config), pip-audit, nbstripout. Pin action theo SHA, `permissions: contents: read`. Renovate cập nhật digest image, pip và actions. Thêm `.pre-commit-config.yaml` chạy cùng các tool này.

### P2: Harden từng service
- **Postgres:** chuyển schema sang Flyway (`db/migrations/V1__baseline.sql` = schema hiện tại, dùng `baselineOnMigrate` cho DB đang chạy), chạy bằng service one-shot `pg-migrate`. Script roles đọc password từ file secret. `pg_hba.conf` ghi rõ: chỉ cho subnet của `backend-net`, dùng scram. Thêm bảng `adjust.debezium_heartbeat`.
- **tooling-db / iceberg-rest / Metabase:** pin `postgres:16.x`, có healthcheck, không publish. Mỗi DB một owner riêng: DB `metabase` cho user `metabase`, DB `iceberg_catalog` cho user `iceberg` (sửa [ddl/tooling/init.sql](ddl/tooling/init.sql) thành script đọc secret). iceberg-rest pin tag, `CATALOG_URI` trỏ tới `iceberg_catalog` (ADR ghi rõ rủi ro: bản reference, không có auth, chỉ nằm trong `lake-net`). Metabase pin version, đặt `MB_ENCRYPTION_SECRET_KEY`, dùng user DB riêng.
- **Trino:** pin version, bật password file auth (`allow-insecure-over-http` chỉ trong mạng nội bộ) và file-based access control (user `metabase` chỉ được đọc). Bỏ region hardcode.
- **MinIO:** pin `minio` và `mc`. `scripts/minio-bootstrap.sh` tạo bucket theo env và 3 user dịch vụ với policy scoped theo prefix (spark rw `lakehouse/<env>/` + `data/checkpoints/<env>/`, trino chỉ đọc, iceberg-rest rw `lakehouse/<env>/`). Root chỉ dùng để bootstrap.
- **Kafka:** chuyển `CLUSTER_ID` sang `.env` và gắn JMX exporter (java agent). **Bước riêng có maintenance window:** bật SASL/SCRAM-SHA-512 cho listener client và inter-broker (listener controller dùng SASL PLAIN vì KRaft không hỗ trợ SCRAM ở controller listener, cần xác nhận lúc implement), `StandardAuthorizer`, `allow.everyone.if.no.acl.found=false`. `scripts/kafka-acl.sh` cấp ACL tối thiểu cho từng principal (connect, schema-registry, spark, kafka-ui). Migrate theo kiểu chạy song song 2 listener rồi mới cắt hẳn PLAINTEXT.
- **Debezium:** image riêng `docker/kconnect` dựa trên `quay.io/debezium/connect:2.7.x` cộng jar Confluent Avro converter (pin sha256). Config connector chuyển ra `config/connect/connectors/adjust-event-cdc.json`, apply idempotent bằng `PUT /connectors/<name>/config` (service one-shot `kconnect-init`). Đổi `database.server.name` → `topic.prefix=adjust-dbserver` (giữ tên topic và offset). Bật heartbeat (`heartbeat.interval.ms` + `action.query`), `delete.handling.mode=rewrite`, `add.fields=op,source.ts_ms,lsn`. Schema Registry đặt compatibility `BACKWARD`. Cập nhật `test_publication_covers_only_event_table` để chấp nhận thêm bảng heartbeat.
- **Spark runtime:** image non-root, verify jar theo `jars.lock`. `spark.authenticate=true` cho master, worker và driver. Job chạy như service compose `spark-job-bronze` (`spark-submit` client mode, có restart policy), mỗi driver một job. Bật eventLog vào `s3a://data/spark-events/<env>`, history server đọc từ đó. Credential S3 lấy qua env (DefaultCredentialsProvider), không đặt trong Spark conf.
- **Simulator (viết lại):** package `src/simulator` dùng pydantic-settings (đọc `*_FILE`, fail-fast khi thiếu biến, không còn default `postgres/postgres`), psycopg3 `AsyncConnectionPool`, log JSON, graceful shutdown, tốc độ sinh event cấu hình được. Có `/healthz` (liveness), `/readyz` (ping DB), `/metrics`. `POST /events/install` yêu cầu token, hoặc tắt hẳn bằng `SIMULATOR_API_ENABLED=false` ở prod. Dockerfile multi-stage, non-root, không `--reload`. Chuyển [tests/simulator/test_main.py](tests/simulator/test_main.py) sang module mới.

### P3: Observability (`compose/observability.yml`)
- Prometheus (giữ 15 ngày), Alertmanager (receiver đọc webhook từ secret), Grafana (datasource và dashboard provision từ repo, tắt anonymous), Loki cùng **Grafana Alloy** để gom log Docker (Promtail đã EOL).
- Exporter: node-exporter, cAdvisor, postgres-exporter cho cả 2 DB (thêm custom query về lag của replication slot: `pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)` và `active`), JMX cho Kafka và Connect, endpoint Prometheus của MinIO, Trino `/metrics`, PrometheusServlet của Spark.
- Lag của Spark: Spark không commit offset vào consumer group nên kafka-exporter không thấy lag của job. Vì vậy cần thêm `spark/common/metrics.py`, một Python `StreamingQueryListener` expose qua `prometheus_client`: thời điểm progress gần nhất, inputRows/s, processedRows/s, batch duration, `maxOffsetsBehindLatest`.
- Alert rules (có `promtool test rules`, mỗi alert gắn link runbook): target down, container restart loop, disk >80%, slot lag >2GB hoặc slot inactive, URP >0, offline partitions, active controller ≠1, connector/task FAILED, streaming không có progress >5 phút, lag tăng liên tục, Iceberg commit lỗi, backup không thành công trong 26h, cert/secret sắp hết hạn (nếu có).
- Dashboard: Pipeline overview (lag theo từng chặng từ PG → bronze), Kafka, Postgres, Spark streaming, Host/containers.

### P4: Backup, DR, deploy và vận hành host
- **Backup** (`compose/backup.yml` + systemd timer):
  - Postgres OLTP: WAL-G gồm base backup hằng ngày và WAL archiving liên tục, đẩy lên **đích off-host** (S3-compatible, cấu hình qua env và secret).
  - tooling-db (metabase + iceberg_catalog): `pg_dump` mỗi giờ, catalog được ưu tiên.
  - MinIO `lakehouse`: `mc mirror` hằng đêm ra off-host.
  - Config connector và schema đã nằm trong repo.
  - Script backup ghi metric thời điểm thành công gần nhất vào textfile collector của node-exporter.
- `scripts/restore-test.sh` chạy hằng tuần bằng timer: restore PG và tooling-db vào container tạm, chạy truy vấn kiểm tra rồi đẩy kết quả thành metric.
- **Release/deploy:** khi đẩy tag `vX.Y.Z`, CI build image (simulator, spark, kconnect) kèm SBOM và provenance rồi push lên GHCR. Deploy theo kiểu **pull** (giữ policy không mở SSH ra ngoài): operator vào host qua VPN và chạy `scripts/deploy.sh vX.Y.Z`. Script đặt `IMAGE_TAG`, pull, chạy `pg-migrate`, `up --wait` theo thứ tự, apply connector rồi smoke check. `rollback.sh` quay về tag trước. Migration theo kiểu expand/contract để rollback được.
- **Host:** `ops/systemd/adjust-streaming.service` để stack tự lên khi boot. Docs host gồm: cấu hình daemon.json (log rotate, `live-restore`), chain iptables `DOCKER-USER`, ufw, sizing (RAM/disk cho toàn stack cộng observability), đồng bộ giờ, unattended-upgrades.

### P5: Pipeline correctness (data, ưu tiên sau ops/security)
- Viết lại job bronze:
  - Đọc schema id ở byte 1–4 của từng message và decode bằng đúng writer schema (lấy theo id, có cache, có timeout và retry) trong `foreachBatch`, sau đó `unionByName`.
  - Commit idempotent bằng snapshot property `streaming.batch-id` (bỏ qua batch đã commit).
  - Thêm cột metadata: topic, partition, offset, kafka_ts, schema_id, op, lsn, ingested_at.
  - Đặt `maxOffsetsPerTrigger`, validate config (fail-fast).
- Bảng Iceberg được tạo bằng DDL tường minh qua job `bootstrap`: namespace theo env, format-version 2, partition `days(event_ts)`, đặt target file size, số lần retry commit, tự xoá metadata cũ.
- Job `maintenance` chạy hằng ngày: `rewrite_data_files`, `expire_snapshots` (7 ngày), `remove_orphan_files`, `rewrite_manifests`.
- **Thay đổi breaking, cần runbook riêng:** đổi cột thời gian sang `TIMESTAMPTZ` (`USING col AT TIME ZONE 'Asia/Ho_Chi_Minh'`), `id` sang `BIGINT`, rồi set Postgres `timezone=UTC`. Debezium sẽ chuyển sang phát `ZonedTimestamp` (string), nên job parse về timestamp UTC. Tạo bảng bronze `adjust_events_v2` với kiểu đúng và backfill từ v1 (đổi micros giờ VN sang UTC). Cập nhật `test_config.py` (TimeZone).
- Unit test decode với PySpark local và message Avro có framing Confluent (dựng bằng fastavro). Sửa notebook sang REST catalog và xoá output.

### P6: Docs (viết dần qua các phase, phase này rà lại và tổng hợp; viết tiếng Việt như hiện tại)
- `README.md`: ngắn gọn gồm giới thiệu, quickstart dev 5 bước (đã chạy thử) và link tới `docs/`.
- `docs/architecture.md`: sơ đồ mermaid luồng dữ liệu, network, trust boundary. Silver/Gold đánh dấu "roadmap, chưa implement".
- `docs/security.md`: threat model, ma trận port và bind, bảng credential (ai dùng, quyền gì, file nào, cách rotate), rủi ro chấp nhận (PLAINTEXT trong mạng docker nội bộ, iceberg-rest không có auth).
- `docs/configuration.md`: mọi biến env và secret (required/default/ý nghĩa).
- `docs/operations/`: runbook deploy/rollback, thứ tự start/stop, backup/restore, rotate từng secret, Debezium (slot lost cần resnapshot, connector FAILED), Spark (restart, reset checkpoint, backfill), thay broker Kafka, disk đầy, Iceberg maintenance, checklist xử lý incident. **Mỗi alert có runbook tương ứng.**
- `docs/observability.md` (dashboard và ý nghĩa alert), `docs/development.md` (dev loop, test, notebook), `docs/adr/` (compose 1 host, giữ iceberg-rest, secrets dạng file, nâng Debezium 2.7, bronze at-least-once + idempotent commit, migrate timestamptz), `SECURITY.md`, `CHANGELOG.md`.

## Cutover trên host đang chạy (tóm tắt, runbook đầy đủ nằm ở P6)
1. Làm P0 ngay vì không ảnh hưởng dữ liệu.
2. Chạy `secrets.sh --import-env` trước khi đổi bất cứ thứ gì để giữ password hiện tại, sau đó mới rotate.
3. Chuyển `./*-volumes` sang `DATA_DIR`: stop, rsync giữ owner, start, kiểm tra.
4. Nâng Debezium: giữ `topic.prefix` bằng server name cũ và giữ topic `connect_offsets`, nên không cần snapshot lại.
5. Bật Kafka SASL và migrate timestamptz trong maintenance window riêng, backup trước khi làm.

## Verification
- **Từng PR:** CI (lint, scan, `compose config` dev/prod, `check-exposure`, unit test). [tests/postgres/](tests/postgres/) chạy thật trong CI bằng `docker compose up --wait postgres` với secret sinh tạm, không còn bị skip.
- **E2E** (`make e2e`, chạy hằng đêm trên CI và trên host sau deploy): `make up`, simulator sinh event, connector `RUNNING`, topic có message, `SELECT count(*) FROM iceberg.bronze.adjust_events` qua Trino tăng trong vòng 3 phút, so khớp dải `id` giữa PG và bronze (không có gap).
- **Security:** quét từ máy ngoài VPN thấy mọi port đóng. Client Kafka không có credential bị từ chối. Kafka UI không xoá được topic. User MinIO `spark` không xoá được object ngoài prefix của mình. User Trino `metabase` không `DROP` được. trivy không còn lỗi HIGH/CRITICAL nào có bản fix. gitleaks sạch.
- **Observability:** `promtool check/test rules`. Chaos thủ công: stop `kconnect` thì alert connector bắn, stop job Spark thì alert no-progress bắn, đầy disk giả thì alert disk bắn, đều nhận được qua receiver.
- **DR:** `restore-test.sh` pass. Restart job Spark thì job tiếp tục từ checkpoint, không mất và không trùng `id` ở bronze. Rolling restart từng broker Kafka thì URP về 0.

## Ngoài phạm vi
Kubernetes · job Silver/Gold · HA multi-host · TLS trong mạng docker nội bộ (ghi trong ADR là rủi ro chấp nhận) · thay iceberg-rest bằng một catalog production-grade (ADR ghi đây là hướng nâng cấp sau).
