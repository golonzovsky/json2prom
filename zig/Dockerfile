FROM debian:bookworm AS builder

ARG ZIG_VERSION=0.16.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    libjq-dev \
    xz-utils \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH="$(uname -m)" \
    && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ARCH}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY vendor ./vendor
COPY src ./src

RUN zig build -Doptimize=ReleaseSafe

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libjq1 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/zig-out/bin/json2prom /app/json2prom

EXPOSE 9102

ENTRYPOINT ["/app/json2prom", "--config", "/etc/json2prom/config.yaml"]
