# frozen_string_literal: true

# In-memory stand-in for Sequel datasets over the v1_* catalog views.
# Implements the dataset methods app.rb actually calls so Rack tests can
# drive the shipped Sinatra routes without Postgres. Terminal reads go
# through #execute so the shipped SQL counter sees one statement per query.
class FakeCatalog
  YEARS = [
    { year: 2024, slug: "2024", name: "Carolina Code Camp 2024", status: "past" },
    { year: 2025, slug: "2025", name: "Carolina Code Camp 2025", status: "past" },
    { year: 2026, slug: "2026", name: "Carolina Code Camp 2026", status: "upcoming" }
  ].freeze

  SPEAKERS = [
    {
      slug: "diana-pham",
      first_name: "Diana",
      last_name: "Pham",
      name: "Diana Pham",
      tagline: "Speaker",
      bio: "Bio",
      company: "Example",
      location: "NC",
      photo_path: nil,
      twitter_url: nil,
      linkedin_url: nil,
      website_url: nil,
      github_url: nil,
      featured: false
    },
    {
      slug: "ada-lin",
      first_name: "Ada",
      last_name: "Lin",
      name: "Ada Lin",
      tagline: "Speaker",
      bio: "Bio",
      company: "Example",
      location: "NC",
      photo_path: nil,
      twitter_url: nil,
      linkedin_url: nil,
      website_url: nil,
      github_url: nil,
      featured: false
    },
    {
      slug: "miles-okonkwo",
      first_name: "Miles",
      last_name: "Okonkwo",
      name: "Miles Okonkwo",
      tagline: "Speaker",
      bio: "Bio",
      company: "Example",
      location: "SC",
      photo_path: nil,
      twitter_url: nil,
      linkedin_url: nil,
      website_url: nil,
      github_url: nil,
      featured: false
    }
  ].freeze

  TALKS = [
    {
      slug: "shipping-sinatra",
      title: "Shipping Sinatra",
      description: "Talk",
      format: "session",
      youtube_id: nil,
      year: 2026,
      speaker_slug: "diana-pham",
      languages: ["ruby"],
      topics: ["development"]
    },
    {
      slug: "earlier-elixir",
      title: "Earlier Elixir",
      description: "Talk",
      format: "session",
      youtube_id: nil,
      year: 2024,
      speaker_slug: "diana-pham",
      languages: ["elixir"],
      topics: ["architecture"]
    },
    {
      slug: "tracing-requests",
      title: "Tracing Requests",
      description: "Talk",
      format: "session",
      youtube_id: nil,
      year: 2026,
      speaker_slug: "ada-lin",
      languages: ["go"],
      topics: ["observability"]
    },
    {
      slug: "catalog-windows",
      title: "Catalog Windows",
      description: "Talk",
      format: "session",
      youtube_id: nil,
      year: 2026,
      speaker_slug: "miles-okonkwo",
      languages: ["python"],
      topics: ["data"]
    }
  ].freeze

  SPONSORS = [
    {
      slug: "flywheel",
      name: "Flywheel",
      website: "https://example.com",
      logo_path: nil,
      description: "Sponsor",
      twitter_url: nil,
      linkedin_url: nil,
      youtube_url: nil,
      instagram_url: nil,
      facebook_url: nil
    }
  ].freeze

  YEAR_SPONSORS = [
    {
      slug: "flywheel",
      name: "Flywheel",
      website: "https://example.com",
      logo_path: nil,
      description: "Sponsor",
      blurb: "Blurb",
      tier: "platinum",
      featured: false,
      year: 2026,
      twitter_url: nil,
      linkedin_url: nil,
      youtube_url: nil,
      instagram_url: nil,
      facebook_url: nil
    }
  ].freeze

  SPONSORSHIPS = [
    { sponsor_slug: "flywheel", year: 2026, tier: "platinum" },
    { sponsor_slug: "flywheel", year: 2024, tier: "gold" }
  ].freeze

  def self.database
    new(
      v1_years: YEARS,
      v1_speakers: SPEAKERS,
      v1_talks: TALKS,
      v1_sponsors: SPONSORS,
      v1_year_sponsors: YEAR_SPONSORS,
      v1_sponsorships: SPONSORSHIPS,
      v1_year_speakers: []
    )
  end

  def initialize(tables)
    @tables = tables
  end

  def [](name)
    Dataset.new(Array(@tables[name.to_sym]), db: self)
  end

  def execute(*)
    []
  end

  # Minimal Sequel-like dataset used by the shipped handlers.
  class Dataset
    attr_reader :rows, :selected, :db

    def initialize(rows, selected: nil, db: nil)
      @rows = rows
      @selected = selected
      @db = db
    end

    def order(*columns)
      sorted = rows.sort do |left, right|
        columns.reduce(0) do |memo, column|
          next memo unless memo.zero?

          name, descending = order_spec(column)
          compared = compare_values(row_value(left, name), row_value(right, name))
          descending ? -compared : compared
        end
      end
      Dataset.new(sorted, selected: selected, db: db)
    end

    def where(conditions)
      filtered = rows.select { |row| row_matches?(row, conditions) }
      Dataset.new(filtered, selected: selected, db: db)
    end

    def select(*columns)
      Dataset.new(rows, selected: columns, db: db)
    end

    def distinct
      projected =
        if selected&.any?
          rows.uniq { |row| selected.map { |col| row_value(row, col) } }
        else
          rows.uniq
        end
      Dataset.new(projected, selected: selected, db: db)
    end

    def all
      record_statement!
      rows
    end

    def first
      record_statement!
      rows.first
    end

    def select_map(column)
      record_statement!
      rows.map { |row| row_value(row, column) }
    end

    private

    def record_statement!
      db&.execute("catalog")
    end

    def order_spec(column)
      if defined?(Sequel::SQL::OrderedExpression) && column.is_a?(Sequel::SQL::OrderedExpression)
        [column.expression, column.descending]
      else
        [column, false]
      end
    end

    def compare_values(left, right)
      return 0 if left == right
      return -1 if left.nil?
      return 1 if right.nil?

      left <=> right
    end

    def row_matches?(row, conditions)
      conditions.all? do |key, expected|
        actual = row_value(row, key)
        value_matches?(actual, expected)
      end
    end

    def value_matches?(actual, expected)
      case expected
      when Dataset
        subquery_values(expected).include?(actual)
      when Array
        expected.include?(actual)
      else
        actual == expected
      end
    end

    def subquery_values(dataset)
      if dataset.selected&.any?
        dataset.selected.flat_map do |col|
          dataset.rows.map { |row| row_value(row, col) }
        end
      else
        dataset.rows.flat_map(&:values)
      end
    end

    def row_value(row, key)
      return row[key] if row.key?(key)
      return row[key.to_sym] if row.key?(key.to_sym)
      return row[key.to_s] if row.key?(key.to_s)

      nil
    end
  end
end
