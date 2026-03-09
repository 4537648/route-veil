This project routes traffic for selected resources through a VPN tunnel on Netcraze routers using the [Entware](https://entware.net/) repository.

## Installation
The installation script requires [curl](https://curl.se/). If it is missing, install it with:

```shell
opkg install curl
```

To start the installation, run:

```shell
curl -sfL https://raw.githubusercontent.com/4537648/route-veil/main/install.sh | sh
```

The installer creates the `/opt/etc/route-veil` directory if it does not exist and places the required files there. It also creates two symlinks to monitor VPN tunnel state changes and refresh routes once a day. The `parser.sh` script requires `bind-dig`, `cron`, and `grep`; they will be installed if missing.

After installation, you need to:
- Edit `/opt/etc/route-veil/config` and set `IFACE` to the VPN interface name shown by `ip address show` or `ifconfig`, for example `ovpn_br0` (=`OpenVPN0`) or `nwg0` (=`Wireguard0`);
- Fill `/opt/etc/route-veil/route-veil-list.txt` with domains and/or IPv4 addresses of the resources whose traffic should go through the VPN. Prefixes are supported for IPv4 addresses;
- Start the VPN connection, or restart it if it was already running before installation.

### Example `config` values
For an OpenVPN tunnel:

```shell
# VPN tunnel interface name from ifconfig or ip address show
IFACE="ovpn_br0"

# Path to the file with addresses and domains
FILE="/opt/etc/route-veil/route-veil-list.txt"
```

For a WireGuard tunnel:

```shell
# VPN tunnel interface name from ifconfig or ip address show
IFACE="nwg0"

# Path to the file with addresses and domains
FILE="/opt/etc/route-veil/route-veil-list.txt"
```

### Example `route-veil-list.txt`
```
example.com
1.1.1.1
93.184.220.0/24
```

## ASN-Based List Generation
If you do not want to maintain `route-veil-list.txt` manually, you can generate it with `asn_parser.sh`.

The script uses three values from `config`:
- `ASN_SERVICE_URL`: the HTTP endpoint used to fetch subnet lists for an ASN;
- `LIST_ASN`: a file containing one ASN per line;
- `LIST_STATIC`: a file containing static domains, IPv4 addresses, or IPv4 prefixes that should always be included.

How it works:
- `asn_parser.sh` reads every ASN from `LIST_ASN`;
- for each ASN, it sends a request to `${ASN_SERVICE_URL}/?asn=<ASN>`;
- all returned networks are collected into a temporary file;
- the script concatenates `LIST_STATIC` and the fetched ASN networks into the final file defined by `FILE`;
- `parser.sh` then uses that generated file to populate routing table `1000`.

Example `config` entries for ASN mode:

```shell
FILE="/opt/etc/route-veil/route-veil-list.txt"
ASN_SERVICE_URL="https://asn-api.example.net"
LIST_ASN="/opt/etc/route-veil/list-asn.txt"
LIST_STATIC="/opt/etc/route-veil/list-static.txt"
```

Example `list-asn.txt`:

```text
AS15169
AS13335
```

Example `list-static.txt`:

```text
example.com
1.1.1.1
93.184.220.0/24
```

To rebuild the final routing list manually, run:

```shell
/opt/etc/route-veil/asn_parser.sh
```

## Note
By default, traffic is redirected only for devices in the "Home network" segment (`Bridge0`). Traffic generated directly on the router itself is not sent through the VPN tunnel. If you want all traffic, including the router's own traffic, to use the VPN, run these three commands:

```shell
ip rule del priority 1995 2>/dev/null
ip rule add table 1000 priority 1995
sed -i 's/iif br0 //' /opt/etc/route-veil/start-stop.sh
```

After that, traffic from all devices, including the router itself, will be redirected.

## Removal
To remove the project, run:

```shell
/opt/etc/route-veil/uninstall.sh
```

This removes **all** files downloaded and created by the installer, as well as the `/opt/etc/route-veil` directory if it does not contain any unrelated files.
