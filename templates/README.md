# {{SITE_TITLE}}

The theme and custom plugins of [{{PROD_HOST}}](https://{{PROD_HOST}}). This repository holds the code only; the database and images come from production.

- `AGENTS.md` (also `CLAUDE.md`): how the site is built, its rules and conventions.
- `docs/STATUS.md`: state, next steps, log.
- `hosting/README.md`: server and Local settings that live outside WordPress; `hosting/site.conf`: this site's values for the tools.
- `tools/`: the shared [wp-site-tools](https://github.com/m-misovic/wp-site-tools) (submodule). `php tools/package.php` builds release ZIPs, `tools/deploy.sh` deploys (GitHub Actions runs it), `tools/pull-db.sh` copies production's database into Local.

## Run a local clone of production

You need [Local](https://localwp.com), Git, Node.js 20 or newer, access to this repository and to the site's Hostinger hPanel.

### 1. Create the site in Local
1. **Create a new site**: name `{{SITE}}`, domain `{{LOCAL_HOST}}`, **Custom** environment with PHP {{PHP_VERSION}}, nginx and MySQL 8.0. Any admin user will do; step 5 replaces it with production's users.
2. Site → **SSL → Trust**, so `https://{{LOCAL_HOST}}` opens without warnings.
3. Leave the `wp-config.php` that Local writes. Never copy production's.
4. Create `~/Local Sites/{{SITE}}/CLAUDE.md` containing the single line `@app/public/AGENTS.md`, so an agent started in the site folder reads this repository's guide.

Commands below run in a terminal in `app/public` (or Local's site shell: right-click the site → *Open site shell*).

### 2. Install the third-party plugins
```sh
wp plugin install {{THIRD_PARTY_PLUGINS}}
```
Use the versions production runs (wp-admin → Plugins on {{PROD_HOST}}). Do not activate them; the imported database does that. The staging guard's production-only plugins ({{PRODUCTION_ONLY_PLUGINS_LIST}}) are not needed locally.

### 3. Get the code
The folder already contains WordPress, so initialise Git in place instead of cloning:
```sh
git init
git remote add origin git@github.com:{{GITHUB_REPO}}.git
git fetch origin
git checkout -f -t origin/main
git submodule update --init
```
`-f` lets the repository overwrite the few `index.php` files WordPress also ships; WordPress itself and `wp-config.php` are left alone. The last command fetches `tools/`.

### 4. Build
```sh
npm ci
npm run build
```
The plugins' `build/` folders are not in Git, so blocks and styles are missing until this runs.

### 5. Import the production database
```sh
tools/pull-db.sh
```
It backs up the local database, runs only `mysqldump` on the server over SSH, checks the dump is complete, adapts it to Local's MySQL 8.0, asks, imports it and points it at `https://{{LOCAL_HOST}}`; a failed import restores the backup. Dumps and backups (the newest three) are kept in `~/Local Sites/{{SITE}}/backups/`: they hold production data, so they never go into Git or leave the machine.

**SSH, once per machine** (your machine's key, never the deploy key):
1. `ssh-keygen -t ed25519` if `~/.ssh/id_ed25519` does not exist; paste `~/.ssh/id_ed25519.pub` in hPanel → Advanced → **SSH Access**.
2. Add to `~/.ssh/config`:
   ```
   Host {{SSH_ALIAS}}
     HostName {{SSH_IP}}
     Port {{SSH_PORT}}
     User {{HOSTINGER_USER}}
     IdentityFile ~/.ssh/id_ed25519
     IdentitiesOnly yes
     UseKeychain yes
     AddKeysToAgent yes
   ```
3. Check: `ssh {{SSH_ALIAS}} 'cd {{PROD_ROOT}} && wp core version'` (the first time: `yes` for the server, then the key's passphrase).

**Without SSH:** hPanel → **Backups → Database backups** (or a phpMyAdmin export), then `tools/pull-db.sh --file ~/Downloads/<dump>.sql.gz`.

Then log in at `https://{{LOCAL_HOST}}/wp-admin` with your **production** username and password.

### 6. Images
Set up `hosting/local/uploads-proxy.conf` as [hosting/README.md](hosting/README.md) describes: images missing locally are fetched from {{PROD_HOST}} on demand. Local deletes never touch production.

### 7. Check
- `https://{{LOCAL_HOST}}` opens and the main pages work.
- The toolbar shows **STAGING COPY**: the staging guard is active, production-only plugins are not loaded, e-mail goes to Local's Mailpit and the site is noindex.

## Notes
- To refresh the clone later, repeat steps 5 and 6.
- Never point a local site at the production database.
