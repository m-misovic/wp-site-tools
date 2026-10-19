#!/usr/bin/env bash
# Deploy the site's own plugins and must-use plugins to one WordPress install.
#
# .github/workflows/deploy.yml runs this on a push: `staging` goes to the staging site,
# `main` to production. The plugins are the ones Git tracks (tools/package.php --list).
# Each is built and filtered by tools/package.php, so a deploy ships exactly what a
# release ZIP would hold, and a plugin's own checks gate it. rsync then mirrors each
# plugin folder: only changed files travel, files removed from the plugin are removed on
# the server, and nothing outside those folders is touched.
# Only plugins already installed on the server are updated: a new plugin is installed
# once by hand from its ZIP, so a plugin kept local-only never appears on the server.
# Themes are left out by owner decision: they rarely change and go up by hand as a ZIP.
# Before rsync, WordPress must load on the server, and a site's own hosting/deploy-check.php
# (optional) can hold the deploy back while the site is busy.
#
# Usage: tools/deploy.sh <wordpress-root> [--dry-run]
# Env:   DEPLOY_SSH   user@host of the server; empty means a local path (for testing)
#        DEPLOY_PORT  SSH port (default 22; Hostinger uses 65002)
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
target=${1:?Usage: tools/deploy.sh <wordpress-root> [--dry-run]}
dry_run=${2:-}
port=${DEPLOY_PORT:-22}
q_target=$(printf '%q' "$target")
# A server that does not answer gives up after 20 s instead of ssh's default of minutes,
# and a connection that goes quiet mid-deploy is dropped rather than left hanging.
ssh_options=(-o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# Runs a shell command on the server, or locally when DEPLOY_SSH is empty.
remote() {
    if [ -n "${DEPLOY_SSH:-}" ]; then
        ssh -p "$port" "${ssh_options[@]}" "$DEPLOY_SSH" "$1"
    else
        bash -c "$1"
    fi
}

# ssh exits with 255 when the connection itself fails, which is not the command failing.
lost_connection() {
    if [ "$1" -eq 255 ]; then
        fail "The SSH connection to the server failed; nothing was deployed. Re-run this deploy."
    fi
}

# The server's SSH sometimes does not answer for a moment (seen 2026-10-13), so the first
# connection is tried three times, 15 s apart, before the deploy gives up.
connect() {
    local attempt status
    for attempt in 1 2 3; do
        status=0
        remote true || status=$?
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        if [ "$status" -ne 255 ]; then
            fail "SSH to the server failed (exit $status); nothing was deployed."
        fi
        echo "NOTE: no SSH connection to the server (attempt $attempt of 3)." >&2
        if [ "$attempt" -lt 3 ]; then
            sleep 15
        fi
    done
    fail "Cannot connect to the server over SSH; nothing was deployed. Re-run this deploy later."
}

if [ -n "${DEPLOY_SSH:-}" ]; then
    connect
fi

status=0
remote "test -f $q_target/wp-config.php" || status=$?
if [ "$status" -ne 0 ]; then
    lost_connection "$status"
    fail "$target is not a WordPress root (no wp-config.php)."
fi
installed=$(remote "ls -1 $q_target/wp-content/plugins") || fail "Cannot list the plugins on the server."

# Build and filter every installed plugin through the release tool, then unpack the ZIPs.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
plugins=$(php "$root_dir/tools/package.php" --list | sed -n 's/^plugin //p')
[ -n "$plugins" ] || fail "Git tracks no plugins."
while read -r slug; do
    if ! printf '%s\n' "$installed" | grep -qxF "$slug"; then
        echo "NOTE: $slug is not installed on the server; skipped. Install it once by hand from its ZIP."
        continue
    fi
    echo "Packaging $slug..."
    if ! output=$(php "$root_dir/tools/package.php" "$slug" 2>&1); then
        echo "$output" >&2
        fail "Packaging $slug failed; nothing was deployed."
    fi
    zip=$(printf '%s\n' "$output" | sed -n 's/^Built \(.*\.zip\) (.*/\1/p')
    case $zip in
        /*) ;;
        *) zip="$root_dir/$zip" ;;
    esac
    [ -f "$zip" ] || fail "No ZIP found for $slug."
    unzip -q "$zip" -d "$stage"
done <<< "$plugins"

# Before anything changes, WordPress must load on the server through WP-CLI. A site whose
# plugins must not be replaced at some moments (an import mid-run, say) keeps its own check
# in hosting/deploy-check.php: PHP that runs there through WP-CLI and prints "idle" when the
# deploy may go ahead. Without that file the check only proves that WordPress loads.
check_file="$root_dir/hosting/deploy-check.php"
if [ -f "$check_file" ]; then
    check_name=hosting/deploy-check.php
    check_php=$(cat "$check_file")
else
    check_name="WordPress loads"
    check_php="<?php echo 'idle';"
fi
state=$(printf '%s\n' "$check_php" | remote "cd $q_target && wp eval-file - 2>&1" || true)
if [ "$(printf '%s\n' "$state" | tail -n 1)" != idle ]; then
    printf '%s\n' "$state" >&2
    fail "The pre-deploy check ($check_name) did not report idle: the site is busy, or the check could not run. Nothing was deployed; re-run this deploy later."
fi
echo "Pre-deploy check ($check_name): idle."

options=(-rlc --delete --delay-updates --itemize-changes)
if [ "$dry_run" = --dry-run ]; then
    options+=(--dry-run)
    echo "DRY RUN: listing changes only."
fi
if [ -n "${DEPLOY_SSH:-}" ]; then
    options+=(-e "ssh -p $port ${ssh_options[*]}")
    destination_prefix="$DEPLOY_SSH:"
else
    destination_prefix=""
fi

# Must-use plugins Git tracks go to every site, production included: each decides for
# itself where it acts, as the staging guard does. Other files in mu-plugins are left alone.
mu_plugins=$(git -C "$root_dir" ls-files -- 'wp-content/mu-plugins/*.php' | grep -v '/index\.php$' || true)
if [ -n "$mu_plugins" ]; then
    echo "== mu-plugins"
    [ "$dry_run" = --dry-run ] || remote "mkdir -p $q_target/wp-content/mu-plugins"
    while read -r file; do
        rsync "${options[@]}" "$root_dir/$file" "$destination_prefix$target/wp-content/mu-plugins/"
    done <<< "$mu_plugins"
fi

for plugin in "$stage"/*; do
    [ -d "$plugin" ] || continue
    slug=$(basename "$plugin")
    echo "== $slug"
    rsync "${options[@]}" "$plugin/" "$destination_prefix$target/wp-content/plugins/$slug/"
done

if [ "$dry_run" != --dry-run ]; then
    echo "Deployed to $target."
fi
