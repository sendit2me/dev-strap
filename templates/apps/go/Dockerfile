FROM golang:1.24-alpine

# Air for live-reload on file changes
RUN go install github.com/air-verse/air@latest

# CA certificates package (needed for update-ca-certificates at runtime)
RUN apk add --no-cache ca-certificates

WORKDIR /app

# Download dependencies first (layer caching)
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true

COPY . .

# NOTE: The DevStack CA cert is mounted at /certs/ca.crt at runtime (not build time).
# Go trusts it via SSL_CERT_FILE=/certs/ca.crt set in service.yml.
# If you need OS-level trust (e.g. for CGO or exec'd subprocesses), add this to init.sh:
#   cp /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt && update-ca-certificates

EXPOSE 3000

# Default: air for live-reload. Override with `go run .` for simpler setup.
CMD ["air", "-c", ".air.toml"]
