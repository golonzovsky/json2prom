FROM golang:1.24.3 as builder

WORKDIR /usr/src/app
COPY . .

# Build the application with static linking
RUN CGO_ENABLED=0 go mod download && \
  CGO_ENABLED=0 go build -o json2prom -ldflags="-w -s" .

# Use distroless as minimal base image
FROM gcr.io/distroless/static:nonroot

WORKDIR /app

# Copy the binary from the builder stage
COPY --from=builder /usr/src/app/json2prom /app/json2prom

# Set the entrypoint
ENTRYPOINT ["/app/json2prom", "--config", "/etc/json2prom/config.yaml", "--log-level", "debug"]

# Expose Prometheus metrics port
EXPOSE 9100
