FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates xz-utils gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Install Zig 0.13.0
RUN curl -sSL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz | tar -xJ --strip-components=1 -C /usr/local/bin

COPY . .

# Build the LIR compiler
RUN zig build -Doptimize=ReleaseFast

# Runtime stage
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/zig-out/bin/lir /usr/local/bin/lir

WORKDIR /app

ENTRYPOINT ["lir"]
CMD ["help"]
