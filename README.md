# ⚡ The 30-Second Dino Installer

A slim, one-command setup for the Dino backend stack. Instead of hand-editing
`.env`, `nginx.conf` and TLS certs (and keeping their domains in sync), you run
`setup.sh` once: it asks for a single **base domain**, auto-generates every
secret, and renders a consistent configuration ready for `docker compose up -d`.

## Quick start

```bash
# 1. Clone
git clone git@github.com:gnucoop/dino-install.git
cd dino-install

# 2. Generate a deployment into a folder of your choice, and answer the prompts
./setup.sh my-dino

# 3. Start the stack
cd my-dino
docker compose up -d          # or: docker-compose up -d

# 4. Open the app in your browser at the Dino URL
#    https://dino.<BASE_DOMAIN>
#    (the exact URL + admin email/password are printed at the end of setup.sh)
```

> See [Requirements](#requirements) first. For `selfsigned` TLS you need
> **mkcert**, and the subdomains must resolve (`setup.sh` offers to add the
> `/etc/hosts` entries for you).

## Stack

Services: **nginx** (TLS termination + reverse proxy), **dinoapp** (the Dino SPA,
served from the `devgnucoop/dinoapp` image), **PostgreSQL** (pgvector),
**Hasura GraphQL**, **nhost Auth**, **MinIO** (S3-compatible storage) and
**nhost Storage**. Two short-lived helpers run on first boot: `createbucket`
(creates the default MinIO bucket) and `postinstall` (seeds initial data once the
schema exists — see below).

```mermaid
flowchart TB
    U(["👤 Browser"])

    subgraph PROXY["Edge"]
        N["🔒 nginx<br>TLS + reverse proxy<br>:80 / :443"]
    end

    subgraph APP["Application"]
        D["dinoapp · SPA<br>devgnucoop/dinoapp<br>:8090"]
        G["Hasura GraphQL<br>nhost/graphql-engine<br>:9000"]
        A["Auth<br>nhost/auth<br>:9001 · /v1"]
        S["Storage<br>nhost/storage<br>:9002"]
        M["MinIO · S3<br>:9006 API / :32765 console"]
    end

    subgraph DATA["Data"]
        P[("PostgreSQL<br>+ pgvector")]
    end

    subgraph BOOT["First-boot one-shots"]
        CB["createbucket<br>minio/mc"]
        PI["postinstall<br>psql · postinstall.sql"]
    end

    NA[["nhost_apps<br>metadata · migrations · emails"]]
    IS[["init.sql · DB seed"]]

    U -->|"HTTPS · *.BASE_DOMAIN"| N
    N -->|"dino."| D
    N -->|"hasura."| G
    N -->|"auth."| A
    N -->|"storage."| S
    N -->|"minio. / minio-console."| M

    G --> P
    A --> P
    A -.-> G
    S --> P
    S -.-> G
    S -->|"S3"| M

    NA -. "mount" .-> G
    IS -. "mount" .-> P
    CB -->|"creates default bucket"| M
    PI -->|"seeds roles + admin user"| P
```

**Request flow:** the browser hits `https://<service>.<BASE_DOMAIN>`; nginx
terminates TLS and reverse-proxies each subdomain to the right service. Hasura,
Auth and Storage all talk to Postgres; Storage keeps objects in MinIO; Hasura
applies the `nhost_apps` migrations/metadata; Postgres is seeded from `init.sql`.
On first boot `createbucket` creates the default bucket and `postinstall` seeds
the roles + admin login, then both exit.

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

## Requirements

### Software (required)

`setup.sh` checks all of these up front and aborts with a clear message if any
are missing:

| Tool | Purpose |
|------|---------|
| **Docker** (daemon running) | runs the stack |
| **Docker Compose** | `docker compose` plugin *or* legacy `docker-compose` |
| **openssl** | generates secrets and self-signed certificates |
| **git** | clones `nhost_apps` |
| **bash** (3.2+) / **sed** | run and render the installer |

### Software (TLS-mode dependent)

| Tool | When | Purpose |
|------|------|---------|
| **mkcert** | **required** for `selfsigned` | installs a local CA so browsers trust the certs. `setup.sh` **aborts** in `selfsigned` mode if it is missing — a plain openssl self-signed cert is untrusted and breaks cross-origin auth/GraphQL/WebSocket, so there is no fallback. |
| **certbot** | recommended for `letsencrypt` | auto-issues **Let's Encrypt** certs. If absent, the script prints the exact command to run. |

### Access & network

- **git access to the `nhost_apps` repo** (Hasura metadata / migrations / emails).
  `setup.sh` clones it into a real `nhost_apps/` folder — the installer never
  depends on any file outside itself. Default is SSH
  (`git@github.com:gnucoop/nhost_apps.git`, branch `prod-1.21.0-permissions-m2`);
  override with `SETUP_NHOST_APPS_REPO` / `SETUP_NHOST_APPS_BRANCH`.
- **Free host ports:** `80`, `443` (nginx), `5432` (postgres), `8090` (SPA),
  `9000`/`9001`/`9002` (hasura/auth/storage), `9006`/`32765` (MinIO API/console).
- **Name resolution** for the six subdomains (see the table below):
  - local install → `setup.sh` prints the `/etc/hosts` lines and can append them;
  - public install → real DNS A/AAAA records pointing at the host.

### Backend image

- The SPA ships as the **`devgnucoop/dinoapp`** image (no Node/Angular build
  needed here). If you build your own image, its `environment.ts` **must** define
  `dataConfig.socketJwtExpiredCode` (e.g. `4403`) — otherwise the app hangs on
  "Initializing data…". Set `DINOAPP_VERSION` in `.env` to pick the tag.

### Bundled (nothing to fetch)

`init.sql` (DB seed) and `postinstall.sql` (first-boot data) ship committed in
this folder and are copied into each deployment automatically.

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

- **selfsigned** — generates a locally-trusted wildcard cert via **mkcert**
  (required; no browser warnings). The script prints the `/etc/hosts` lines you
  need and can append them for you.
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
