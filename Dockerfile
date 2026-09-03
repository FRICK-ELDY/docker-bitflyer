# 開発用。ソースは Compose で bind mount する。イメージにはソースを埋め込まない。
FROM elixir:1.18.3-otp-27-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    inotify-tools \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
  && mix local.rebar --force

WORKDIR /app

# `docker compose run --rm app mix ...` で上書きする。常駐時は空待ち。
CMD ["sleep", "infinity"]
