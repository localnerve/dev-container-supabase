# =============================================================================
# supabase-dev-container
#
# A standalone webdev workstation for local Supabase development, modeled on
# the artist-film-hub project devcontainer and delivered as a `docker compose`
# service instead of a VS Code .devcontainer. It provides:
#   - Node.js 24 (via the Dev Containers base image) + Bun
#   - The Supabase CLI (for `supabase start` / local stack orchestration)
#   - Chromium + Playwright system dependencies (all three engines)
#   - Xvfb + x11vnc for headful browser debugging via VNC
#   - Docker CLI, paired with a `docker:dind` sidecar (see docker-compose.yml) so
#     the Supabase CLI can launch its local-stack service containers. DinD is
#     used — not DooD — because `supabase start` reaches its services at
#     127.0.0.1:*, which only works when the daemon shares this container's
#     network namespace (the same reason artist-film-hub uses Docker-in-Docker).
#   - Portable git-check / git-check-remote and xvfb-start / xvfb-stop helpers
#
# Version pins live here as ARGs; docker-compose.yml passes them through.
# =============================================================================

# --- Build-time version pins (single source of truth) -----------------------
# SUPABASE_VERSION defaults to empty (= latest from GitHub releases); pin it in
# docker-compose.yml to freeze, e.g. SUPABASE_VERSION=2.122.0.
ARG NODE_MAJOR=24
ARG BUN_VERSION=1.4.4
ARG SUPABASE_VERSION
ARG CURL_OPTS="-fsSL --retry 5 --retry-delay 2 --retry-all-errors"

# =============================================================================
# Base image — same family the artist-film-hub devcontainer used:
# Dev Containers TypeScript/Node image, Node ${NODE_MAJOR}, Debian bookworm.
# The default working user is `node`; its home is /home/node.
# =============================================================================
FROM mcr.microsoft.com/devcontainers/typescript-node:5-${NODE_MAJOR}-bookworm

ARG BUN_VERSION
ARG SUPABASE_VERSION
ARG CURL_OPTS
ARG USERNAME=node
ARG USER_HOME=/home/${USERNAME}

ENV DEBIAN_FRONTEND=noninteractive

# Puppeteer/Playwright: use the Playwright-managed browser rather than
# triggering Puppeteer's own Chromium download.
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Make Bun available on PATH for every shell without needing /usr/local symlinks
# (the install lives under ${USER_HOME}/.bun, which is node-user private).
ENV PATH="${USER_HOME}/.bun/bin:${PATH}"

# =============================================================================
# System packages — single RUN to minimise layers:
#   - build prereqs + git/curl/ca-certificates/procps
#   - Xvfb + x11vnc for headful browser debugging
#   - Docker CLI (no daemon) — talks to the `docker:dind` sidecar over a shared
#     network namespace, so `supabase start` launches its service containers and
#     reaches them at 127.0.0.1:*.
# =============================================================================
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git ca-certificates curl procps \
       software-properties-common \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Xvfb + x11vnc for headful browser debugging (headless runs are
    #     unaffected; only headed runs need xvfb-start first) ---
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       xvfb \
       x11-utils \
       x11vnc \
    && mkdir -p /tmp/.X11-unix \
    && chmod 1777 /tmp/.X11-unix \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    \
    # --- Docker CLI only (no daemon). It talks to the `docker:dind` sidecar
    #     over a shared network namespace (see compose), so `supabase start`
    #     can launch its service containers and reach them at 127.0.0.1:*. ---
    && install -m 0755 -d /etc/apt/keyrings \
    && curl ${CURL_OPTS} https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       docker-ce-cli \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    # Strip accumulated doc/man/info pages from all packages installed so far
    && rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# =============================================================================
# Playwright system dependencies (all three engines).
#
# Installs the ~220 apt packages browsers need to render using Playwright's
# own OS-aware resolver — far more reliable than hand-curating package names,
# which drift between Debian releases. This installs *system libraries only*:
# it does NOT download browser binaries or install a project's node_modules.
# Those belong to each project's own `bun install` + `bunx playwright install`,
# which populates the shared /home/node/.cache/ms-playwright volume (see
# compose). A throwaway global playwright is used purely to invoke install-deps.
# =============================================================================
RUN npm install -g playwright \
    && npx playwright install-deps chromium \
    && npx playwright install-deps firefox \
    && npx playwright install-deps webkit \
    && npm uninstall -g playwright \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.npm \
    && rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*

# =============================================================================
# Supabase CLI — installed to a world-readable path for `supabase start`.
# Empty SUPABASE_VERSION resolves to the latest GitHub release (the same URL
# the artist-film-hub devcontainer uses); pin it in docker-compose.yml to freeze.
# Done as root so no sudo is required and the binary lands in /usr/local/bin.
# =============================================================================
RUN if [ -n "${SUPABASE_VERSION}" ]; then \
        curl ${CURL_OPTS} "https://github.com/supabase/cli/releases/download/v${SUPABASE_VERSION}/supabase_linux_$(dpkg --print-architecture).tar.gz" | tar -xz -C /usr/local/bin supabase; \
    else \
        curl ${CURL_OPTS} "https://github.com/supabase/cli/releases/latest/download/supabase_linux_$(dpkg --print-architecture).tar.gz" | tar -xz -C /usr/local/bin supabase; \
    fi \
    && chmod +x /usr/local/bin/supabase \
    && supabase --version

# =============================================================================
# DinD readiness — point the client at the `docker:dind` sidecar.
#
# The daemon runs in a sibling service that shares this container's network
# namespace (see docker-compose.yml), so it and the Supabase services are all
# reachable at 127.0.0.1:*. No host socket bind-mount or group membership is
# needed; DOCKER_HOST is supplied by the compose file.
# =============================================================================
ENV DOCKER_HOST=tcp://127.0.0.1:2375

# Pre-create the Playwright cache dir with correct ownership so a named volume
# mounted here (see compose) comes up owned by node, not root.
RUN mkdir -p ${USER_HOME}/.cache/ms-playwright \
    && chown -R ${USERNAME}:${USERNAME} ${USER_HOME}/.cache

# =============================================================================
# Bun — installed for the node user (installs under ${USER_HOME}/.bun).
# =============================================================================
USER ${USERNAME}
WORKDIR ${USER_HOME}
RUN curl ${CURL_OPTS} "https://bun.sh/install?v=${BUN_VERSION}" | bash \
    && bun --version

# =============================================================================
# Shell helpers — xvfb-start/xvfb-stop and portable git-check/git-check-remote.
# Baked into the image and sourced from .bashrc in new terminals.
# =============================================================================
# The exec bit is not required (we `source` the file), so skip chmod — some base
# images set attributes that make chmod on copied files fail with EPERM.
COPY scripts/bash-functions.sh ${USER_HOME}/bash-functions.sh
RUN printf '\nsource "%s"\n' "${USER_HOME}/bash-functions.sh" >> ${USER_HOME}/.bashrc

# =============================================================================
# Final working directory — projects are bind-mounted here (see compose).
# =============================================================================
WORKDIR /workspace
CMD ["sleep", "infinity"]
