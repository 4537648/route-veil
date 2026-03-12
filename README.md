This project routes selected traffic through a tunnel on [Netcraze](https://netcraze.ru/) routers using [Entware](https://entware.net/).

## Installation
The installer requires [curl](https://curl.se/). If it is missing:

```shell
opkg install curl
```

Run the installer:

```shell
curl -sfL https://raw.githubusercontent.com/4537648/route-veil/main/install.sh | sh
```

The installer creates `/opt/etc/route-veil`, `/opt/etc/route-veil/sources`, downloads the working scripts, and creates these empty source files:
- `/opt/etc/route-veil/sources/ip.txt`
- `/opt/etc/route-veil/sources/domain.txt`
- `/opt/etc/route-veil/sources/domain-asn.txt`
- `/opt/etc/route-veil/sources/asn.txt`

These source files are not stored in the Git repository. They are created as empty files during installation and are intended to be filled locally on the router.

It also installs the required dependencies `bind-dig`, `cron`, `grep`, `ip-full`, `jq`, `python3`, creates a tunnel state hook, and adds a daily refresh job.

After installation:
- Edit `/opt/etc/route-veil/config` and set `IFACE`.
- Fill the files in `/opt/etc/route-veil/sources/`.
- Run `/opt/etc/route-veil/refresh.sh`.

## Upgrades

Automatic migration of local configuration and source files between incompatible project versions is not provided. When upgrading an existing installation, review your local files in `/opt/etc/route-veil/` and adapt or move them manually if file names, paths, or formats have changed.

To update the installed project code without removing local data, run:

```shell
/opt/etc/route-veil/upgrade.sh
```

`upgrade.sh` updates the project scripts, ensures the required packages are installed, recreates the hook and daily job symlinks, and restarts cron. It preserves:
- `/opt/etc/route-veil/config`
- `/opt/etc/route-veil/sources/*`
- `/opt/etc/route-veil/route-list.txt`
- `/opt/etc/route-veil/active-table`

### Example config

```shell
# Tunnel interface name from ifconfig or ip address show
IFACE="nwg0"

# Path to the generated route list
FILE="/opt/etc/route-veil/route-list.txt"

# Directory with source lists for builder.sh
SOURCE_DIR="/opt/etc/route-veil/sources"

# Incoming interface for policy routing. Leave empty to apply to all traffic.
RULE_IIF="br0"

# Active/staging routing tables
TABLE_PRIMARY="1000"
TABLE_SECONDARY="1001"
ACTIVE_TABLE_FILE="/opt/etc/route-veil/active-table"

# Minimum number of RIPEstat peers that must see the ASN prefix
MIN_PEERS_SEEING="10"
```

## Source files

`ip.txt`
- Contains IPv4 and IPv4 CIDR entries.
- These entries are copied into the final route set as-is.

Example:
```text
1.1.1.1
93.184.220.0/24
```

`domain.txt`
- Contains domains.
- Only the currently resolved IPv4 addresses of each domain are added to the final route set.

Example:
```text
example.com
api.example.com
```

`domain-asn.txt`
- Contains domains.
- For each domain: `domain -> IPv4 -> ASN -> prefixes -> strict aggregation`.

Example:
```text
quora.com
www.cloudflare.com
```

`asn.txt`
- Contains ASN values as either `13335` or `AS13335`.
- For each ASN: `ASN -> prefixes -> strict aggregation`.

Example:
```text
13335
AS15169
```

In all files:
- empty lines are ignored;
- lines starting with `#` are ignored.

## Building route list

`/opt/etc/route-veil/builder.sh` works as follows:

1. Reads the four input files from `SOURCE_DIR`.
2. Deduplicates each list independently.
3. `ip.txt`: adds IP/CIDR entries directly to the combined route list.
4. `domain.txt`: resolves domains to IPv4 and adds them to the combined route list.
5. `domain-asn.txt`: resolves domains to IPv4, deduplicates IPv4, resolves ASN via Team Cymru, fetches ASN prefixes from RIPEstat, and adds them to the combined route list.
6. `asn.txt`: normalizes ASN values, fetches their prefixes from RIPEstat, and adds them to the combined route list.
7. Performs a global deduplication of the combined route list.
8. Runs final strict CIDR aggregation.
9. Rebuilds `route-list.txt`.

Run it with:

```shell
/opt/etc/route-veil/builder.sh
```

During execution it prints short progress stages:
- reading source files;
- processing `domain.txt`;
- processing `domain-asn.txt`;
- resolving ASN for unique IPv4 from `domain-asn.txt`;
- fetching ASN IPv4 prefixes from RIPEstat;
- aggregating ASN prefixes;
- running final strict CIDR aggregation;
- printing the final summary.

`builder.sh` only rebuilds `/opt/etc/route-veil/route-list.txt`. To rebuild the route list and immediately apply it, use `refresh.sh`.

`route-list.txt` is a generated file. It is rebuilt by `builder.sh` and is not intended for manual editing. Update `sources/*` instead, then run `refresh.sh`.

## Routing tables

The project uses two routing tables:
- the active table currently used by policy routing;
- the staging table used to prepare the next route set.

By default these are tables `1000` and `1001`. The currently active table number is stored in `/opt/etc/route-veil/active-table`.

During `refresh.sh`:
- `builder.sh` rebuilds `route-list.txt`;
- `apply-routes.sh` populates the staging table from ready IPv4/CIDR entries in `route-list.txt`;
- only after a successful rebuild does the policy rule switch to the staging table;
- the previously active table is then cleared.

This keeps the old working route set in place until the new one is fully ready.

## Output file format

`route-list.txt` contains:
- a header with the generation timestamp;
- a note that the file is generated and should not be edited manually;
- per-stage statistics as `#` comments;
- source comments:
  - `# domain ...`
  - `# domain-asn ...`
  - `# explicit ASN`
- a final `# final routes` block with ready-to-use IPv4/CIDR entries.

Example statistics:

```text
# generated by /opt/etc/route-veil/builder.sh on 2026-03-09T12:34:56Z
# input ip total: 3
# input ip unique: 2
# input domain total: 4
# input domain unique: 3
# input domain-asn total: 2
# input domain-asn unique: 2
# input asn total: 2
# input asn unique: 2
# domain IPv4 total: 7
# domain IPv4 unique: 5
# domain-asn IPv4 total: 6
# domain-asn IPv4 unique: 4
# domain-asn ASN total: 5
# domain-asn ASN unique: 3
# combined ASN total: 5
# combined ASN unique: 4
# prefixes total: 420
# prefixes unique: 390
# routes raw total: 412
# routes raw unique: 398
# final routes total: 275
```

To rebuild the route list and immediately apply it manually:

```shell
/opt/etc/route-veil/refresh.sh
```

`refresh.sh` rebuilds `route-list.txt`, populates the staging table, switches the policy rule to it, updates `active-table`, and then clears the previously active table. `builder.sh` is the only component that resolves domains and ASNs; `apply-routes.sh` applies only ready IPv4/CIDR routes from `route-list.txt`. This makes `refresh.sh` suitable both for daily scheduled refreshes and for the first manual activation on a router where the tunnel is already up.

## Scheduled jobs

The installer creates:
- `/opt/etc/ndm/ifstatechanged.d/ip_rule_switch` -> `start-stop.sh`
- `/opt/etc/cron.daily/routing_table_update` -> `refresh.sh`

The daily job runs `refresh.sh` through the router's existing `run-parts` schedule for `/opt/etc/cron.daily`.

This means:
- `builder.sh` rebuilds `route-list.txt` from `sources/*`;
- `refresh.sh` populates the staging table and switches policy routing to it only after a successful update.

## Traffic scope

By default, policy routing is applied only to traffic entering through `Bridge0` (`br0`):

```shell
RULE_IIF="br0"
```

If you want route-veil to apply to all traffic, including traffic generated by the router itself, set `RULE_IIF` to an empty quoted value in `/opt/etc/route-veil/config`:

```shell
RULE_IIF=""
```

After changing `RULE_IIF`, run:

```shell
/opt/etc/route-veil/refresh.sh
```

or restart the tunnel connection so that the hook reapplies the policy rule with the new scope.

## Removal

Remove the project with:

```shell
/opt/etc/route-veil/uninstall.sh
```

This removes all downloaded and installer-created files, including `/opt/etc/route-veil/sources`, if it does not contain any unrelated files.
