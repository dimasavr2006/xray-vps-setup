# Installer execution audit — 2026-10-09

The review covered the entrypoint builder, CLI dispatch, configuration contract,
all Bash modules, embedded Caddy/cover assets and the optional statistics addon.
The comparison baseline is the host-security release (`def8ba3`, with report
updates in `93f021e`). This change does not introduce new image versions.

The current candidate is paused at the owner's request. Eight additional removal
checks and native armed-UFW uninstall passed. Stored rules of inactive UFW are now
removed safely; network/volume inventory is rechecked after confirmation. API and
image-pull deadline changes have been implemented but still need targeted failure
tests. Three alternating lifecycle comparisons and final publication are pending.

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
| Payload | Full installer assets included in uninstaller | Removal includes only its required module set; about 216 KB reduced to 80 KB |

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

## Measurements and acceptance

Five runs against the same 15-file fixture on the native Debian filesystem:

| Operation | Before, median | After, median |
| --- | ---: | ---: |
| Rebuild file manifest | 188 ms | 43 ms |
| Verify file integrity | 163 ms | 100 ms |

These are local operation measurements, not a claimed speedup for downloading
images or starting Remnawave. Full lifecycle results and final acceptance are
recorded in `tests/verification.optimization.json` relative to the project root.
The test guest uses native Docker, reserved DNS names and internal TLS. Real
provider DNS/ACME, a new upstream image pair and production-load performance are
outside this optimization comparison. FI runtime is not redeployed by this task.
