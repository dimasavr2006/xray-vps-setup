# Installer execution audit — 2026-10-10

The review covered the entrypoint builder, CLI dispatch, configuration contract,
all Bash modules, embedded Caddy/cover assets and the optional statistics addon.
The comparison baseline is the host-security release (`def8ba3`, with report
updates in `93f021e`). This change does not introduce new image versions.

The optimization acceptance is complete: 129 Bash checks, deterministic build,
ShellCheck, real role/maintenance/security/failure tests and three alternating
lifecycle comparisons passed. Publication evidence and FI CLI promotion are
tracked in the verification report. The pinned production image set is unchanged.

## Execution path

Setup installs missing tools, collects/normalizes configuration, checks resource
and DNS admission, prepares Docker, and checks ports/network/ownership. Under an
installation lock it renders private files, records existing host access, pulls
required pinned images and validates Caddy. It starts the database/cache/panel,
reconciles administrator/tokens/profile/node/hosts/squads through the API, starts
public services, checks health, configures host security and writes the access
card. A standalone node stops in the prepared state until panel attachment.

Maintenance commands share ownership/integrity checks. Backups capture PostgreSQL
and Caddy state. Restore regenerates executable files from trusted source.
Node/subscription rollback preserves concurrent database writes. Uninstall
validates the selected resources and removes only that installation's objects.

## Changes

| Area | Previous work | Current work |
| --- | --- | --- |
| DNS admission | Same hostname queried for each role, then again in preflight | One A/AAAA pair per distinct hostname during apply |
| Host admission | Resources always checked twice | Rechecked after installing a new Docker daemon; otherwise once |
| Fresh rendering | Full render followed immediately by prepared-package render | Full render once; existing prepared packages still receive template fixes |
| IP discovery | Serial IPv4 and IPv6 HTTPS probes | Independent bounded probes run together; local/DNS validation and confirmation remain |
| Docker ownership | Three inspections per container | One batched inspection, validating every returned identity and result count |
| Ports | One `ss` invocation per configured port | One listener snapshot per check |
| Doctor | Compose lookup per service and repeated state inspections | One service list and batched initial state/health inspection; poll only starting containers |
| Managed files | SHA process, `cut` and `jq` per file | One SHA invocation and one JSON conversion, with NUL-delimited paths |
| Parent traversal | `dirname` process for each ancestor | Shell path operations inside ancestor loops |
| Image pulls | Registry access even for cached digest references | Pull only missing digest-pinned images |
| Component upgrade | Pull entire stack and validate unchanged Caddy for node/subscription | Pull selected service only; Caddy validation retained for coordinated upgrades |
| Public startup | Separate Compose launches for Caddy/subscription/node | One launch with the role's selected services |
| Removal | Stop/remove containers one by one | Batched stop/remove of the exact verified container list |
| APT | Repeated index refresh in one invocation | Reuse successful refresh; invalidate after adding the Docker repository |
| Payload | Full installer assets included in uninstaller | Removal includes only its required module set; 216,173 bytes reduced to 81,682 bytes |

Panel/node readiness now shares an overall 120/60-second deadline with short
requests; image pulls have a 900-second limit before activation. Inactive UFW
rules are removed through validated exact-owner entries from `ufw show added`.
Uninstall repeats container, network and volume ownership/inventory checks after
confirmation.

The unused `rw_jwrite` wrapper and a duplicate doctor login were removed. Normal
setup also avoids a second dependency scan after its initial preparation.

## Retained behavior

Write journals, API reconciliation, checksum/ownership checks, private backups,
MFA, source-restricted node management, UFW/SSH rollback and FI parallel mode
remain. These protect supported operations and are not dead code. The optional
statistics addon remains embedded in setup/rwctl for installation and trusted
restore; it is not started by an ordinary installation. No remote module loader,
automatic version watcher or recurring check was added.

Repeated explicit upgrades still recreate the selected service even when its
digest is unchanged. This preserves the existing repair/redeployment behavior.
Cached images are safe to reuse here because all accepted references are fixed
SHA-256 digests; changing a digest still requires the corresponding new image.

## Module and function audit

The source contains 160 functions in 17 Bash modules. Conservative textual
references found no unreferenced function after removal of rw_jwrite. These
references include dispatch, error handlers and traps; textual reachability is
not a proof that every branch executes in every role. The uninstall dispatch and
initialized cleanup flags give 28 conservatively reachable functions. Shared
modules define additional helpers, retained to keep a single implementation of
ownership, journaling and host-access recovery.

| Source under bash/ | Responsibility and dependencies |
| --- | --- |
| cli.sh, addresses.sh | Dispatch/wizard; configuration, IP/DNS confirmation and role commands |
| common.sh, config.jq | Configuration/ownership, lock, file journal, dependencies, embedded assets |
| preflight.sh | RAM/disk, listener/Docker/network admission before mutations |
| render.sh, site.sh, summary.sh | Compose/private files, cover, terminal/private access card |
| deploy.sh, tokens.sh, mfa.sh | Service readiness and owned API reconciliation, rotation and MFA status |
| security.sh, ssh.sh | Scoped firewall and access changes with confirmation/rollback |
| maintenance.sh, recovery.sh, upgrade.sh | Integrity, doctor, scoped removal, backup/restore and component rollback |
| tls.sh | Certificate test and reversible existing-proxy handling |
| stats.sh | Optional fixed-version hook, schema, read-only API and trusted restore |

installer/build-entrypoints.sh embeds all modules and assets in setup/rwctl. It
embeds only common/security/preflight/maintenance/ssh/cli plus config.jq in
uninstall. Removal therefore works without a remote module download. The reduced
entrypoint suppresses only shared-helper SC2034/SC2120 warnings; full entrypoints
receive normal ShellCheck. Five native-filesystem help runs had a median of
17 ms for the baseline full payload, 9 ms for reduced uninstall and 14 ms for
current rwctl. Further module fragmentation has little measured benefit here.

## Research decisions

Docker snapshots are reused within individual read-only checks. Ownership and
inventory are refreshed before mutation and after deletion confirmation. A
global cache across object creation/deletion was rejected because it can hide
changed identities. Batched file tracking preserves the journal; unchanged
write suppression was not added because it would need to preserve external-edit
detection and crash recovery for little measured runtime benefit.

API logins still occur where administrator permissions, token rotation or lost
responses require them. There is no cross-command JWT cache. Existing Compose
readiness dependencies and compact memory limits remain; increasing parallel
service startup was not justified by the measurements. The Caddy backup pause
remains to capture consistent authentication/MFA state. Component rollback keeps
current panel writes; full rollback deliberately restores the database snapshot.
Further backup shortcuts/compression changes were not justified by the roughly
1.6-second median node-upgrade backup stage. Disk admission checks remain.

## Measurements and acceptance

Three alternating baseline/optimized pairs on the same Debian 13 amd64 WSL with
native Docker, cached digests, reserved domains and internal TLS. Security was
disabled in the timing fixture and tested separately in real SSH/UFW namespaces.

| Operation | Before, median (range), seconds | After, median (range), seconds |
| --- | ---: | ---: |
| Fresh combined installation | 65.497 (57.846–67.639) | 59.956 (49.471–60.901) |
| Repeat apply | 12.377 (11.765–12.858) | 7.645 (6.557–8.506) |
| Doctor | 2.145 (2.088–2.155) | 0.725 (0.616–0.739) |
| Node upgrade/redeployment | 32.181 (22.475–32.528) | 7.994 (7.811–8.051) |
| Purge uninstall | 9.255 (8.935–9.954) | 4.833 (4.751–5.095) |

Fresh-install ranges overlap, and optimized run 3 was slower than baseline run 3.
These are descriptive measurements, not a guaranteed VPS installation time.
Subscription upgrade took 10.417 seconds and full restore 62.980 seconds in one
additional optimized run; no comparative speedup is claimed for those operations.

Instrumented nested stage medians: fresh render 1.550 → 1.335 seconds; file
tracking during install 0.449 → 0.033 seconds; API token preparation 2.206 →
1.846 seconds. The install doctor/readiness stage remained about 18 seconds,
showing that upstream startup dominates remaining fresh-install delays. Stages
are inclusive and must not be added together. Five separate 15-file runs gave
track medians 188 → 43 ms and integrity medians 163 → 100 ms.

Command-name wrapper counts for the same five operations in runs 2/3: Docker
median 439 → 160.5, jq 1160 → 973, sha256sum 424 → 314. Wrappers exclude subprocess
commands invoked through timeout and service traffic. DNS was stubbed and APT/
Docker already installed in the timing fixture; DNS/APT failure/cache behavior
is covered by targeted tests, not a clean-host timing claim.

An isolated empty image cache pulled all six images in 74.274 seconds; warm
missing-policy took 0.334 seconds, warm always-policy 1.436 seconds. A previously
reviewed absent PostgreSQL digest took 90.436 seconds to download, proving that
missing-policy still fetches changed digests. This used an empty temporary daemon
and no application containers; its 2.28 GB data directory was removed. A separate
live database test upgraded PostgreSQL 18.3 → 18.4 and fully rolled back to 18.3,
preserving row 42 and removing the post-snapshot table. Production pins did not
change, and newer upstream releases were not certified.

Cover HTTPS probes roughly every 250 ms with a 400 ms timeout observed median
node-upgrade failure windows 14.453 → 4.727 seconds. Repeat apply and doctor had
no failed cover samples. This is approximate sampling of one endpoint; it is
not a zero-downtime claim for panel/subscriptions or an external load test.

Driver-process maximum RSS was 44–45 MiB in both variants. Matched-run temporary
directories sampled at operation end were about 0.96 MB. Individual container
memory peaks approached their configured 512 MiB limit; these are not simultaneous
total RAM measurements or proof that OOM never occurred. Compact hard limits and
admission remain. Provider public DNS/ACME, external global IPv6 and production
load performance remain outside this comparison.

Acceptance includes all three roles and old prepared packages, FI-style parallel
layout with legacy HTTPS/config restoration, real armed-UFW uninstall/SSH guards,
foreign/changed resources, stalled API and failed pull, real SIGTERM/SIGKILL write
boundaries and API bootstrap continuation. An old pre-optimization MFA/stats
archive restored with trusted current code and preserved secrets/API UUIDs/TOTP;
fresh HTTP MFA, wrong-code rejection and separate Remnawave authentication passed.
FI received only a separate CLI promotion, verified without container restarts or
changes to SSH/UFW/config/MFA; private backups were checksum-verified offhost.

See [verification](../tests/verification.optimization.json) and
[safe measurements](../tests/measurements.optimization.json) for evidence and
limitations. Full private profiles/API data are not published. No recurring
monitor, automatic updater or image builder was added.
