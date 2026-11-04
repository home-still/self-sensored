#!/usr/bin/env bash
# Rotate JWT_SECRET and the Postgres password for user `ladvien` in one shot:
#   1. Generate new values.
#   2. Push them to Bitwarden (items self-sensored/jwt and self-sensored/db).
#   3. ALTER USER on host `four` over SSH.
#   4. Verify the new DB password by connecting with psql.
#   5. Rewrite api/.env via render-env.sh.
#   6. Restart the API container if docker compose is running it.
#
# Does NOT rotate self-sensored/ollama — that key comes from the Ollama dashboard
# and is edited in the vault manually.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER_SCRIPT="$REPO_ROOT/scripts/render-env.sh"

die() { echo "error: $*" >&2; exit 1; }

command -v bw       >/dev/null 2>&1 || die "bw CLI not installed"
command -v jq       >/dev/null 2>&1 || die "jq not installed (brew install jq)"
command -v openssl  >/dev/null 2>&1 || die "openssl not installed"
command -v ssh      >/dev/null 2>&1 || die "ssh not available"
[[ -n "${BW_SESSION:-}" ]] || die 'BW_SESSION not set. Run: export BW_SESSION="$(bw unlock --raw)"'

status="$(bw status | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
[[ "$status" == "unlocked" ]] || die "Bitwarden vault is ${status:-unreachable}"

SSH_HOST="${SSH_HOST:-four}"
DB_HOST="${DB_HOST:-192.168.1.104}"
DB_NAME="${DB_NAME:-self_sensored}"
DB_USER="${DB_USER:-ladvien}"

echo "==> Generating new secrets"
NEW_JWT="$(openssl rand -base64 48 | tr -d '\n')"
NEW_DB="$(openssl rand -base64 24 | tr -d '\n')"
[[ ${#NEW_JWT} -ge 32 ]] || die "generated JWT too short (${#NEW_JWT} < 32)"

# Back up the current DB password from the vault so we can roll back if ALTER USER fails.
OLD_DB="$(bw get password self-sensored/db 2>/dev/null || true)"

update_item() {
    local name="$1" new_password="$2"
    local id current updated
    id="$(bw get item "$name" | jq -r '.id')"
    [[ -n "$id" && "$id" != "null" ]] || die "vault item '$name' not found"
    current="$(bw get item "$id")"
    updated="$(printf '%s' "$current" | jq --arg pw "$new_password" '.login.password = $pw')"
    printf '%s' "$updated" | bw encode | bw edit item "$id" >/dev/null
}

echo "==> Updating Bitwarden: self-sensored/jwt"
update_item self-sensored/jwt "$NEW_JWT"

echo "==> Updating Bitwarden: self-sensored/db"
update_item self-sensored/db "$NEW_DB"

bw sync >/dev/null
echo "    vault synced"

rollback_vault() {
    echo "==> Rolling back Bitwarden self-sensored/db to previous password" >&2
    if [[ -n "$OLD_DB" ]]; then
        update_item self-sensored/db "$OLD_DB" || true
        bw sync >/dev/null || true
    else
        echo "    (no previous password captured — vault left at new value)" >&2
    fi
}

echo "==> ALTER USER on $SSH_HOST"
# Build the SQL locally with the password already embedded and Postgres-escaped,
# then pipe it to `psql` on the remote. `openssl rand -base64` never emits a
# single quote, but we double-up any just in case.
escaped_pw="${NEW_DB//\'/\'\'}"
alter_sql="ALTER USER $DB_USER WITH PASSWORD '$escaped_pw';"
if ! printf '%s\n' "$alter_sql" | ssh "$SSH_HOST" 'sudo -u postgres psql -v ON_ERROR_STOP=1'; then
    rollback_vault
    die "ALTER USER failed; vault rolled back"
fi

echo "==> Verifying new DB password"
if command -v psql >/dev/null 2>&1; then
    if ! PGPASSWORD="$NEW_DB" psql -h "$DB_HOST" -U "$DB_USER" -d "$DB_NAME" -c '\q' >/dev/null 2>&1; then
        rollback_vault
        die "psql verify failed with new password; vault rolled back. DB may still hold new password — re-run after investigation."
    fi
    echo "    psql connected successfully"
else
    echo "    psql not installed locally — skipping verify (install with: brew install libpq)"
fi

echo "==> Rendering api/.env"
"$RENDER_SCRIPT"

echo "==> Restarting API container if running"
if (cd "$REPO_ROOT" && docker compose ps --services --status running 2>/dev/null | grep -qx api); then
    (cd "$REPO_ROOT" && docker compose up -d --force-recreate api)
    echo "    api container restarted"
else
    echo "    api container not running — skipped"
fi

cat >&2 <<'DONE'

==> Rotation complete.

    Reminder: every existing iOS JWT is now invalid. On each phone:
      Settings -> sign out, then sign back in.
DONE
