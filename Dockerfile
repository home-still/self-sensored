FROM rust:1.94-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY api/ api/
COPY mcp/ mcp/
RUN cargo build --release -p self-sensored-api -p self-sensored-mcp

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=builder /app/target/release/self-sensored-api /usr/local/bin/
COPY --from=builder /app/target/release/self-sensored-mcp /usr/local/bin/
USER app
EXPOSE 3000 7446
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost:3000/health || exit 1
CMD ["self-sensored-api"]
