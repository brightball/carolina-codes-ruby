# Carolina Codes — Ruby API

Read-only Sinatra API for the [Carolina Code Conference](https://carolina.codes) polyglot site.

Queries PostgreSQL **v1 views** (`v1_speakers`, `v1_sponsors`, `v1_years`, `v1_talks`, `v1_sponsorships`, `v1_year_speakers`, `v1_year_sponsors`). Year-scoped detail:

- `GET /v1/speakers/2026/diana-pham`
- `GET /v1/sponsors/2026/flywheel`

See `elixir/priv/api/openapi.yaml`.

Registers with the Elixir site **once on boot**. Does not heartbeat.

```bash
bundle install
DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/carolina_dev \
CAROLINA_URL=http://127.0.0.1:4000 \
POLYGLOT_REGISTER_TOKEN=dev \
PUBLIC_BASE_URL=http://127.0.0.1:4001 \
bundle exec puma
```
