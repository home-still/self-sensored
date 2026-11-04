# Secrets & Credentials

`api/.env` is a **derived artifact** — always regenerated from a Bitwarden
vault, never hand-edited. This guide covers two workflows:

1. **[First-time setup](#first-time-setup)** — what a new dev does on day one.
2. **[Renewing credentials](#renewing-credentials)** — rotating the JWT signing
   key and the Postgres password.

The mechanics live in `scripts/render-env.sh` and `scripts/rotate-secrets.sh`;
`scripts/README.md` has a terse command reference. This doc is the narrative
version.

---

## Source of truth

Three Login items in Bitwarden, named literally (the `/` is part of the title,
not a folder):

| Vault item         | Holds                                           | Rotation                         |
| ------------------ | ----------------------------------------------- | -------------------------------- |
| `self-sensored/jwt`   | `JWT_SECRET` (HS256 signing key, ≥32 bytes)     | Auto — `rotate-secrets.sh`       |
| `self-sensored/db`    | Postgres password for role `self_sensored` on `four`  | Auto — `rotate-secrets.sh`       |
| `self-sensored/ollama`| `OLLAMA_API_KEY` from ollama.com                | Manual — edit in the vault UI    |

Everything else in `api/.env` (DB host, DB name, DB user, URLs, log level,
ports) is hardcoded in `scripts/render-env.sh`. If you need to change one of
those values, edit the script.

`api/.env` is gitignored. The file on your disk has mode 600 so only your
macOS user can read it.

---

## First-time setup

### 1. Install prerequisites

```bash
brew install bitwarden-cli jq libpq
```

Optionally put `psql` on your PATH (recommended — lets the rotation script
verify the new DB password works before committing):

```bash
echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
psql --version
```

### 2. Log in to Bitwarden

```bash
bw login
```

Enter your Bitwarden email + master password. First login may ask for an OTP
sent to your email. You only do this once per machine.

### 3. Seed the three vault items

If the items **don't exist yet** in the shared Bitwarden vault (you're the
first dev on a brand-new deployment):

1. Open <https://vault.bitwarden.com> and sign in.
2. For each row in the [Source of truth](#source-of-truth) table, click
   **Add item → Login** and create it with the exact name shown. For
   `self-sensored/jwt` and `self-sensored/db`, the password can be any placeholder
   — the first rotation overwrites them. For `self-sensored/ollama`, paste the
   real API key from <https://ollama.com/settings/keys>.
3. Save each item.

If the items **already exist** (most common case — you're joining a team
that's already using this workflow): skip to step 4.

### 4. Unlock the vault in your shell

```bash
export BW_SESSION="$(bw unlock --raw)"
```

`BW_SESSION` stays valid for the lifetime of the shell (subject to the vault's
inactivity timeout — default 15 minutes). Re-run the command any time the
scripts complain that the vault is locked.

Verify:

```bash
bw status | jq -r .status      # prints: unlocked
bw list items --search self-sensored | jq -r '.[].name' | sort
# expected:
#   self-sensored/db
#   self-sensored/jwt
#   self-sensored/ollama
```

### 5. Render `api/.env`

From the repo root:

```bash
scripts/render-env.sh
```

This pulls the three passwords from Bitwarden and writes `api/.env`
(mode 600). No secrets are generated or mutated — it's a pure read.

If you're the first dev and the `jwt`/`db` items still hold placeholder
passwords, **stop here and go to
[Renewing credentials](#renewing-credentials) instead** — the placeholders
won't match the actual database, and the JWT placeholder probably doesn't
meet the 32-byte length requirement.

### 6. Boot the API

```bash
docker compose up -d --build
docker compose logs api | tail
curl -fsS http://localhost:3000/health && echo OK
```

Expected logs:

```
self_sensored_api: connected to database
self_sensored_api: listening on 0.0.0.0:3000
```

If `/health` returns `OK`, you're set.

> **Using podman instead of Docker Desktop?** You'll need
> `export DOCKER_HOST='unix:///var/folders/.../podman-machine-default-api.sock'`
> first. Add it to `~/.zshrc` so you don't have to think about it again.

---

## Renewing credentials

The rotation script does the whole flow in one shot. It:

1. Generates a new JWT secret (48 bytes base64) and a new Postgres password
   (24 bytes base64).
2. Writes both to Bitwarden (`self-sensored/jwt` and `self-sensored/db`).
3. SSHes to `four` and runs `ALTER USER ladvien WITH PASSWORD ...`.
4. Verifies the new DB password with `psql`.
5. Re-renders `api/.env` via `render-env.sh`.
6. Restarts the running `docker compose` API container if one is up.

Rotation never touches `self-sensored/ollama`.

### Prerequisites

- All of [First-time setup](#first-time-setup) done on this machine.
- SSH access to `four` works (`ssh four whoami` prints `ladvien`).
- `ladvien` on `four` can `sudo -u postgres psql` without a password prompt,
  OR you're OK being prompted once when the script SSHes in.
- Vault is unlocked: `export BW_SESSION="$(bw unlock --raw)"`.

### Run the rotation

```bash
scripts/rotate-secrets.sh
```

Expected output:

```
==> Generating new secrets
==> Updating Bitwarden: self-sensored/jwt
==> Updating Bitwarden: self-sensored/db
    vault synced
==> ALTER USER on four
ALTER ROLE
==> Verifying new DB password
    psql connected successfully
==> Rendering api/.env
Wrote .../api/.env (mode 600).
==> Restarting API container if running
    api container restarted    # or: api container not running — skipped
==> Rotation complete.
    Reminder: every existing iOS JWT is now invalid. On each phone:
      Settings -> sign out, then sign back in.
```

### After rotation

- Every existing iOS JWT is invalid. On each phone: Settings → sign out →
  sign in again. `APIClient.clearAuth()` deletes the stale Keychain token;
  login writes a new one.
- If the API container wasn't running, start it with
  `docker compose up -d --build` so it picks up the new `.env`.

### Safety net

If the `ALTER USER` step fails (network hiccup, sudo denial, psql syntax
error), the script **rolls the vault back** to the previous DB password so
the vault and the DB stay in sync. The rotation aborts and your existing
`api/.env` is untouched.

`self-sensored/ollama` is never written by the script, so Ollama access is
unaffected by a failed rotation.

---

## Changing the Ollama API key

This is a manual path because the key comes from Ollama's dashboard, not from
`openssl rand`.

1. Generate a new key at <https://ollama.com/settings/keys>.
2. In the Bitwarden web vault, open `self-sensored/ollama` and paste the new
   value into the **Password** field. Save.
3. Locally:

   ```bash
   bw sync
   scripts/render-env.sh
   docker compose up -d --force-recreate api   # if the API is running
   ```

---

## Fresh-machine render (no rotation)

You've cloned the repo on a new laptop and just want a working `api/.env`
populated from the existing vault:

```bash
export BW_SESSION="$(bw unlock --raw)"
scripts/render-env.sh
```

No secrets are generated or mutated. `api/.env` lands with mode 600.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `BW_SESSION not set` | Vault not unlocked in this shell | `export BW_SESSION="$(bw unlock --raw)"` |
| `Bitwarden vault is locked` | Session timed out | Same as above |
| `vault item 'self-sensored/xxx' not found` | Item name typo, or item lives in a collection you lack access to | Verify with `bw list items --search self-sensored` — names must match exactly |
| `JWT_SECRET must be at least 32 bytes` on API boot | Placeholder in vault is too short | Run `scripts/rotate-secrets.sh` to replace it with a 48-byte value |
| `psql: password authentication failed` during rotation | Vault and DB are out of sync (a previous rotation was interrupted) | See [Recovering from desync](#recovering-from-desync) |
| `ALTER USER failed` | Can't SSH to `four`, or `sudo -u postgres` isn't allowed noninteractively | Fix SSH/sudo config on `four`; vault rolls back automatically |
| `Cannot connect to the Docker daemon` on macOS | Podman machine not running | `podman machine start` and set `DOCKER_HOST` |

### Recovering from desync

If an interrupted rotation leaves the vault holding a new password while the
DB still has the old one (or vice versa), pick whichever side you're sure of
and force the other to match:

- **DB is correct, vault is wrong** — the previous real DB password is gone
  for good, but you can rotate fresh:
  ```bash
  scripts/rotate-secrets.sh
  ```
  It doesn't need the current password (uses `sudo -u postgres`), so it'll
  set a new one and write it to the vault.
- **Vault is correct, DB is wrong** — SSH to `four` and manually run
  ```bash
  NEW_DB=$(bw get password self-sensored/db)
  ssh four "sudo -u postgres psql -c \"ALTER USER ladvien WITH PASSWORD '\$NEW_DB';\""
  ```
  Then re-render: `scripts/render-env.sh`.

---

## Why Bitwarden and not Secrets Manager / env-only?

- **Why not commit `.env`?** Obvious: secrets in git.
- **Why not keep `.env` hand-edited and uncommitted?** Every new laptop has
  to manually copy secrets around; rotation is tedious; easy to leak in
  backups. Bitwarden keeps a single source of truth, access-controlled,
  backed up, audit-logged.
- **Why not Bitwarden Secrets Manager (`bws`)?** Nicer workflow — secrets
  inject directly into commands without touching disk — but a separate paid
  SKU. We may switch later; today the CLI vault approach works with the
  personal license we already have.
- **Why a hardcoded DB host/port/user in the render script?** Those aren't
  secrets. Keeping them out of the vault means `render-env.sh` is the one
  place to update when you move Postgres to a new host.
