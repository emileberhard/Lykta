FROM swift:6.4.2-noble@sha256:bca121f6eb59fd80340d1296887b2698ed8f3eb9eca7d80c181f8af769dc7ee0 AS build
ARG APT_SNAPSHOT
RUN snapshot="${APT_SNAPSHOT:-$(date -u -d '24 hours ago' +%Y%m%dT%H%M%SZ)}" \
    && apt-get -o Acquire::Retries=10 -S "$snapshot" update && apt-get -o Acquire::Retries=10 -S "$snapshot" install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Core Core
COPY Gateway Gateway
ARG JOBS
RUN --mount=type=cache,target=/src/Gateway/.build \
    swift build --package-path Gateway --configuration release --static-swift-stdlib --force-resolved-versions --product LyktaGateway ${JOBS:+--jobs $JOBS} \
    && cp Gateway/.build/release/LyktaGateway /usr/local/bin/lykta-gateway

FROM ubuntu:noble@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852
ARG APT_SNAPSHOT
RUN snapshot="${APT_SNAPSHOT:-$(date -u -d '24 hours ago' +%Y%m%dT%H%M%SZ)}" \
    && apt-get -o Acquire::Retries=10 -S "$snapshot" update && apt-get -o Acquire::Retries=10 -S "$snapshot" install -y --no-install-recommends ca-certificates libcurl4t64 libsqlite3-0 zlib1g \
    && rm -rf /var/lib/apt/lists/* && useradd --system --create-home --home-dir /data lykta
COPY --from=build /usr/local/bin/lykta-gateway /usr/local/bin/lykta-gateway
USER lykta
WORKDIR /data
ENV LYKTA_HOST=0.0.0.0 LYKTA_DATABASE=/data/lykta.sqlite
ARG LYKTA_VERSION
ENV LYKTA_VERSION=${LYKTA_VERSION}
LABEL org.opencontainers.image.version=${LYKTA_VERSION}
EXPOSE 8080
VOLUME /data
ENTRYPOINT ["lykta-gateway"]
