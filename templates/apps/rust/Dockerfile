FROM rust:1.83-slim

# System dependencies for common crates (openssl, database drivers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

# cargo-watch for live reload on file changes
RUN cargo install cargo-watch

WORKDIR /app

# Copy dependency files first (layer caching)
COPY Cargo.toml Cargo.lock* ./
# Create a dummy main.rs so cargo can resolve/download dependencies
RUN mkdir -p src && echo 'fn main() {}' > src/main.rs \
    && cargo build 2>/dev/null || true \
    && rm -rf src

COPY . .

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Rust trusts it via SSL_CERT_FILE=/certs/ca.crt set in service.yml.
# For apps that need to reach both mocked and real HTTPS endpoints, add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# cargo-watch rebuilds and runs on file changes
CMD ["cargo", "watch", "-x", "run"]
