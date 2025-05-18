FROM rust:1.86-slim as builder

WORKDIR /usr/src/app
COPY . .

# Install build dependencies
RUN apt-get update && \
  apt-get install -y pkg-config libssl-dev && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Build the application in release mode
RUN cargo build --release

# Create a minimal runtime image
FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && \
  apt-get install -y ca-certificates libssl3 && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the binary from the builder stage
COPY --from=builder /usr/src/app/target/release/json2prom /app/json2prom

# Set the entrypoint
ENTRYPOINT ["/app/json2prom", "--config", "/etc/json2prom/config.yaml"]

# Expose Prometheus metrics port
EXPOSE 9100
