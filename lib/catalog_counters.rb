# frozen_string_literal: true

# Tests may set connect_fn before requiring app.rb so the boot pool is a
# fake catalog and live Postgres is not required.
module CatalogCounters
  class << self
    attr_accessor :connect_fn, :query_fn

    def sql_count
      @sql_count || 0
    end

    def connect_count
      @connect_count || 0
    end

    def inc_sql
      @sql_count = sql_count + 1
    end

    def inc_connect
      @connect_count = connect_count + 1
    end

    # Statement counter only. The boot connection tally stays so a later
    # catalog read can show it reused the pool opened at load.
    def reset_sql!
      @sql_count = 0
    end

    def reset!
      reset_sql!
      @connect_count = 0
    end
  end
end
