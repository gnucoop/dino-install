#!/usr/bin/env bash
# =============================================================================
# Dino installer — renders .env, nginx.conf and TLS certs from one BASE_DOMAIN,
# auto-generating all cryptographic secrets. Run this, then `docker compose up -d`.
#
# Usage:
#   ./setup.sh [TARGET_DIR]
#     TARGET_DIR   where to write the generated deployment (default: this folder).
#                  e.g.  ./setup.sh ../my-dino   materializes a ready-to-run stack there.
#
# Interactive by default. For unattended / cloud (Elestio, AWS, ...) runs, set:
#   SETUP_NONINTERACTIVE=1 SETUP_BASE_DOMAIN=... SETUP_ADMIN_EMAIL=... \
#   SETUP_ADMIN_PASSWORD=... SETUP_TLS_MODE=selfsigned|letsencrypt|provided \
#   ./setup.sh [TARGET_DIR]
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Dino installer — render a ready-to-run deployment (.env, nginx.conf, TLS certs)
from a single base domain, auto-generating all cryptographic secrets.

Usage:
  ./setup.sh [TARGET_DIR]
  ./setup.sh -h | --help

Arguments:
  TARGET_DIR   Folder to write the generated deployment into (default: this
               folder). Created if it does not exist. Example:
                 ./setup.sh ../my-dino

Environment overrides (for unattended / cloud installs):
  SETUP_NONINTERACTIVE=1   Skip all prompts and use defaults / overrides below.
  SETUP_BASE_DOMAIN        Base domain (subdomains are derived from it).
  SETUP_ADMIN_EMAIL        Admin email.
  SETUP_ADMIN_PASSWORD     Admin / Hasura secret (blank = auto-generated).
  SETUP_TLS_MODE           selfsigned | letsencrypt | provided.
  SETUP_UPSTREAM_HOST      Docker host gateway nginx uses to reach services.
  SETUP_AUTH_SMTP_*        Optional SMTP settings (HOST/PORT/USER/PASS/SENDER).

Safety guards:
  SETUP_SKIP_PORT_CHECK=1  Skip the check that all Dino host ports are free.
  SETUP_FORCE=1            Proceed even if the target already looks like a
                           deployment (existing docker-compose.yml / .env).

Example:
  SETUP_NONINTERACTIVE=1 SETUP_BASE_DOMAIN=dino.example.com \
    SETUP_TLS_MODE=letsencrypt ./setup.sh ../my-dino
EOF
}

# ---------- argument parsing ----------
TARGET_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1" >&2; echo "Try './setup.sh --help'." >&2; exit 2 ;;
    *)  [ -z "$TARGET_ARG" ] || { echo "Unexpected extra argument: $1" >&2; exit 2; }
        TARGET_ARG="$1" ;;
  esac
  shift
done
[ $# -eq 0 ] || TARGET_ARG="${TARGET_ARG:-$1}"

# Target folder for generated files (default: alongside the templates).
TARGET_DIR="${TARGET_ARG:-$SCRIPT_DIR}"
mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
cd "$TARGET_DIR"

NHOST_APPS_REPO="${SETUP_NHOST_APPS_REPO:-git@github.com:gnucoop/nhost_apps.git}"
NHOST_APPS_BRANCH="${SETUP_NHOST_APPS_BRANCH:-prod-1.21.0-permissions-m2}"
SUBDOMAINS=(dino auth hasura storage minio minio-console)

# Host ports are read from .env.template so docker-compose.yml, nginx.conf and the
# port check below all share one source of truth (nothing is hardcoded twice).
_envval() { grep -E "^$1=" "$SCRIPT_DIR/.env.template" | head -1 | cut -d= -f2- | tr -d '"'; }
P_HTTP="$(_envval HTTP_PORT)"
P_HTTPS="$(_envval HTTPS_PORT)"
P_PG="$(_envval PG_PORT)"
P_DINOAPP="$(_envval DINOAPP_HOST_PORT)"
P_HASURA="$(_envval YOUR_HASURA_PORT)"
P_AUTH="$(_envval YOUR_AUTH_PORT)"
P_STORAGE="$(_envval YOUR_STORAGE_PORT)"
P_MINIO="$(_envval MINIO_API_PORT)"
P_CONSOLE="$(_envval MINIO_CONSOLE_PORT)"
DINO_PORTS=("$P_HTTP" "$P_HTTPS" "$P_PG" "$P_DINOAPP" "$P_HASURA" "$P_AUTH" "$P_STORAGE" "$P_MINIO" "$P_CONSOLE")

# ---------- pretty output ----------
c_bold=$'\033[1m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_red=$'\033[31m'; c_rst=$'\033[0m'
info()  { printf '%s==>%s %s\n' "$c_grn"  "$c_rst" "$*"; }
warn()  { printf '%s!! %s %s\n' "$c_yel"  "$c_rst" "$*"; }
err()   { printf '%sxx %s %s\n' "$c_red"  "$c_rst" "$*" >&2; }
die()   { err "$*"; exit 1; }

NONINTERACTIVE="${SETUP_NONINTERACTIVE:-0}"

# port_in_use <port>  → returns 0 if something is LISTENing on it (macOS + Linux).
port_in_use() {
  local p="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$p" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") >/dev/null 2>&1
  fi
}

# prompt VAR "Question" "default" [silent]
prompt() {
  local __var="$1" __msg="$2" __def="${3:-}" __silent="${4:-0}" __env_ovr __ans
  # Allow override via SETUP_<VAR>
  __env_ovr="SETUP_${__var}"
  if [ -n "${!__env_ovr:-}" ]; then printf -v "$__var" '%s' "${!__env_ovr}"; return; fi
  if [ "$NONINTERACTIVE" = "1" ]; then printf -v "$__var" '%s' "$__def"; return; fi
  if [ "$__silent" = "1" ]; then
    read -r -s -p "$__msg${__def:+ [$__def]}: " __ans; echo
  else
    read -r -p "$__msg${__def:+ [$__def]}: " __ans
  fi
  printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ---------- 1. preflight: software requirements ----------
info "Checking software requirements..."
MISSING=0
ok()   { printf '   %s✓%s %-16s %s\n' "$c_grn" "$c_rst" "$1" "${2:-}"; }
miss() { printf '   %s✗%s %-16s %s\n' "$c_red" "$c_rst" "$1" "$2"; MISSING=$((MISSING+1)); }

# require <name> <version-cmd> <install-hint>
require() {
  local name="$1" vcmd="$2" hint="$3" ver
  if command -v "$name" >/dev/null 2>&1; then
    ver="$(eval "$vcmd" 2>/dev/null | head -n1)"
    ok "$name" "$ver"
  else
    miss "$name" "not found — $hint"
  fi
}

require bash    'bash --version'    "install bash 3.2+"
require docker  'docker --version'  "install Docker: https://docs.docker.com/get-docker/"
require openssl 'openssl version'   "install openssl (brew install openssl / apt-get install openssl)"
require git     'git --version'     "install git (brew install git / apt-get install git)"
require sed     'echo sed'          "sed is part of coreutils/base system"

# Docker Compose: v2 plugin ('docker compose') or standalone v1 ('docker-compose').
COMPOSE=""
if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"; ok "docker compose" "$(docker compose version 2>/dev/null | head -n1)"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"; ok "docker-compose" "$(docker-compose version --short 2>/dev/null | head -n1)"
else
  miss "docker compose" "not found — install the Compose plugin: https://docs.docker.com/compose/install/"
fi

# Docker installed is not enough — the daemon must be running and reachable.
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker daemon" "running"
  else
    miss "docker daemon" "not reachable — start Docker Desktop / 'sudo systemctl start docker' (or fix permissions)"
  fi
fi

if [ "$MISSING" -gt 0 ]; then
  die "$MISSING requirement(s) missing — install them and re-run ./setup.sh"
fi
info "All software requirements satisfied."

# ---------- 1b. don't clobber an existing deployment ----------
# Only a separate TARGET folder is guarded by docker-compose.yml (the installer's
# own folder always has it as source); in-place runs use a generated .env instead.
if [ "${SETUP_FORCE:-0}" = "1" ]; then
  warn "SETUP_FORCE=1 — skipping existing-deployment guard."
elif [ "$TARGET_DIR" != "$SCRIPT_DIR" ] && [ -f docker-compose.yml ]; then
  die "Target '$TARGET_DIR' already contains docker-compose.yml (existing deployment).
    Refusing to overwrite it and regenerate secrets. Choose a fresh folder, remove
    the existing one, or override with SETUP_FORCE=1."
elif [ "$TARGET_DIR" = "$SCRIPT_DIR" ] && [ -f .env ]; then
  die "This folder already has a generated .env (existing in-place deployment).
    Refusing to regenerate secrets. Deploy into a new folder (./setup.sh my-dino),
    or override with SETUP_FORCE=1."
fi

# ---------- 1c. required host ports must be free ----------
if [ "${SETUP_SKIP_PORT_CHECK:-0}" = "1" ]; then
  warn "SETUP_SKIP_PORT_CHECK=1 — skipping host port check."
else
  info "Checking required host ports are free (${DINO_PORTS[*]})..."
  BUSY=()
  for p in "${DINO_PORTS[@]}"; do port_in_use "$p" && BUSY+=("$p"); done
  if [ "${#BUSY[@]}" -gt 0 ]; then
    err "The following host ports are already in use: ${BUSY[*]}"
    if command -v lsof >/dev/null 2>&1; then
      for p in "${BUSY[@]}"; do
        proc="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR==2{print $1" (pid "$2")"}')"
        printf '     :%-6s %s\n' "$p" "${proc:-in use}"
      done
    fi
    die "Free these ports (or stop the conflicting services) and re-run.
    Override with SETUP_SKIP_PORT_CHECK=1."
  fi
  info "All required host ports are free."
fi

OS="$(uname -s)"
case "$OS" in
  Linux)  DEFAULT_UPSTREAM="172.17.0.1" ;;
  Darwin) DEFAULT_UPSTREAM="host.docker.internal" ;;
  *)      DEFAULT_UPSTREAM="host.docker.internal" ;;
esac

# ---------- 2. collect inputs ----------
info "Collecting configuration..."
prompt BASE_DOMAIN       "Base domain for Dino (subdomains derived from it)" "local.dinoapp.cloud"
prompt USER_DISPLAY_NAME "Admin display name" "Admin"
prompt ADMIN_EMAIL       "Admin email" "admin@${BASE_DOMAIN}"
prompt ADMIN_PASSWORD    "Admin / Hasura secret (blank = auto-generate)" ""
prompt INSTANCE_NAME     "SPA instance name" "dinoapp"
prompt TLS_MODE          "TLS mode (selfsigned|letsencrypt|provided)" "selfsigned"
prompt UPSTREAM_HOST     "Docker host gateway nginx uses to reach services" "$DEFAULT_UPSTREAM"

info "SMTP is optional (leave blank to disable outbound email)."
prompt AUTH_SMTP_HOST   "SMTP host" ""
prompt AUTH_SMTP_PORT   "SMTP port" "587"
prompt AUTH_SMTP_USER   "SMTP user" ""
prompt AUTH_SMTP_PASS   "SMTP password" "" 1
prompt AUTH_SMTP_SENDER "SMTP sender address" "no-reply@${BASE_DOMAIN}"

case "$TLS_MODE" in selfsigned|letsencrypt|provided) ;; *) die "Invalid TLS mode: $TLS_MODE";; esac

# ---------- 3. generate crypto ----------
info "Generating secrets..."
[ -n "$ADMIN_PASSWORD" ] || ADMIN_PASSWORD="$(openssl rand -hex 24)"
JWT_KEY="$(openssl rand -base64 48 | tr -d '\n')"
PG_PASSWORD="$(openssl rand -hex 16)"
S3_ACCESS_KEY="$(openssl rand -hex 10)"
S3_SECRET_KEY="$(openssl rand -base64 30 | tr -d '/+=')"
AUTH_ENCRYPTION_KEY="$(openssl rand -hex 32)"

# ---------- 4. render .env ----------
render() {  # render <template> <output>  (literal token substitution, safe for any chars)
  local content; content="$(cat "$1")"
  content="${content//__BASE_DOMAIN__/$BASE_DOMAIN}"
  content="${content//__ADMIN_EMAIL__/$ADMIN_EMAIL}"
  content="${content//__ADMIN_PASSWORD__/$ADMIN_PASSWORD}"
  content="${content//__USER_DISPLAY_NAME__/$USER_DISPLAY_NAME}"
  content="${content//__INSTANCE_NAME__/$INSTANCE_NAME}"
  content="${content//__JWT_KEY__/$JWT_KEY}"
  content="${content//__PG_PASSWORD__/$PG_PASSWORD}"
  content="${content//__S3_ACCESS_KEY__/$S3_ACCESS_KEY}"
  content="${content//__S3_SECRET_KEY__/$S3_SECRET_KEY}"
  content="${content//__AUTH_ENCRYPTION_KEY__/$AUTH_ENCRYPTION_KEY}"
  content="${content//__AUTH_SMTP_HOST__/$AUTH_SMTP_HOST}"
  content="${content//__AUTH_SMTP_PORT__/$AUTH_SMTP_PORT}"
  content="${content//__AUTH_SMTP_USER__/$AUTH_SMTP_USER}"
  content="${content//__AUTH_SMTP_PASS__/$AUTH_SMTP_PASS}"
  content="${content//__AUTH_SMTP_SENDER__/$AUTH_SMTP_SENDER}"
  content="${content//__UPSTREAM_HOST__/$UPSTREAM_HOST}"
  # nginx upstream ports (kept in sync with docker-compose host ports / .env)
  content="${content//__DINOAPP_HOST_PORT__/$P_DINOAPP}"
  content="${content//__YOUR_HASURA_PORT__/$P_HASURA}"
  content="${content//__YOUR_AUTH_PORT__/$P_AUTH}"
  content="${content//__YOUR_STORAGE_PORT__/$P_STORAGE}"
  content="${content//__MINIO_API_PORT__/$P_MINIO}"
  content="${content//__MINIO_CONSOLE_PORT__/$P_CONSOLE}"
  printf '%s\n' "$content" > "$2"
}

info "Writing generated files to: $TARGET_DIR"
if [ -f .env ]; then info "Backing up existing .env -> .env.backup"; cp .env .env.backup; fi
render "$SCRIPT_DIR/.env.template" .env
info "Wrote .env"

# ---------- 5. render nginx.conf + copy compose ----------
render "$SCRIPT_DIR/nginx.conf.template" nginx.conf
info "Wrote nginx.conf (upstream host: $UPSTREAM_HOST)"
if [ "$TARGET_DIR" != "$SCRIPT_DIR" ]; then
  cp "$SCRIPT_DIR/docker-compose.yml" ./docker-compose.yml
  info "Copied docker-compose.yml"
fi

# ---------- 6. TLS certificates ----------
mkdir -p certs
case "$TLS_MODE" in
  selfsigned)
    # mkcert is REQUIRED for selfsigned: it installs a local CA so browsers
    # trust the certs. A plain openssl self-signed cert is untrusted and breaks
    # cross-origin XHR/WebSocket (auth/hasura), so we do not fall back to it.
    command -v mkcert >/dev/null 2>&1 || die "TLS mode 'selfsigned' requires mkcert.
    Install it (macOS: 'brew install mkcert'  •  Linux: apt/dnf install mkcert or
    https://github.com/FiloSottile/mkcert) and re-run, or choose another TLS mode
    (SETUP_TLS_MODE=letsencrypt|provided)."
    info "Generating a locally-trusted certificate with mkcert for *.${BASE_DOMAIN} ..."
    mkcert -install || warn "mkcert -install failed; the CA may not be trusted yet (run 'mkcert -install' manually)."
    mkcert -cert-file certs/fullchain.pem -key-file certs/privkey.pem \
      "*.${BASE_DOMAIN}" "${BASE_DOMAIN}"
    chmod 600 certs/privkey.pem
    info "mkcert CA installed — browsers trust these certs automatically (restart the browser)."
    ;;
  letsencrypt)
    if command -v certbot >/dev/null 2>&1; then
      local_d=(); for d in "${SUBDOMAINS[@]}"; do local_d+=(-d "${d}.${BASE_DOMAIN}"); done
      info "Requesting Let's Encrypt certs (standalone, needs public DNS + free port 80)..."
      certbot certonly --standalone "${local_d[@]}" --agree-tos -m "$ADMIN_EMAIL" -n
      cp "/etc/letsencrypt/live/dino.${BASE_DOMAIN}/fullchain.pem" certs/fullchain.pem
      cp "/etc/letsencrypt/live/dino.${BASE_DOMAIN}/privkey.pem"   certs/privkey.pem
    else
      warn "certbot not installed. Obtain certs manually, e.g.:"
      printf '    certbot certonly --standalone'; for d in "${SUBDOMAINS[@]}"; do printf ' -d %s.%s' "$d" "$BASE_DOMAIN"; done; echo
      warn "Then copy fullchain.pem + privkey.pem into ./certs/ and re-run with SETUP_TLS_MODE=provided."
    fi
    ;;
  provided)
    [ -f certs/fullchain.pem ] && [ -f certs/privkey.pem ] \
      || die "TLS mode 'provided' but certs/fullchain.pem or certs/privkey.pem is missing."
    info "Using provided certificates in ./certs/"
    ;;
esac

# ---------- 7. resolve heavy assets ----------
# The Dino SPA ships as the devgnucoop/dinoapp image and init.sql ships with the
# installer (versioned in this repo). nhost_apps (Hasura metadata/migrations/
# emails) is always fetched into a REAL folder via git — never symlinked from a
# sibling checkout — so the deployment is fully self-contained.
if [ -L nhost_apps ]; then
  warn "Removing stale nhost_apps symlink (a real git clone is used instead)."
  rm -f nhost_apps
fi
if [ -d nhost_apps/.git ]; then
  info "Updating nhost_apps (branch $NHOST_APPS_BRANCH)..."
  if git -C nhost_apps fetch --depth 1 origin "$NHOST_APPS_BRANCH" 2>/dev/null; then
    git -C nhost_apps checkout -B "$NHOST_APPS_BRANCH" FETCH_HEAD 2>/dev/null \
      || warn "Could not switch nhost_apps to $NHOST_APPS_BRANCH; keeping current checkout."
  else
    warn "git fetch failed; keeping existing nhost_apps."
  fi
else
  [ -e nhost_apps ] && rm -rf nhost_apps
  info "Cloning nhost_apps ($NHOST_APPS_BRANCH) from $NHOST_APPS_REPO ..."
  git clone --depth 1 --branch "$NHOST_APPS_BRANCH" "$NHOST_APPS_REPO" nhost_apps \
    || die "Failed to clone nhost_apps ($NHOST_APPS_BRANCH) from $NHOST_APPS_REPO.
    The stack needs it (Hasura migrations/metadata/emails). Check the branch name,
    configure git access (SSH key or HTTPS credentials), or set
    SETUP_NHOST_APPS_REPO / SETUP_NHOST_APPS_BRANCH, then re-run ./setup.sh."
fi

# init.sql (DB seed) and postinstall.sql (initial data) ship in the installer
# folder. Copy them into a separate target.
copy_bundled() {  # copy_bundled <name> <warn-msg>
  local n="$1"
  if [ -e "$n" ]; then info "$n already present."
  elif [ -f "$SCRIPT_DIR/$n" ]; then cp "$SCRIPT_DIR/$n" "$n"; info "Copied $n from installer."
  else warn "Missing $n in $SCRIPT_DIR — $2"; fi
}
copy_bundled init.sql        "the database will not be seeded on first boot."
copy_bundled postinstall.sql "initial data (roles / admin user) will not be created."
mkdir -p data minio/storage

# ---------- 8. /etc/hosts helper (local) ----------
if [ "$TLS_MODE" = "selfsigned" ]; then
  echo
  info "For local access, these names must resolve to your machine. Add to /etc/hosts:"
  for d in "${SUBDOMAINS[@]}"; do printf '    127.0.0.1  %s.%s\n' "$d" "$BASE_DOMAIN"; done
  if [ "$NONINTERACTIVE" != "1" ]; then
    read -r -p "Append these entries to /etc/hosts now (needs sudo)? [y/N]: " ans
    if [[ "${ans:-N}" =~ ^[Yy]$ ]]; then
      { for d in "${SUBDOMAINS[@]}"; do printf '127.0.0.1  %s.%s\n' "$d" "$BASE_DOMAIN"; done; } \
        | sudo tee -a /etc/hosts >/dev/null && info "Added to /etc/hosts."
    fi
  fi
fi

# ---------- 9. summary ----------
echo
info "${c_bold}Setup complete.${c_rst}"
cat <<EOF

  Admin email : ${ADMIN_EMAIL}
  Admin secret: ${ADMIN_PASSWORD}
  Base domain : ${BASE_DOMAIN}

  On first boot the stack seeds a web login user (postinstall.sql):
    login    ${ADMIN_EMAIL}  /  ${ADMIN_PASSWORD}
    name     ${USER_DISPLAY_NAME}

  URLs:
    App      https://dino.${BASE_DOMAIN}
    Hasura   https://hasura.${BASE_DOMAIN}/console
    Auth     https://auth.${BASE_DOMAIN}/v1
    Storage  https://storage.${BASE_DOMAIN}
    MinIO    https://minio-console.${BASE_DOMAIN}

  Next:  cd ${TARGET_DIR} && ${COMPOSE} up -d

EOF
