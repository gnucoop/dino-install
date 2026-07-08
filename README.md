# Dino installer

A slim, one-command setup for the Dino backend stack. Instead of hand-editing
`.env`, `nginx.conf` and TLS certs (and keeping their domains in sync), you run
`setup.sh` once: it asks for a single **base domain**, auto-generates every
secret, and renders a consistent configuration ready for `docker compose up -d`.

## Stack

Services: **nginx** (TLS termination + reverse proxy), **dinoapp** (the Dino SPA,
served from the `devgnucoop/dinoapp` image), **PostgreSQL** (pgvector),
**Hasura GraphQL**, **nhost Auth**, **MinIO** (S3-compatible storage) and
**nhost Storage**. Two short-lived helpers run on first boot: `createbucket`
(creates the default MinIO bucket) and `postinstall` (seeds initial data once the
schema exists — see below).

### First-boot seed (`postinstall.sql`)

After Hasura and Auth have applied their migrations, the `postinstall` service
seeds initial data **once** (idempotent — it only runs when the tables are empty):

- the four roles: `admin`, `supervisor`, `collector`, `guest`
- an `Admin` user group (full permissions)
- a **web login user** in `auth.users` whose email/password are the
  `ADMIN_EMAIL` / `ADMIN_PASSWORD` from setup, display name `USER_DISPLAY_NAME`
- that user's `admin` + `user` role mapping and a linked `user_data` row
- an anonymous `user_data` row

So after `docker compose up -d` you can log into the SPA at `https://dino.<domain>`
with the admin email + password shown at the end of `setup.sh`.

> Pandino (AI backend), the chatbot proxy and the welcome site are intentionally
> excluded from this slim kit.

## Prerequisites

- Docker + Docker Compose (`setup.sh` checks these, plus `openssl`, `git`,
  `bash`, `sed`, and that the Docker daemon is running — before doing anything).
- **git access to the `nhost_apps` repo** (Hasura metadata/migrations/emails).
  `setup.sh` always clones it into a real `nhost_apps/` folder — the installer
  never depends on any file outside itself. Override the source with
  `SETUP_NHOST_APPS_REPO=<url>` if needed.
- Everything else is self-contained: the SPA ships as the `devgnucoop/dinoapp`
  image, and `init.sql` (DB seed) + `postinstall.sql` (first-boot data) ship
  committed inside this folder.

## Usage

```bash
./setup.sh                 # generate in place
./setup.sh ../my-dino      # generate a ready-to-run deployment in ../my-dino
docker compose up -d       # (run from the folder setup.sh wrote to)
```

`setup.sh [TARGET_DIR]` writes `.env`, `nginx.conf`, TLS `certs/`, a copy of
`docker-compose.yml`, copies `init.sql` + `postinstall.sql`, and clones
`nhost_apps/` into `TARGET_DIR` (default: this folder). This lets you keep the
installer as read-only source and
materialize each deployment into its own directory.

You'll be asked for a base domain (e.g. `local.dinoapp.cloud` or
`dino.example.com`), an admin email/password (blank = auto-generated), and a
TLS mode. All service hostnames are derived from the base domain:

| Service      | Hostname                          |
|--------------|-----------------------------------|
| App (SPA)    | `dino.<BASE_DOMAIN>`              |
| Auth         | `auth.<BASE_DOMAIN>`             |
| Hasura       | `hasura.<BASE_DOMAIN>`          |
| Storage      | `storage.<BASE_DOMAIN>`        |
| MinIO API    | `minio.<BASE_DOMAIN>`          |
| MinIO console| `minio-console.<BASE_DOMAIN>` |

### TLS modes

- **selfsigned** — generates a self-signed wildcard cert (browsers warn; fine
  for local evaluation). The script prints the `/etc/hosts` lines you need and
  can append them for you.
- **letsencrypt** — runs `certbot` if installed (needs public DNS + port 80),
  otherwise prints the exact command.
- **provided** — bring your own `certs/fullchain.pem` + `certs/privkey.pem`.

### Unattended / cloud install

Every prompt has a `SETUP_<NAME>` override; set `SETUP_NONINTERACTIVE=1` to skip
prompting entirely:

```bash
SETUP_NONINTERACTIVE=1 \
SETUP_BASE_DOMAIN=dino.example.com \
SETUP_ADMIN_EMAIL=admin@example.com \
SETUP_TLS_MODE=letsencrypt \
./setup.sh
```

## What gets generated

`.env`, `nginx.conf`, `certs/` and a cloned `nhost_apps/` — all git-ignored.
Re-running `setup.sh` backs up any existing `.env` to `.env.backup`.
