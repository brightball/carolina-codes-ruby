FROM ruby:3.3-bookworm
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*
