#!/usr/bin/env bash
#
# setup.sh — install selected tools into a sandbox container.
#
# Usage: ./setup.sh <flyakeed|vectora|personal> [--local] <tool>...
#   ./setup.sh personal node gh hermes
#   ./setup.sh vectora --local node claude cursor
#   ./setup.sh --local flyakeed all
#   ./setup.sh vectora base      → git + base packages only (any tool pulls these too)
#   ./setup.sh              → print the tool list (always explicit)
#
# One shared script for all three sandboxes: on the host it validates the
# slug and tools, then pipes ITSELF into the target container
# (SANDBOX_INSTALL=1, TOOLS="...") where only the requested tool handlers
# run. The container runs as root with the host group (umask 002); installs
# land in the persistent HOME volume (/root), so they survive container
# recreation — re-run after wiping a state volume.

set -euo pipefail

# Timestamped progress line. A moving clock means it is working; a frozen one
# means a real hang.
log() { printf '>> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# --- Tool handlers (run INSIDE the container; see SANDBOX_INSTALL) ----------

# Base packages the image doesn't ship (it holds only the root user).
# Idempotent. libatomic1 is required by the nvm-managed glibc Node; procps
# provides pgrep.
ensure_base() {
  if command -v curl >/dev/null 2>&1 \
    && command -v git >/dev/null 2>&1 \
    && command -v rg >/dev/null 2>&1 \
    && command -v pgrep >/dev/null 2>&1 \
    && { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q 'libatomic\.so\.1'; then
    return
  fi
  log "base: apt-get update"
  apt-get update
  log "base: installing packages (curl, git, jq, ripgrep, procps, libatomic1, ...)"
  apt-get install -y --no-install-recommends \
    ca-certificates curl git less ripgrep unzip xz-utils gnupg openssh-client jq procps libatomic1
  rm -rf /var/lib/apt/lists/*
}

# Node.js 26 (current) via nvm, per https://nodejs.org/en/download/current.
# Idempotent: nvm install reuses an already-installed 26.x. Node lands in
# ~/.nvm (persistent volume) and is on PATH in interactive shells via the
# rc files nvm writes.
install_node() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.8/install.sh | bash
  fi
  # shellcheck disable=SC1091
  . "$NVM_DIR/nvm.sh"
  nvm install 26
  nvm alias default 26
  log "node $(node --version)"
}

install_gh() {
  if [ -x "$HOME/.local/bin/gh" ] || command -v gh >/dev/null 2>&1; then
    log "gh already installed"
    return
  fi
  log "gh: downloading standalone binary (~10 MB)"
  case "$(uname -m)" in
    x86_64|amd64) gh_arch=amd64 ;;
    aarch64|arm64) gh_arch=arm64 ;;
    *) echo "!! unsupported arch '$(uname -m)' for gh" >&2; return 1 ;;
  esac
  gh_ver="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')"
  if [ -z "${gh_ver}" ] || [ "${gh_ver}" = "null" ]; then
    echo "!! could not resolve the latest gh version" >&2
    return 1
  fi
  gh_tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/cli/cli/releases/download/v${gh_ver}/gh_${gh_ver}_linux_${gh_arch}.tar.gz" \
    -o "${gh_tmp}/gh.tar.gz"
  tar -xzf "${gh_tmp}/gh.tar.gz" -C "${gh_tmp}"
  install -d -m 0755 "$HOME/.local/bin"
  install -m 0755 "${gh_tmp}/gh_${gh_ver}_linux_${gh_arch}/bin/gh" "$HOME/.local/bin/gh"
  rm -rf "${gh_tmp}"
  log "gh $("$HOME/.local/bin/gh" --version | head -1)"
}

install_kiro() {
  if [ -x "$HOME/.local/bin/kiro-cli" ]; then
    log "kiro-cli already installed"
    return
  fi
  log "kiro: downloading + installing (large zip, may take a minute)"
  curl -fsSL https://cli.kiro.dev/install -o /tmp/kiro-install.sh
  HOME="$HOME" KIRO_CLI_SKIP_SETUP=1 bash /tmp/kiro-install.sh --force --channel stable
  rm -f /tmp/kiro-install.sh
  log "kiro-cli installed"
}

# Claude Code is an npm package — ensure node first (idempotent).
install_claude() {
  install_node
  if command -v claude >/dev/null 2>&1; then
    log "claude-code already installed"
    return
  fi
  log "claude-code: npm install -g @anthropic-ai/claude-code"
  npm install -g @anthropic-ai/claude-code
  log "claude-code $(claude --version)"
}

install_cursor() {
  if [ -x "$HOME/.local/bin/cursor-agent" ]; then
    log "cursor-agent already installed"
    return
  fi
  log "cursor: downloading + installing"
  curl https://cursor.com/install -fsS | bash
  log "cursor-agent installed"
}

# OpenCode (installer drops the binary in ~/.opencode/bin and adds it to PATH
# in the shell rc files).
install_opencode() {
  if command -v opencode >/dev/null 2>&1; then
    log "opencode already installed"
    return
  fi
  log "opencode: downloading + installing"
  curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh
  bash /tmp/opencode-install.sh
  rm -f /tmp/opencode-install.sh
  log "opencode installed"
}

# Hermes Agent via the official installer (heavy: clones the repo, provisions
# uv/Python/node through pm — no nvm node needed). Publishes `hermes` to
# ~/.local/bin, state to ~/.hermes. --non-interactive skips the stages that
# need a terminal. Afterwards starts gateway + dashboard if not running
# (both processes are python launchers whose cmdlines end in "gateway run" /
# "dashboard --host"; the dashboard binds 0.0.0.0 so the compose port
# mapping 9229:9119 reaches it).
install_hermes() {
  if [ -x "$HOME/.local/bin/hermes" ]; then
    log "hermes already installed"
  else
    log "hermes: downloading + installing (heavy: uv/Python/node + build; several minutes)"
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh
    bash /tmp/hermes-install.sh --non-interactive
    rm -f /tmp/hermes-install.sh
    log "hermes installed"
  fi
  if ! pgrep -f "gateway run" >/dev/null 2>&1; then
    nohup "$HOME/.local/bin/hermes" gateway run >>"$HOME/.hermes/gateway.log" 2>&1 &
    log "hermes gateway starting (log: ~/.hermes/gateway.log)"
  fi
  if ! pgrep -f "dashboard --host" >/dev/null 2>&1; then
    nohup "$HOME/.local/bin/hermes" dashboard --host 0.0.0.0 --port 9119 --no-open >>"$HOME/.hermes/dashboard.log" 2>&1 &
    log "hermes dashboard starting (log: ~/.hermes/dashboard.log)"
  fi
}

install_all() {
  install_node
  install_gh
  install_kiro
  install_claude
  install_cursor
  install_opencode
  install_hermes
}

# --- Container mode ---------------------------------------------------------
# The host wrapper pipes this file in with SANDBOX_INSTALL=1 and TOOLS set.
if [ "${SANDBOX_INSTALL:-}" = "1" ]; then
  export DEBIAN_FRONTEND=noninteractive
  umask 002
  ensure_base
  total=0
  for _t in ${TOOLS}; do total=$((total + 1)); done
  idx=0
  for tool in ${TOOLS}; do
    idx=$((idx + 1))
    log "[${idx}/${total}] ${tool}: installing..."
    case "$tool" in
      node)     install_node ;;
      gh)       install_gh ;;
      kiro)     install_kiro ;;
      claude)   install_claude ;;
      cursor)   install_cursor ;;
      opencode) install_opencode ;;
      hermes)   install_hermes ;;
      all)      install_all ;;
      base)     ensure_base ;;
      *) echo "!! unknown tool '${tool}'" >&2; exit 1 ;;
    esac
  done
  exit 0
fi

# --- Host mode: validate args, then pipe this script into the container -----

usage() {
  sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
}

known_tool() {
  case "$1" in
    node|gh|kiro|claude|cursor|opencode|hermes|all|base) return 0 ;;
    *) return 1 ;;
  esac
}

slug=""
local_stack=false
tools=()
while [ $# -gt 0 ]; do
  case "$1" in
    --local) local_stack=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "!! unknown option '$1'" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "${slug}" ]; then
        slug="$1"
      else
        tools+=("$1")
      fi
      shift ;;
  esac
done

case "${slug}" in
  flyakeed|vectora|personal) ;;
  node|gh|kiro|claude|cursor|opencode|hermes|all|base)
    echo "!! first argument must be a sandbox slug (flyakeed|vectora|personal)," >&2
    echo "   got '${slug}' — did you mean: ./setup.sh <slug> ${slug}${tools[*]:+ ${tools[*]}}" >&2
    exit 1 ;;
  *)
    usage
    [ -n "${slug}" ] && echo "!! unknown sandbox '${slug}'" >&2
    exit 1 ;;
esac

if [ ${#tools[@]} -eq 0 ]; then
  usage
  exit 1
fi

for tool in "${tools[@]}"; do
  if ! known_tool "${tool}"; then
    echo "!! unknown tool '${tool}'" >&2
    usage >&2
    exit 1
  fi
done

compose=(docker compose)
if [ "${local_stack}" = true ]; then
  compose+=(-f compose.local.yaml)
fi
service="${slug}-sandbox"
tools_str="${tools[*]}"

log "Installing [${tools_str}] into ${service}..."
cat "$0" | "${compose[@]}" exec -T -e SANDBOX_INSTALL=1 -e TOOLS="${tools_str}" "${service}" bash -s
log "Done."
