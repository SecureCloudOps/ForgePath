FROM python:3.12.13-alpine3.23@sha256:601d3d3797e90e2534782e69c85fafb7971b43f24c7b1b079b7e48dd435e458d

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --disable-pip-version-check \
      --root-user-action=ignore -r requirements.txt
COPY --chown=10001:10001 app ./app

USER 10001:10001
EXPOSE 8080
CMD ["python", "-m", "uvicorn", "app.main:app", "--host=0.0.0.0", "--port=8080", "--no-access-log"]
