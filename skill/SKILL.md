---
name: wp-site
description: Set up a new WordPress site, or bring an existing one, onto the owner's standard layout - Local by Flywheel locally, a private GitHub repo rooted at app/public with main/staging branches, Hostinger production and staging, push deploys through the shared wp-site-tools submodule, a staging guard, an uploads proxy, tools/pull-db.sh, and AGENTS.md/README/docs/STATUS.md for agents. Use when the user creates a new Local or WordPress site, asks for "the same setup" as the other sites, or wants an existing WordPress site moved onto this setup. Not for non-WordPress apps (that is new-project).
---

# WordPress site on the standard layout

Every site on this layout works the same way: code in a private GitHub repo whose root is the WordPress root (`~/Local Sites/<site>/app/public`), a push to `staging` or `main` deploys the site's own plugins to Hostinger, `tools/` is the shared public repo wp-site-tools, a must-use staging guard keeps copies from acting like production, and `AGENTS.md` plus `docs/STATUS.md` carry the project's memory for every agent.

**Sources** (read before working):
- `~/My Git/wp-site-tools` (this skill lives in its `skill/`; `git -C ~/My\ Git/wp-site-tools pull` first): `templates/`, `site.conf.example`, `workflows/deploy.yml`, and README's "Things these tools work around".
- Worked examples: the owner's sites already on this layout - every `~/Local Sites/*/app/public` with a `hosting/site.conf` (`ls ~/Local\ Sites/*/app/public/hosting/site.conf`). Read their `AGENTS.md`, `README.md` and `hosting/` when a template leaves a choice open.

## Hard rules
- **Interview and plan first. Change nothing before the user approves the plan.**
- **Never ask for, read or write secrets** (passwords, private keys, API keys, tokens). The owner runs the commands that handle them; give them exactly.
- **The owner** does everything in hPanel and GitHub settings, runs `tools/pull-db.sh` against production, and pushes `main` (real production deploys). You may push `staging`, with `[dry run]` in the message until the deploy is proven.
- No destructive Git operations. In a folder that already has Git, docs or a `tools/` folder, take the **Adopt** path: merge into what exists, never overwrite it.
- Commit messages carry no `Co-Authored-By` line. Never write `[skip ci]` in one.
- Nothing site-specific goes into wp-site-tools: it is public.
- Write the production domain split in deployed code (`'name' . '.tld'`); Hostinger's staging tool rewrites it in copied files.
- Template placeholders are `{{UPPER_CASE…}}` (the text after a colon says what goes there). None may survive: `grep -rnE '\{\{[A-Z]'` over the generated files must print nothing. (`{{#unless …}}` in hosting/README.md is Local's own syntax and stays.)
- Conversation follows the user's language; docs follow the language chosen in the interview (default English).

## Phase 1 — Interview
Ask in plain text, one numbered list in one message:
1. Site name (short, as the Local folder), title, production domain. Staging site (`dev.<domain>`): exists, wanted later, or not at all?
2. Local site: already created? PHP version (match production).
3. Hostinger: the account's SSH user, IP and port (hPanel → Advanced → SSH Access). Is the domain behind Cloudflare?
4. GitHub: new private repo `m-misovic/<site>`, or an existing one?
5. The site's own code: which plugins and theme (folders or a prefix such as `mybrand*`), and which have an npm build.
6. Plugins that must not run on copies: anything reporting to real accounts (analytics and ad tags, pixels, product feeds and catalogue sync, payments, SMTP, services whose account is shared with production). Plugins the site's own code must be testable with stay on.
7. Background jobs (Action Scheduler, heavy WP-Cron)? They need the server cron and the `noabort` block. Anything a deploy must not interrupt (an import that runs for minutes)? Then the site gets `hosting/deploy-check.php`.
8. Docs language.

Sensible defaults over more questions. If the folder already has a repository or docs, say so and switch to **Adopt**.

## Phase 2 — Plan
Show compactly: the files you will create or change, the owner's tasks with their exact commands, and the order. Wait for approval.

## Phase 3 — Setup
Work in `~/Local Sites/<site>/app/public`.

**A. Owner:** creates the site in Local (Custom: PHP as production, nginx, MySQL 8.0), Site → SSL → Trust, starts it.

**B. You:** `git init -b main` (new repo), then fill the templates:

| Template (in wp-site-tools) | Goes to |
|---|---|
| `templates/gitignore` | `.gitignore` |
| `templates/AGENTS.md` | `AGENTS.md`, then `ln -s AGENTS.md CLAUDE.md` |
| `templates/site-root-CLAUDE.md` | `~/Local Sites/<site>/CLAUDE.md` (outside the repo) |
| `templates/README.md` | `README.md` |
| `templates/STATUS.md` | `docs/STATUS.md` |
| `templates/hosting-README.md` | `hosting/README.md` |
| `site.conf.example` | `hosting/site.conf` |
| `templates/uploads-proxy.conf` | `hosting/local/uploads-proxy.conf`; also copy it to `~/Local Sites/<site>/conf/nginx/` and add `include uploads-proxy.conf;` to `site.conf.hbs` there as hosting/README.md says (the owner restarts the site) |
| `templates/background-tasks.htaccess` | `hosting/background-tasks.htaccess` (only with background jobs) |
| (no template; site-specific) | `hosting/deploy-check.php` only when a deploy must wait for something: PHP run on the server through WP-CLI that prints `idle` when the deploy may go ahead (see `deploy.sh`) |
| `templates/staging-guard.php` | `wp-content/mu-plugins/staging-guard.php` |
| `templates/package.json` | `package.json` (only when plugins have an npm build) |

Then:
```sh
git submodule add https://github.com/m-misovic/wp-site-tools.git tools
mkdir -p .github/workflows && cp tools/workflows/deploy.yml .github/workflows/deploy.yml
```
Check before the first commit:
- `php -l wp-content/mu-plugins/staging-guard.php`
- `php tools/package.php` lists exactly the site's own plugins and theme
- `git status --short` tracks nothing private: no `wp-config.php`, `uploads`, third-party plugins, `node_modules`, `build/`
- no placeholders left (grep above); `npm ci && npm run build` when there is a `package.json`

Commit on `main` with `[dry run]` in the message, then `git branch staging`.

**C. GitHub.** The owner creates the private repo (or you run `gh repo create m-misovic/<site> --private` once they agree). You: `git remote add origin https://github.com/m-misovic/<site>.git && git push -u origin main staging`. Without secrets the workflow stops with "Deploy secrets are not set; nothing was deployed" - expected.

**D. Owner: keys and secrets.** Their machine key in hPanel → SSH Access (`pbcopy < ~/.ssh/id_ed25519.pub`; `ssh-keygen -t ed25519` first if it does not exist). Then the deploy key, which only GitHub keeps:
```sh
ssh-keygen -t ed25519 -N "" -C github-deploy -f /tmp/<site>-deploy
pbcopy < /tmp/<site>-deploy.pub     # hPanel → SSH Access → Add SSH key, name: github-deploy
gh secret set DEPLOY_KEY -R m-misovic/<site> < /tmp/<site>-deploy
gh secret set DEPLOY_SSH -R m-misovic/<site> -b "<ssh-user>@<ssh-ip>"
gh secret set DEPLOY_PORT -R m-misovic/<site> -b "<ssh-port>"
ssh-keyscan -p <ssh-port> <ssh-ip> 2>/dev/null | gh secret set DEPLOY_KNOWN_HOSTS -R m-misovic/<site>
rm /tmp/<site>-deploy /tmp/<site>-deploy.pub
```

**E. You:** append the `Host <SSH_ALIAS>` block to `~/.ssh/config` (from README.md; never a duplicate). **Owner:** `ssh <alias> 'cd <PROD_ROOT> && wp core version'` - the first time `yes` for the server, then the key's passphrase.

**F. Owner, once on the server:** install each of the site's own plugins from its ZIP (`php tools/package.php <slug>`) if it is not there yet - the deploy only updates installed plugins (the staging guard needs nothing: tracked must-use plugins go to every site). Create the staging site in hPanel if wanted. With background jobs: the cron job and the `.htaccess` block (hosting/README.md).

**G. Database.** Owner: `tools/pull-db.sh`. You check locally: `https://<local host>` answers 200, the toolbar shows STAGING COPY, the page is `noindex`, the production-only plugins are not loaded.

**H. Deploy check.** You push `staging` with `[dry run]`, then `gh run watch <id> -R m-misovic/<site>` and read the log: submodule checked out, "Check this workflow matches the pinned tools" passed, packages built, "DRY RUN", the change list. Owner: `git push origin staging:main` and `git fetch origin main:main`.

**I.** Record the setup in `docs/STATUS.md` (Done and Log) and commit.

## Adopt an existing site
- Read its `AGENTS.md`, `README.md` and docs first. Keep their content and language; add what the templates have and the site lacks; ask before restructuring.
- A `tools/` folder with plain files: compare with wp-site-tools, move the site's values into `hosting/site.conf`, remove the files (`git rm -f`, keep a copy until done), add `!/tools` and `!.gitmodules` to `.gitignore`, then `git submodule add …` and copy the workflow. While `main` still has `tools/` as a folder, `git checkout main` fails: bring `main` up with `git push origin staging:main` and `git fetch origin main:main`.
- Compare its staging guard with `templates/staging-guard.php`: take the improvements, keep its hosts and plugin list.

## Phase 4 — Handoff
Tell the owner what is done, what is left for them, and where things live (`AGENTS.md`, `docs/STATUS.md`, `hosting/`). From then on every session reads `docs/STATUS.md` first.

## Keeping the standard alive
- An improvement that applies to every site (staging guard, docs structure, deploy, pull-db) goes into wp-site-tools as well: `templates/`, this `skill/`, or the tools. Commit, push, tag a new version, then `git submodule update --remote tools` in each site (and copy the workflow when it changed), commit, push `staging` with `[dry run]`.
- Each site pins the tools version it was tested with; a site that is not updated keeps working on its version.
