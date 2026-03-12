#!/bin/sh

msg() {
  printf "%s\n" "$1"
}

IP_CIDR_ERE='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(/(3[0-2]|[12]?[0-9]))?$'

error_msg() {
  printf "[!] %s\n" "$1" >&2
}

log_info() {
  logger -t "route-veil/builder" "$1"
}

log_error() {
  logger -t "route-veil/builder" "Error: $1"
}

failure() {
  error_msg "$1"
  log_error "$1"
  exit 1
}

dedup_file() {
  src="$1"
  tmp="${src}.tmp"
  awk '
    {
      sub(/\r$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 != "") {
        print
      }
    }
  ' "$src" | sort -u > "$tmp" || return 1
  mv "$tmp" "$src"
}

count_file_lines() {
  awk '
    {
      sub(/\r$/, "")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "")
      if ($0 != "") {
        count++
      }
    }
    END {
      print count + 0
    }
  ' "$1"
}

check_ip() {
  printf "%s\n" "$1" | grep -qE "$IP_CIDR_ERE"
}

check_asn() {
  echo "$1" | grep -qE '^(AS)?[0-9]+$'
}

normalize_asn() {
  echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed 's/^AS//'
}

reverse_ip() {
  echo "$1" | awk -F. '{ print $4 "." $3 "." $2 "." $1 }'
}

resolve_domain() {
  dig +short A "$1" @localhost 2>/dev/null | \
  grep -P \
  '^((25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])\.){3}(25[0-5]|(2[0-4]|1[0-9]|[1-9]|)[0-9])$' | \
  sort -u
}

lookup_asn() {
  reverse="$(reverse_ip "$1")" || return 1
  dig +short TXT "${reverse}.origin.asn.cymru.com" @localhost 2>/dev/null | \
  awk -F'|' '
    {
      gsub(/"/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      split($1, items, /[[:space:]]+/)
      for (i in items) {
        if (items[i] ~ /^[0-9]+$/) {
          print items[i]
        }
      }
    }
  ' | \
  sort -u
}

fetch_prefixes() {
  curl -fsS \
    "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${1}&min_peers_seeing=${MIN_PEERS_SEEING}" | \
  jq -r '.data.prefixes[]?.prefix // empty' | \
  awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/([0-9]|[12][0-9]|3[0-2])$/ { print }
  '
}

aggregate_prefixes() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

networks = []

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    for raw_line in handle:
        line = raw_line.strip()
        if not line:
            continue
        networks.append(ipaddress.IPv4Network(line, strict=False))

collapsed = ipaddress.collapse_addresses(
    sorted(networks, key=lambda network: (int(network.network_address), network.prefixlen))
)

for network in collapsed:
    print(network.with_prefixlen)
PY
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG="/opt/etc/route-veil/config"
[ -f "$CONFIG" ] || failure "Could not find file \"config\"."
. "$CONFIG"

SOURCE_DIR="${SOURCE_DIR:-/opt/etc/route-veil/sources}"
MIN_PEERS_SEEING="${MIN_PEERS_SEEING:-10}"

for _tool in awk cp curl date dig grep jq mktemp mv python3 rm sed sort tr uniq; do
  command -v "$_tool" >/dev/null 2>&1 || \
  failure "\"${_tool}\" is required to run the script."
done

[ -n "$FILE" ] || failure "Output file path FILE is not set."
[ -d "$SOURCE_DIR" ] || failure "Directory \"${SOURCE_DIR}\" is missing."

TMPDIR_ROOT="${TMPDIR:-/tmp}"
WORKDIR="$(mktemp -d "${TMPDIR_ROOT}/builder.XXXXXX")" || \
failure "Failed to create a temporary directory."

cleanup() {
  rm -rf "$WORKDIR"
}

trap cleanup EXIT INT TERM QUIT HUP

INPUT_IP_FILE="${SOURCE_DIR}/ip.txt"
INPUT_DOMAIN_FILE="${SOURCE_DIR}/domain.txt"
INPUT_DOMAIN_ASN_FILE="${SOURCE_DIR}/domain-asn.txt"
INPUT_ASN_FILE="${SOURCE_DIR}/asn.txt"

COMMENTS_FILE="${WORKDIR}/comments.txt"
STATS_FILE="${WORKDIR}/stats.txt"

IP_RAW_FILE="${WORKDIR}/input-ip-raw.txt"
IP_FILE="${WORKDIR}/input-ip.txt"
DOMAIN_RAW_FILE="${WORKDIR}/input-domain-raw.txt"
DOMAIN_FILE="${WORKDIR}/input-domain.txt"
DOMAIN_ASN_RAW_FILE="${WORKDIR}/input-domain-asn-raw.txt"
DOMAIN_ASN_FILE="${WORKDIR}/input-domain-asn.txt"
EXPLICIT_ASN_RAW_FILE="${WORKDIR}/input-asn-raw.txt"
EXPLICIT_ASN_FILE="${WORKDIR}/input-asn.txt"

DOMAIN_RESULTS_FILE="${WORKDIR}/domain-results.txt"
DOMAIN_UNRESOLVED_FILE="${WORKDIR}/domain-unresolved.txt"
DOMAIN_ASN_RESULTS_FILE="${WORKDIR}/domain-asn-results.txt"
DOMAIN_ASN_UNRESOLVED_FILE="${WORKDIR}/domain-asn-unresolved.txt"

DOMAIN_ASN_IPV4_FILE="${WORKDIR}/domain-asn-ipv4.txt"
DOMAIN_ASN_IP_ASN_FILE="${WORKDIR}/domain-asn-ip-asn.txt"
DOMAIN_ASN_ASN_FILE="${WORKDIR}/domain-asn-asn.txt"
ALL_ASN_RAW_FILE="${WORKDIR}/all-asn-raw.txt"
ALL_ASN_FILE="${WORKDIR}/all-asn.txt"
PREFIXES_RAW_FILE="${WORKDIR}/prefixes-raw.txt"
PREFIXES_FILE="${WORKDIR}/prefixes.txt"
ROUTES_RAW_FILE="${WORKDIR}/routes-raw.txt"
ROUTES_FINAL_FILE="${WORKDIR}/routes-final.txt"
OUTPUT_FILE="${WORKDIR}/route-list.txt"

touch \
  "$COMMENTS_FILE" "$STATS_FILE" \
  "$IP_RAW_FILE" "$IP_FILE" \
  "$DOMAIN_RAW_FILE" "$DOMAIN_FILE" \
  "$DOMAIN_ASN_RAW_FILE" "$DOMAIN_ASN_FILE" \
  "$EXPLICIT_ASN_RAW_FILE" "$EXPLICIT_ASN_FILE" \
  "$DOMAIN_RESULTS_FILE" "$DOMAIN_UNRESOLVED_FILE" \
  "$DOMAIN_ASN_RESULTS_FILE" "$DOMAIN_ASN_UNRESOLVED_FILE" \
  "$DOMAIN_ASN_IPV4_FILE" "$DOMAIN_ASN_IP_ASN_FILE" "$DOMAIN_ASN_ASN_FILE" \
  "$ALL_ASN_RAW_FILE" "$ALL_ASN_FILE" \
  "$PREFIXES_RAW_FILE" "$PREFIXES_FILE" \
  "$ROUTES_RAW_FILE" "$ROUTES_FINAL_FILE" "$OUTPUT_FILE" || \
failure "Failed to prepare temporary files."

msg "Reading source files from \"${SOURCE_DIR}\"..."
log_info "Route list rebuild started."

if [ -f "$INPUT_IP_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [ "${line#\#}" != "$line" ] && continue
    check_ip "$line" && printf "%s\n" "$line" >> "$IP_RAW_FILE"
  done < "$INPUT_IP_FILE"
fi

if [ -f "$INPUT_DOMAIN_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [ "${line#\#}" != "$line" ] && continue
    printf "%s\n" "$line" >> "$DOMAIN_RAW_FILE"
  done < "$INPUT_DOMAIN_FILE"
fi

if [ -f "$INPUT_DOMAIN_ASN_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [ "${line#\#}" != "$line" ] && continue
    printf "%s\n" "$line" >> "$DOMAIN_ASN_RAW_FILE"
  done < "$INPUT_DOMAIN_ASN_FILE"
fi

if [ -f "$INPUT_ASN_FILE" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    [ "${line#\#}" != "$line" ] && continue
    if check_asn "$line"; then
      normalize_asn "$line" >> "$EXPLICIT_ASN_RAW_FILE"
    fi
  done < "$INPUT_ASN_FILE"
fi

input_ip_total="$(count_file_lines "$IP_RAW_FILE")"
input_domain_total="$(count_file_lines "$DOMAIN_RAW_FILE")"
input_domain_asn_total="$(count_file_lines "$DOMAIN_ASN_RAW_FILE")"
input_asn_total="$(count_file_lines "$EXPLICIT_ASN_RAW_FILE")"

cp "$IP_RAW_FILE" "$IP_FILE"
cp "$DOMAIN_RAW_FILE" "$DOMAIN_FILE"
cp "$DOMAIN_ASN_RAW_FILE" "$DOMAIN_ASN_FILE"
cp "$EXPLICIT_ASN_RAW_FILE" "$EXPLICIT_ASN_FILE"

dedup_file "$IP_FILE" || failure "Failed to process the IP/CIDR list."
dedup_file "$DOMAIN_FILE" || failure "Failed to process the domain list."
dedup_file "$DOMAIN_ASN_FILE" || failure "Failed to process the domain-asn list."
dedup_file "$EXPLICIT_ASN_FILE" || failure "Failed to process the ASN list."

input_ip_unique="$(count_file_lines "$IP_FILE")"
input_domain_unique="$(count_file_lines "$DOMAIN_FILE")"
input_domain_asn_unique="$(count_file_lines "$DOMAIN_ASN_FILE")"
input_asn_unique="$(count_file_lines "$EXPLICIT_ASN_FILE")"

if [ -s "$IP_FILE" ]; then
  cat "$IP_FILE" >> "$ROUTES_RAW_FILE"
fi

if [ -s "$DOMAIN_FILE" ]; then
  msg "Processing domains from domain.txt..."
  while IFS= read -r domain || [ -n "$domain" ]; do
    [ -z "$domain" ] && continue
    resolved_ips="$(resolve_domain "$domain")"
    if [ -z "$resolved_ips" ]; then
      printf "%s\n" "$domain" >> "$DOMAIN_UNRESOLVED_FILE"
      continue
    fi
    for ip in $resolved_ips; do
      printf "%s\t%s\n" "$domain" "$ip" >> "$DOMAIN_RESULTS_FILE"
      printf "%s\n" "$ip" >> "$ROUTES_RAW_FILE"
    done
  done < "$DOMAIN_FILE"
fi

domain_ipv4_total="$(count_file_lines "$DOMAIN_RESULTS_FILE")"

if [ -s "$DOMAIN_ASN_FILE" ]; then
  msg "Processing domains from domain-asn.txt..."
  while IFS= read -r domain || [ -n "$domain" ]; do
    [ -z "$domain" ] && continue
    resolved_ips="$(resolve_domain "$domain")"
    if [ -z "$resolved_ips" ]; then
      printf "%s\n" "$domain" >> "$DOMAIN_ASN_UNRESOLVED_FILE"
      continue
    fi
    for ip in $resolved_ips; do
      printf "%s\t%s\n" "$domain" "$ip" >> "$DOMAIN_ASN_RESULTS_FILE"
      printf "%s\n" "$ip" >> "$DOMAIN_ASN_IPV4_FILE"
    done
  done < "$DOMAIN_ASN_FILE"
fi

domain_asn_ipv4_total="$(count_file_lines "$DOMAIN_ASN_RESULTS_FILE")"
dedup_file "$DOMAIN_ASN_IPV4_FILE" || failure "Failed to process the IPv4 list for domain-asn."
domain_ipv4_unique="$(awk -F'\t' 'NF >= 2 { print $2 }' "$DOMAIN_RESULTS_FILE" | sort -u | awk 'END { print NR + 0 }')"
domain_asn_ipv4_unique="$(count_file_lines "$DOMAIN_ASN_IPV4_FILE")"

if [ -s "$DOMAIN_ASN_IPV4_FILE" ]; then
  msg "Resolving ASN for unique IPv4 entries from domain-asn.txt..."
  while IFS= read -r ip || [ -n "$ip" ]; do
    [ -z "$ip" ] && continue
    ip_asns="$(lookup_asn "$ip")"
    [ -n "$ip_asns" ] || continue
    for asn in $ip_asns; do
      printf "%s\t%s\n" "$ip" "$asn" >> "$DOMAIN_ASN_IP_ASN_FILE"
      printf "%s\n" "$asn" >> "$DOMAIN_ASN_ASN_FILE"
      printf "%s\n" "$asn" >> "$ALL_ASN_RAW_FILE"
    done
  done < "$DOMAIN_ASN_IPV4_FILE"
fi

domain_asn_asn_total="$(count_file_lines "$DOMAIN_ASN_IP_ASN_FILE")"
dedup_file "$DOMAIN_ASN_IP_ASN_FILE" || failure "Failed to process the IPv4 -> ASN mapping."
dedup_file "$DOMAIN_ASN_ASN_FILE" || failure "Failed to process ASN entries for domain-asn."
domain_asn_asn_unique="$(count_file_lines "$DOMAIN_ASN_ASN_FILE")"

if [ -s "$EXPLICIT_ASN_FILE" ]; then
  cat "$EXPLICIT_ASN_FILE" >> "$ALL_ASN_RAW_FILE"
fi

combined_asn_total="$(count_file_lines "$ALL_ASN_RAW_FILE")"
cp "$ALL_ASN_RAW_FILE" "$ALL_ASN_FILE"
dedup_file "$ALL_ASN_FILE" || failure "Failed to process the combined ASN list."
combined_asn_unique="$(count_file_lines "$ALL_ASN_FILE")"

if [ -s "$ALL_ASN_FILE" ]; then
  msg "Fetching ASN IPv4 prefixes from RIPEstat..."
  while IFS= read -r asn || [ -n "$asn" ]; do
    [ -z "$asn" ] && continue
    fetch_prefixes "$asn" >> "$PREFIXES_RAW_FILE" || \
    error_msg "Failed to fetch prefixes for AS${asn}."
  done < "$ALL_ASN_FILE"
fi

prefixes_total="$(count_file_lines "$PREFIXES_RAW_FILE")"
cp "$PREFIXES_RAW_FILE" "$PREFIXES_FILE"
dedup_file "$PREFIXES_FILE" || failure "Failed to process the prefix list."
prefixes_unique="$(count_file_lines "$PREFIXES_FILE")"

if [ -s "$PREFIXES_FILE" ]; then
  msg "Aggregating ASN prefixes..."
  aggregate_prefixes "$PREFIXES_FILE" >> "$ROUTES_RAW_FILE" || \
  failure "Failed to aggregate ASN prefixes."
fi

raw_routes_total="$(count_file_lines "$ROUTES_RAW_FILE")"
dedup_file "$ROUTES_RAW_FILE" || failure "Failed to process the combined route list."
raw_routes_unique="$(count_file_lines "$ROUTES_RAW_FILE")"

if [ -s "$ROUTES_RAW_FILE" ]; then
  msg "Running final strict CIDR aggregation..."
  aggregate_prefixes "$ROUTES_RAW_FILE" > "$ROUTES_FINAL_FILE" || \
  failure "Failed to run final strict aggregation."
fi

final_routes_total="$(count_file_lines "$ROUTES_FINAL_FILE")"

if [ -s "$DOMAIN_FILE" ] || [ -s "$DOMAIN_ASN_FILE" ]; then
  msg "Building source comments..."
fi

while IFS= read -r domain || [ -n "$domain" ]; do
  [ -z "$domain" ] && continue
  printf "# domain %s\n" "$domain" >> "$COMMENTS_FILE"
  if grep -Fxq "$domain" "$DOMAIN_UNRESOLVED_FILE"; then
    printf "# unresolved\n" >> "$COMMENTS_FILE"
    continue
  fi
  awk -F'\t' -v target_domain="$domain" '
    $1 == target_domain {
      print "# resolved IPv4: " $2
    }
  ' "$DOMAIN_RESULTS_FILE" >> "$COMMENTS_FILE"
done < "$DOMAIN_FILE"

if [ -s "$COMMENTS_FILE" ] && [ -s "$DOMAIN_ASN_FILE" ]; then
  printf "\n" >> "$COMMENTS_FILE"
fi

if [ -s "$DOMAIN_ASN_FILE" ]; then
  current_domain=""
  domain_asn_file=""

  while IFS="$(printf '\t')" read -r domain ip || [ -n "$domain" ] || [ -n "$ip" ]; do
    [ -n "$domain" ] || continue
    [ -n "$ip" ] || continue
    if [ "$domain" != "$current_domain" ]; then
      if [ -n "$domain_asn_file" ] && [ -s "$domain_asn_file" ]; then
        dedup_file "$domain_asn_file" || failure "Failed to process ASN entries for domain \"${current_domain}\"."
      fi
      current_domain="$domain"
      domain_asn_file="${WORKDIR}/$(echo "$domain" | tr -c 'A-Za-z0-9._-' '_').domain-asn"
      : > "$domain_asn_file"
    fi

    awk -F'\t' -v target_ip="$ip" '
      $1 == target_ip {
        print $2
      }
    ' "$DOMAIN_ASN_IP_ASN_FILE" >> "$domain_asn_file"
  done < "$DOMAIN_ASN_RESULTS_FILE"

  if [ -n "$domain_asn_file" ] && [ -s "$domain_asn_file" ]; then
    dedup_file "$domain_asn_file" || failure "Failed to process ASN entries for domain \"${current_domain}\"."
  fi

  while IFS= read -r domain || [ -n "$domain" ]; do
    [ -z "$domain" ] && continue
    printf "# domain-asn %s\n" "$domain" >> "$COMMENTS_FILE"
    if grep -Fxq "$domain" "$DOMAIN_ASN_UNRESOLVED_FILE"; then
      printf "# unresolved\n" >> "$COMMENTS_FILE"
      continue
    fi

    awk -F'\t' -v target_domain="$domain" '
      $1 == target_domain {
        print "# resolved IPv4: " $2
      }
    ' "$DOMAIN_ASN_RESULTS_FILE" >> "$COMMENTS_FILE"

    domain_asn_file="${WORKDIR}/$(echo "$domain" | tr -c 'A-Za-z0-9._-' '_').domain-asn"
    if [ -s "$domain_asn_file" ]; then
      printf "# ASNs:" >> "$COMMENTS_FILE"
      while IFS= read -r asn || [ -n "$asn" ]; do
        [ -z "$asn" ] && continue
        printf " AS%s" "$asn" >> "$COMMENTS_FILE"
      done < "$domain_asn_file"
      printf "\n" >> "$COMMENTS_FILE"
    else
      printf "# ASN lookup failed\n" >> "$COMMENTS_FILE"
    fi
  done < "$DOMAIN_ASN_FILE"
fi

if [ -s "$COMMENTS_FILE" ] && [ -s "$EXPLICIT_ASN_FILE" ]; then
  printf "\n" >> "$COMMENTS_FILE"
fi

if [ -s "$EXPLICIT_ASN_FILE" ]; then
  printf "# explicit ASN\n" >> "$COMMENTS_FILE"
  while IFS= read -r asn || [ -n "$asn" ]; do
    [ -z "$asn" ] && continue
    printf "# AS%s\n" "$asn" >> "$COMMENTS_FILE"
  done < "$EXPLICIT_ASN_FILE"
fi

{
  printf "# input ip total: %s\n" "$input_ip_total"
  printf "# input ip unique: %s\n" "$input_ip_unique"
  printf "# input domain total: %s\n" "$input_domain_total"
  printf "# input domain unique: %s\n" "$input_domain_unique"
  printf "# input domain-asn total: %s\n" "$input_domain_asn_total"
  printf "# input domain-asn unique: %s\n" "$input_domain_asn_unique"
  printf "# input asn total: %s\n" "$input_asn_total"
  printf "# input asn unique: %s\n" "$input_asn_unique"
  printf "# domain IPv4 total: %s\n" "$domain_ipv4_total"
  printf "# domain IPv4 unique: %s\n" "$domain_ipv4_unique"
  printf "# domain-asn IPv4 total: %s\n" "$domain_asn_ipv4_total"
  printf "# domain-asn IPv4 unique: %s\n" "$domain_asn_ipv4_unique"
  printf "# domain-asn ASN total: %s\n" "$domain_asn_asn_total"
  printf "# domain-asn ASN unique: %s\n" "$domain_asn_asn_unique"
  printf "# combined ASN total: %s\n" "$combined_asn_total"
  printf "# combined ASN unique: %s\n" "$combined_asn_unique"
  printf "# prefixes total: %s\n" "$prefixes_total"
  printf "# prefixes unique: %s\n" "$prefixes_unique"
  printf "# routes raw total: %s\n" "$raw_routes_total"
  printf "# routes raw unique: %s\n" "$raw_routes_unique"
  printf "# final routes total: %s\n" "$final_routes_total"
} > "$STATS_FILE" || failure "Failed to prepare statistics."

timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"

{
  printf "# generated by %s on %s\n" "/opt/etc/route-veil/builder.sh" "$timestamp"
  printf "# generated file, do not edit manually\n"
  printf "# edit files in sources/ and rebuild with refresh.sh\n"

  printf "\n"
  cat "$STATS_FILE"

  if [ -s "$COMMENTS_FILE" ]; then
    printf "\n"
    cat "$COMMENTS_FILE"
  fi

  printf "\n# final routes\n"
  cat "$ROUTES_FINAL_FILE"
} > "$OUTPUT_FILE" || failure "Failed to prepare the output file."

mv "$OUTPUT_FILE" "$FILE" || failure "Failed to update file \"${FILE}\"."

msg "Done."
msg "Input IP entries: ${input_ip_total}, unique: ${input_ip_unique}"
msg "Input domain entries: ${input_domain_total}, unique: ${input_domain_unique}"
msg "Input domain-asn entries: ${input_domain_asn_total}, unique: ${input_domain_asn_unique}"
msg "Input ASN entries: ${input_asn_total}, unique: ${input_asn_unique}"
msg "domain IPv4: ${domain_ipv4_total}, unique: ${domain_ipv4_unique}"
msg "domain-asn IPv4: ${domain_asn_ipv4_total}, unique: ${domain_asn_ipv4_unique}"
msg "domain-asn ASN mappings: ${domain_asn_asn_total}, unique ASN: ${domain_asn_asn_unique}"
msg "Combined ASN entries: ${combined_asn_total}, unique: ${combined_asn_unique}"
msg "Prefixes: ${prefixes_total}, unique: ${prefixes_unique}"
msg "Routes before final aggregation: ${raw_routes_total}, unique: ${raw_routes_unique}"
msg "Final routes: ${final_routes_total}"
msg "Result written to \"${FILE}\"."
log_info "Route list rebuilt successfully: ${final_routes_total} route(s) written to \"${FILE}\"."

exit 0
