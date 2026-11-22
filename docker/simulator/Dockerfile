# Simulator (đóng vai backend app). Build từ gốc repo:
#   docker build -f docker/simulator/Dockerfile .
# Context chỉ gồm những gì liệt kê trong Dockerfile.dockerignore bên cạnh.
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY simulator/main.py .

EXPOSE 8000
# Không dùng --reload: chỉ dành cho dev, tốn CPU theo dõi file và restart giữa chừng.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
