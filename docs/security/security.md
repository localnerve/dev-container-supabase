# Security profile

This workstation is a development environment, not a security boundary. The notes below explain the two real decisions — the privileged `dind` sidecar and the seccomp profile — and what each does and does not protect against. They are adapted from the [`dev-container`](../../dev-container/docs/security/security.md) analysis for this project's smaller scope (no Caddy, no OpenBao).

## The two levers that actually matter

### 1. The privileged `dind` sidecar is the real attack surface

```yaml
services:
  dind:
    image: docker:${DIND_VERSION}-dind
    privileged: true              # ← this, not seccomp, defines the blast radius
    environment:
      DOCKER_TLS_CERTDIR: ""      # daemon on plain tcp://127.0.0.1:2375 (netns-local)
```

We use a nested Docker daemon (`docker:dind`) rather than mounting the host socket because `supabase start` must reach its own services at `127.0.0.1:5432x` *from inside* the workstation — see [dind-dood-security.md](dind-dood-security.md). The daemon needs `privileged: true` (it manages iptables and mounts for the containers it launches), which is a broad grant **within the Docker Desktop VM**, not on your Mac.

What "privileged" does and does *not* reach here:

- **Isolated network namespace.** The daemon and every container it spawns live in the `dind` service's netns, with only loopback + a private bridge visible. Nothing there can address host services by their real addresses; the only outward path is the explicit compose `ports:` (5900, 54321–54324).
- **Bounded to the VM.** On **Docker Desktop for Mac**, everything — the daemon, Supabase's containers, your app — runs inside Docker Desktop's Linux VM, isolated from macOS by Apple's `Virtualization.framework`. A compromised process can reach root *inside that VM* but not your Mac's real filesystem (`/Users`, `/System`) without a separate hypervisor-level exploit.
- **Still exposed: mounted paths.** The workstation bind-mounts `${PROJECTS_PATH}` and the SSH agent socket, and shares its netns with `dind`. A process in the VM that can talk to the daemon (i.e. anything in the shared netns) can create a privileged container that reads those mounts — so the practical blast radius is "root in the VM + your mounted project files + SSH agent," not full macOS compromise.

The trade-off: you accept that untrusted code run here could reach VM root and access mounted files/credentials, in exchange for `supabase start` working exactly as it does on a bare machine. Only run trusted code in this environment.

### 2. The seccomp profile is defense-in-depth, not a boundary

`chrome.json` starts from Docker's default deny-by-default profile (blocks kernel-module loading, `ptrace`, arbitrary mounts, time-setting, and ~120 other dangerous syscalls) and adds only the Chromium zygote/sandbox syscalls browser rendering needs. It applies to the `supabase-dev` container (where the browser runs), not to the privileged daemon. Against an attacker who already has code execution *and* can drive the daemon, seccomp on the workstation offers no meaningful protection — the daemon bypasses it. Its value is stopping accidental / low-level escapes from ordinary application bugs in the app and browser.

## What this environment does NOT do

- It is not multi-tenant or hardened for untrusted third-party code.
- The Supabase local stack (Postgres, Studio, etc.) runs as containers on the `dind` daemon with default capabilities; treat its data and keys as development-only. Never point the workstation at production credentials.
- `supabase status --output env` prints a service-role key for the local stack. Keep it in your ignored `.env.local`, never commit it.

## Recommendations

- Run only trusted code here (your own projects and their dependencies).
- Keep the image, the Supabase CLI, and `DIND_VERSION` current to pick up container-runtime and dependency patches.
- Regenerate `chrome.json` when you update the base image or browser, with `./scripts/update-chrome-seccomp.sh`.
- If you need isolation from code that must not touch your project files at all, run it in a separate CI runner rather than this workstation.
