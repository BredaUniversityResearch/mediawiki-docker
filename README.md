# mediawiki-docker

Self-hosted MediaWiki via Docker Compose, with scripts for importing Softaculous backups, upgrading, backing up, and updating extensions.

## Project Structure

```
mediawiki-docker/
├── docker-compose.yml              # MediaWiki + MariaDB services
├── .env.example                    # Template — copy to .env and edit
├── .env                            # Your local config (git-ignored)
├── .gitignore
├── import-from-softaculous.sh      # Import a cPanel/Softaculous backup
├── backup-mediawiki.sh             # Back up the running wiki
└── docker/                         # Files mounted into the container
    ├── LocalSettings.php           # Your wiki config (git-ignored)
    ├── extension-updates.txt       # Your extension URLs (git-ignored)
    ├── extension-updates.txt.example
    └── update-extensions-skins.sh        # Update installed extensions
```

---

## Option A — Fresh Setup

### 1. Configure credentials

Copy `.env.example` to `.env` and fill in the two required passwords:

```bash
cp .env.example .env
```

```
MYSQL_ROOT_PASSWORD=...   # required
MYSQL_PASSWORD=...        # required
```

All other values have defaults and can be left commented out.

### 2. Start the stack

```bash
docker compose up -d
```

### 3. Run the web installer

Open `http://localhost:80` and follow the setup wizard.

- Database host: `db`
- Database name / user / password: from your `.env`

At the end it downloads a `LocalSettings.php`. Save it to `LocalSettings.php` in the project root.

### 4. Restart

```bash
docker compose restart mediawiki
```

The wiki should now be fully functional.

---

## Option B — Import from a Softaculous (cPanel) Backup

If you have an existing MediaWiki hosted on cPanel, you can export it via the **Softaculous Apps Installer** and restore it here.

### 1. Export the backup from cPanel

In cPanel, open **Softaculous Apps Installer** → **MediaWiki** → **Backups**.
Create or download a backup — it will be a `.tar.gz` file.

### 2. Run the import script

```bash
./import-from-softaculous.sh /path/to/your-backup.tar.gz
```

The script fully automates the import. It will prompt you for:

- MediaWiki version (pre-filled from backup, latest shown for reference)
- MariaDB version (see https://www.mediawiki.org/wiki/Compatibility#Database)
- HTTP port (default: 80)
- Project name (default: `mw_{version}_{port}`, used for container/volume naming)
- Server URL (pre-filled from backup, e.g. `http://localhost`)

It then:

- Sets all values in `.env`
- Extracts and rewrites `LocalSettings.php` with Docker connection settings
- Starts the Docker stack
- Restores `images/`, `skins/`, and (if not upgrading) `extensions/`
- Imports the database
- On upgrade: runs schema update, restores extensions, runs extension updater

### 3. Restart and verify

```bash
docker compose restart mediawiki
```

Open `http://localhost` — your wiki should appear with all content intact.

---

## Upgrading MediaWiki

The import script handles upgrades. MediaWiki only supports upgrades from up to two LTS releases ago — check the upgrade path before starting:

- LTS releases: https://www.mediawiki.org/wiki/Version_lifecycle
- More info: https://www.mediawiki.org/wiki/Compatibility#Upgrade

**Strategy:** pick the LTS version closest to (but below) your target as your intermediate step. For example, to reach 1.45 from 1.37, go via 1.43.

Run the import script with your existing backup and enter the target version when prompted:

```bash
./import-from-softaculous.sh /path/to/your-backup.tar.gz
```

At the end of an upgrade the script offers to create a new backup and chain into the next upgrade step automatically.

---

## Backing Up

Create a backup of the running wiki at any time:

```bash
./backup-mediawiki.sh
```

This creates a `mw-backup-{version}-{date}.tar.gz` in the project directory containing `images/`, `extensions/`, `skins/`, `LocalSettings.php`, `softver.txt`, and a full database dump. The output can be used directly with `import-from-softaculous.sh`.

To specify an output path:

```bash
./backup-mediawiki.sh /path/to/my-backup.tar.gz
```

---

## Updating Extensions

Extensions are updated from inside the container. The script scans the `extensions/` folder, reads each extension's `version` file, and prompts for a download URL — pre-filling it automatically from the MediaWiki ExtensionDistributor where possible.

### Run the updater

```bash
docker exec -it <container> bash /var/www/html/update-extensions-skins.sh
```

Where `<container>` is your container name, e.g. `mw_1_45_80-mediawiki-1`. Check with:

```bash
docker compose ps
```

### Re-ask all extensions (reset saved URLs)

```bash
docker exec -it <container> bash /var/www/html/update-extensions-skins.sh --reset
```

### How it works

- Extensions with a `version` file matching the current MW version are skipped
- For each extension that needs updating, the script fetches the download URL automatically from https://www.mediawiki.org/wiki/Special:ExtensionDistributor
- The URL is shown as a default — press Enter to accept or paste a custom one
- Type `-` to skip an extension and remember that choice for future runs
- Resolved URLs are saved to `extension-updates.txt`
- After all updates, runs `php maintenance/run.php update` to apply any extension schema changes

### Finding URLs manually

If auto-fetch doesn't find a URL:

1. Go to https://www.mediawiki.org/wiki/MediaWiki
2. Search for the extension name (e.g. `AdminLinks`)
3. Open `Extension:AdminLinks` → Installation section → **Download** link
4. Select your MediaWiki version and press **Continue**
5. Cancel the download — paste the `.tar.gz` URL into the prompt

---

## Updating MediaWiki Itself (without re-importing)

To update the MW image version without a full re-import:

```bash
# Edit .env: MEDIAWIKI_VERSION=1.43
docker compose pull mediawiki
docker compose up -d mediawiki
docker exec -it <container> php maintenance/run.php update --quick
```

---

## Volumes

| Volume | Contents |
|---|---|
| `{project}_db_data` | MariaDB data |
| `{project}_mw_images` | Uploaded files and images |
| `{project}_mw_extensions` | Installed extensions |

Volume names are prefixed with the project name (e.g. `mw_1_45_80_db_data`), so multiple wiki instances on the same host are fully isolated.
