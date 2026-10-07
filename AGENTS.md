# Carolina Codes — Ruby API

Read-only HTTP API in Ruby that the Carolina Code Conference Elixir site can rotate onto. This repository is the finished Sinatra service. It is not the unfinished language starter, and it is its own git remote (`github.com/brightball/carolina-codes-ruby`). Do not fold this tree into the CMS remote (`github.com/brightball/carolina-codes`).

Before an architectural change, read [MEMORY.md](MEMORY.md) and [DECISIONS.md](DECISIONS.md). Read both before architectural changes. When a durable decision changes, append a record to `DECISIONS.md` and mark the old record superseded. When a recurring operational fact changes, update `MEMORY.md`. Keep this file as the short always-loaded instructions.

The source of truth for routes and payloads is the CMS contract: `priv/api/openapi.yaml` and `priv/api/AGENTS.md` in the CMS repo. This repo does not ship `openapi.yaml`. Do not implement Ash JSON:API (`application/vnd.api+json`). This API speaks ordinary JSON over the v1 REST + SQL-view contract.

You do not need a checkout of the Elixir CMS to run handler tests. Registration is best-effort: if `CAROLINA_URL` is unset or the CMS is down, skip the register call and still serve HTTP.

## Purpose

The Phoenix app (`Carolina.Polyglot`) keeps at most one language API warm and reads speakers and sponsors from it. With no APIs registered, it falls back to Ash. This process must:

1. Query only the PostgreSQL v1 views listed below, never Ash tables.
2. Expose the required routes.
3. Register once on boot with the Elixir site (no heartbeat). Registration runs off the listen path, does not query the catalog, and must not block `GET /health`. If the site is not running, log and continue.

## Environment

| Variable | Example | Role |
| --- | --- | --- |
| `DATABASE_URL` | `postgres://postgres:postgres@127.0.0.1:5432/carolina_dev` | SQL views |
| `CAROLINA_URL` | `http://127.0.0.1:4000` | Elixir site (optional; register no-ops if down) |
| `POLYGLOT_REGISTER_TOKEN` | `dev` | Bearer token for register |
| `PUBLIC_BASE_URL` | `http://127.0.0.1:4001` | URL Elixir will call |
| `PORT` | `4001` locally, `8080` in the container | Listen port |

`bundle exec rake test` drives the shipped Sinatra app with a fake catalog and no Postgres. For live HTTP against the views, start Postgres 16 and set the variables above. The `v1_*` views live in the CMS database.

## SQL views (query these)

Query only these views: `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_speakers`, `v1_year_sponsors`.

Year-scoped speaker rows include `languages` and `topics`. Year-scoped sponsor rows include `tier` (and `blurb`).

Do not `SELECT` from `speakers`, `organizations`, `talks`, or other Ash or base tables. The views are the API. This repo has no local `db/*.sql` seed and no Compose catalog.

## Required HTTP routes

Wrap list payloads as `{ "data": [ ... ] }` unless noted. Unknown slugs return 404 `{ "error": "not_found" }`.

- `GET /health` — liveness (`{ "ok": true }`). No catalog SQL and no extra connection.
- `GET /` — identity (`language`, `language_version`, `api_version`, `framework`, `created_year`, `schema_version`, `endpoints`). No catalog SQL.
- `GET /v1/years`
- `GET /v1/speakers` and `GET /v1/speakers?year=`
- `GET /v1/speakers/{slug}` and `GET /v1/speakers/{year}/{slug}`
- `GET /v1/sponsors` and `GET /v1/sponsors?year=`
- `GET /v1/sponsors/{slug}` and `GET /v1/sponsors/{year}/{slug}`

`photo_path` and `logo_path` values are web paths. Return the path. This process does not serve image bytes.

## Register on boot (once)

`POST {CAROLINA_URL}/internal/api-endpoints/register`

```
Authorization: Bearer {POLYGLOT_REGISTER_TOKEN}
Content-Type: application/json
```

Body fields: `language`, `language_version`, `api_version`, `framework`, `created_year`, `base_url` (`PUBLIC_BASE_URL`), `schema_version` (1), `endpoints`.

`endpoints` is the same list `GET /` returns. Each item is an object with `method`, `path`, and `query`, not a bare `"GET /path"` string.

`register_with_elixir` claims the attempt once under a mutex, then posts from a background thread (`carolina-registration`) with a one-second open, read, and write timeout. It does not query the catalog. Do not heartbeat. Elixir keep-alives the currently warm API.

If `CAROLINA_URL` or `POLYGLOT_REGISTER_TOKEN` is empty, or the POST fails, log and keep serving.

## Layout

| Path | Role |
| --- | --- |
| `app.rb` | Sinatra routes, Sequel queries, registration |
| `config.ru` | Rack entry (`run Sinatra::Application`) |
| `config/puma.rb` | IPv6 bind `tcp://[::]:PORT` |
| `lib/catalog_counters.rb` | Test seam for connect and SQL counts |
| `test/fake_catalog.rb` | In-memory catalog used by handler tests |
| `Rakefile` | `test`, `sast`, `audit`, `gitleaks`, `lint`, `hooks` |
| `Dockerfile` | Multi-stage Ruby image; native gems compile in the build stage |
| `fly.toml` | Fly app settings. Do not deploy as part of documentation-only work |
| `.gitea/workflows/quality.yml` | Prepare job, then one job per quality gate |
| `MEMORY.md` | Operational facts and gotchas |
| `DECISIONS.md` | Append-only decision records |

There is no `src/` tree, no `tests/test_catalog.py`, and no `docker-compose.yml`. The Dockerfile is the Ruby runtime image, not a placeholder to replace.

## Tests and quality gates

`bundle exec rake test` drives the shipped Sinatra app with a fake catalog (no Postgres). `bundle exec rake hooks` installs pre-commit (tests, Semgrep Ruby SAST, bundler-audit, gitleaks, RuboCop). Gitea quality jobs live in `.gitea/workflows/quality.yml`: a prepare job installs the shared environment, then the five check jobs restore that tree and each run one gate.

See `README.md` for install and run commands. Language and gem versions are pinned in `mise.toml` and `Gemfile.lock`.

## Checklist

- Required paths return 200 with example-shaped JSON (404 on an unknown slug)
- `?year=` speaker rows include `languages` and `topics`; sponsor rows include `tier`
- Register runs once at process start, off the listen path, with no catalog SQL
- Registration no-ops if the Elixir site is down; there is no heartbeat
- No writes; never Ash tables
- `GET /health` avoids the database
- Puma listens on IPv6 (`::`)
- Durable decisions and operational facts stay in `DECISIONS.md` and `MEMORY.md`

## Cursor Cloud specific instructions

This repository is one sibling git remote in the carolina.codes polyglot fleet. Cloud agents should treat this repo as the workspace root. The Phoenix CMS is a different remote (`github.com/brightball/carolina-codes`). Do not assume `../elixir` or other sibling directories exist unless those remotes are attached to the same Cloud environment.

Postgres `v1_*` views live in the CMS database. Handler and unit tests that use a fake catalog do not need Postgres. For live HTTP against the views, start Postgres 16 and set:

- `DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev`
- `CAROLINA_URL=http://127.0.0.1:4000` (optional; registration no-ops if the CMS is down)
- `POLYGLOT_REGISTER_TOKEN=dev`
- `PUBLIC_BASE_URL` and `PORT` as in the README

Do not query Ash tables. Do not fold this tree into the CMS git remote. Contract: CMS `priv/api/openapi.yaml` and `priv/api/AGENTS.md`.
