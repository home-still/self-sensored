# Secrets workflow (Bitwarden)

**See [docs/secrets.md](../docs/secrets.md) for the full narrative —
first-time setup, renewal, recovery, troubleshooting.** This file is a
command-level quick reference.

> `scripts/review_mcp.sh` bundles the `self-sensored-mcp` crate + a review
> checklist into `reports/mcp_review_<ts>.md`, ready to paste into Claude
> Desktop for a design review. No secrets; no network calls.

`api/.env` is a derived artifact — never hand-edit it. Its values live in a
personal Bitwarden vault under three items:

| Vault item         | Holds                                       |
| ------------------ | ------------------------------------------- |
| `self-sensored/jwt`   | `JWT_SECRET` (auto-rotated)                 |
| `self-sensored/db`    | Postgres password for role `self_sensored` (auto) |
| `self-sensored/ollama`| `OLLAMA_API_KEY` (set once, never rotated)  |

Everything else in `api/.env` (DB host, DB name, URLs, log level, port) is
hardcoded in `scripts/render-env.sh`. To change one of those, edit the script.

## One-time setup

```bash
brew install bitwarden-cli jq libpq
bw login                                    # browser/email flow
```

In the Bitwarden web vault (or `bw create item`), add three Login items with
**exactly** those names. The `/` in the name is literal, not a folder — it's
part of the item title. Put placeholder passwords in `self-sensored/jwt` and
`self-sensored/db` (they'll be overwritten on first rotation). Put your real
Ollama API key in `self-sensored/ollama`.

## Daily use: unlock the vault once per terminal

```bash
export BW_SESSION="$(bw unlock --raw)"
```

This stays valid until the vault times out or you close the shell.

## Rotate `JWT_SECRET` + DB password

```bash
scripts/rotate-secrets.sh
```

What it does:
1. Generates a 48-byte base64 JWT and a 24-byte base64 DB password.
2. Writes both back to Bitwarden.
3. SSHes to `four` and runs `ALTER USER ladvien WITH PASSWORD ...`.
4. Verifies the new password via `psql`.
5. Rewrites `api/.env` by calling `render-env.sh`.
6. Restarts the running `docker compose` API container if one is up.

On any failure before step 3 succeeds, the vault is rolled back so it stays
consistent with the DB.

## Regenerate `api/.env` on a fresh machine

```bash
scripts/render-env.sh
```

Reads the three vault items, writes `api/.env` (mode 600). No secrets are
generated or mutated.

## Change the Ollama key

Edit the password field of `self-sensored/ollama` in the vault UI, then:

```bash
bw sync
scripts/render-env.sh
docker compose up -d --force-recreate api   # if running
```

## Troubleshooting

- **`BW_SESSION not set`** — you haven't unlocked the vault in this shell.
  Run the `export BW_SESSION=...` line above.
- **`Bitwarden vault is locked`** — session timed out. Unlock again.
- **`vault item 'self-sensored/xxx' not found`** — the item name is wrong or the
  item is in a collection you don't have access to. Double-check the name is
  literally `self-sensored/jwt` etc.
- **`ALTER USER failed`** — can't SSH to `four` or `sudo -u postgres` is not
  permitted for user `ladvien` on that host. Fix the SSH/sudo config and
  rerun; the vault will be rolled back automatically.
- **`psql verify failed`** — DB accepted the new password but we can't connect
  locally. This is rare (network blip) — the rotate script rolls the vault
  back; fix the network and rerun.
- **DB and vault out of sync** (e.g., rotation interrupted) — pick whichever
  is correct, copy its value into the other manually, then rerun.

## iOS client note

Every rotation invalidates all existing JWTs. Users have to sign out and back
in on each phone. The client handles this cleanly:
`APIClient.clearAuth()` deletes the stale Keychain token and the next login
writes a new one.
