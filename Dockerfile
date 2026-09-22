# Compile native gems in the build stage. The runtime stage has no compiler
# and does not install gems when the container starts. Gems are locked to
# Gemfile.lock inside the image bundle.
FROM ruby:3.3-alpine AS build

RUN apk add --no-cache build-base postgresql-dev

WORKDIR /app

COPY Gemfile Gemfile.lock ./

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_FROZEN=1 \
    BUNDLE_PATH=/usr/local/bundle

RUN bundle install --jobs 4

FROM ruby:3.3-alpine AS runtime

RUN apk add --no-cache libpq

WORKDIR /app

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY . .

ENV BUNDLE_WITHOUT=development:test \
    BUNDLE_FROZEN=1 \
    BUNDLE_PATH=/usr/local/bundle \
    RACK_ENV=production \
    PORT=8080

EXPOSE 8080

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb", "config.ru"]
