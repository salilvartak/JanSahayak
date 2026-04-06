FROM python:3.11-slim

# System libs required by:
#   opencv-headless  → libglib2.0, libgomp1
#   Azure Speech SDK → libssl3, libicu, libasound2
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libgomp1 \
    libssl3 \
    ca-certificates \
    libasound2 \
    libgl1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app code and model
COPY . .

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
