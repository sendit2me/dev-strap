FROM python:3.12-slim

# uv for fast dependency management
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# CA certificates package (needed for update-ca-certificates in init)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies first (layer caching)
COPY requirements.txt* pyproject.toml* ./
RUN if [ -f requirements.txt ]; then uv pip install --system -r requirements.txt; \
    elif [ -f pyproject.toml ]; then uv pip install --system -e .; fi

# Don't COPY app source — it's volume-mounted in dev

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Python trusts it via REQUESTS_CA_BUNDLE and SSL_CERT_FILE set in service.yml.
# For OS-level trust (e.g., subprocess calls), add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# uvicorn with --reload for live development
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "3000", "--reload"]
