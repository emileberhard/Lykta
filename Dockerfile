FROM swift:6.4.1-noble@sha256:6304481cf2717966b7ba175162e397ea2f2cc3161909f2b2a5cf40036079a0f7 AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev zlib1g-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY Core Core
COPY Gateway Gateway
ARG JOBS
RUN --mount=type=cache,target=/src/Gateway/.build \
    swift build --package-path Gateway --configuration release --static-swift-stdlib --force-resolved-versions --product LyktaGateway ${JOBS:+--jobs $JOBS} \
    && cp Gateway/.build/release/LyktaGateway /usr/local/bin/lykta-gateway

FROM ubuntu:noble@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libcurl4t64 libsqlite3-0 zlib1g \
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
