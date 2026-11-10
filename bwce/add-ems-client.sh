#!/usr/bin/env bash
# Build an EMS-enabled BWCE base image: the equivalent of BW6's
# "bwinstall ems-driver" for a container.
#
# The BWCE runtime ships empty placeholder bundles for the EMS client
# (system/shared/com.tibco.jms.jmsclient*_<ver>/ with only a MANIFEST.MF).
# Apps that use JMS fail with a NullPointerException in the JMS activity
# until the client jars are put INSIDE those bundle folders. Dropping them in
# /resources/addons/jars does not work: they land in hotfix/shared as non-OSGi
# jars ("Found a duplicate bundle within the same folder").
#
# This script copies the runtime zip out of <base-image> and fills the
# placeholder bundles from <ems-lib-dir>: tibjms.jar -> jmsclient,
# tibjmsadmin.jar -> jmsclient.admin, tibjmsufo.jar -> jmsclient.ufo. The
# BWCE 2.9 placeholders have no Bundle-ClassPath, so the jar's classes are
# unpacked into the bundle root (TIBCO's MANIFEST.MF is kept). It then builds
# <new-tag> on top of <base-image> with the patched zip. No TIBCO script is
# modified.
#
# Usage: ./add-ems-client.sh <base-image> <ems-lib-dir> <new-tag>
#   e.g. ./add-ems-client.sh registry.example.com/tibco/bwce-base:2.9.1 \
#          local/ems-lib bwce-base:2.9.1-ems
#
# <ems-lib-dir> holds the jars from <EMS_HOME>/lib (e.g. /opt/tibco/ems/10.1/lib):
# tibjms.jar is required, tibjmsadmin.jar and tibjmsufo.jar are added if present.
# The JMS API (jakarta.jms-api 2.0.3) is already in the runtime; jms-2.0.jar
# is not needed.
#
# Needs docker, unzip and either python3 or zip on the build host.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
[[ $# -eq 3 ]] || usage
base="$1"; libdir="$2"; tag="$3"
[[ -f "$libdir/tibjms.jar" ]] || { echo "ERROR: $libdir/tibjms.jar not found" >&2; exit 1; }

if command -v python3 >/dev/null 2>&1; then
  add_to_zip() {  # <zip> <file> <entry-name>
    python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "a", zipfile.ZIP_DEFLATED) as z: z.write(sys.argv[2], sys.argv[3])' "$1" "$2" "$3"
  }
elif command -v zip >/dev/null 2>&1; then
  add_to_zip() {
    local stage; stage="$(mktemp -d "$work/stage.XXXX")"
    mkdir -p "$stage/$(dirname "$3")"; cp "$2" "$stage/$3"
    (cd "$stage" && zip -q "$1" "$3"); rm -rf "$stage"
  }
else
  echo "ERROR: need python3 or zip on this host to update the runtime zip" >&2; exit 1
fi

# Work under bwce/local (gitignored, usually on the big data disk), not /tmp.
mkdir -p "$here/local"
work="$(mktemp -d "$here/local/ems-build.XXXXXX")"
trap 'rm -rf "$work"' EXIT

echo "Copying runtime zip out of $base"
cid="$(docker create "$base")"
docker cp "$cid:/resources/bwce-runtime/." "$work/rt" >/dev/null
docker rm "$cid" >/dev/null
shopt -s nullglob; zips=("$work"/rt/bwce*.zip); shopt -u nullglob
[[ ${#zips[@]} -eq 1 ]] || { echo "ERROR: expected one bwce*.zip in $base:/resources/bwce-runtime, found ${#zips[@]}" >&2; exit 1; }
zip_path="$(cd "$(dirname "${zips[0]}")" && pwd)/$(basename "${zips[0]}")"

manifests="$(unzip -Z1 "$zip_path" | grep -E '^tibco\.home/[^/]+/[^/]+/system/shared/com\.tibco\.jms\.jmsclient[^/]*_[0-9][^/]*/META-INF/MANIFEST\.MF$' || true)"
[[ -n "$manifests" ]] || { echo "ERROR: no com.tibco.jms.jmsclient placeholder bundles in the runtime zip" >&2; exit 1; }

# Unpack <jar>'s classes into <bundle_dir>/ in the zip, keeping the bundle's
# own META-INF/MANIFEST.MF (the jar's manifest and signatures are skipped).
# Prints the number of files added.
if command -v python3 >/dev/null 2>&1; then
  explode_into_zip() {  # <zip> <jar> <bundle_dir>
    python3 - "$1" "$2" "$3" <<'PY'
import sys, zipfile, re
zpath, jar, bdir = sys.argv[1:4]
skip = re.compile(r'^META-INF/(MANIFEST\.MF|INDEX\.LIST|[^/]+\.(SF|RSA|DSA))$', re.I)
with zipfile.ZipFile(zpath, "a", zipfile.ZIP_DEFLATED) as z, zipfile.ZipFile(jar) as j:
    have = set(z.namelist()); n = 0
    for e in j.infolist():
        if e.is_dir() or skip.match(e.filename): continue
        name = bdir + "/" + e.filename
        if name in have: continue
        z.writestr(name, j.read(e)); n += 1
print(n)
PY
  }
else
  explode_into_zip() {
    local stage; stage="$(mktemp -d "$work/x.XXXX")"
    unzip -q -o "$2" -d "$stage/$3" -x 'META-INF/MANIFEST.MF' 'META-INF/*.SF' 'META-INF/*.RSA' 'META-INF/*.DSA' 'META-INF/INDEX.LIST'
    (cd "$stage" && zip -q -r "$1" "$3" && find "$3" -type f | wc -l)
    rm -rf "$stage"
  }
fi

# Placeholder bundle -> EMS client jar that provides its packages.
jar_for_bundle() {
  case "$1" in
    */com.tibco.jms.jmsclient_*)       echo tibjms.jar ;;
    */com.tibco.jms.jmsclient.admin_*) echo tibjmsadmin.jar ;;
    */com.tibco.jms.jmsclient.ufo_*)   echo tibjmsufo.jar ;;
    *) echo "" ;;
  esac
}

added=0
while IFS= read -r mf; do
  bundle_dir="${mf%/META-INF/MANIFEST.MF}"
  # Bundle-ClassPath may wrap onto continuation lines (leading space).
  cp_list="$(unzip -p "$zip_path" "$mf" | tr -d '\r' \
    | awk '/^ /{sub(/^ /,""); buf=buf $0; next} {if (buf!="") print buf; buf=$0} END{print buf}' \
    | sed -n 's/^Bundle-ClassPath: *//p')"
  jars=()
  for entry in ${cp_list//,/ }; do entry="${entry%%;*}"; [[ "$entry" == *.jar ]] && jars+=("$entry"); done

  if [[ ${#jars[@]} -gt 0 ]]; then
    # Bundle expects the jar(s) inside it, at the Bundle-ClassPath entries.
    for entry in "${jars[@]}"; do
      name="$(basename "$entry")"
      if unzip -l "$zip_path" "$bundle_dir/$entry" >/dev/null 2>&1; then
        echo "  already present: $bundle_dir/$entry"; added=$((added + 1))
      elif [[ -f "$libdir/$name" ]]; then
        add_to_zip "$zip_path" "$libdir/$name" "$bundle_dir/$entry"
        echo "  added $name -> $bundle_dir/$entry"; added=$((added + 1))
      elif [[ "$name" == tibjms.jar ]]; then
        echo "ERROR: $bundle_dir needs $name, not found in $libdir" >&2; exit 1
      else
        echo "  WARNING: $bundle_dir wants $name, not in $libdir (skipped)" >&2
      fi
    done
  else
    # No Bundle-ClassPath (BWCE 2.9 placeholders): classes go in the bundle root.
    name="$(jar_for_bundle "$bundle_dir")"
    [[ -n "$name" ]] || { echo "  WARNING: don't know which jar fills $bundle_dir (skipped)" >&2; continue; }
    # Note: no "grep -q" after unzip anywhere here. grep -q exits on the first
    # match, unzip gets SIGPIPE, and with pipefail the match reads as failure.
    if unzip -Z1 "$zip_path" | grep "^$bundle_dir/com/" >/dev/null; then
      echo "  already present: classes in $bundle_dir"; added=$((added + 1))
    elif [[ -f "$libdir/$name" ]]; then
      n="$(explode_into_zip "$zip_path" "$libdir/$name" "$bundle_dir")"
      echo "  unpacked $name ($n files) -> $bundle_dir/"; added=$((added + 1))
    elif [[ "$name" == tibjms.jar ]]; then
      echo "ERROR: $bundle_dir needs $name, not found in $libdir" >&2; exit 1
    else
      echo "  WARNING: $bundle_dir needs $name, not in $libdir (skipped)" >&2
    fi
  fi
done <<< "$manifests"
[[ $added -gt 0 ]] || { echo "ERROR: no EMS client classes were added; check $libdir and the bundle layout above" >&2; exit 1; }
unzip -Z1 "$zip_path" | grep -E '/com\.tibco\.jms\.jmsclient_[^/]+/(com/tibco/tibjms/TibjmsConnectionFactory\.class|.*\.jar)$' >/dev/null \
  || { echo "ERROR: com.tibco.tibjms classes not found in the jmsclient bundle after patching" >&2; exit 1; }

chmod 644 "$zip_path"
cat > "$work/rt/Dockerfile" <<EOF
FROM $base
COPY $(basename "$zip_path") /resources/bwce-runtime/
EOF
docker build -t "$tag" "$work/rt"
echo "Built $tag (EMS client added). Use it as the base for JMS apps:"
echo "  ./build.sh app apps/<app> $tag <app-tag>"
