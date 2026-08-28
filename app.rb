# frozen_string_literal: true

require "sinatra"
require "json"
require "sequel"
require "net/http"
require "uri"

DB = Sequel.connect(ENV.fetch("DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/carolina_dev"))

LANGUAGE = "Ruby"
LANGUAGE_VERSION = RUBY_VERSION
API_VERSION = "0.1.0"
FRAMEWORK = "Sinatra"
CREATED_YEAR = 2026
SCHEMA_VERSION = 1

ENDPOINTS = [
  { "method" => "GET", "path" => "/", "query" => [] },
  { "method" => "GET", "path" => "/health", "query" => [] },
  { "method" => "GET", "path" => "/v1/years", "query" => [] },
  { "method" => "GET", "path" => "/v1/speakers", "query" => ["year"] },
  { "method" => "GET", "path" => "/v1/speakers/:slug", "query" => [] },
  { "method" => "GET", "path" => "/v1/sponsors", "query" => ["year"] },
  { "method" => "GET", "path" => "/v1/sponsors/:slug", "query" => [] }
].freeze

set :bind, "0.0.0.0"
set :port, Integer(ENV.fetch("PORT", "4001"))
disable :protection

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
  dataset = DB[:v1_speakers]
  if params["year"]
    year = Integer(params["year"])
    slugs = DB[:v1_talks].where(year: year).select_map(:speaker_slug)
    dataset = dataset.where(slug: slugs)
  end
  JSON.generate(data: dataset.order(:last_name, :first_name).all.map { |r| stringify_keys(r) })
end

get "/v1/speakers/:slug" do
  speaker = DB[:v1_speakers].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless speaker

  talks = DB[:v1_talks].where(speaker_slug: params["slug"]).all
  payload = stringify_keys(speaker).merge("talks" => talks.map { |t| stringify_keys(t) })
  JSON.generate(data: payload)
end

get "/v1/sponsors" do
  dataset = DB[:v1_sponsors]
  if params["year"]
    year = Integer(params["year"])
    slugs = DB[:v1_sponsorships].where(year: year).select_map(:sponsor_slug)
    dataset = dataset.where(slug: slugs)
  end
  JSON.generate(data: dataset.order(:name).all.map { |r| stringify_keys(r) })
end

get "/v1/sponsors/:slug" do
  sponsor = DB[:v1_sponsors].where(slug: params["slug"]).first
  halt 404, JSON.generate(error: "not_found") unless sponsor

  sponsorships = DB[:v1_sponsorships].where(sponsor_slug: params["slug"]).all
  payload = stringify_keys(sponsor).merge("sponsorships" => sponsorships.map { |s| stringify_keys(s) })
  JSON.generate(data: payload)
end

def stringify_keys(row)
  row.each_with_object({}) do |(key, value), acc|
    acc[key.to_s] = value
  end
end

def register_with_elixir
  url = ENV["CAROLINA_URL"]
  token = ENV["POLYGLOT_REGISTER_TOKEN"]
  return if url.nil? || url.empty? || token.nil? || token.empty?

  uri = URI.join(url.end_with?("/") ? url : "#{url}/", "internal/api-endpoints/register")
  body = {
    language: LANGUAGE,
    language_version: LANGUAGE_VERSION,
    api_version: API_VERSION,
    framework: FRAMEWORK,
    created_year: CREATED_YEAR,
    schema_version: SCHEMA_VERSION,
    base_url: ENV.fetch("PUBLIC_BASE_URL", "http://127.0.0.1:#{settings.port}"),
    endpoints: ENDPOINTS
  }

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{token}"
  req["Content-Type"] = "application/json"
  req.body = JSON.generate(body)
  http.request(req)
rescue StandardError => e
  warn "registration failed: #{e.message}"
end

register_with_elixir
