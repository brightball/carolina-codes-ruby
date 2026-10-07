# Decisions

Durable decisions for this Ruby / Sinatra API. Append a new record when a decision changes. Set the old record's status to `superseded` and link the new id. Do not silently rewrite history.

Each record uses a short Nygard form: status, context, decision, consequences.

## D001. Query v1 SQL views from Sinatra, never Ash tables

- Status: accepted
- Date: 2026-08-27

### Context

The Carolina Codes site keeps at most one polyglot language API warm. The public contract is ordinary JSON over PostgreSQL views, not Ash JSON:API. The language starter described that contract and shipped no finished API. This repository is the Ruby implementation (`2ca6cf8`).

### Decision

Serve the API with Sinatra and Sequel. Query only `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_speakers`, and `v1_year_sponsors`. Never query Ash tables. Do not write to the catalog.

### Consequences

Handlers stay read-only. A change to the public shape belongs in the CMS contract (`priv/api/openapi.yaml`), then in these queries. Tests can substitute a fake catalog because reads go through Sequel datasets.

## D002. Year-scoped speaker and sponsor routes

- Status: accepted
- Date: 2026-08-27

### Context

The contract needs collection filters and detail routes for one conference year, in addition to all-years lists and slug detail. Commit `52dd695` added the routes. Commit `b33f58b` attached talk tags to the year-scoped speaker payloads.

### Decision

Expose `GET /v1/speakers?year=`, `GET /v1/speakers/{year}/{slug}`, `GET /v1/sponsors?year=`, and `GET /v1/sponsors/{year}/{slug}` beside the unscoped routes. Year-scoped speaker rows include `languages`, `topics`, `talks`, `years`, and `other_years`. Year-scoped sponsor rows come from `v1_year_sponsors` and include `tier`. A year-scoped speaker with no talks in that year returns 404.

### Consequences

Clients can request one year without downloading every year. Unscoped speaker detail still returns every talk. Listing filters and detail routes must stay in sync with the CMS contract.

## D003. Handler tests use a fake catalog and do not open Postgres

- Status: accepted
- Date: 2026-08-27

### Context

`bundle exec rake test` runs in pre-commit and in Gitea. Those gates must not require the CMS database.

### Decision

`test/test_helper.rb` assigns `CatalogCounters.connect_fn` to `FakeCatalog.database` before requiring `app.rb`. The pool opened at load is the fake. `wrap_execute!` counts SQL so tests can show `/health` and `/` issue none. The test helper also deletes `CAROLINA_URL` and `POLYGLOT_REGISTER_TOKEN`.

### Consequences

`bundle exec rake test` needs no `DATABASE_URL` and no Postgres. Live HTTP still needs Postgres 16 and the CMS views. The connect function has to be installed before `app.rb` is required. Requiring the app a second time does not reopen the pool.

## D004. Register once, off the listen path, without catalog SQL

- Status: accepted
- Date: 2026-09-22

### Context

A CMS that accepts the TCP connection and never answers can hold process boot. Fly and local probes call `GET /health` as soon as the process listens. Registration is not required to serve the catalog. Commit `1a8a43c` moved that work off the listen path.

### Decision

`register_with_elixir` runs when `app.rb` loads. It claims a single attempt under a mutex and posts from a background thread named `carolina-registration`. Open, read, and write timeouts are one second (`REGISTRATION_TIMEOUT`). The body is built from constants and `PUBLIC_BASE_URL`, not from a catalog query. Failures are warned and swallowed. There is no heartbeat. Empty `CAROLINA_URL` or `POLYGLOT_REGISTER_TOKEN` skips the call.

### Consequences

`GET /health` does not wait on the CMS and does not increment the SQL counter. A second call in-process does not post again. Elixir keep-alives the warm API. The register URL is `{CAROLINA_URL}/internal/api-endpoints/register` with `Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}`.

## D005. Identity and registration share one endpoint list

- Status: accepted
- Date: 2026-08-27

### Context

The language starter described `endpoints` as `"GET /path"` strings. This service also returns the list from `GET /`, including optional query keys such as `year`.

### Decision

`ENDPOINTS` is the single list. Each item is an object with `method`, `path`, and `query`. `GET /` and the register POST both send it. `schema_version` is 1. `API_VERSION` is `0.2.0`.

### Consequences

Adding a route means editing `ENDPOINTS` and the Sinatra route together. Clients of `GET /` receive objects, not bare method-path strings.

## D006. Listen on IPv6 and keep one Fly machine warm

- Status: accepted
- Date: 2026-09-01

### Context

Fly private networking reaches the process over IPv6. Commit `5b4e74c` set the listen address. Commit `1a8a43c` stopped the machine from scaling to zero so boot work could not race the health check.

### Decision

Puma binds `tcp://[::]:PORT` in `config/puma.rb`. `LISTEN_HOST` in `app.rb` is `::`. `fly.toml` sets `auto_stop_machines = "off"`, `min_machines_running = 1`, and a `GET /health` check on internal port 8080. Do not bind `0.0.0.0`. Sinatra `host_authorization` uses an empty permitted-host list so Fly public and internal checks are accepted.

### Consequences

The health check hits a process that is already listening. Network work during boot stays off that path (see D004). Documentation-only changes do not deploy Fly.

## D007. Batch year-scoped speaker reads

- Status: accepted
- Date: 2026-09-01

### Context

Commit `5b4e74c` called out batched catalog SQL. A year listing that queried talks once per speaker dominated catalog time.

### Decision

`year_speakers` loads that year's talks in one query and the distinct years for those slugs in one query, then attaches `languages` and `topics` in memory.

### Consequences

The year-scoped speaker list does not do a per-speaker round trip. Slug detail routes still query by slug. `languages` and `topics` may arrive as Ruby arrays or as Postgres array text; `pg_text_array` accepts both.

## D008. Quality gates are separate jobs, and Gitea restores a prepared tree

- Status: accepted
- Date: 2026-09-22

### Context

Pre-commit runs tests, Semgrep (`p/ruby`), bundler-audit, gitleaks, and RuboCop. Gitea Actions 1.24 schedules each job on its own, rejects YAML anchors, and starts a new container per job. Host bind mounts and `actions/checkout` are not available. Later commits in that series fixed Semgrep's console script, manual `workflow_dispatch`, and a cancelled run.

### Decision

`.gitea/workflows/quality.yml` has a prepare job that clones the full history with the job token, installs gems, Semgrep, and gitleaks, and uploads that tree. Five check jobs (`tests`, `sast`, `audit`, `gitleaks`, `lint`) restore the tree and each run one gate. They do not `apt-get` or `bundle install`. The workflow can be started by hand.

### Consequences

A new gate is a new job plus a prepare install, not a combined script. The gitleaks job needs full git history in the restored tree. Locally the same gates are `bundle exec rake test`, `sast`, `audit`, `gitleaks`, and `lint`. Pre-commit gitleaks uses `gitleaks protect --staged`.

## D009. This repository is its own remote

- Status: accepted
- Date: 2026-09-06

### Context

The polyglot fleet is one git remote per language. Commit `042df6a` added Cloud instructions after agents assumed a sibling checkout that is not always present.

### Decision

Treat this repo as the workspace root. The Phoenix CMS is `github.com/brightball/carolina-codes`. Do not vendor the CMS tree. Do not commit a local `openapi.yaml`, `db/*.sql` seed, or Compose file. The contract stays in the CMS at `priv/api/openapi.yaml` and `priv/api/AGENTS.md`.

### Consequences

Do not assume `../elixir` exists. Image bytes and the SQL view definitions are not in this repo. `photo_path` and `logo_path` are returned as paths.

## D010. Compile native gems in the image build stage

- Status: accepted
- Date: 2026-08-27

### Context

`pg` and Puma need a compiler to build extensions. Installing gems when the container starts leaves a toolchain in the runtime image and slows boot. The Dockerfile states that split.

### Decision

Use a build stage (`ruby:3.3-alpine` with `build-base` and `postgresql-dev`) and a runtime stage with `libpq` only. `BUNDLE_FROZEN=1` installs from `Gemfile.lock` into `/usr/local/bundle`, and the runtime stage copies that bundle. The process command is `bundle exec puma -C config/puma.rb config.ru`. `BUNDLE_WITHOUT=development:test` omits RuboCop, Minitest, Rake, and bundler-audit from the image.

### Consequences

Gem changes require a rebuild. The runtime image has no compiler and does not run `bundle install`. CI uses `ruby:3.3-bookworm` and installs the development group because it runs the gates.
