# {{SITE_TITLE}}: agent guide

Single source of truth for every coding agent (Claude Code, Codex, …): `CLAUDE.md` here is a symlink to this file, and `CLAUDE.md` in the Local site folder (two levels up) only points here. {{LANGUAGE_RULE: e.g. "Code comments and project docs are in English. Storefront strings are in the site's language (its locale, e.g. de_DE). Conversation follows the user."}}

## Every session
1. Read [docs/STATUS.md](docs/STATUS.md) first: what is done, what is next, open questions.
2. When something is finished, started or newly asked, update docs/STATUS.md: move it to "Done", add new items under "Next", and add a one-line "Log" entry (date and what).
3. Durable facts and decisions (stack, architecture, why something is the way it is) go in this file, not in STATUS.

## Product
{{PRODUCT: one paragraph: what the site is, for whom, what it sells or shows, the storefront language}}

## Repository
- The Git root is `app/public` (this directory). Remote: `github.com/{{GITHUB_REPO}}` (private), with branches `main` (production) and `staging` ({{STAGING_HOST}}); **a push to either deploys** (see Release). Work on `staging`, check {{STAGING_HOST}}, then bring `main` up to it with `git push origin staging:main`. No destructive Git operations, force pushes included, and keep the owner's uncommitted changes intact. **Commit messages carry no `Co-Authored-By` line.**
- `.gitignore` is a whitelist (ignore everything, then `!` exceptions): the site's own plugins and theme, `staging-guard.php`, `tools` (with `!/tools` without the slash, because it is a submodule), `.gitmodules`, `hosting/`, `docs/`, `.github/` and a short list of root files. A new root file or folder needs its own `!` line; never remove existing lines.
- `wp-config.php` is not tracked: each environment keeps its own. Never add it.
- Not tracked: WordPress core, `wp-content/uploads`, third-party plugins, every `build/` folder, `node_modules`, `dist/`, databases and dumps.
- **`tools/` is a Git submodule of the public repository [`m-misovic/wp-site-tools`](https://github.com/m-misovic/wp-site-tools)**, shared by all the owner's sites: `package.php`, `deploy.sh`, `pull-db.sh` and the workflow template. This site's values live only in `hosting/site.conf`; never put anything site-specific in the public repository. To change the tools: commit and push in wp-site-tools (or in `tools/` after `git -C tools switch main`), then in every site run `git submodule update --remote tools` (plus `cp tools/workflows/deploy.yml .github/workflows/deploy.yml` when the template changed), commit, and push to `staging` with `[dry run]`. An improvement that applies to every site (staging guard, docs structure, deploy) also goes into wp-site-tools' `templates/` and `skill/`. A fresh clone or `git worktree` needs `git submodule update --init`.

## Environments
- **Local**: Local by Flywheel, site `{{LOCAL_HOST}}` (PHP {{PHP_VERSION}}, MySQL 8.0, nginx), `~/Local Sites/{{SITE}}/app/public`. [README.md](README.md) sets up a local clone of production. `tools/pull-db.sh` replaces the local database with production's (the owner runs it: it needs the owner's SSH key, alias `{{SSH_ALIAS}}`). Run any manual local `wp db export`/`import` with `--default-character-set=utf8mb4`: Local's `wp-config.php` has `DB_CHARSET` `utf8`, and WP-CLI would turn emoji into `?`. Images missing locally come from production through the uploads proxy, so **a local page can show images that do not exist locally**; judge media by the filesystem.
- **Staging**: `{{STAGING_HOST}}`, a Hostinger staging copy in `public_html/dev` of the production account, with its own database. Hostinger's staging tool replaces the production domain with the staging one in every file it copies.
- **Production**: `{{PROD_HOST}}`, Hostinger shared hosting (LiteSpeed){{CDN_NOTE: e.g. " behind Cloudflare, so SSH goes to the hPanel SSH IP, never to the domain"}}. Server settings outside WordPress: [hosting/README.md](hosting/README.md).
- **Staging guard** (`wp-content/mu-plugins/staging-guard.php`): on every host except production's it blocks e-mail (except where PHP's `sendmail_path` is Local's Mailpit), skips the production-only plugins without touching the database, sets noindex and marks wp-admin and the toolbar "STAGING COPY". Deploys ship it to production too, where it does nothing. Production-only plugins: {{PRODUCTION_ONLY_PLUGINS_LIST}}. A plugin that reports to production's accounts belongs on that list, and so does any SMTP plugin. Update `PRODUCTION_HOSTS` before production moves to another domain.
- **Never write the production domain in one piece in deployed code**: split it, as the guard does (`'{{DOMAIN_LABEL}}' . '.{{TLD}}'`).
- Always say which environment a result comes from. A local check is not a staging or production confirmation.

## Release
- **Push deploy**: `.github/workflows/deploy.yml` (a copy of `tools/workflows/deploy.yml`; the deploy stops when they differ) runs `tools/deploy.sh` on every push: `staging` → {{STAGING_HOST}}, `main` → {{PROD_HOST}} (server paths in `hosting/site.conf`). It packages every plugin Git tracks through `tools/package.php` and mirrors each one already installed on the server with rsync, deleting files that left the plugin and touching nothing else; a new plugin is installed once by hand from its ZIP. Tracked must-use plugins go to every site. The theme is not deployed: `php tools/package.php <theme>` and upload it by hand. Templates, settings and content live in the database and are never deployed.
- **Dry run** (lists changes only): `[dry run]` in the last commit message of a push, or GitHub → Actions → Deploy → "Run workflow" (dry run by default). Never write `[skip ci]` in a commit message by accident: it skips the workflow.
- Secrets (GitHub → Settings → Secrets): `DEPLOY_SSH`, `DEPLOY_PORT`, `DEPLOY_KEY` (its public half is `github-deploy` in hPanel → SSH Access), `DEPLOY_KNOWN_HOSTS`. The real production deploy is started by the owner.
- **Rollback**: `git revert` and a push (`staging` first, then `main`). Without GitHub: build the old version's ZIP (`php tools/package.php <slug>` on the old commit, in a `git worktree` after `git submodule update --init`) and upload it by hand (Plugins → Add New Plugin → Upload Plugin → "Replace current with uploaded"). Runtime code must never read what packages leave out (`src/`, `assets/js`, `assets/scss`).
- Browser and CDN caches key static files by `?ver=`, so a changed file must change its version: wp-scripts asset hashes, or file times for block styles. Bump `Version:` in the plugin header so wp-admin shows what is live.

## Code
- **The database, not the theme folder, holds the live templates.** Site Editor edits are stored as `wp_template` / `wp_template_part` / `wp_global_styles` posts and override the theme's files; a theme ZIP never changes an overridden template, and "Reset" in the Site Editor falls back to the (often older) file. Check the real state in the database (`wp post list --post_type=wp_template,wp_template_part`).
{{CODE_MAP: a table or list of the site's own plugins and theme: path → what it does; build steps (npm workspaces in package.json, `npm ci && npm run build`)}}

## Rules
- Never put credentials, API keys, customer data, databases or dumps in code, ZIPs, logs or the repository. Do not ask for secrets; the owner sets them.
{{SITE_RULES: owner decisions that keep mattering}}

## Context map
- [README.md](README.md): local clone of production (Local, plugins, code, build, database, images).
- [hosting/README.md](hosting/README.md): Hostinger, CDN and Local settings outside WordPress; [hosting/site.conf](hosting/site.conf): this site's values for `tools/`.
- [docs/STATUS.md](docs/STATUS.md): state, next steps, log.
- [tools/README.md](tools/README.md): the shared tools and what they work around.

## Maintenance
Update this file when a plugin is added or removed, an environment changes or a lasting decision is made. Keep it lean: plugin-level detail belongs in the plugin's own docs or a scoped `AGENTS.md` next to the code (with a `CLAUDE.md` symlink).
