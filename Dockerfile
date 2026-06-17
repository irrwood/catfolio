FROM python:3.11-slim

WORKDIR /app

# Install dependencies first (cached layer)
COPY v3_backend/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY scripts/ scripts/
COPY v3_backend/ v3_backend/

WORKDIR /app/v3_backend

ENV CATFOLIO_DATA_DIR=/data
ENV CATFOLIO_DEMO=0

EXPOSE 8787

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8787"]
