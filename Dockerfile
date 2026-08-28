FROM ruby:3.3-alpine

RUN apk add --no-cache build-base postgresql-dev

WORKDIR /app
COPY Gemfile Gemfile.lock* ./
RUN bundle install
COPY . .

ENV PORT=8080
EXPOSE 8080
CMD ["bundle", "exec", "puma", "-p", "8080", "config.ru"]
