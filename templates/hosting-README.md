# Hosting configuration

Server and Local settings that live outside WordPress. Each exists only on the server or in Local, so these notes and copies are the reference for restoring them. The host's daily backup covers the database and files, not this history.

## Hostinger
- **Account**: hPanel → {{PROD_HOST}}; plan {{PLAN}}, data centre {{REGION}}; PHP {{PHP_VERSION}} (change it only after a local test).
- **SSH** (hPanel → Advanced → SSH Access): `{{HOSTINGER_USER}}@{{SSH_IP}}`, port {{SSH_PORT}}.{{CDN_SSH_NOTE: e.g. " The site is behind Cloudflare, so SSH goes to this IP, never to the domain."}} Keys: `github-deploy` (the deploy key; its private half is only a GitHub secret) and each developer machine's own key.
- **Paths**: production `{{PROD_ROOT}}`, staging `{{STAGING_ROOT}}`.
- **`site.conf`**: this site's values for the shared tools in `tools/` (domains, the paths above, the SSH alias `tools/pull-db.sh` uses). The deploy workflow and `pull-db.sh` read it.
- **Background jobs** (when the site relies on Action Scheduler or WP-Cron): hPanel → Advanced → Cron Jobs, every minute, `/usr/bin/php {{PROD_ROOT}}/wp-cron.php >/dev/null 2>&1` (staging: the same with its path), and `background-tasks.htaccess` pasted at the very top of the site's `.htaccess`, above `# BEGIN LSCACHE` and `# BEGIN WordPress`. It sets LiteSpeed's `noabort` for the Action Scheduler async runner and for `wp-cron.php`, so LiteSpeed does not kill them mid-action.
- **Backups**: daily, kept about a week (hPanel → Backups; database and files can be restored separately).
- **`deploy-check.php`** (only when the site needs it): PHP that `tools/deploy.sh` runs on the server through WP-CLI before any change; the deploy goes ahead only when it prints `idle` (for example, not while an import is running). Without it, the deploy only checks that WordPress loads.
{{CDN_SECTION: optional "## Cloudflare" section: DNS records (proxied or not), what must not be touched}}

## Local (development)
`local/uploads-proxy.conf` makes nginx fetch any upload missing on disk from `https://{{PROD_HOST}}`, so a local clone shows every image without copying `uploads`. To set it up (again after reinstalling the site in Local):
1. Copy the file to `~/Local Sites/{{SITE}}/conf/nginx/uploads-proxy.conf`.
2. In `~/Local Sites/{{SITE}}/conf/nginx/site.conf.hbs`, add `include uploads-proxy.conf;` right after the `{{#unless site.multiSite}} … {{/unless}}` WordPress rules block, before `error_page 404`.
3. Restart the site in Local.

Because of this proxy, a local page can show images that do not exist locally. Judge media by the filesystem, never by the browser.
