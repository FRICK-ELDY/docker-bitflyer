# 開発用。ソースは Compose で bind mount する。イメージにはソースを埋め込まない。
FROM elixir:1.18.3-otp-27-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git \
    inotify-tools \
    postgresql-client \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
  && mix local.rebar --force

WORKDIR /app

# 起動時の ash.setup / DB 待ちは compose の entrypoint（bin/docker-entrypoint.sh）が担う。
CMD ["mix", "phx.server"]
