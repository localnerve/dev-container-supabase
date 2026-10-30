# Why DinD, not DooD

This workstation uses **DinD** (Docker-in-Docker): a `docker:dind` sidecar runs the Docker daemon *inside* the stack's own network namespace, and the `supabase-dev` container joins that netns (`network_mode: service:dind`). The Supabase CLI reaches the daemon at `tcp://127.0.0.1:2375`, and `supabase start`'s published ports land in that same shared netns — so the CLI can reach its services at `127.0.0.1:5432x`.

The obvious alternative is **DooD** (Docker-outside-of-Docker): bind-mount the host's Docker socket and let `supabase start` launch its containers as siblings on the host daemon, exactly how Testcontainers runs on a bare GHA runner. For *most* container-orchestration workloads DooD is the lighter choice — but **not for Supabase**, because Supabase's CLI connects to its own stack over loopback.

> Adapted from the [`dev-container`](../../dev-container/docs/security/dind-dood-security.md) analysis, whose conclusion is inverted here for the reason below.

## The decisive constraint: Supabase talks to itself at 127.0.0.1

`supabase start` does two things in sequence:

1. It launches ~12 service containers (Postgres, Kong, Studio, PostgREST, Auth, Storage, …) through the Docker daemon, **publishing** their ports so they're reachable at `127.0.0.1:5432x`.
2. The CLI then *connects* to those published addresses — `127.0.0.1:54322` for Postgres, etc. — to seed the schema, run migrations, and report status.

Where a "published port" actually lands depends entirely on **which network namespace the daemon treats as its host**:

- **DooD** → the daemon is the *host* daemon, so published ports bind to the **host's** loopback. From inside the `supabase-dev` container, `127.0.0.1` is the *container's own* (empty) loopback. The connections in step 2 are refused:
  ```
  failed to connect to postgres ... ECONNREFUSED 127.0.0.1:54322
  ```
  (Observed directly: the Postgres container came up *healthy*, yet the CLI couldn't reach it — the DB was fine, only the localhost path was broken.)

- **DinD** → the daemon runs in the `dind` container's netns and treats *that* netns as its "host." Published ports bind into that netns. Because `supabase-dev` is a member of the same netns (`network_mode: service:dind`), `127.0.0.1:5432x` resolves to the Supabase services. The CLI connects cleanly.

This is precisely why artist-film-hub's devcontainer uses the `ghcr.io/devcontainers/features/docker-in-docker` feature and forwards 54321–54324 — its workflow runs `supabase start`, which has no DooD-compatible path. **For this project DinD is not a preference, it's a correctness requirement.**

## What DinD costs you (accepted trade-offs)

None of these block the stack from working; they're the price of getting loopback reach right.

1. **Image re-pull / storage.** The `dind` daemon has its own image store, so Supabase's images are pulled into it rather than shared with the host cache. First run pulls ~12 images; a clean rebuild re-pulls them (the store is lost when the sidecar is recreated). A named volume backed by `${PROJECTS_PATH}`-adjacent storage can persist it if you want to avoid that.
2. **`privileged: true`.** The daemon needs `privileged` for iptables and mounts, a broader grant than a socket mount — but scoped to the Docker Desktop VM, not your Mac (see [security.md](security.md)).
3. **An extra service + a health gate.** `supabase-dev` waits for `dind` to be healthy before starting. That's one more container and a few seconds of startup, and it means you can't run `supabase start` until the daemon is up — which is fine because it must be.
4. **Nested namespaces.** The topology is `macOS → Docker Desktop VM → dind daemon → Supabase containers`, plus `supabase-dev` sharing that netns. Slightly deeper than DooD's flatter sibling layout, but transparent in practice: you run `supabase start` the same way you would on a bare machine.

## What DooD *would* have saved you (and why it doesn't matter)

- Shared image cache with the host daemon — nice, but Supabase re-pulling once per rebuild is minutes, not hours.
- No privileged container — meaningful only if your threat model were "a malicious daemon," which isn't the case here; you control both the app code and the (trusted) Supabase images.
- One fewer service — trivial against a feature that simply doesn't work under DooD.

## Bottom line

For a generic `docker`/Testcontainers workload, DooD's lower overhead usually wins. But Supabase is the specific case where the CLI *must* reach its own services at `127.0.0.1`, and only a daemon that shares the app container's network namespace satisfies that. This project therefore runs DinD — matching artist-film-hub — and accepts the modest overhead (re-pulls, privileged mode, an extra healthy-gated sidecar) as the cost of `supabase start` actually working from inside the workstation.

If you ever drop Supabase in favor of a stack that reaches its services by name/IP on a user-defined network (rather than loopback), DooD becomes viable again and would be the lighter choice — revisit this file at that point.
