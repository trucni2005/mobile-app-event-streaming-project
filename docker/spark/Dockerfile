# Spark (master/worker/history server + code job). Build từ gốc repo:
#   docker build -f docker/spark/Dockerfile .
# Context chỉ gồm những gì liệt kê trong Dockerfile.dockerignore bên cạnh.
FROM apache/spark:4.0.0-scala2.13-java17-python3-ubuntu

USER root

RUN pip install pyyaml requests

COPY docker/spark/jars.txt /tmp/jars.txt

RUN cd /opt/spark/jars && \
    grep -v '^$' /tmp/jars.txt | while read jar; do \
        org=$(echo "$jar" | cut -d: -f1); \
        artifact=$(echo "$jar" | cut -d: -f2); \
        version=$(echo "$jar" | cut -d: -f3); \
        org_path=$(echo "$org" | sed 's/\./\//g'); \
        url="https://repo1.maven.org/maven2/${org_path}/${artifact}/${version}/${artifact}-${version}.jar"; \
        echo "Downloading: $url"; \
        curl -fL -O "$url" || exit 1; \
    done

COPY spark /app
