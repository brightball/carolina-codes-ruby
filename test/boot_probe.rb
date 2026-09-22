# frozen_string_literal: true

# Fresh-process boot for cold_start_test. The fake-catalog hook is installed
# before the shipped app loads, then GET /health is served on stdout.
# Registration is joined afterward so a hanging peer cannot keep the process up.
require "json"
require "rack/mock"

require_relative "fake_catalog"
require_relative "../lib/catalog_counters"

CatalogCounters.connect_fn = -> { FakeCatalog.database }

require_relative "../app"

response = Rack::MockRequest.new(Sinatra::Application).get("/health")
puts "HEALTH #{response.body}"
$stdout.flush

# Join only the registration attempt. Ruby's Timeout watcher thread never
# exits; joining it deadlocks the process.
Thread.list.each do |thread|
  next unless thread.name == "carolina-registration"

  thread.join
end

puts "COUNTS sql=#{CatalogCounters.sql_count} connect=#{CatalogCounters.connect_count}"
$stdout.flush
