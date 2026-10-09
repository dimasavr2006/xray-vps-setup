# xray-vps-setup

VPS installers for VLESS with a domain and a Confluence cover page.

## Remnawave

The new Linux/Bash/Docker installer supports a panel, a standalone node or
both. Its current supported server is Debian 13 amd64. See
[the Remnawave guide](remnawave/README.md) for the wizard, MFA, component
updates and backup/recovery.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/rw-setup.sh)
```

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/remnawave/uninstall.sh)
```

## Legacy Marzneshin installer

Root-level commands install Marzneshin, Marznode and Caddy, or a standalone
Marznode. They configure VLESS Reality (TCP/443), optional XHTTP (TCP/8443)
and Hysteria2 (UDP/8443), a Confluence cover, and optional UFW/SSH hardening.
Full installation creates an administrator and registers the local node.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/vps-setup.sh)
```

Select mode 1 for the full stack or mode 2 for a remote-panel node. The script
prints connection information and the enabled transport parameters.

```bash
bash <(wget -qO- https://raw.githubusercontent.com/dimasavr2006/xray-vps-setup/refs/heads/main/uninstall.sh)
```

The legacy scripts retain their existing behavior. Cover layout:
[confluence-marzban-home](https://github.com/Jolymmiles/confluence-marzban-home).
