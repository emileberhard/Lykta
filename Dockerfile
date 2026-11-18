FROM swift:6.4.2-noble@sha256:23d9b28ad97fb1cf1999edc3a0cb265ee915ed42299a9344e7173d5a6d2b05f4 AS build
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

FROM ubuntu:noble@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8
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
