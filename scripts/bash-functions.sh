# =============================================================================
# dev-container-supabase shell helpers
#
# Sourced from ~/.bashrc in new terminals (see Dockerfile). Provides:
#   xvfb-start / xvfb-stop  — on-demand headful browser debugging over VNC
#   git-check               — verify git can reach the origin remote
#   git-check-remote        — local vs upstream tracking state for this repo
#
# Replicated from a typical project's devcontainer, with a
# project-neutral prefix. Port 5900 (VNC) is forwarded by docker-compose.yml.
# =============================================================================

_SUPABASE_DEV_XVFB_STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/supabase-dev-xvfb-${UID:-$(id -u)}"

_supabase_dev_process_matches() {
  local pid="$1"
  local expected="$2"
  local command

  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command="$(ps -p "$pid" -o args= 2>/dev/null)" || return 1
  [[ "$command" == *"$expected"* ]]
}

_supabase_dev_stop_process() {
  local name="$1"
  local pid="$2"
  local expected="$3"
  local attempt

  if ! _supabase_dev_process_matches "$pid" "$expected"; then
    return 0
  fi
  if ! kill "$pid"; then
    echo "Could not stop $name process $pid." >&2
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  for ((attempt = 0; attempt < 50; attempt += 1)); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Stopped $name process $pid."
      return 0
    fi
    sleep 0.1
  done
  echo "$name process $pid did not stop after SIGTERM." >&2
  return 1
}

xvfb-start() {
  local display=":99"
  local xvfb_pid_file="$_SUPABASE_DEV_XVFB_STATE_DIR/xvfb.pid"
  local vnc_pid_file="$_SUPABASE_DEV_XVFB_STATE_DIR/x11vnc.pid"
  local xvfb_log="$_SUPABASE_DEV_XVFB_STATE_DIR/xvfb.log"
  local vnc_log="$_SUPABASE_DEV_XVFB_STATE_DIR/x11vnc.log"
  local pid attempt

  if ! command -v Xvfb >/dev/null || ! command -v xdpyinfo >/dev/null; then
    echo "Xvfb is unavailable. Rebuild the container to install its system packages." >&2
    return 1
  fi

  mkdir -p "$_SUPABASE_DEV_XVFB_STATE_DIR"
  chmod 700 "$_SUPABASE_DEV_XVFB_STATE_DIR"

  if [[ ! ${_SUPABASE_DEV_PREVIOUS_DISPLAY+x} ]]; then
    _SUPABASE_DEV_PREVIOUS_DISPLAY="${DISPLAY-}"
  fi
  export DISPLAY="$display"

  if ! xdpyinfo -display "$display" >/dev/null 2>&1; then
    Xvfb "$display" -screen 0 1920x1080x24 -nolisten tcp >"$xvfb_log" 2>&1 &
    pid=$!
    printf '%s\n' "$pid" >"$xvfb_pid_file"

    for ((attempt = 0; attempt < 50; attempt += 1)); do
      if xdpyinfo -display "$display" >/dev/null 2>&1; then
        break
      fi
      if ! kill -0 "$pid" 2>/dev/null; then
        cat "$xvfb_log" >&2
        rm -f "$xvfb_pid_file"
        echo "Xvfb failed to start on $display." >&2
        return 1
      fi
      sleep 0.1
    done

    if ! xdpyinfo -display "$display" >/dev/null 2>&1; then
      kill "$pid" 2>/dev/null || true
      rm -f "$xvfb_pid_file"
      echo "Xvfb did not become ready on $display." >&2
      return 1
    fi
    echo "Xvfb started on $display."
  else
    echo "An X server is already available on $display."
  fi

  if [[ -f "$vnc_pid_file" ]] &&
    _supabase_dev_process_matches "$(cat "$vnc_pid_file")" "x11vnc -display $display"; then
    echo "x11vnc is already running on localhost:5900."
    return 0
  fi

  if ! command -v x11vnc >/dev/null; then
    echo "x11vnc is unavailable. Rebuild the container to install its system packages." >&2
    return 1
  fi

  x11vnc -display "$display" -forever -shared -nopw -localhost -quiet >"$vnc_log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" >"$vnc_pid_file"
  sleep 0.2
  if ! _supabase_dev_process_matches "$pid" "x11vnc -display $display"; then
    cat "$vnc_log" >&2
    rm -f "$vnc_pid_file"
    echo "x11vnc failed to start on localhost:5900." >&2
    return 1
  fi
  echo "x11vnc started on localhost:5900. Use the forwarded port to view the desktop."
}

xvfb-stop() {
  local name pid_file expected pid
  local -a services=(
    "x11vnc|$_SUPABASE_DEV_XVFB_STATE_DIR/x11vnc.pid|x11vnc -display :99"
    "Xvfb|$_SUPABASE_DEV_XVFB_STATE_DIR/xvfb.pid|Xvfb :99"
  )

  for service in "${services[@]}"; do
    IFS='|' read -r name pid_file expected <<<"$service"
    if [[ -f "$pid_file" ]]; then
      pid="$(cat "$pid_file")"
      if _supabase_dev_process_matches "$pid" "$expected"; then
        if ! _supabase_dev_stop_process "$name" "$pid" "$expected"; then
          return 1
        fi
      fi
      rm -f "$pid_file"
    fi
  done

  if [[ ${_SUPABASE_DEV_PREVIOUS_DISPLAY+x} ]]; then
    if [[ -n "$_SUPABASE_DEV_PREVIOUS_DISPLAY" ]]; then
      export DISPLAY="$_SUPABASE_DEV_PREVIOUS_DISPLAY"
    else
      unset DISPLAY
    fi
    unset _SUPABASE_DEV_PREVIOUS_DISPLAY
  fi
}

git-check() {
  if git ls-remote --exit-code origin HEAD >/dev/null 2>&1; then
    echo "Git can access the origin remote."
  else
    echo "Git could not access the origin remote. Check the remote URL and credentials." >&2
    return 1
  fi
}

git-check-remote() {
  local branch local_sha remote_sha base_sha
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || {
    echo "Not in a Git repository." >&2
    return 1
  }
  echo "Fetching remote state..."
  git fetch --quiet || return 1

  local_sha="$(git rev-parse HEAD)" || return 1
  remote_sha="$(git rev-parse '@{u}' 2>/dev/null)" || {
    echo "No upstream tracking branch set for '$branch'." >&2
    return 1
  }
  base_sha="$(git merge-base HEAD '@{u}')" || return 1

  if [[ "$local_sha" == "$remote_sha" ]]; then
    echo "Up to date with remote."
  elif [[ "$local_sha" == "$base_sha" ]]; then
    echo "Behind remote — $(git rev-list HEAD..@{u} --count) commit(s) to pull."
  elif [[ "$remote_sha" == "$base_sha" ]]; then
    echo "Ahead of remote — $(git rev-list @{u}..HEAD --count) commit(s) to push."
  else
    echo "Diverged from remote — $(git rev-list HEAD..@{u} --count) to pull, $(git rev-list @{u}..HEAD --count) to push."
  fi
}
