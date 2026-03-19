FROM golang:1.24-alpine

# Air for live-reload on file changes
RUN go install github.com/air-verse/air@latest

WORKDIR /app

# Download dependencies first (layer caching)
COPY go.mod go.sum* ./
RUN go mod download 2>/dev/null || true

COPY . .

# Trust the devstack CA
COPY /certs/ca.crt /usr/local/share/ca-certificates/devstack-ca.crt 2>/dev/null || true
RUN update-ca-certificates 2>/dev/null || true

EXPOSE 3000

# Default: air for live-reload. Override with `go run .` for simpler setup.
CMD ["air", "-c", ".air.toml"]
