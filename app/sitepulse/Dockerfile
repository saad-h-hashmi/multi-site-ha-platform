# SitePulse demo application: Python standard library only, runs as non-root.
FROM python:3.13-alpine
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PORT=8000
WORKDIR /app
COPY app.py /app/app.py
RUN adduser -D -H -u 10001 sitepulse
USER 10001
EXPOSE 8000
HEALTHCHECK --interval=10s --timeout=2s CMD wget -qO- http://127.0.0.1:8000/healthz || exit 1
LABEL org.opencontainers.image.title="sitepulse" \
      org.opencontainers.image.description="Multi-site HA platform demo application"
ENTRYPOINT ["python3", "/app/app.py"]
