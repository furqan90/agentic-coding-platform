FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY static ./static

RUN useradd --system --uid 10001 onboarding
USER onboarding
EXPOSE 8000
CMD ["uvicorn", "app:app_from_env", "--factory", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
