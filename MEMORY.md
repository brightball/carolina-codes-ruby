# Memory

Operational facts for agents in this repository. The why lives in [DECISIONS.md](DECISIONS.md). Update this file when a command, pin, or gotcha changes. Do not paste secrets, tailnet hostnames, or private credentials here.

## What this process is

- Read-only Sinatra app. Entry points: `app.rb` and `config.ru` (`run Sinatra::Application`).
- Identity constants in `app.rb`: language `Ruby`, framework `Sinatra`, `API_VERSION` `0.2.0`, `SCHEMA_VERSION` 1, `CREATED_YEAR` 2026. `language_version` is `RUBY_VERSION` at runtime.
- `GET /health` returns `{ "ok": true }` and must not run SQL or open another connection.
- `GET /` returns identity JSON, including the `endpoints` list, and must not run SQL.
- List routes wrap rows as `{ "data": [ ... ] }`. Missing rows halt 404 `{ "error": "not_found" }`.
- Every response is JSON and sends `X-Polyglot-Language` and `X-Polyglot-Framework`.
- Sinatra `:protection` is disabled. `host_authorization` permitted hosts is an empty list.

## Pins

The pin files win if this paragraph drifts.

- `mise.toml`: Ruby `3.3.10`, gitleaks `8.30.1`.
- `Gemfile` floor: `ruby >= 3.2`. Direct gems: `sinatra ~> 4.0`, `puma ~> 7.2`, `sequel ~> 5.84`, `pg ~> 1.5`, `json ~> 2.7`. Development group: `bundler-audit`, `minitest`, `rake`, `rubocop`.
- `Gemfile.lock`: Ruby `3.3.10p183`, Sinatra `4.2.1`, Puma `7.2.1`, Sequel `5.107.0`, pg `1.6.3`, RuboCop `1.91.0`, bundler-audit `0.9.3`, Minitest `5.27.0`, Rake `13.4.2`.
- Image: `ruby:3.3-alpine` for build and runtime. Gitea jobs use `ruby:3.3-bookworm`.
- Default listen port is `4001`. The container and `fly.toml` use `8080`.
- `fly.toml` scales to zero: `min_machines_running = 0`, `auto_stop_machines = "stop"`, `auto_start_machines = true`. Idle machines stop. The CMS keepalive starts this app when it is the warm language API. Do not pin a resident machine in this file.

## Commands

```bash
bundle install
bundle exec rake test
bundle exec rake sast
bundle exec rake audit
bundle exec rake gitleaks
bundle exec rake lint
bundle exec rake hooks
```

`rake sast` is `semgrep scan --config p/ruby`. `rake audit` is `bundler-audit check --update`. `rake gitleaks` is `gitleaks detect --source .`. `rake lint` is RuboCop. `rake hooks` runs `pre-commit install` and sets `core.hooksPath=.githooks`.

Emergency skip: `SKIP=tests,sast,audit,gitleaks,lint git commit`.

Live server, with Postgres 16 already serving the CMS views:

```bash
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4001 \
bundle exec puma
```

Puma's config file binds `tcp://[::]:PORT`. Do not switch that to `0.0.0.0`.

## Tests

- `test/test_helper.rb` sets `RACK_ENV` and `APP_ENV` to `test`, deletes `CAROLINA_URL` and `POLYGLOT_REGISTER_TOKEN`, points `CatalogCounters.connect_fn` at `FakeCatalog.database`, then requires `app.rb`.
- That order is load-bearing. `open_pool` runs at require time.
- `CatalogCounters.reset_sql!` clears the statement counter and leaves the connect tally, so a later read can show pool reuse.
- `bundle exec rake test` does not need Postgres.
- RuboCop enforces double quotes and `# frozen_string_literal: true`. Line length max is 120. `vendor/**/*` is excluded.

## Registration

- Invoked at the bottom of `app.rb` (`register_with_elixir`).
- Skips when `CAROLINA_URL` or `POLYGLOT_REGISTER_TOKEN` is empty.
- One attempt per process (`claim_registration` under `REGISTRATION_LOCK`).
- Background thread name: `carolina-registration`. Timeouts: 1 second on open, read, and write.
- Does not query the catalog. `GET /health` must stay fast if the peer hangs.
- URL: `{CAROLINA_URL}/internal/api-endpoints/register`. Header: `Authorization: Bearer`.
- No heartbeat loop.

## Contract and remotes

- HTTP contract: `priv/api/openapi.yaml` and `priv/api/AGENTS.md` in `github.com/brightball/carolina-codes`.
- This repo has no `openapi.yaml`, no `db/*.sql`, and no Compose catalog.
- Workspace root is this repo. Do not assume `../elixir` or any other sibling checkout.
- GitHub remote name: `origin` (`github.com/brightball/carolina-codes-ruby`). A second remote may be named `gitea`. Do not deploy Fly for documentation-only changes.
- Query only `v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_speakers`, `v1_year_sponsors`.
- Never query Ash tables.

## Quality workflow

- File: `.gitea/workflows/quality.yml`.
- The prepare job installs the shared tree. The check jobs restore it and each run one gate: tests, sast, audit, gitleaks, lint.
- Gitea 1.24 rejects YAML anchors, so the Ruby container and the restore step are copied into every job.
- Do not use `actions/checkout`. The job clones with its token. The clone is full history so gitleaks can scan it.
- CI Semgrep is the pip console script on `PATH` via `.ci`, not a bare module import.

## Gotchas

- Year-scoped speaker detail returns 404 when `talks` is empty for that year.
- `pg_text_array` accepts a Ruby array, a Postgres `{a,b}` string, or nil.
- `Sequel.extension :pg_array` runs only for a real `Sequel.connect`, not for the fake catalog.
- Year speaker listings are batched (`load_talks_for_year`, `load_years_for_slugs`). Slug detail is not.
- Local dev database URL and `POLYGLOT_REGISTER_TOKEN=dev` are the public fixtures. Do not replace them with real credentials in docs.
