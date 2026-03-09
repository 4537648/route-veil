#!/bin/sh

WORK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_FILE="${WORK_DIR}/asn_nets_temp.txt"

CONFIG="/opt/etc/route-veil/config"
if [ -f "$CONFIG" ]; then
  . "$CONFIG"
else
  printf "%s\n" "Failed to find file \"${CONFIG}\"." >&2
  exit 1
fi

for _tool in cat curl rm; do
  command -v "$_tool" >/dev/null 2>&1 || {
    printf "%s\n" "\"${_tool}\" is required to run this script." >&2
    exit 1
  }
done

rm -f "$TMP_FILE"
if [ -f "$LIST_ASN" ]; then
    echo "--- Start read ASN list from $LIST_ASN ---"
    while IFS= read -r ASN || [ -n "$ASN" ]; do
        [ -z "$ASN" ] && continue
        echo "GET data for '$ASN' to temp-file"
        curl "$ASN_SERVICE_URL/?asn=$ASN" --silent --retry 12 --retry-delay 5 >> "$TMP_FILE" || exit 1
    done < "$LIST_ASN"
    echo "--- Finish read ASN list from $LIST_ASN ---"
else
    echo "$LIST_ASN not found"
fi

cat "$LIST_STATIC" "$TMP_FILE" > "$FILE"
rm -f "$TMP_FILE"
echo "--- Static and ASN lists merged into $FILE ---"
