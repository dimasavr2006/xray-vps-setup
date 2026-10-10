# Remnawave VPS installer

Linux installer for a panel, a standalone node, or both on one server. The
supported server is **Debian 13 amd64**. Run as root. The installer uses Bash,
APT, Docker Compose, curl and jq. Host security uses Debian's UFW package,
whose dependencies include Python; the installer itself remains Bash.

## Install and remove

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/rw-setup.sh)
```

The downloaded script contains its Bash modules, templates and image lock.
It installs dependencies from Debian and Docker, pulls pinned images, creates
configuration and starts the selected services. A checkout is not required.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/uninstall.sh)
```

Removal selects an installation under `/opt/pdm-remnawave`. Persistent volumes
are retained by default. Use `--output /opt/pdm-remnawave/vpn-main --purge` to
remove that installation's data as well. `--dry-run` previews the operation.
Ownership labels, managed file hashes and path checks protect adjacent stacks.
Removal keeps Docker, cached images, SSH and unrelated firewall rules.

The root-level `vps-setup.sh` and `uninstall.sh` remain the legacy
Marzneshin installer. Use the `/remnawave/` URLs above for Remnawave.

## Wizard

All prompts and runtime messages are in English.

1. Select `panel`, `standalone node`, or `panel and node`.
2. Choose an installation name, such as `vpn-main` or `node-main`. This names
   the directory and Docker project; it is not an account or domain.
3. Choose `standard installation` or `parallel test beside an existing stack`.
4. Enter the relevant domains. Panel, subscriptions and cover can use different
   domains pointing to the same IP, or share one domain with separate ports.
5. For a panel, enter the administrator username and email.
6. Review automatically detected public IPs and each domain's A/AAAA records.
   Accept the proposal or enter corrected IPs. IPv6 is optional. Detection uses
   local interfaces and bounded HTTPS requests to the open-source
   [ipify service](https://www.ipify.org/). Matching DNS can narrow the proposal
   to the addresses actually used. Unverified DNS never silently replaces the
   server's detected IPs. Preflight requires DNS to match the confirmed list.
7. For a standalone node, enter the panel server's domain or source IPs and
   confirm the management allowlist. With a CDN, supply the panel server's
   actual outbound IPs.
8. For standard installs, select `test` or `production` (default: production).
   Tests may select `compact-test`. Parallel installs ask for the existing
   Caddyfile, container and HTTPS health URL, and default to `compact-test`.
9. If root has no valid key in its configured `AuthorizedKeysFile`, paste one
   public SSH key. Existing root keys are preserved and no extra key is appended.

The standard panel uses HTTPS/443. A combined installation uses panel/9443,
Reality/443 and XHTTP/8443. Separate subscription domains use the panel's HTTPS
port; a shared panel/subscription hostname uses subscription/9444.
The parallel test layout uses panel/9443, subscription/9444 when shared,
Reality/24443 and XHTTP/28443. `fi-parallel` is the existing JSON name for this
test layout. It reserves legacy ports and shares the existing HTTP ACME route;
it is not required for an ordinary installation.

Installation checks OS, architecture, RAM, disk, DNS, ports, Docker ownership,
time synchronization and firewall state. It then creates the private files,
starts the database and panel, creates scoped API tokens and owned API objects,
configures the node and starts Caddy, subscriptions and transports.
Repeating the same configuration preserves keys and recorded API UUIDs.

Panel credentials are in `private/admin.json`. The separate Caddy Auth password
is in `private/secrets.json`. Visit the panel's `/r` route to enroll MFA, then
verify a fresh login. Caddy authentication and Remnawave authentication are
separate. Secret files are root-only and are not printed by status commands.

At the end, an English summary shows the panel/MFA/subscription/cover URLs,
usernames, actual node ports, Reality public key, Short ID, XHTTP path and
maintenance commands. A normal SSH terminal also shows the two saved login
passwords. Redirected output hides passwords. The full card is saved as
`private/install-info.txt` with mode 0600. Display it again with:

```bash
bash /opt/pdm-remnawave/vpn-main/rwctl info
bash /opt/pdm-remnawave/vpn-main/rwctl info --show-secrets
```

`info` is read-only and hides passwords by default. `--show-secrets` requires
root and a terminal. The card excludes database passwords, API tokens, native
management keys and the private Reality key. A prepared standalone node shows
planned endpoints and copy/attachment commands, not a running-service claim.

Production panel admission requires at least 2 CPU, 4 GiB RAM and 20 GiB free
disk. Standalone node admission starts at 1 CPU and 1 GiB RAM, with a separate
disk budget. Compact tests enforce container limits and host headroom; they
do not bypass available-memory checks or increase swap.

## UFW and root access

Host security is enabled during setup. UFW is installed from Debian APT when
missing. The root public key is appended only when no existing valid root key
was found. Existing lines, keys and SSH authentication policy are preserved;
the installer does not generate a private SSH key on the VPS.

Before starting the new stack, the installer records existing non-loopback
TCP/UDP listeners and Docker publications. When enabling an inactive UFW, it
preserves these ports, actual SSH ports and existing UFW rules. It sets default
incoming deny and outgoing allow and enables IPv6 filtering. Installation web
ports include HTTP3 UDP; node management is allowed only from panel source IPs.
An already active incoming-deny policy receives additive installation rules;
foreign listening ports are not automatically opened through its restrictions.
Outgoing policy is retained for an already active UFW.

After activation or a change to default incoming policy, reconnect SSH in a
new terminal and run the command printed by the summary:

```bash
bash /opt/pdm-remnawave/vpn-main/rwctl security confirm
```

With a sudo administrator, preserve the SSH session variable:

```bash
sudo --preserve-env=SSH_CONNECTION bash /opt/pdm-remnawave/vpn-main/rwctl security confirm
```

A one-time five-minute watchdog restores the prior UFW configuration if the
fresh connection is not confirmed. Confirmation stops that timer. It is not
a recurring monitor. A conflicting external UFW change is reported rather
than silently overwritten. For an existing installation:

```bash
bash /opt/pdm-remnawave/vpn-main/rwctl security apply --dry-run
bash /opt/pdm-remnawave/vpn-main/rwctl security apply
bash /opt/pdm-remnawave/vpn-main/rwctl security status
```

Noninteractive configuration can supply
`security: {"enabled": true, "root_public_key": "ssh-ed25519 AAAA... owner"}`.
Use an actual complete public key. `security.enabled=false` explicitly skips
this host-security stage. An omitted security object uses the default without
changing the fingerprint of an older saved configuration. Removal retains
root keys, UFW, host SSH/preserved-service rules and default policy, deleting
only rules tagged for the removed installation. Host-specific UFW rollback
state is not copied from a backup onto a replacement server.

Docker-published ports can bypass UFW; the installer also binds its private
APIs to loopback and retains the separate scoped nftables protections for its
management API/database/bridge. See
[Docker firewall documentation](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

## Default cover

Nodes serve the static Confluence login layout used by the legacy installer,
adapted to English with an embedded logo. This is a cover page, not a Confluence
server. The form never sends credentials or makes network requests.

```bash
bash /opt/pdm-remnawave/vpn-main/rwctl site set --template confluence
bash /opt/pdm-remnawave/vpn-main/rwctl site set --template simple
bash /opt/pdm-remnawave/vpn-main/rwctl site set --site-file /root/cover.html
```

Cover changes preserve domains, Reality keys and transports. Rerender and
recovery preserve an existing custom page. Panel-only installs have no node
cover. Layout: [confluence-marzban-home](https://github.com/Jolymmiles/confluence-marzban-home);
embedded icon: [Simple Icons](https://github.com/simple-icons/simple-icons).

## JSON configuration and standalone nodes

Use the [examples](installer/examples/) for noninteractive installs. Replace
sample domains/IPs, review ports and set `resources.purpose` explicitly.

```bash
bash rw-setup.sh --config /root/install.json --dry-run
bash rw-setup.sh --config /root/install.json
```

The node wizard prepares Docker, configuration and source-restricted firewall.
Without a native management key, it finishes as
`node-prepared-awaiting-attachment`. On the panel server, attach it using its
saved public configuration:

```bash
bash /opt/pdm-remnawave/panel-main/rwctl node attach \
  --ssh root@NODE_HOST --node-config /root/node.json
```

The SSH host must already be trusted in `known_hosts`. Attachment verifies the
prepared configuration, registers the node/profile through the panel API and
sends a short-lived connection package over SSH. It does not send the panel
API token to the node or fabricate `SECRET_KEY` locally.

The panel connects to the node's **TCP 2222** management API by default
(`ports.node_api` / `NODE_PORT`). This is an inbound port on the node, restricted
to the confirmed panel source IPs. The panel does not need a new inbound port
for node management. SSH (normally TCP 22, or the host's SSH configuration)
is used to verify and provision the prepared node. Attachment registers the
profile/node/hosts/access groups, obtains the panel's native `SECRET_KEY`,
delivers the one-hour configuration-bound package through SSH, starts the node
and waits for connected status and running Xray. Existing users are not given
access automatically. Client traffic uses separate Reality/XHTTP ports.
See [official node installation](https://docs.rw/install/remnawave-node/).

## Maintenance and updates

Every installation contains a self-contained `rwctl`:

```bash
bash /opt/pdm-remnawave/vpn-main/rwctl doctor
bash /opt/pdm-remnawave/vpn-main/rwctl info
bash /opt/pdm-remnawave/vpn-main/rwctl backup --archive /root/vpn-main.tgz
bash rwctl restore --archive /root/vpn-main.tgz --output /opt/pdm-remnawave/vpn-main
bash /opt/pdm-remnawave/vpn-main/rwctl tokens status
bash /opt/pdm-remnawave/vpn-main/rwctl tokens rotate --token all
bash /opt/pdm-remnawave/vpn-main/rwctl mfa status
```

Keep private backups off the VPS. Backups include the database, managed files
and Caddy certificate/MFA storage. Recovery validates ownership and checksums
and generates trusted runtime code rather than executing code from the archive.

Images are fixed by SHA256 digest in
[versions.lock.json](installer/versions.lock.json). Panel 3.4.5 and Node 3.4.2
are the current tested pair. `source_tag: latest` records where a digest was
resolved; Compose still uses that fixed digest. Caddy currently uses Remnawave's
`caddy-with-auth`, built from official Caddy with the authentication modules
required for MFA. No custom image build or automatic upstream watcher is used.

Updating this repository does not automatically change an existing VPS. Download
the new `rwctl` to a separate file and invoke it with `--output` pointing to the
existing installation. With no `--versions`, upgrade uses that CLI's embedded
release lock. A reviewed candidate lock can be passed explicitly:

```bash
bash rwctl upgrade --output /opt/pdm-remnawave/vpn-main \
  --component node --versions /root/candidate.lock.json --dry-run
bash rwctl upgrade --output /opt/pdm-remnawave/vpn-main \
  --component node --versions /root/candidate.lock.json
```

| Component | Behavior |
| --- | --- |
| `node` | Recreates only the node; failure restores its previous image without replacing panel data. Run on the node's server. |
| `subscription` | Recreates only subscriptions; failure keeps current panel data. |
| `panel` | Selects only the panel image, using coordinated stack maintenance and database rollback on failure. |
| `caddy` | Selects only Caddy, using coordinated stack maintenance and backup of MFA/certificates. |
| `all` (default) | Applies the entire reviewed lock with coordinated maintenance and rollback. |

Each upgrade creates a private rollback backup before activation. Node and
subscription backups briefly pause Caddy to capture its storage; these commands
are not a zero-downtime guarantee. Successful activation runs health checks.
New versions still require compatibility checks; upgrades never follow mutable
`latest` tags. With the optional statistics addon, a changed panel digest is
blocked until its hook compatibility is verified. PostgreSQL major upgrades
require a separate data migration. A manual `rollback --archive FILE` restores
the full snapshot, including its database. See the
[official update guide](https://docs.rw/install/upgrading/).

Already cached images with the exact pinned digest are reused. A component
upgrade pulls only the selected service's missing image; it still recreates and
checks that service. See the [execution audit](installer/OPTIMIZATION.md) for
startup, maintenance and removal optimizations.

Optional interval accounting is documented in [stats/README.md](stats/README.md).
Additional commands include `preflight`, `tls-test`, `ssh prepare` and
`ssh harden`; see `rwctl --help` and [developer notes](installer/README.md).

## Verification

The optimized release passed 129 Bash checks, deterministic builds and ShellCheck.
Real tests cover all three roles, old prepared packages, parallel legacy Caddy,
armed-UFW uninstall, API deadlines, failed pulls, interruption/recovery and old
MFA/stats backup restore. Three alternating comparisons measured repeat apply
12.377 → 7.645 seconds, doctor 2.145 → 0.725 seconds and node redeployment
32.181 → 7.994 seconds. These cached-image/internal-TLS measurements are not
guaranteed VPS timings; fresh-install ranges overlap. See the
[optimization audit](installer/OPTIMIZATION.md) and
[optimization verification](tests/verification.optimization.json).
Host-security tests cover root key
validation/preservation, public port discovery, legacy config compatibility,
active-policy restrictions and read-only preview. Native Debian UFW namespace
tests preserved TCP/UDP/IPv6 services, blocked unapproved listeners, confirmed
a real fresh SSH connection and exercised the systemd rollback timer. On FI,
UFW is enabled and confirmed; 15 external TCP probes retained their prior
reachability, legacy/new HTTPS worked, root keys and container start times
were unchanged, and the private backup was verified offhost.
Summary checks exercised three roles,
shared hostname ports, IPv6 copy commands, real terminal password display and
password suppression in redirected output. FI verified its actual summary,
root-only access card and installed `rwctl info` without changing secrets or
container start times. A fresh Debian 13 WSL installation with
native Docker exercised real Confluence HTTPS, cover replacement, node and
subscription upgrades, and node rollback retaining concurrent database writes.
The browser check verified English rendering with a Russian locale and no
network requests from the cover form. Local tests used reserved DNS fixtures
and internal TLS; they are not public DNS/ACME acceptance on a clean provider VPS.
FI has separate external TLS/TCP/XHTTP and backup/MFA verification. Full passive
48-hour observation was stopped by the owner and is not claimed as completed.
See [installer verification](tests/verification.installer.json) and
[FI verification](tests/verification.fi.json).
