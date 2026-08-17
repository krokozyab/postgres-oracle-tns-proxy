FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --uid 10001 orapglink
COPY --chmod=0755 orapglink /usr/local/bin/orapglink

USER orapglink
EXPOSE 1521
ENTRYPOINT ["/usr/local/bin/orapglink"]
