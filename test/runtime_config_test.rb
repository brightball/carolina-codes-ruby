# frozen_string_literal: true

require_relative "test_helper"

class RuntimeConfigTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_production_image_installs_locked_gems_without_a_runtime_compiler
    dockerfile = File.read(File.join(ROOT, "Dockerfile"))
    stages = dockerfile.split(/^FROM /).select { |part| part.include?("ruby:") }
    assert_equal 2, stages.size
    build, runtime = stages

    assert_match(%r{COPY Gemfile Gemfile\.lock \./}, build)
    refute_match(/Gemfile\.lock\*/, dockerfile)
    assert_match(/BUNDLE_FROZEN=1/, build)
    assert_match(/bundle install/, build)
    assert_match(/build-base/, build)

    refute_match(/build-base/, runtime)
    refute_match(/\bgcc\b/, runtime)
    refute_match(/\bg\+\+/, runtime)
    refute_match(/bundle install/, runtime)
    refute_match(%r{vendor/bundle}, dockerfile)
    assert_match(%r{COPY --from=build /usr/local/bundle /usr/local/bundle}, runtime)
    assert_match(/BUNDLE_FROZEN=1/, runtime)
    assert_match(%r{BUNDLE_PATH=/usr/local/bundle}, runtime)
    assert_match(/puma/, runtime)
    assert_match(/config\.ru/, runtime)
    assert_match(%r{config/puma\.rb}, runtime)
    refute_match(/0\.0\.0\.0/, dockerfile)

    ignore = File.read(File.join(ROOT, ".dockerignore"))
    assert_match(%r{(^|\n)\.git/?(?:\n|\z)}, ignore)
    assert_match(%r{(^|\n)vendor/?(?:\n|\z)}, ignore)
  end

  def test_fly_stops_when_idle_and_puma_binds_ipv6
    fly = File.read(File.join(ROOT, "fly.toml"))
    puma = File.read(File.join(ROOT, "config/puma.rb"))
    app = File.read(File.join(ROOT, "app.rb"))

    assert_match(/app\s*=\s*"carolina-codes-ruby"/, fly)
    assert_match(/internal_port\s*=\s*8080/, fly)
    assert_match(%r{path\s*=\s*"/health"}, fly)
    assert_match(/memory\s*=\s*"256mb"/, fly)
    assert_match(/cpu_kind\s*=\s*"shared"/, fly)
    assert_match(/cpus\s*=\s*1/, fly)
    assert_match(/min_machines_running\s*=\s*0\b/, fly)
    assert_match(/auto_stop_machines\s*=\s*"(?:stop|suspend)"/, fly)
    assert_match(/auto_start_machines\s*=\s*true/, fly)
    refute_match(/auto_stop_machines\s*=\s*"off"/, fly)

    assert_match(%r{bind "tcp://\[::\]:}, puma)
    refute_match(/0\.0\.0\.0/, puma)
    refute_match(/^\s*workers\s+[1-9]/, puma)
    assert_match(/LISTEN_HOST = "::"/, app)
    refute_match(/0\.0\.0\.0/, app)
  end
end
