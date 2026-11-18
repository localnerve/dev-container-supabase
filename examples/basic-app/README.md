# basic-app — minimal Bun + TypeScript Supabase starter

A dependency-free scaffold for developing against the local Supabase stack inside
`dev-container-supabase`. Full walkthrough: [../../docs/new-project-guide.md](../../docs/new-project-guide.md).

## Quick start (first time in a fresh copy)

```bash
supabase init      # generates supabase/config.toml + .env with local keys/URLs
supabase start     # starts the ~12 local services (first run pulls images; fast after)
supabase status    # verify — prints the stack table and URLs
```

> Until you've run `init` + `start`, every Supabase command here prints
> `Not linked.` / "No such container" — that means "no local stack yet", not a broken install.

Then:

```bash
bun install
supabase migration up                              # applies supabase/migrations/ to the local stack
KEY=$(supabase status --output env | grep -oE 'sb_publishable_[A-Za-z0-9_-]+')
SUPABASE_PUBLISHABLE_KEY=$KEY bun run start        # prints the seeded row via PostgREST at 127.0.0.1:54321
```

Studio (schema/tables/auth UI) is at http://127.0.0.1:54323 from your Mac browser.

## What's here

| File | Purpose |
| --- | --- |
| `package.json` | ESM, Bun scripts (`dev`/`start`/`typecheck`) — no framework baked in |
| `tsconfig.json` | strict TS (TypeScript 7 native compiler), ES2022, Bundler resolution, `@/*` → `src/` |
| `bunfig.toml` | text lockfile + 24h supply-chain guard (`minimumReleaseAge`) |
| `.env.example` | template for `SUPABASE_URL` / `SUPABASE_PUBLISHABLE_KEY` (copy to gitignored `.env.local`) |
| `src/index.ts` | smoke test: queries the `items` table through PostgREST |
| `supabase/migrations/` | example first migration (table + seed row) — model your schema on it |
