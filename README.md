# Carolina Codes — Ruby API

Read-only Sinatra API for the [Carolina Code Conference](https://carolina.codes) polyglot site.

## Runtime

Versions below are the pins in `mise.toml` and `Gemfile.lock`. The Gemfile floor is `ruby >= 3.2`.

| Piece | Version |
| --- | --- |
| Ruby | 3.3.10 (`Gemfile.lock` records `ruby 3.3.10p183`; `mise.toml` pins `3.3.10`) |
| Sinatra | 4.2.1 |
| Puma | 7.2.1 |
| Sequel | 5.107.0 |
| pg | 1.6.3 |

Quality tooling of note: RuboCop 1.91.0, bundler-audit 0.9.3, gitleaks 8.30.1 (`mise.toml`), Minitest 5.27.0, and Rake 13.4.2. Direct runtime gems also include `json`. The container is `ruby:3.3-alpine`. Agent instructions and decision history: `AGENTS.md`, `MEMORY.md`, `DECISIONS.md`.

Queries PostgreSQL **v1 views** (`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_speakers`, `v1_year_sponsors`). Year-scoped detail:

- `GET /v1/speakers/2026/diana-pham`
- `GET /v1/sponsors/2026/flywheel`

The HTTP contract is the CMS file `priv/api/openapi.yaml` in `github.com/brightball/carolina-codes`. This repo does not ship a copy.

Registers with the Elixir site **once on boot**, in a background thread with a one-second timeout, and does not query the catalog to do it. A failed registration is logged and swallowed. Does not heartbeat.

```bash
bundle install
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4001 \
bundle exec puma
```

## Tests and quality gates

Handler tests drive the shipped Sinatra app over Rack with a fake catalog (no Postgres):

```bash
bundle exec rake test
```

Other gates (also run as git pre-commit and as parallel Gitea Actions jobs):

```bash
bundle exec rake sast      # semgrep p/ruby (Sinatra-capable SAST)
bundle exec rake audit     # bundler-audit
gitleaks protect --staged --verbose   # pre-commit (staged secrets)
gitleaks detect --source . --verbose  # CI / full history
bundle exec rake lint      # RuboCop
```

Install pre-commit hooks once:

```bash
bundle exec rake hooks     # pre-commit install + core.hooksPath=.githooks
```

Emergency skip: `SKIP=tests,sast,audit,gitleaks,lint git commit`.
