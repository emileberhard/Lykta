FROM node:24-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl procps python3 ripgrep tzdata \
    && rm -rf /var/lib/apt/lists/* && ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime
RUN npm install -g @openai/codex @anthropic-ai/claude-code
ENV TZ=Europe/Stockholm
WORKDIR /app
