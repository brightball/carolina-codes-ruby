# frozen_string_literal: true

ENV["RACK_ENV"] = "test"
ENV["APP_ENV"] = "test"
ENV.delete("CAROLINA_URL")
ENV.delete("POLYGLOT_REGISTER_TOKEN")

require "minitest/autorun"
require "json"
require "rack/mock"
require "yaml"

require_relative "fake_catalog"
require_relative "../lib/catalog_counters"

CatalogCounters.connect_fn = -> { FakeCatalog.database }

require_relative "../app"

module CarolinaTest
  def mock_request
    Rack::MockRequest.new(Sinatra::Application)
  end

  def get(path)
    mock_request.get(path)
  end

  def json_body(response)
    JSON.parse(response.body)
  end
end
