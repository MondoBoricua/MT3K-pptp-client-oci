# MT3K PPTP Client

MT3K PPTP Client is a small container that runs `pppd` as PID 1 and dials a PPTP server. The usual peer is the legacy PPTP server built into a home router (Tenda, TP-Link, and similar). After the tunnel comes up, the container installs only the CIDR routes you list.

**PPTP with MPPE is broken cryptography.** MS-CHAPv2 and MPPE are not a secure VPN. Use this client only on networks you already trust, or where a newer VPN is not available. For anything that needs real confidentiality, use WireGuard or another modern VPN.

The image is `ghcr.io/mondoboricua/mt3k-pptp-client`. It is built for `linux/amd64` and `linux/arm64` from Debian packages. No binaries are downloaded by hand.

## What the host must provide

`pppd` inside the container needs three things from the Proxmox (or Docker) host:

1. The host kernel modules `ppp_generic` and `ppp_mppe`. The `pptp` kernel module is not needed (the client uses userspace `pptp` over GRE, IP protocol 47). Load them on the host, not inside the container:

   ```sh
   modprobe ppp_generic
   modprobe ppp_mppe
   ```

2. The character device `/dev/ppp` passed into the container (`uid=0`, `gid=0`, `mode=0600`).
3. `CAP_NET_ADMIN` in the container. On an unprivileged LXC that already has `/dev/ppp`, that capability is enough to bring the tunnel up. The container does not need to be privileged.

GRE must be allowed on the path between this host and the PPTP server. Some ISPs and guest networks block IP protocol 47. When they do, `pppd` never finishes negotiation.

## Variables

| Variable | Required | Default | Meaning |
| --- | --- | --- | --- |
| `PPTP_SERVER` | yes | | Hostname or IPv4 of the PPTP server. |
| `PPTP_USER` | yes | | Username. Letters, digits, `.`, `_`, `@`, `+`, `-`. |
| `PPTP_PASS` | yes, unless `PPTP_PASS_FILE` is set | | Password. Never written into the image and never printed. |
| `PPTP_PASS_FILE` | no | | File with the password on one line. If the variable is set, this file wins over `PPTP_PASS`. |
| `PPTP_ROUTES` | no | empty | CIDRs to route through the tunnel, separated by commas or spaces. Empty means no extra routes. |
| `PPTP_DEFAULT_ROUTE` | no | `false` | `true` adds `defaultroute` and `replacedefaultroute`. |
| `PPTP_MPPE` | no | `required` | `required` (`require-mppe-128`), `optional` (negotiate), or `off` (`nomppe`). |
| `PPTP_MTU` | no | `1400` | MTU and MRU, from 576 to 1500. |
| `PPTP_PEER_NAME` | no | `mt3k-pptp` | `remotename` / `linkname` in the pppd options. |
| `PPTP_RETRY_MIN` | no | `30` | First retry delay, in seconds. |
| `PPTP_RETRY_MAX` | no | `300` | Ceiling of the exponential backoff, in seconds. |
| `PPTP_DNS` | no | `false` | `true` adds `usepeerdns`. |
| `PPTP_DEBUG` | no | `false` | `true` adds pppd `debug`. The entrypoint still does not print the password. |
| `PPTP_NET_WAIT` | no | `120` | Seconds to wait for DNS (or a default route, if `PPTP_SERVER` is an IPv4 address) before starting `pppd`. |

`pppd` exit codes that mean a bad password or a bad configuration (2, 3, 11, 19, and the immediately fatal 1, 4, and 9) do not retry. The process logs the code and repeats that message every 5 minutes until you stop the container. Link drops and negotiation failures retry with backoff from `PPTP_RETRY_MIN` up to `PPTP_RETRY_MAX`. `SIGTERM` stops `pppd` and exits 0.

Secrets are written at start to `/run/mt3k-pptp/` with mode `0600`. `pppd` reads CHAP secrets from `/etc/ppp/chap-secrets`, so that path is a symlink into `/run`. Nothing secret is copied into the image.

## Docker Compose

```yaml
name: mt3k-pptp-client
services:
  mt3k-pptp-client:
    image: ghcr.io/mondoboricua/mt3k-pptp-client:latest
    container_name: mt3k-pptp-client
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/ppp:/dev/ppp
    environment:
      PPTP_SERVER: vpn.example.com
      PPTP_USER: pptp-user
      PPTP_PASS: change-me
      PPTP_ROUTES: "192.0.2.0/24 198.51.100.0/24"
      PPTP_DEFAULT_ROUTE: "false"
      PPTP_MPPE: required
      PPTP_MTU: "1400"
    restart: unless-stopped
```

The file in the repository is the contract ProxMenux reads. Example addresses are documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `vpn.example.com`).

Check the configuration without touching the network:

```sh
PPTP_SERVER=vpn.example.com PPTP_USER=pptp-user PPTP_PASS=change-me \
  PPTP_ROUTES=192.0.2.0/24 \
  ./entrypoint.sh --check
```

The password is replaced with `********`.

## Proxmox LXC-OCI

Pull the image onto a template storage, then create an unprivileged container. `pct(1)` documents `--ostype unmanaged`, `--entrypoint`, `--dev[n]`, and `--env` (one NUL-separated `KEY=value` list that replaces `lxc.environment.runtime`). The example uses `printf` so those NULs are real separators.

```sh
pct create 9000 local:vztmpl/mt3k-pptp-client.tar \
  --ostype unmanaged \
  --unprivileged 1 \
  --hostname mt3k-pptp \
  --memory 256 --swap 128 --cores 1 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,host-managed=1 \
  --entrypoint /usr/local/bin/mt3k-pptp-entrypoint \
  --dev0 /dev/ppp,uid=0,gid=0,mode=0600 \
  --env "$(printf 'PPTP_SERVER=vpn.example.com\0PPTP_USER=pptp-user\0PPTP_PASS=change-me\0PPTP_ROUTES=192.0.2.0/24')"
```

Load `ppp_generic` and `ppp_mppe` on the Proxmox host before starting the container. Confirm that `/dev/ppp` exists on the host (`ls -l /dev/ppp`).

## ProxMenux

A catalog entry for the ProxMenux OCI catalog lives beside this image: category **Remote Access & VPN**, image `ghcr.io/mondoboricua/mt3k-pptp-client:latest`, no published ports, `/dev/ppp` as a required character device, and `NET_ADMIN`. The same security warning applies there: this is a legacy tunnel, not a secure VPN.

## Troubleshooting

**MTU.** If the tunnel connects and small pings work, but larger traffic stalls, lower `PPTP_MTU`. The default is 1400. Some DSL links need 1396 or less.

**GRE blocked.** PPTP encapsulates PPP in GRE (IP protocol 47) plus a TCP session to port 1723. If the log shows the TCP session and then negotiation never completes, the path is often dropping GRE. A home router in front of this host, or a filtered guest network, is a common cause.

**Host modules.** `pppd` exit 4 means the kernel has no PPP support. Load `ppp_generic` and `ppp_mppe` on the host and pass `/dev/ppp` through. Those modules cannot be loaded from an unprivileged container.

**`getaddrinfo` / name does not resolve.** The entrypoint waits up to `PPTP_NET_WAIT` seconds (default 120) before starting `pppd`. On a hostname it resolves `PPTP_SERVER` with `getent ahostsv4` (getaddrinfo). On a literal IPv4 address it waits until an IPv4 default route exists, because an address does not prove the link is up. If the wait expires, fix DNS or the container address and start again.

**Authentication.** Exit 19 means the server rejected the username or password. Exit 11 means the peer failed to authenticate to us. The client pauses instead of guessing again. Fix the credentials and recreate the container.

## Layout

- `entrypoint.sh` — PID 1, supervisor, and `--check`.
- `ip-up.sh` / `ip-down.sh` — installed as `/etc/ppp/ip-up.d/mt3k-pptp` and `ip-down.d/mt3k-pptp`. They read `/run/mt3k-pptp/routes`.
- `docker-compose.yml` — example and catalog contract.

## License

MIT. Copyright 2026 MT3K.
