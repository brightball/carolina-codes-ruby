# frozen_string_literal: true

require_relative "test_helper"

class ApiTest < Minitest::Test
  include CarolinaTest

  def test_health_is_ok_json_without_sql_or_postgres
    connects = CatalogCounters.connect_count
    CatalogCounters.reset_sql!
    response = get("/health")

    assert_equal 200, response.status
    body = json_body(response)
    assert_equal true, body["ok"]
    assert_equal 0, CatalogCounters.sql_count
    assert_equal connects, CatalogCounters.connect_count
  end

  def test_root_identity_is_ruby_sinatra_without_sql
    connects = CatalogCounters.connect_count
    CatalogCounters.reset_sql!
    response = get("/")

    assert_equal 200, response.status
    body = json_body(response)
    assert_equal "Ruby", body["language"]
    assert_equal "Sinatra", body["framework"]
    assert_equal API_VERSION, body["api_version"]
    assert body["endpoints"].is_a?(Array)
    assert_equal 0, CatalogCounters.sql_count
    assert_equal connects, CatalogCounters.connect_count
  end

  def test_years_listing_uses_fake_catalog
    response = get("/v1/years")

    assert_equal 200, response.status
    years = json_body(response).fetch("data")
    catalog_years = FakeCatalog::YEARS.map { |row| row[:year] }
    returned_years = years.map { |row| row["year"] }
    assert_equal catalog_years.sort.reverse, returned_years
    years.each do |row|
      source = FakeCatalog::YEARS.find { |item| item[:year] == row["year"] }
      assert_equal source[:slug], row["slug"]
      assert_equal source[:name], row["name"]
    end
  end

  def test_speakers_listing_uses_fake_catalog
    response = get("/v1/speakers")

    assert_equal 200, response.status
    speakers = json_body(response).fetch("data")
    assert_equal FakeCatalog::SPEAKERS.size, speakers.size
    FakeCatalog::SPEAKERS.each do |source|
      row = speakers.find { |item| item["slug"] == source[:slug] }
      assert_speaker_identity(row, source)
    end
  end

  def test_year_scoped_speakers_merge_languages_and_topics
    response = get("/v1/speakers?year=2026")

    assert_equal 200, response.status
    speakers = json_body(response).fetch("data")
    assert_equal speakers_for_year(2026).size, speakers.size
    diana = speakers.find { |row| row["slug"] == "diana-pham" }
    talks = talks_for("diana-pham", 2026)
    assert_equal talks.flat_map { |talk| talk[:languages] }.uniq.sort, diana["languages"].sort
    assert_equal talks.flat_map { |talk| talk[:topics] }.uniq.sort, diana["topics"].sort
    assert_equal 2026, diana["year"]
    assert_descending_catalog_years(diana, "diana-pham")
    assert_talks_match(diana["talks"], talks)
  end

  def test_speaker_detail_includes_catalog_talks_and_years
    source = FakeCatalog::SPEAKERS.find { |row| row[:slug] == "diana-pham" }
    response = get("/v1/speakers/#{source[:slug]}")

    assert_equal 200, response.status
    row = json_body(response).fetch("data")
    assert_speaker_identity(row, source)
    assert_descending_catalog_years(row, source[:slug])
    assert_talks_match(row["talks"], talks_for(source[:slug]))
  end

  def test_year_scoped_speaker_includes_talks_languages_and_topics
    response = get("/v1/speakers/2026/diana-pham")

    assert_equal 200, response.status
    row = json_body(response).fetch("data")
    source = FakeCatalog::SPEAKERS.find { |item| item[:slug] == "diana-pham" }
    talks = talks_for("diana-pham", 2026)
    assert_speaker_identity(row, source)
    assert_equal 2026, row["year"]
    assert_equal talks.flat_map { |talk| talk[:languages] }.uniq.sort, row["languages"].sort
    assert_equal talks.flat_map { |talk| talk[:topics] }.uniq.sort, row["topics"].sort
    assert_descending_catalog_years(row, "diana-pham")
    assert_talks_match(row["talks"], talks)
  end

  def test_unknown_speaker_slug_returns_not_found
    assert_not_found("/v1/speakers/no-such-slug")
  end

  def test_unknown_year_scoped_speaker_returns_not_found
    assert_not_found("/v1/speakers/2026/no-such-slug")
    assert_not_found("/v1/speakers/2024/ada-lin")
  end

  def test_sponsors_listing_includes_catalog_identity
    response = get("/v1/sponsors")

    assert_equal 200, response.status
    sponsors = json_body(response).fetch("data")
    assert_equal FakeCatalog::SPONSORS.size, sponsors.size
    FakeCatalog::SPONSORS.each do |source|
      row = sponsors.find { |item| item["slug"] == source[:slug] }
      assert_equal source[:name], row["name"]
      assert_equal source[:website], row["website"]
    end
  end

  def test_year_scoped_sponsors_include_catalog_identity
    response = get("/v1/sponsors?year=2026")

    assert_equal 200, response.status
    sponsors = json_body(response).fetch("data")
    expected = FakeCatalog::YEAR_SPONSORS.select { |row| row[:year] == 2026 }
    assert_equal expected.size, sponsors.size
    expected.each do |source|
      row = sponsors.find { |item| item["slug"] == source[:slug] }
      assert_equal source[:name], row["name"]
      assert_equal source[:tier], row["tier"]
      assert_equal source[:year], row["year"]
    end
  end

  def test_sponsor_detail_includes_sponsorships
    source = FakeCatalog::SPONSORS.find { |row| row[:slug] == "flywheel" }
    response = get("/v1/sponsors/#{source[:slug]}")

    assert_equal 200, response.status
    row = json_body(response).fetch("data")
    assert_equal source[:slug], row["slug"]
    assert_equal source[:name], row["name"]
    assert_sponsorships_match(row["sponsorships"], source[:slug])
  end

  def test_year_scoped_sponsor_includes_sponsorships_and_years
    response = get("/v1/sponsors/2026/flywheel")

    assert_equal 200, response.status
    row = json_body(response).fetch("data")
    source = FakeCatalog::YEAR_SPONSORS.find { |item| item[:slug] == "flywheel" && item[:year] == 2026 }
    assert_equal source[:slug], row["slug"]
    assert_equal source[:name], row["name"]
    assert_equal source[:tier], row["tier"]
    assert_equal source[:year], row["year"]
    assert_sponsorships_match(row["sponsorships"], "flywheel")
    catalog_years = FakeCatalog::SPONSORSHIPS
                    .select { |item| item[:sponsor_slug] == "flywheel" }
                    .map { |item| item[:year] }
                    .uniq
    assert_equal catalog_years.size, row["years"].size
    catalog_years.each { |year| assert_includes row["years"], year }
    assert_equal row["years"].sort.reverse, row["years"]
    assert_operator row["years"].size, :>=, 2
  end

  def test_unknown_sponsor_slug_returns_not_found
    assert_not_found("/v1/sponsors/no-such-sponsor")
  end

  def test_unknown_year_scoped_sponsor_returns_not_found
    assert_not_found("/v1/sponsors/2026/no-such-sponsor")
  end

  def test_year_scoped_speakers_bound_sql_and_reuse_boot_pool
    connects = CatalogCounters.connect_count
    assert_equal 1, connects, "boot should open the catalog pool once"
    CatalogCounters.reset_sql!

    response = get("/v1/speakers?year=2026")
    assert_equal 200, response.status
    speakers = json_body(response).fetch("data")
    sql = CatalogCounters.sql_count
    descending = speakers.all? { |row| row["years"] == row["years"].sort.reverse }
    multi_year = speakers.any? { |row| row["years"].size >= 2 }
    puts "year_speaker_sql=#{sql} speakers=#{speakers.size} sql_bound=#{sql <= 4} " \
         "sql_not_2n=#{sql < (2 * speakers.size)} connect_before=#{connects} " \
         "connect_after=#{CatalogCounters.connect_count} years_desc=#{descending} multi_year=#{multi_year}"

    assert_operator speakers.size, :>=, 3
    assert_operator sql, :>, 0
    assert_operator sql, :<=, 4
    assert_operator sql, :<, 2 * speakers.size
    assert descending
    assert multi_year
    assert_equal connects, CatalogCounters.connect_count

    CatalogCounters.reset_sql!
    again = get("/v1/speakers?year=2026")
    assert_equal 200, again.status
    assert_equal connects, CatalogCounters.connect_count
    puts "connect_unchanged=#{CatalogCounters.connect_count == connects}"
  end

  private

  def assert_not_found(path)
    response = get(path)
    assert_equal 404, response.status
    assert_equal "not_found", json_body(response)["error"]
  end

  def assert_speaker_identity(row, source)
    refute_nil row, "missing speaker #{source[:slug]}"
    assert_equal source[:slug], row["slug"]
    assert_equal source[:first_name], row["first_name"]
    assert_equal source[:last_name], row["last_name"]
    assert_equal source[:name], row["name"]
  end

  def assert_descending_catalog_years(row, slug)
    catalog_years = talks_for(slug).map { |talk| talk[:year] }.uniq
    assert_equal catalog_years.size, row["years"].size
    catalog_years.each { |year| assert_includes row["years"], year }
    assert_equal row["years"].sort.reverse, row["years"]
    assert_operator row["years"].size, :>=, 2 if slug == "diana-pham"
  end

  def assert_talks_match(returned, catalog_talks)
    assert_equal catalog_talks.size, returned.size
    catalog_talks.each do |talk|
      found = returned.find { |item| item["slug"] == talk[:slug] }
      refute_nil found, "missing talk #{talk[:slug]}"
      assert_equal talk[:title], found["title"]
      assert_equal talk[:year], found["year"]
      assert_equal talk[:speaker_slug], found["speaker_slug"]
    end
  end

  def assert_sponsorships_match(returned, slug)
    catalog = FakeCatalog::SPONSORSHIPS.select { |row| row[:sponsor_slug] == slug }
    assert_equal catalog.size, returned.size
    catalog.each do |item|
      found = returned.find { |row| row["year"] == item[:year] && row["sponsor_slug"] == slug }
      refute_nil found, "missing sponsorship #{item[:year]}"
      assert_equal item[:tier], found["tier"]
    end
  end

  def speakers_for_year(year)
    slugs = talks_for_year(year).map { |talk| talk[:speaker_slug] }.uniq
    FakeCatalog::SPEAKERS.select { |speaker| slugs.include?(speaker[:slug]) }
  end

  def talks_for(slug, year = nil)
    FakeCatalog::TALKS.select do |talk|
      talk[:speaker_slug] == slug && (year.nil? || talk[:year] == year)
    end
  end

  def talks_for_year(year)
    FakeCatalog::TALKS.select { |talk| talk[:year] == year }
  end
end
