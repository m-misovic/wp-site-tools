# wp-site-tools

Release and local-copy tools shared by WordPress sites built the same way:

- the Git repository root is the WordPress root, and Git tracks only the site's own plugins, themes and must-use plugins;
- production and staging run on Hostinger shared hosting; a push to `main` / `staging` deploys through GitHub Actions;
- the local copy runs in [Local](https://localwp.com).

Each site repository includes this repository as a Git submodule at `tools/`, so every site runs the same code. Nothing site-specific lives here: the site's values are in its own `hosting/site.conf`.

| File | What it does |
|---|---|
| `package.php` | `php tools/package.php <slug>` builds the release ZIP of one tracked plugin or theme from committed code (runs `npm run build` when the package has one). No arguments lists the packages; `--list` prints them for scripts; `--allow-dirty` builds a `-dirty` trial ZIP. |
| `deploy.sh` | Run by the workflow: packages every tracked plugin that is already installed on the server and mirrors it there with rsync over SSH, plus the tracked must-use plugins. Before any change WordPress must load on the server, and the site's optional `hosting/deploy-check.php` (PHP run there through WP-CLI) must print `idle`, so a site can hold a deploy back while it is busy. `--dry-run` only lists changes. |
| `workflows/deploy.yml` | The GitHub Actions workflow. Each site keeps a byte-identical copy in `.github/workflows/deploy.yml`; the deploy stops when they differ. |
| `pull-db.sh` | `tools/pull-db.sh` replaces the Local database with production's over SSH (or `--file <dump>`), backing up the local one first and restoring it if the import fails. |
| `site.conf.example` | Template for the site's `hosting/site.conf`. |
| `templates/` | Starting files for a site on this layout: `.gitignore` whitelist, staging guard, `AGENTS.md`, `README.md`, `docs/STATUS.md`, `hosting/README.md`, Local uploads proxy, LiteSpeed `noabort` block, root `package.json`, and the one-line `CLAUDE.md` for Local's site folder. Placeholders are `{{UPPER_CASE…}}`. |
| `skill/SKILL.md` | The `wp-site` agent skill: sets up a new site, or adopts an existing one, on this layout using the templates. |

This repository is public. Never commit site data, hostnames of private servers, credentials or dumps here.

## Set up a new site

Use the skill: link it once per machine, then ask the agent for a new site (or to bring an existing one onto this layout).

```sh
git clone https://github.com/m-misovic/wp-site-tools.git ~/"My Git/wp-site-tools"
ln -s ~/"My Git/wp-site-tools/skill" ~/.claude/skills/wp-site
```

It interviews first, shows a plan, and splits the work: the agent writes the files from `templates/`, the owner does everything in hPanel and GitHub settings (it gives the exact commands for the deploy key and secrets) and starts production deploys. By hand, follow the steps in `skill/SKILL.md`.

## Add the tools to a site

```sh
git submodule add https://github.com/m-misovic/wp-site-tools.git tools
cp tools/site.conf.example hosting/site.conf        # then fill in the site's values
mkdir -p .github/workflows && cp tools/workflows/deploy.yml .github/workflows/deploy.yml
```

- A whitelist `.gitignore` (ignore everything, then `!` exceptions) needs `!.gitmodules`, `!/hosting/` and `!/tools` without a trailing slash: Git sees a submodule as one entry, which `!/tools/` (folders only) does not match.
- GitHub secrets for the deploy: `DEPLOY_SSH` (`user@host`), `DEPLOY_PORT`, `DEPLOY_KEY` (a private key whose public half is in hPanel → SSH Access), `DEPLOY_KNOWN_HOSTS`.
- A plugin is deployed only once it is installed on the server: install a new plugin once by hand from its ZIP.

A fresh clone of a site needs `git submodule update --init` after checkout.

## Change the tools

1. Edit here, or inside any site's `tools/` checkout after `git -C tools switch main`. Commit and push to this repository.
2. In every site: `git submodule update --remote tools`, and when `workflows/deploy.yml` changed, `cp tools/workflows/deploy.yml .github/workflows/deploy.yml`. Commit, push to `staging` with `[dry run]` in the message, and check the run.

Each site pins the commit it was tested with, so a site moves to a new version only when it is updated, and `git revert` in the site also reverts its tools.

An improvement that applies to every site but lives in the site's own files (the staging guard, the docs structure) goes into `templates/` as well, so the next site starts from it. Existing sites take it over by hand.

## Pulling the production database

`pull-db.sh` reads production through the SSH alias named by `SSH_ALIAS`. One key per machine is enough for every site:

1. `ssh-keygen -t ed25519` if `~/.ssh/id_ed25519` does not exist; paste `~/.ssh/id_ed25519.pub` into hPanel → Advanced → SSH Access of each hosting account.
2. In `~/.ssh/config`, with the IP and port that hPanel shows under SSH Access (a site behind Cloudflare does not answer SSH on its own domain):
   ```
   Host example-prod
     HostName <SSH IP>
     Port 65002
     User <hPanel SSH user>
     IdentityFile ~/.ssh/id_ed25519
     IdentitiesOnly yes
     UseKeychain yes
     AddKeysToAgent yes
   ```
3. Check: `ssh example-prod 'cd <PROD_ROOT> && wp core version'`.

Run it from any terminal or Local's site shell while the site runs in Local. Dumps and backups (the newest three of each) go to `backups/` next to Local's `app/` folder.

## Things these tools work around

- **Hostinger's CLI PHP disables `proc_open()`**, so `wp db export` (and any WP-CLI command that runs `mysql`/`mysqldump`) fails on the server. `pull-db.sh` runs `mysqldump` directly with the credentials `wp config get` reads.
- **Local writes `DB_CHARSET` `utf8` (3 bytes) into `wp-config.php`.** WP-CLI dumps and imports in that charset unless told otherwise, turning emoji into `?`. Run any manual `wp db export`/`import` on a Local site with `--default-character-set=utf8mb4`.
- **Production is MariaDB, Local is MySQL 8.0.** Dumps get their `uca1400` collations and the "sandbox mode" first line rewritten before import.
- **macOS ships bash 3.2.** The scripts avoid `mapfile` and `case` inside `$(…)`.
- **Hostinger's staging tool rewrites the production domain inside the files it copies.** Write the domain split in two wherever it must stay the production one.
- **Hostinger's SSH sometimes does not answer for a moment.** The deploy waits at most 20 s per attempt and tries the first connection three times before giving up; a failed connection deploys nothing, so re-run the workflow.
