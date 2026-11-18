FROM rust:1.94.1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto/ proto/
COPY src/ src/
RUN cargo build --locked --release

FROM scratch AS binary
COPY --from=build /build/target/release/atermius-agent /atermius-agent

FROM debian:bookworm-slim AS hub
RUN install -d -m 0700 -o 10001 -g 10001 /state
COPY --from=build /build/target/release/atermius-agent /usr/local/bin/atermius-agent
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/atermius-agent"]
