# syntax=docker/dockerfile:1.7
# =============================================================================
# StrongMind standard Rails 8 production image
#
# Stages: builder (toolchain, gems, assets) -> runtime (compiled results only).
# The pipeline pushes `--target runtime`.
#
# Base image: ruby:3.3-slim over ruby:3.3-alpine. pg, nokogiri, bootsnap and
# bcrypt compile native extensions; on glibc they build cleanly or ship
# precompiled, on musl they periodically break. The ~40 MB size gap after
# multi-stage trimming does not buy back a class of production-only failures.
#
# The pipeline passes --build-arg RUBY_VERSION from .ruby-version so the
# image and CI never drift.
# =============================================================================

ARG RUBY_VERSION=3.3
FROM docker.io/library/ruby:${RUBY_VERSION}-slim-bookworm AS base

WORKDIR /rails

# Production defaults; any of these can be overridden in the task definition.
ENV RAILS_ENV=production \
    RACK_ENV=production \
    RAILS_LOG_TO_STDOUT=1 \
    RAILS_SERVE_STATIC_FILES=1 \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT="development:test" \
    LANG=C.UTF-8 \
    PORT=3000

# Runtime-only packages. Deliberately absent: libvips (only for ActiveStorage
# variants), postgresql-client (psql belongs in a debug sidecar), curl (the
# HEALTHCHECK uses Ruby's stdlib).
#
# DL3008 (pin apt versions) is ignored: pinned Debian versions break the build
# on every security patch. Reproducibility comes from the base image digest.
# hadolint ignore=DL3008
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      ca-certificates \
      libjemalloc2 \
      libpq5 \
      tzdata && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    # Arch-neutral path so one LD_PRELOAD value works for amd64 and arm64.
    ln -s "/usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2" /usr/local/lib/libjemalloc.so.2

# =============================================================================
FROM base AS builder

# Build toolchain; none of it reaches the runtime stage. No Node: assumes
# Propshaft + importmap (Rails 8 default). For jsbundling, add a node stage.
# hadolint ignore=DL3008
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential \
      git \
      libpq-dev \
      libyaml-dev \
      pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Gems on their own layer so app code changes do not invalidate the bundle.
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs "$(nproc)" --retry 3 && \
    # Gem source caches and git checkouts: the largest single size win.
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # Pay the bootsnap cost here, not while the ALB waits on first boot.
    bundle exec bootsnap precompile --gemfile

COPY . .

# SECRET_KEY_BASE_DUMMY lets Rails boot without credentials at build time.
# RAILS_MASTER_KEY is never a build arg: it would persist in layer history.
RUN bundle exec bootsnap precompile app/ lib/ && \
    SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    rm -rf tmp/cache node_modules app/assets/builds/.keep 2>/dev/null || true

# =============================================================================
FROM base AS runtime

# Set by the pipeline; surfaced in logs for correlation.
ARG GIT_SHA=unknown
ENV GIT_SHA=${GIT_SHA}

# jemalloc cuts memory fragmentation in long-running Puma processes. Same
# allocator Rails 8's generated Dockerfile uses.
ENV LD_PRELOAD=/usr/local/lib/libjemalloc.so.2 \
    MALLOC_CONF=dirty_decay_ms:1000,narenas:2,background_thread:true

# Fixed uid so ECS `user` and file ownership are predictable.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash

# No --chown: code and gems stay root-owned and read-only to the app user,
# so a compromised process cannot rewrite what it is running.
COPY --from=builder "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=builder /rails /rails

# The only directories Rails writes at runtime.
RUN mkdir -p db log storage tmp/pids tmp/cache && \
    chown -R rails:rails db log storage tmp

# Numeric so the runtime can verify non-root without reading /etc/passwd.
USER 1000:1000

# Not 80: a non-root process would need CAP_NET_BIND_SERVICE, and the ALB
# terminates TLS anyway.
EXPOSE 3000

# /up is the Rails 7.1+ health endpoint: boots the app, does not touch the
# database. That is the right "is this process alive" semantics; DB health
# belongs to the RDS alarms. Ruby stdlib rather than curl keeps an HTTP
# client out of the image.
#
# Fargate ignores this instruction. The task definition needs the same
# command in its `healthCheck` block:
#   ["CMD", "ruby", "-rnet/http", "-e",
#    "exit(Net::HTTP.get_response(URI('http://127.0.0.1:3000/up')).code == '200' ? 0 : 1)"]
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD ["ruby", "-rnet/http", "-e", "exit(Net::HTTP.get_response(URI('http://127.0.0.1:3000/up')).code == '200' ? 0 : 1)"]

# Rails 8 generated entrypoint: runs `db:prepare` on server start, then execs
# the command. This is where migrations run. The 30s start-period above and
# minimumHealthyPercent=100 on the service give it room.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Puma reads PORT, WEB_CONCURRENCY and RAILS_MAX_THREADS from the environment;
# tune per task size in the task definition, not here.
CMD ["./bin/rails", "server", "-b", "0.0.0.0"]