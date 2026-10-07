# frozen_string_literal: true

require "minitest/autorun"

# Reads the shipped docs and the version pin files. A lockfile bump that
# leaves README.md behind fails here.
class DocsContractTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  DOC_NAMES = %w[README.md AGENTS.md MEMORY.md DECISIONS.md].freeze

  CONTRACT_PHRASES = [
    "v1_speakers",
    "v1_sponsors",
    "v1_years",
    "v1_talks",
    "v1_sponsorships",
    "v1_year_speakers",
    "v1_year_sponsors",
    "never Ash tables",
    "`GET /health`",
    "`GET /`",
    "/v1/years",
    "/v1/speakers",
    "/v1/sponsors",
    "/v1/speakers?year=",
    "/v1/sponsors?year=",
    "/v1/speakers/{slug}",
    "/v1/speakers/{year}/{slug}",
    "/v1/sponsors/{slug}",
    "/v1/sponsors/{year}/{slug}",
    "Register once on boot",
    "no heartbeat",
    "DATABASE_URL",
    "CAROLINA_URL",
    "POLYGLOT_REGISTER_TOKEN",
    "PUBLIC_BASE_URL",
    "PORT",
    "Sinatra",
    "bundle exec rake test",
    "fake catalog",
    "no Postgres",
    "Semgrep",
    "bundler-audit",
    "gitleaks",
    "RuboCop",
    ".gitea/workflows/quality.yml",
    "priv/api/openapi.yaml",
    "off the listen path",
    "does not query the catalog",
    "its own git remote",
    "MEMORY.md",
    "DECISIONS.md"
  ].freeze

  def test_agents_keeps_the_starter_contract_and_points_at_memory
    agents = read_doc("AGENTS.md")

    CONTRACT_PHRASES.each do |phrase|
      assert_includes agents, phrase, "AGENTS.md is missing #{phrase.inspect}"
    end

    assert_match(/read both before architectural changes/i, agents)
    assert_match(/update `MEMORY\.md`/i, agents)
    assert_match(/append a record to `DECISIONS\.md`/i, agents)
  end

  def test_readme_versions_come_from_the_pin_files
    readme = read_doc("README.md")
    ruby_version = mise_tool("ruby")
    sinatra = locked_gem("sinatra")
    puma = locked_gem("puma")
    sequel = locked_gem("sequel")
    pg = locked_gem("pg")

    lock = File.read(File.join(ROOT, "Gemfile.lock"))
    locked_ruby = lock[/^RUBY VERSION\r?\n\s*ruby ([0-9]\S*)/, 1]
    refute_nil locked_ruby, "Gemfile.lock has no RUBY VERSION"
    assert_includes locked_ruby, ruby_version

    assert_includes readme, ruby_version
    assert_includes readme, sinatra
    assert_includes readme, puma
    assert_includes readme, sequel
    assert_includes readme, pg
    assert_includes readme, "Puma"
    assert_includes readme, "Sequel"
    assert_match(/\bpg\b/, readme)
    assert_includes readme, "RuboCop"
    assert_includes readme, "bundler-audit"
    assert_includes readme, "gitleaks"
    refute_match(/CRaC/i, readme)

    gemfile = File.read(File.join(ROOT, "Gemfile"))
    floor = gemfile[/ruby "([^"]+)"/, 1]
    refute_nil floor
    assert_includes readme, floor if readme.include?("floor")
  end

  def test_decisions_are_nygard_records_and_memory_is_separate
    decisions = read_doc("DECISIONS.md")
    memory = read_doc("MEMORY.md")

    assert_match(/\baccepted\b/, decisions)
    assert_match(/^### Context$/m, decisions)
    assert_match(/^### Decision$/m, decisions)
    assert_match(/^### Consequences$/m, decisions)
    assert_includes decisions, "v1_speakers"
    assert_match(/never Ash tables/i, decisions)
    assert_match(/does not query the catalog|not from a catalog query/i, decisions)
    assert_operator decisions.length, :>, 400

    refute_empty memory.strip
    refute_equal memory, decisions
    assert_includes memory, "bundle exec rake test"
    assert_includes memory, "priv/api/openapi.yaml"
    refute_includes memory, "## D001"
  end

  def test_docs_do_not_add_private_credentials_or_a_tailnet_host
    DOC_NAMES.each do |name|
      text = read_doc(name)
      refute_match(/ts\.net/, text, "#{name} names a tailnet host")
      refute_match(/ghp_|github_pat_/, text, "#{name} contains a GitHub token")
      refute_match(/BEGIN (?:OPENSSH |RSA )?PRIVATE KEY/, text, "#{name} contains a private key")
      refute_match(/AKIA[0-9A-Z]{16}/, text, "#{name} contains an AWS access key")
    end
  end

  private

  def read_doc(name)
    path = File.join(ROOT, name)
    assert File.file?(path), "#{name} is missing"
    File.read(path)
  end

  def mise_tool(name)
    mise = File.read(File.join(ROOT, "mise.toml"))
    value = mise[/^\s*#{Regexp.escape(name)}\s*=\s*"([^"]+)"/, 1]
    refute_nil value, "mise.toml has no #{name} pin"
    value
  end

  def locked_gem(name)
    lock = File.read(File.join(ROOT, "Gemfile.lock"))
    version = lock[/^\s{4}#{Regexp.escape(name)} \(([0-9][^)]*)\)/, 1]
    refute_nil version, "Gemfile.lock has no #{name} spec"
    version
  end
end
