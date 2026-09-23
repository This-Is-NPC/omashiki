FROM elixir:1.17-alpine AS builder

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY assets/package.json assets/package-lock.json assets/
RUN npm ci --prefix assets

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets
COPY rel rel

RUN mix assets.deploy
RUN mix compile
RUN mix release

FROM alpine:3.22

# docker-cli: an embedded house loads its configuration by running each
# agent image to check that it provides the plugin's binaries.
RUN apk add --no-cache libstdc++ openssl ncurses-libs git docker-cli \
 && git config --system --add safe.directory '*'

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/omashiki ./

# gitleaks scans job output for secrets before it is published. The official
# image, pinned by digest, ships a static binary for each architecture.
COPY --from=ghcr.io/gitleaks/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f \
     /usr/bin/gitleaks /usr/local/bin/gitleaks

# The release writes its runtime configuration under RELEASE_TMP at each
# start. /tmp is writable by whichever user runs the container.
ENV HOME=/app \
    RELEASE_TMP=/tmp
EXPOSE 4000

CMD ["bin/entrypoint"]

