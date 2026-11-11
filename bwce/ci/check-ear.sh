#!/usr/bin/env bash
# Pre-build checks that catch, in seconds, problems that otherwise only show
# up at container start (see TROUBLESHOOTING.md):
#   - EAR not exported for BWCE (no "bwcf" edition)        -> "not supported in BWCE"
#   - profile missing from the EAR                          -> wrong BW_PROFILE
#   - a module uses JMS but the image isn't on the -ems base -> warning
#     (if those activities are initialised: all processes Unresolved)
#   - DataDirect JDBC driver in the profile (info: fix-profile.sh handles it)
#
# Usage: ./ci/check-ear.sh <app.ear> <PROFILE> <plain|ems>
set -euo pipefail

[[ $# -eq 3 ]] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
ear="$1"; profile="${2%.substvar}"; flavor="$3"
fail=0

edition="$(unzip -p "$ear" META-INF/MANIFEST.MF | tr -d '\r' | sed -n 's/^TIBCO-BW-Edition: *//p')"
if [[ "$edition" == *bwcf* ]]; then echo "OK   edition: $edition"
else echo "FAIL edition '$edition' has no bwcf: export the EAR from Business Studio for BWCE"; fail=1; fi

if unzip -l "$ear" "META-INF/$profile.substvar" >/dev/null 2>&1; then echo "OK   profile $profile present"
else
  echo "FAIL profile $profile not in EAR. Available:"
  unzip -Z1 "$ear" | sed -n 's#^META-INF/\(.*\)\.substvar$#       \1#p'; fail=1
fi

# Module jars at the EAR root; their manifests declare the palettes they use.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
jms_modules=()
while IFS= read -r jar; do
  unzip -p "$ear" "$jar" > "$tmp/m.jar"
  # Manifest lines wrap at 72 chars: join them before matching.
  if unzip -p "$tmp/m.jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r\n ' | grep -Ei 'bw\.jms|palette\.jms' >/dev/null; then
    jms_modules+=("$(basename "$jar" .jar)")
  fi
done < <(unzip -Z1 "$ear" | grep -E '^[^/]+\.jar$' || true)

if [[ ${#jms_modules[@]} -gt 0 ]]; then
  if [[ "$flavor" == ems ]]; then echo "OK   JMS used by: ${jms_modules[*]} (ems base)"
  else
    # Not a hard failure: an app can start if its flows never initialise the
    # JMS activities of a shared module. If they do, every process ends up
    # Unresolved (TROUBLESHOOTING.md). The -ems base is the safe choice.
    echo "WARN JMS used by: ${jms_modules[*]}, but BASE_FLAVOR=$flavor."
    echo "     If the app goes Impaired/Unresolved with 'Could not load EMS Client', set BASE_FLAVOR=ems."
  fi
else
  echo "OK   no JMS palette found in module manifests"
fi

if unzip -p "$ear" "META-INF/$profile.substvar" 2>/dev/null | grep tibcosoftwareinc >/dev/null; then
  echo "INFO DataDirect JDBC driver in $profile: fix-profile.sh rewrites it (deploy job does this)"
fi

exit "$fail"
