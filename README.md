# mediawiki-docker

Self-hosted MediaWiki via Docker Compose, with scripts for importing Softaculous backups, upgrading, backing up, and updating extensions and skins.

## Project Structure

```
mediawiki-docker/
├── docker-compose.yml              # MediaWiki + MariaDB services
├── .env.example                    # Template — copy to .env and edit
├── .env                            # Your local config (git-ignored)
├── .gitignore
├── import-from-softaculous.sh      # Import or upgrade from a cPanel/Softaculous backup
├── backup-mediawiki.sh             # Back up the running wiki
└── docker/                         # Files mounted into the container
    ├── LocalSettings.php           # Your wiki config (git-ignored, deployed via docker cp)
    ├── extension-updates.txt       # Saved extension URLs (git-ignored)
    ├── extension-updates.txt.example
    ├── skin-updates.txt            # Saved skin URLs (git-ignored)
    └── update-extensions-skins.sh  # Update installed extensions and skins
```

---

## Option A — Fresh Setup

### 1. Configure credentials

Copy `.env.example` to `.env` and fill in the required passwords:

```bash
cp .env.example .env
```

```
MYSQL_ROOT_PASSWORD=...   # required
MYSQL_PASSWORD=...        # required
```

All other values have defaults and can be left as-is.

### 2. Start the stack

```bash
docker compose up -d
```

### 3. Run the web installer

Open `http://localhost:80` and follow the setup wizard.

- Database host: `db`
- Database name / user / password: from your `.env`

At the end, download the generated `LocalSettings.php` and deploy it into the container:

```bash
docker cp LocalSettings.php mediawiki-mediawiki-1:/var/www/html/LocalSettings.php
```

### 4. Restart

```bash
docker compose restart mediawiki
```

The wiki should now be fully functional.

---

## Option B — Import from a Softaculous (cPanel) Backup

If you have an existing MediaWiki hosted on cPanel, export it via **Softaculous Apps Installer** and restore it here.

### 1. Export the backup from cPanel

In cPanel, open **Softaculous Apps Installer** → **MediaWiki** → **Backups**. Create or download a backup — it will be a `.tar.gz` file.

### 2. Run the import script

```bash
./import-from-softaculous.sh /path/to/your-backup.tar.gz
```

The script will first ask whether you want a **Fresh import** or an **Upgrade**:

- **Fresh import** — removes any existing stack and volumes for this project, then imports from scratch
- **Upgrade** — keeps existing data, pulls a new MediaWiki image, and upgrades in place

It then prompts for:

- MediaWiki version (pre-filled from backup, latest shown for reference)
- MariaDB version (see https://www.mediawiki.org/wiki/Compatibility#Database)
- HTTP port (default: 80)
- Project name (default: `mediawiki`, used for container/volume naming)
- Server URL (pre-filled from backup)

The upgrade flow:

1. Pull the new MediaWiki image
2. Restore `LocalSettings.php` from backup (with Docker settings rewritten), deployed via `docker cp`
3. Restore missing `extensions/` and `skins/` from backup (existing ones preserved)
4. Run `update-extensions-skins.sh` to update all extensions and skins to the new version
5. Run `php maintenance/run.php update` to apply all schema changes

At the end the script offers to create a new backup and chain into the next upgrade step automatically.

### 3. Verify

Open `http://localhost` — your wiki should appear with all content intact.

---

## Upgrading MediaWiki

MediaWiki only supports upgrades from up to two LTS releases ago. Check the upgrade path before starting:

- LTS releases: https://www.mediawiki.org/wiki/Version_lifecycle
- Compatibility: https://www.mediawiki.org/wiki/Compatibility#Upgrade

**Strategy:** pick the LTS version closest to (but below) your target as the intermediate step. For example, to reach 1.45 from 1.37, go via 1.43.

Run the import script with your latest backup and choose **Upgrade** when prompted. At the end it offers to create a backup and chain into the next upgrade automatically.

---

## Backing Up

```bash
./backup-mediawiki.sh
```

Creates `mw-backup-{version}-{date}.tar.gz` in the project directory containing `images/`, `extensions/`, `skins/`, `LocalSettings.php`, `softver.txt`, and a full database dump. The output can be used directly with `import-from-softaculous.sh`.

---

## Updating Extensions and Skins

Extensions and skins are updated from inside the container using a three-phase approach:

1. **Phase 1** — Extensions/skins without a `version` file are auto-skipped (bundled or manually installed)
2. **Phase 2** — Compatibility check against the current MW version via ExtensionDistributor/SkinDistributor. Incompatible ones can be disabled in `LocalSettings.php` with a hint to search for their usage
3. **Phase 3** — Compatible ones are auto-downloaded. If download fails, a manual URL prompt appears

```bash
docker exec -it mediawiki-mediawiki-1 bash /var/www/html/update-extensions-skins.sh
```

To re-ask all extensions and skins (reset saved URLs):

```bash
docker exec -it mediawiki-mediawiki-1 bash /var/www/html/update-extensions-skins.sh --reset
```

Saved URLs are stored in `docker/extension-updates.txt` and `docker/skin-updates.txt`.

---

## Multiple Wiki Instances

Each wiki instance should live in its own copy of this repository with its own `.env`. Set a unique `COMPOSE_PROJECT_NAME` in each `.env` to keep containers and volumes isolated:

```
COMPOSE_PROJECT_NAME=mywiki1
```

---

## Volumes

| Volume | Contents |
|---|---|
| `{project}_db_data` | MariaDB data |
| `{project}_mw_images` | Uploaded files and images |
| `{project}_mw_extensions` | Installed extensions |
| `{project}_mw_skins` | Installed skins |
| `{project}_mw_tmp` | MediaWiki tmp directory |

Volume names are prefixed with the project name (default: `mediawiki`), so multiple instances on the same host are fully isolated.
