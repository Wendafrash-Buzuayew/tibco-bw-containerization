#!/usr/bin/env bash
# Extract a .substvar profile from a BW6/BWCE EAR and rewrite TIBCO DataDirect
# PostgreSQL JDBC settings (rejected by BWCE) to the standard PostgreSQL driver:
#
#   tibcosoftwareinc.jdbc.postgresql.PostgreSQLDriver      -> org.postgresql.Driver
#   jdbc:tibcosoftwareinc:postgresql://H:P;DatabaseName=DB -> jdbc:postgresql://H:P/DB
#
# The result is meant to be mounted at /<PROFILE>.substvar in the container
# (BWCE uses a /*.substvar file in preference to the one inside the EAR).
# It contains the profile's passwords: keep it out of Git (bwce/local/ is
# ignored) and load it into Kubernetes as a Secret.
#
# Usage: ./fix-profile.sh <app.ear> <PROFILE> <output.substvar> [--set NAME=VALUE ...]
#   e.g. ./fix-profile.sh apps/my-app/*.ear UAT local/my-app/UAT.substvar \
#          --set /Backend/Host=api.example.com
#
# --set overrides a property value. NAME is the property as shown in Studio
# (e.g. /TargetAPI/BigDataHost); it matches regardless of module prefix.
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[[ $# -ge 3 ]] || usage
ear="$1"; profile="${2%.substvar}"; out="$3"; shift 3
sets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --set) [[ $# -ge 2 && "$2" == *=* ]] || usage; sets+=("$2"); shift 2 ;;
    *) usage ;;
  esac
done

[[ -f "$ear" ]] || { echo "ERROR: EAR not found: $ear" >&2; exit 1; }
unzip -l "$ear" "META-INF/$profile.substvar" >/dev/null 2>&1 || {
  echo "ERROR: profile '$profile' not in EAR. Available:" >&2
  unzip -Z1 "$ear" | grep -E '^META-INF/.*\.substvar$' | sed 's#META-INF/##; s#\.substvar$##; s#^#  #' >&2
  exit 1
}

mkdir -p "$(dirname "$out")"
unzip -p "$ear" "META-INF/$profile.substvar" \
  | sed -E \
      -e 's#tibcosoftwareinc\.jdbc\.postgresql\.PostgreSQLDriver#org.postgresql.Driver#g' \
      -e 's#jdbc:tibcosoftwareinc:postgresql://([^;<]+);[Dd]atabase[Nn]ame=([^;<]+)[^<]*#jdbc:postgresql://\1/\2#g' \
  > "$out"
chmod 600 "$out" 2>/dev/null || true

# Apply --set overrides: replace the <value> following a matching <name>.
for kv in ${sets[@]+"${sets[@]}"}; do
  key="${kv%%=*}"; val="${kv#*=}"
  val="${val//&/&amp;}"; val="${val//</&lt;}"; val="${val//>/&gt;}"
  tmp="$out.tmp"
  KEY="$key" VAL="$val" awk '
    BEGIN { key = ENVIRON["KEY"]; val = ENVIRON["VAL"]; hit = 0; n = 0 }
    match($0, /<name>[^<]*<\/name>/) {
      name = substr($0, RSTART + 6, RLENGTH - 13)
      k = key; sub(/^\/+/, "", k)
      tail = name; sub(/^.*\/\/\/?/, "", tail)
      hit = (name == key || tail == k)
    }
    hit && /<value>/ {
      sub(/<value>[^<]*<\/value>/, "<value>" val "</value>"); hit = 0; n++
    }
    { print }
    END { if (n == 0) exit 3; printf "  set %s (%d match%s)\n", key, n, (n > 1 ? "es" : "") > "/dev/stderr" }
  ' "$out" > "$tmp" || { rc=$?; rm -f "$tmp" "$out"; [[ $rc -eq 3 ]] && echo "ERROR: property not found: $key (no output written)" >&2; exit 1; }
  mv "$tmp" "$out"
done

echo "Wrote $out. JDBC settings now:"
grep -oE '(org\.postgresql\.Driver|tibcosoftwareinc[^<]*|jdbc:[a-z]+:[^<]*)' "$out" | sort | uniq -c | sed 's/^/  /'
if grep -q tibcosoftwareinc "$out"; then
  echo "WARNING: some DataDirect settings remain (non-PostgreSQL database?). Check them manually." >&2
fi
