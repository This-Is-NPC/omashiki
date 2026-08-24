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

FROM alpine:3.19

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/omashiki ./

ENV HOME=/app
EXPOSE 4000

CMD ["bin/migrate"]
