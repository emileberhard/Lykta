FROM swift:6.4.1-noble@sha256:19cbe56bdaec1918f7cf5fdeba42b9bd55bdd8a6149c9990d0e0e3a89a127d63 AS build
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

FROM ubuntu:noble@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac
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
