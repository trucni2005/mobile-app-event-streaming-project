-include .env

postgres-secret:
	@mkdir -p secrets
	@test -s secrets/pg_superuser_password || \
		(umask 077 && openssl rand -base64 32 | tr -d '\n' > secrets/pg_superuser_password && \
		echo "Generated secrets/pg_superuser_password")

postgres-up: postgres-secret
	docker compose up -d --wait postgres

# Đồng bộ user/quyền/publication theo .env trên DB đã khởi tạo (idempotent).
postgres-roles:
	docker compose exec postgres /docker-entrypoint-initdb.d/02-roles.sh

# Đồng bộ password superuser tooling-db theo TOOLING_DB_PASSWORD trên DB đã khởi tạo.
# Recreate container trước để nó nhận env mới, sau đó recreate các service dùng DB.
tooling-db-roles:
	docker compose up -d tooling-db
	docker compose exec tooling-db /docker-entrypoint-initdb.d/02-sync-password.sh
	docker compose up -d --force-recreate metabase iceberg-rest

# Chặn port publish ra ngoài 127.0.0.1 / BIND_ADDR (Docker bỏ qua ufw).
check-exposure:
	docker compose config --format json | python3 scripts/check_exposure.py --allow "$(BIND_ADDR)"

# Môi trường Python cho test/lint trên host (cần gói python3-venv).
# .venv/.installed đánh dấu đã cài xong (không touch .venv/bin/python vì là symlink tới python hệ thống).
venv: .venv/.installed

.venv/.installed: requirements.txt
	test -x .venv/bin/python || python3 -m venv .venv
	.venv/bin/pip install -r requirements.txt
	@touch $@

# Integration test với container postgres đang chạy (đọc .env và secrets/).
test-postgres: venv
	.venv/bin/python -m pytest tests/postgres -v -rs

# Password Debezium cho FileConfigProvider của kconnect, sinh lại từ .env mỗi lần
# để luôn khớp với user tạo bởi ddl/postgresql/02-roles.sh.
kconnect-secret:
	@mkdir -p secrets
	@test -n "$(PG_DEBEZIUM_PASSWORD)" || (echo "PG_DEBEZIUM_PASSWORD chưa set trong .env" && exit 1)
	@(umask 077 && printf 'password=%s\n' '$(PG_DEBEZIUM_PASSWORD)' > secrets/debezium.properties)

kafka-up: postgres-secret kconnect-secret
	mkdir -p kafka-cluster-volumes/kafka1/data kafka-cluster-volumes/kafka2/data kafka-cluster-volumes/kafka3/data
	docker run --rm -v $(CURDIR)/kafka-cluster-volumes:/data alpine chown -R 1000:1000 /data
	docker compose up -d --wait kafka1 kafka2 kafka3
	docker compose up -d --wait schema-registry kconnect
	docker compose up -d kafka-ui

register-schema:
	jq -n --rawfile schema schema/adjust-event.avsc '{"schema": $$schema}' | \
	curl -X POST \
	  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
	  --data @- \
	  http://localhost:8081/subjects/adjust.event-value/versions

register-connector:
	curl -X POST http://localhost:8083/connectors \
		-H "Content-Type: application/json" \
		-d '{"name": "streaming-connector", "config": {"connector.class": "io.debezium.connector.postgresql.PostgresConnector", "database.hostname": "postgres", "database.port": "5432", "database.user": "$(PG_DEBEZIUM_USER)", "database.password": "$${file:/run/secrets/debezium.properties:password}", "database.dbname": "$(PG_DATABASE)", "database.server.name": "adjust-dbserver", "slot.name": "debezium", "plugin.name": "pgoutput", "publication.name": "dbz_publication", "publication.autocreate.mode": "disabled", "table.include.list": "adjust.event", "topic.creation.default.replication.factor": "3", "topic.creation.default.partitions": "4", "value.converter": "io.confluent.connect.avro.AvroConverter", "value.converter.schema.registry.url": "http://schema-registry:8081", "value.converter.schemas.enable": "true", "value.subject.name.strategy": "io.confluent.kafka.connect.avro.AvroValueSubjectNameStrategy", "key.converter": "org.apache.kafka.connect.storage.StringConverter", "transforms": "unwrap", "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState"}}'

simulator-up:
	docker compose up -d simulator

minio-up:
	docker compose up -d minio minio-init iceberg-rest

# Submit mọi job trong CONFIG_JOBS (spark/spark_builder.py); chạy foreground tới khi job dừng.
# Job đọc cấu hình qua env, nên spark-up và spark-submit phải truyền cùng một bộ biến.
SPARK_SUBMIT = docker compose exec \
	-e ENV=$(ENV) \
	-e AWS_ACCESS_KEY_ID=$(AWS_ACCESS_KEY_ID) \
	-e AWS_SECRET_ACCESS_KEY=$(AWS_SECRET_ACCESS_KEY) \
	-e S3_ENDPOINT=$(S3_ENDPOINT) \
	-e ICEBERG_REST_URI=$(ICEBERG_REST_URI) \
	-e AWS_REGION=$(AWS_REGION) \
	spark-master /opt/spark/bin/spark-submit \
	--master spark://spark-master:7077 \
	/app/spark_builder.py

spark-up:
	docker compose up -d spark-master spark-worker-1 spark-worker-2
	$(SPARK_SUBMIT)

trino-up:
	docker compose up -d trino

metabase-up:
	docker compose up -d tooling-db metabase
	
down:
	docker compose down

build:
	docker compose build

restart:
	docker compose restart

logs:
	docker compose logs -f $(SERVICE)

ps:
	docker compose ps

spark-submit:
	$(SPARK_SUBMIT)

connector-status:
	curl http://localhost:8083/connectors/streaming-connector/status
