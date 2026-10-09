# Installer source and verification

See the published [user guide](../README.md) for installation, wizard
questions, cover selection and component updates. In the public repository the
same guide is `../README.md`.

`bash/` contains the Bash implementation. `config.jq` validates and normalizes
the public configuration. `addresses.sh` detects and confirms IPs/DNS;
`site.sh` manages the Confluence/custom cover. `summary.sh` renders the
terminal/private access card and read-only `info`. `security.sh` installs UFW,
preserves root keys and host services, and guards policy changes until a fresh
SSH connection is confirmed. `templates/` and
`versions.lock.json` are embedded into the generated entrypoints.
`../stats/` contains the optional interval-accounting addon.

Build from this source tree on Linux:

```bash
bash installer/build-entrypoints.sh
bash installer/build-entrypoints.sh --check
shellcheck --severity=warning rw-setup.sh rwctl uninstall.sh installer/build-entrypoints.sh
```

The builder generates `rw-setup.sh`, `uninstall.sh` and `rwctl` deterministically.
Deployment saves a self-contained `rwctl` beside each installation's config.
There is no Python installer payload. Debian UFW installs its own Python
runtime dependencies through APT.

## Safety model

- The installation name and absolute output directory derive ownership labels.
  Foreign containers, volumes, networks, routes, ports or changed managed files
  block mutation. Operator files are not adopted into the deletion manifest.
- Root-only private files hold credentials, API tokens and native node keys.
  Secrets and API UUIDs persist across repeated setup. The wizard collects no
  plaintext secrets in the public JSON.
- A write journal reconciles interruption before/after atomic rename and manifest
  updates. An unexpected external change blocks recovery rather than overwriting it.
- API operations record intent and reconcile lost responses by owned identity.
  Token rotation keeps the old token until candidate activation succeeds and
  rejects foreign scopes, identities and duplicate matches.
- Backups include managed files, PostgreSQL and Caddy data/config volumes. Restore
  validates the archive and regenerates executable runtime code from the current
  trusted CLI. Node/subscription upgrade rollback keeps current panel data;
  coordinated upgrades and manual full rollback restore their database snapshot.
- SSH hardening stages a key-based admin, requires a fresh login and keeps a
  timed rollback until confirmation. Firewall rules are scoped and persistent.
- A pinned panel hook is required for statistics. A changed panel digest cannot
  proceed with the addon until compatibility has been checked.

## Tests

```bash
bash tests/bash/unit.sh
bash tests/bash/recovery-unit.sh
bash tests/bash/stats-unit.sh
bash tests/bash/tokens-unit.sh
bash tests/bash/interruption-unit.sh
bash tests/bash/wizard-unit.sh
bash tests/bash/summary-unit.sh
bash tests/bash/security-unit.sh
bash tests/bash/http-entrypoints.sh
node tests/stats-hook.cjs
```

The first eight suites contain 103 checks. HTTP tests additionally exercise wget
and process substitution without a source checkout. `mfa-live.cjs` and
`stats-live.py` are development test clients, not VPS installer requirements.
Run live tests only against a disposable, explicitly selected installation.

The checked release combines Debian 13 native Docker role/maintenance tests
with external FI verification. New component tests recreate the current pinned
images and inject failure; they do not certify an untested upstream release.
Clean provider VPS roles with public DNS/ACME and external global IPv6 remain
outside the completed acceptance. Observation stopped by the owner remains
incomplete. Migration/bot plans and private artifacts stay in the local migration
project and are not published with this installer.
