#!/usr/bin/env bash
# Replace the local (Local by Flywheel) database with a copy of production's.
#
# Only the database travels: images come from the live site (an uploads proxy) or a files
# backup, and code comes from Git. Production is only read: the server runs mysqldump and
# nothing else. The site's own values (SSH alias, paths, domains) are in hosting/site.conf.
#
# Steps: back up the local database, pull a dump over SSH (or take --file), check it is
# a whole WordPress dump, make its MariaDB collations readable by Local's MySQL 8,
# import it, point home/siteurl at the local site before WordPress loads (so a staging
# guard that looks at home is active from the first request), then search-replace the
# remaining URLs. If the import fails, the local backup is restored. The newest three
# production dumps and three local backups are kept in ../../backups next to Local's
# app/ folder (outside Git: they hold production data such as users, customers and keys).
#
# Usage: tools/pull-db.sh [--file <dump.sql|dump.sql.gz>] [--yes]
#   --file  import this dump (hPanel database backup or phpMyAdmin export) instead of
#           pulling one over SSH
#   --yes   do not ask before replacing the local database
# Env:   PULL_DB_SSH  SSH host for production (default: SSH_ALIAS from hosting/site.conf)
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
config="$root_dir/hosting/site.conf"
[ -f "$config" ] || { echo "FAIL: $config is missing; start from tools/site.conf.example." >&2; exit 1; }
# shellcheck source=/dev/null
. "$config"
for key in PROD_HOST LOCAL_HOST SSH_ALIAS PROD_ROOT; do
    [ -n "${!key:-}" ] || { echo "FAIL: $key is not set in hosting/site.conf." >&2; exit 1; }
done
backup_dir=$(cd "$root_dir/../.." && pwd)/backups
ssh_host=${PULL_DB_SSH:-$SSH_ALIAS}
# Local writes DB_CHARSET 'utf8' (3-byte) into wp-config.php, and WP-CLI dumps and imports
# in DB_CHARSET: emoji and other 4-byte characters would turn into '?' (seen 2026-10-19).
# Every dump, import and restore here therefore names utf8mb4.
charset=--default-character-set=utf8mb4
local_url=https://$LOCAL_HOST
keep=3

file=
assume_yes=
while [ $# -gt 0 ]; do
    case "$1" in
        --file) file=${2:?--file needs a path}; shift 2 ;;
        --yes) assume_yes=1; shift ;;
        *) echo "Usage: tools/pull-db.sh [--file <dump.sql|dump.sql.gz>] [--yes]" >&2; exit 1 ;;
    esac
done
if [ -n "$file" ]; then
    [ -f "$file" ] || { echo "FAIL: $file does not exist." >&2; exit 1; }
    file=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
fi

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

step() {
    echo "==> $1"
}

# Outside Local's site shell, take the same environment from the shell Local generates
# for this site (PHP, MySQL client, WP-CLI and their config).
if ! command -v wp > /dev/null || ! command -v mysql > /dev/null; then
    entry=$(grep -l -F "cd \"$root_dir\"" "$HOME/Library/Application Support/Local/ssh-entry/"*.sh 2> /dev/null | head -n 1 || true)
    [ -n "$entry" ] || fail "Local's site shell for $root_dir was not found. Run this from Local's site shell."
    eval "$(grep '^export ' "$entry")"
fi
# WP-CLI 2.12 checks the SQL mode with --no-defaults, which skips Local's my.cnf; the
# client still honours this variable.
socket=$(sed -n 's/^socket *= *//p' "${MYSQL_HOME:-/nonexistent}/my.cnf" 2> /dev/null | head -n 1 || true)
if [ -n "$socket" ]; then
    export MYSQL_UNIX_PORT="$socket"
fi

cd "$root_dir"
[ "$(wp config get WP_ENVIRONMENT_TYPE 2> /dev/null || true)" = local ] \
    || fail "WP_ENVIRONMENT_TYPE in wp-config.php is not 'local'; this only runs on a local copy."
prefix=$(wp config get table_prefix)
wp db query "SELECT 1" > /dev/null 2>&1 || fail "Cannot reach the local database. Start the site in Local first."

mkdir -p "$backup_dir"
stamp=$(date +%Y-%m-%d-%H%M%S)
local_backup="$backup_dir/local-$stamp.sql.gz"
prepared="$backup_dir/.import-$stamp.sql"
trap 'rm -f "$prepared"' EXIT

# Runs on the server with the WordPress root as $1 and writes the gzipped dump to stdout.
# `wp db export` cannot run there: Hostinger's CLI PHP disables proc_open() (seen
# 2026-10-19). So mysqldump runs directly, with the credentials `wp config get` reads from
# the server's wp-config.php; they stay in that one command's environment and are never
# printed. bash reads this script from stdin, so every command gets /dev/null as stdin.
# --single-transaction reads a consistent snapshot without locking the live tables.
# (read, not $(cat <<…): macOS's bash 3.2 misparses the case patterns inside $(…).)
IFS= read -r -d '' remote_export << 'REMOTE' || true
set -euo pipefail
cd "$1"
cfg() { wp config get "$1" < /dev/null; }
host=$(cfg DB_HOST)
args=(--single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 --user="$(cfg DB_USER)")
case "$host" in
    *:/*) args+=(--host="${host%%:*}" --socket="${host#*:}") ;;
    *:*) args+=(--host="${host%%:*}" --port="${host##*:}") ;;
    *) args+=(--host="$host") ;;
esac
dump=$(command -v mysqldump || command -v mariadb-dump) || { echo "No mysqldump on the server." >&2; exit 1; }
MYSQL_PWD=$(cfg DB_PASSWORD) "$dump" "${args[@]}" "$(cfg DB_NAME)" < /dev/null | gzip -c
REMOTE

if [ -z "$file" ]; then
    file="$backup_dir/prod-$stamp.sql.gz"
    step "Exporting production's database over SSH ($ssh_host)"
    status=0
    ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$ssh_host" \
        bash -s -- "$(printf '%q' "$PROD_ROOT")" <<< "$remote_export" > "$file" || status=$?
    if [ "$status" -ne 0 ]; then
        rm -f "$file"
        if [ "$status" -eq 255 ]; then
            fail "No SSH connection to $ssh_host; the local database was not touched. See tools/README.md for the SSH setup."
        fi
        fail "The export on the server failed (exit $status); the local database was not touched."
    fi
    # A dump cut short still unpacks; mysqldump's closing line proves it is whole.
    gunzip -c "$file" | tail -n 1 | grep -q 'Dump completed' \
        || { rm -f "$file"; fail "The production dump is incomplete; the local database was not touched."; }
fi

read_dump() {
    case "$file" in
        *.gz) gunzip -c "$file" ;;
        *) cat "$file" ;;
    esac
}
case "$file" in
    *.gz) gzip -t "$file" 2> /dev/null || fail "$file is not a valid gzip file." ;;
esac
# grep -c reads to the end; grep -q would stop early and fail the pipe under pipefail.
options_tables=$(read_dump | grep -c -F "CREATE TABLE \`${prefix}options\`" || true)
[ "${options_tables:-0}" -ge 1 ] \
    || fail "$file has no ${prefix}options table: not a dump of this site, or another table prefix (set \$table_prefix in wp-config.php to the dump's)."
echo "Dump: $file ($(du -h "$file" | cut -f1))"

step "Backing up the local database to $local_backup"
wp db export - $charset | gzip -c > "$local_backup"

# Production runs MariaDB, Local MySQL 8.0. Newer MariaDB dumps start with a sandbox-mode
# line the MySQL client rejects, and MariaDB-only uca1400 collations become the ones the
# earlier imports used. LC_ALL=C keeps sed byte-safe on any content.
step "Preparing the dump for MySQL 8"
read_dump | LC_ALL=C sed -E \
    -e '1{/enable the sandbox mode/d;}' \
    -e 's/utf8mb4_uca1400_[a-z0-9_]+/utf8mb4_unicode_520_ci/g' \
    -e 's/utf8mb3_uca1400_[a-z0-9_]+/utf8mb3_general_ci/g' \
    > "$prepared"

db_name=$(wp config get DB_NAME)
if [ -z "$assume_yes" ]; then
    [ -t 0 ] || fail "Not a terminal; pass --yes to replace the local database."
    read -r -p "Replace the local database '$db_name' with this dump? [y/N] " answer
    case "$answer" in
        y|Y|yes) ;;
        *) echo "Cancelled; the local database was not touched."; exit 0 ;;
    esac
fi

# wp db reset recreates the database in DB_CHARSET; tables carry their own charset, but
# tables created later without one would inherit the 3-byte default.
reset_db() {
    wp db reset --yes > /dev/null
    wp db query "ALTER DATABASE \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci"
}

step "Importing"
reset_db
if ! wp db import "$prepared" $charset; then
    echo "Import failed; restoring the local backup." >&2
    reset_db
    gunzip -c "$local_backup" | wp db import - $charset \
        || fail "Restoring failed too. Restore by hand: gunzip -c '$local_backup' | wp db import - $charset"
    fail "Import failed; the local database was restored from $local_backup."
fi

# A staging guard that decides from home whether it runs on production would, until home
# is local, treat this copy as production (all plugins, real mail).
step "Pointing the site at $local_url"
wp db query "UPDATE ${prefix}options SET option_value = '$local_url' WHERE option_name IN ('home', 'siteurl')"
[ "$(wp option get home)" = "$local_url" ] || fail "home is not $local_url after the import."

# Matching on // covers http and https and leaves e-mail addresses at the production domain
# untouched; the second pass catches JSON-escaped URLs (block attributes, cached script data).
step "Replacing //$PROD_HOST with //$LOCAL_HOST"
wp search-replace "//$PROD_HOST" "//$LOCAL_HOST" --all-tables --skip-columns=guid --report-changed-only
wp search-replace "\\/\\/$PROD_HOST" "\\/\\/$LOCAL_HOST" --all-tables --skip-columns=guid --report-changed-only
wp cache flush

step "Pruning old dumps (keeping $keep of each)"
for pattern in 'prod-*.sql.gz' 'local-*.sql.gz'; do
    find "$backup_dir" -maxdepth 1 -name "$pattern" | sort -r | tail -n +$((keep + 1)) | while IFS= read -r old; do
        rm -f "$old"
        echo "removed $(basename "$old")"
    done
done

step "Done"
summary=${PULL_DB_SUMMARY:-"SELECT post_type, COUNT(*) AS published FROM {prefix}posts WHERE post_status = 'publish' GROUP BY post_type"}
wp db query "${summary//\{prefix\}/$prefix}"
echo "Local backup: $local_backup"
if [ -n "${PULL_DB_REMINDER:-}" ]; then
    echo "$PULL_DB_REMINDER"
fi
