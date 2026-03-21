FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY zig-out/bin/kaisha-server /usr/local/bin/kaisha-server
WORKDIR /workspace
EXPOSE 8420
ENTRYPOINT ["kaisha-server"]
