FROM rust:1.94-slim AS builder

WORKDIR /usr/src/app
COPY . .

RUN cargo build --release

# Create a minimal runtime image (trixie to match the glibc of rust:1.94-slim)
FROM debian:trixie-slim

RUN apt-get update && \
  apt-get install -y ca-certificates && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /usr/src/app/target/release/json2prom /app/json2prom

ENTRYPOINT ["/app/json2prom", "--config", "/etc/json2prom/config.yaml"]

EXPOSE 9100
