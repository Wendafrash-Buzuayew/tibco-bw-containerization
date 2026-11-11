#!/usr/bin/env bash
# Generate the app's profile from its EAR (fix-profile.sh + the committed
# overrides file) and apply it as the Kubernetes Secret the Helm values mount.
# The profile contains passwords: it only exists in a temp dir and in the Secret.
#
# Usage: ./ci/profile-secret.sh <app-dir-name> <namespace>
#   reads apps/<app>/app.env (IMAGE_NAME, APP_VERSION, EAR_FILE, PROFILE,
#   PROFILE_SECRET) and apps/<app>/profile-overrides-<profile lowercase>.txt
#   (one "/Property/Name=value" per line, # comments allowed)
set -euo pipefail

[[ $# -eq 2 ]] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
here="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"; ns="$2"
app_dir="$here/apps/$app"
set -a; . "$app_dir/app.env"; set +a

overrides="$app_dir/profile-overrides-$(echo "$PROFILE" | tr '[:upper:]' '[:lower:]').txt"
sets=()
if [[ -f "$overrides" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "${line// }" || "$line" == \#* ]] && continue
    sets+=(--set "$line")
  done < "$overrides"
fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
chmod 700 "$work"
"$here/ci/artifacts.sh" fetch "$IMAGE_NAME" "$APP_VERSION" "$EAR_FILE" "$work"
"$here/fix-profile.sh" "$work/$EAR_FILE" "$PROFILE" "$work/$PROFILE.substvar" ${sets[@]+"${sets[@]}"}

kubectl -n "$ns" create secret generic "$PROFILE_SECRET" \
  --from-file="$PROFILE.substvar=$work/$PROFILE.substvar" \
  --dry-run=client -o yaml \
  | kubectl -n "$ns" label --local -f - -o yaml app.kubernetes.io/managed-by=bwce-ci \
  | kubectl -n "$ns" apply -f -
echo "Secret $ns/$PROFILE_SECRET updated from $EAR_FILE ($(( ${#sets[@]} / 2 )) overrides)"
