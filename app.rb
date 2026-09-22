# frozen_string_literal: true

require "sinatra"
require "json"
require "sequel"
require "net/http"
require "uri"
require_relative "lib/catalog_counters"

LISTEN_HOST = "::"

CatalogCounters.reset!

def listen_host
  LISTEN_HOST
end

def listen_bind
  LISTEN_HOST
end

def wrap_execute!(database)
  return database if database.nil?
  return database if database.singleton_methods.include?(:__carolina_execute)

  database.define_singleton_method(:__carolina_execute, database.method(:execute))
  database.define_singleton_method(:execute) do |*args, &block|
    CatalogCounters.inc_sql
    if CatalogCounters.query_fn
      CatalogCounters.query_fn.call(*args, &block)
    else
      __carolina_execute(*args, &block)
    end
  end
  database
end

def open_pool
  CatalogCounters.inc_connect
  return CatalogCounters.connect_fn.call if CatalogCounters.connect_fn

  url = ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/carolina_dev")
  db = Sequel.connect(url, max_connections: 8)
  Sequel.extension :pg_array
  db.extension :pg_array
  db
end

DB = wrap_execute!(open_pool)

LANGUAGE = "Ruby"
LANGUAGE_VERSION = RUBY_VERSION
API_VERSION = "0.2.0"
FRAMEWORK = "Sinatra"
CREATED_YEAR = 2026
SCHEMA_VERSION = 1

ENDPOINTS = [
  { "method" => "GET", "path" => "/", "query" => [] },
  { "method" => "GET", "path" => "/health", "query" => [] },
  { "method" => "GET", "path" => "/v1/years", "query" => [] },
  { "method" => "GET", "path" => "/v1/speakers", "query" => ["year"] },
  { "method" => "GET", "path" => "/v1/speakers/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/speakers/:year/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/sponsors", "query" => ["year"] },
  { "method" => "GET", "path" => "/v1/sponsors/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/sponsors/:year/:slug", "query" => [] }
].freeze

set :bind, listen_bind
set :port, Integer(ENV.fetch("PORT", "4001"))
disable :protection
# Empty list allows all Host headers (Fly *.fly.dev + internal checks).
set :host_authorization, permitted_hosts: []

before do
  content_type :json
  headers "X-Polyglot-Language" => LANGUAGE, "X-Polyglot-Framework" => FRAMEWORK
end

get "/" do
  JSON.generate(
    language: LANGUAGE,
    language_version: LANGUAGE_VERSION,
    api_version: API_VERSION,
    framework: FRAMEWORK,
    created_year: CREATED_YEAR,
    schema_version: SCHEMA_VERSION,
    endpoints: ENDPOINTS
  )
end

get "/health" do
  JSON.generate(ok: true)
end

get "/v1/years" do
  rows = DB[:v1_years].order(Sequel.desc(:year)).all
  JSON.generate(data: rows.map { |r| stringify_keys(r) })
end

get "/v1/speakers" do
  if params["year"]
    year = Integer(params["year"])
    JSON.generate(data: year_speakers(year))
  else
    dataset = DB[:v1_speakers].order(:last_name, :first_name)
    JSON.generate(data: dataset.all.map { |r| stringify_keys(r) })
  end
end

get %r{/v1/speakers/(\d{4})/([^/]+)} do |year, slug|
  year = Integer(year)
  speaker = DB[:v1_speakers].where(slug: slug).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  payload = speaker_with_year(speaker, year)
  halt 404, JSON.generate(error: "not_found") if payload["talks"].empty?
  JSON.generate(data: payload)
end

get "/v1/speakers/:slug" do
  speaker = DB[:v1_speakers].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  talks = DB[:v1_talks].where(speaker_slug: params["slug"]).all
  years = talks.map { |t| t[:year] || t["year"] }.uniq.sort.reverse
  payload = stringify_keys(speaker).merge(
    "years" => years,
    "talks" => talks.map { |t| stringify_keys(t) }
  )
  JSON.generate(data: payload)
end

get "/v1/sponsors" do
  if params["year"]
    year = Integer(params["year"])
    rows = DB[:v1_year_sponsors].where(year: year).order(:name).all
    JSON.generate(data: rows.map { |r| stringify_keys(r) })
  else
    dataset = DB[:v1_sponsors].order(:name)
    JSON.generate(data: dataset.all.map { |r| stringify_keys(r) })
  end
end

get %r{/v1/sponsors/(\d{4})/([^/]+)} do |year, slug|
  year = Integer(year)
  row = DB[:v1_year_sponsors].where(year: year, slug: slug).first
  halt 404, JSON.generate(error: "not_found") unless row

  years = DB[:v1_sponsorships].where(sponsor_slug: slug).select_map(:year).uniq.sort.reverse
  payload = stringify_keys(row).merge(
    "years" => years,
    "other_years" => years.reject { |y| y == year },
    "sponsorships" => DB[:v1_sponsorships].where(sponsor_slug: slug).all.map { |s| stringify_keys(s) }
  )
  JSON.generate(data: payload)
end

get "/v1/sponsors/:slug" do
  sponsor = DB[:v1_sponsors].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless sponsor

  sponsorships = DB[:v1_sponsorships].where(sponsor_slug: params["slug"]).all
  payload = stringify_keys(sponsor).merge("sponsorships" => sponsorships.map { |s| stringify_keys(s) })
  JSON.generate(data: payload)
end

def year_speakers(year)
  speakers = DB[:v1_speakers]
             .where(slug: DB[:v1_talks].where(year: year).select(:speaker_slug))
             .order(:last_name, :first_name)
             .all
  attach_year_tags(speakers, year)
end

def attach_year_tags(speakers, year)
  return [] if speakers.empty?

  slugs = speakers.map { |speaker| speaker[:slug] || speaker["slug"] }
  talks_by = load_talks_for_year(year)
  years_by = load_years_for_slugs(slugs)
  speakers.map do |speaker|
    slug = speaker[:slug] || speaker["slug"]
    talks = Array(talks_by[slug]).map { |talk| stringify_keys(talk) }
    years = Array(years_by[slug])
    stringify_keys(speaker).merge(
      "year" => year,
      "years" => years,
      "other_years" => years.reject { |y| y == year },
      "talks" => talks,
      "languages" => unique_tags(talks, "languages"),
      "topics" => unique_tags(talks, "topics")
    )
  end
end

def load_talks_for_year(year)
  DB[:v1_talks].where(year: year).order(:speaker_slug, Sequel.desc(:year)).all
               .group_by { |talk| talk[:speaker_slug] || talk["speaker_slug"] }
end

def load_years_for_slugs(slugs)
  return {} if slugs.empty?

  rows = DB[:v1_talks]
         .where(speaker_slug: slugs)
         .select(:speaker_slug, :year)
         .distinct
         .order(:speaker_slug, Sequel.desc(:year))
         .all
  grouped = {}
  rows.each do |row|
    slug = row[:speaker_slug] || row["speaker_slug"]
    year = row[:year] || row["year"]
    bucket = (grouped[slug] ||= [])
    bucket << year unless bucket.include?(year)
  end
  grouped.transform_values { |years| years.sort.reverse }
end

def speaker_with_year(speaker, year)
  slug = speaker[:slug] || speaker["slug"]
  talks = DB[:v1_talks].where(speaker_slug: slug, year: year).all.map { |t| stringify_keys(t) }
  years = DB[:v1_talks].where(speaker_slug: slug).select_map(:year).uniq.sort.reverse
  stringify_keys(speaker).merge(
    "year" => year,
    "years" => years,
    "other_years" => years.reject { |y| y == year },
    "talks" => talks,
    "languages" => unique_tags(talks, "languages"),
    "topics" => unique_tags(talks, "topics")
  )
end

def unique_tags(talks, key)
  talks.flat_map { |talk| pg_text_array(talk[key]) }.uniq
end

def pg_text_array(value)
  case value
  when nil
    []
  when Array
    value.map(&:to_s).reject(&:empty?)
  when String
    stripped = value.strip
    return [] if stripped.empty? || stripped == "{}"

    inner = stripped.start_with?("{") && stripped.end_with?("}") ? stripped[1..-2] : stripped
    inner.split(",").map { |part| part.gsub(/\A"|"\z/, "").strip }.reject(&:empty?)
  else
    Array(value).map(&:to_s).reject(&:empty?)
  end
end

def stringify_keys(row)
  row.each_with_object({}) do |(key, value), acc|
    name = key.to_s
    acc[name] = %w[languages topics].include?(name) ? pg_text_array(value) : value
  end
end

# One attempt, off the listen path. A peer that accepts and never answers
# must not hold Puma's boot or GET /health.
REGISTRATION_TIMEOUT = 1
REGISTRATION_LOCK = Mutex.new

def claim_registration
  REGISTRATION_LOCK.synchronize do
    claimed = @registration_started
    @registration_started = true
    !claimed
  end
end

def registration_payload
  {
    language: LANGUAGE,
    language_version: LANGUAGE_VERSION,
    api_version: API_VERSION,
    framework: FRAMEWORK,
    created_year: CREATED_YEAR,
    schema_version: SCHEMA_VERSION,
    base_url: ENV.fetch("PUBLIC_BASE_URL", "http://127.0.0.1:#{settings.port}"),
    endpoints: ENDPOINTS
  }
end

def register_with_elixir
  url = ENV["CAROLINA_URL"].to_s
  token = ENV["POLYGLOT_REGISTER_TOKEN"].to_s
  return if url.empty? || token.empty?
  return unless claim_registration

  payload = JSON.generate(registration_payload)
  thread = Thread.new do
    Thread.current.report_on_exception = false
    post_registration(url, token, payload)
  end
  thread.name = "carolina-registration"
  thread
end

def post_registration(url, token, payload)
  uri = URI.join(url.end_with?("/") ? url : "#{url}/", "internal/api-endpoints/register")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = REGISTRATION_TIMEOUT
  http.read_timeout = REGISTRATION_TIMEOUT
  http.write_timeout = REGISTRATION_TIMEOUT
  http.max_retries = 0 if http.respond_to?(:max_retries=)
  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = payload
  http.request(request)
rescue StandardError => e
  warn "registration failed: #{e.message}"
ensure
  close_registration(http)
end

def close_registration(http)
  http.finish if http&.started?
rescue StandardError
  nil
end

register_with_elixir
