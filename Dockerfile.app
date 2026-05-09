# Sandbox demo app — a minimal Flask "Hello World" with /health endpoint
FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir flask==3.0.3

COPY app/ .

EXPOSE 5000

CMD ["python", "app.py"]
