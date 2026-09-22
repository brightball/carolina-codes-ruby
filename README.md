# Carolina Codes — Ruby API

Read-only Sinatra API for the [Carolina Code Conference](https://carolina.codes) polyglot site.

Queries PostgreSQL **v1 views** (`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_speakers`, `v1_year_sponsors`). Year-scoped detail:

- `GET /v1/speakers/2026/diana-pham`
- `GET /v1/sponsors/2026/flywheel`

See `elixir/priv/api/openapi.yaml`.

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
