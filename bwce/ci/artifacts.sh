#!/usr/bin/env bash
# Store / fetch binaries that must not be in Git (EARs, BWCE runtime zip, EMS
# client jars) in this GitLab project's Generic Package Registry. Access follows
# the project's permissions, and versions are kept, so every image can be
# rebuilt from exactly the EAR it was built from.
#
# Usage:
#   ./ci/artifacts.sh publish <package> <version> <local-file>
#   ./ci/artifacts.sh fetch   <package> <version> <file-name> <dest-dir>
#
# Examples (from bwce/):
#   ./ci/artifacts.sh publish my-app 1.0.0 ~/MyApp_1.0.0.ear
#   ./ci/artifacts.sh publish bwce-runtime 2.9.1 ~/bwce-runtime-2.9.1.zip
#   ./ci/artifacts.sh publish ems-client 10.1 /opt/tibco/ems/10.1/lib/tibjms.jar
#
# Auth: inside CI the job token is used. Outside CI export GITLAB_URL,
# GITLAB_PROJECT (url-encoded path) and GITLAB_TOKEN (api scope); never pass the token as an arg.
# Package name = IMAGE_NAME from apps/<app>/app.env, version = APP_VERSION.
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

api="${CI_API_V4_URL:-${GITLAB_URL:?export GITLAB_URL, e.g. https://gitlab.example.com}/api/v4}"
project="${CI_PROJECT_ID:-${GITLAB_PROJECT:?export GITLAB_PROJECT, e.g. group%2Fproject}}"
if [[ -n "${CI_JOB_TOKEN:-}" ]]; then auth=(--header "JOB-TOKEN: $CI_JOB_TOKEN")
elif [[ -n "${GITLAB_TOKEN:-}" ]]; then auth=(--header "PRIVATE-TOKEN: $GITLAB_TOKEN")
else echo "ERROR: export GITLAB_TOKEN first (outside CI)" >&2; exit 1; fi
base="$api/projects/$project/packages/generic"

check_archive() {   # a truncated transfer must fail here, not at container start
  case "$1" in
    *.ear|*.zip|*.jar)
      unzip -l "$1" >/dev/null 2>&1 || { echo "ERROR: $1 is not a valid archive (truncated?)" >&2; exit 1; } ;;
  esac
}

cmd="${1:-}"; shift || true
case "$cmd" in
  publish)
    [[ $# -eq 3 ]] || usage
    pkg="$1"; ver="$2"; file="$3"
    [[ -f "$file" ]] || { echo "ERROR: $file not found" >&2; exit 1; }
    check_archive "$file"
    name="$(basename "$file")"
    # Released versions are immutable: refuse to overwrite an existing file.
    if curl -sf -o /dev/null "${auth[@]}" -r 0-0 "$base/$pkg/$ver/$name"; then
      echo "ERROR: $pkg/$ver/$name already exists. Publish it under a new version." >&2; exit 1
    fi
    echo "Uploading $name ($(wc -c < "$file") bytes) -> $pkg/$ver"
    curl -sSf "${auth[@]}" --upload-file "$file" "$base/$pkg/$ver/$name" >/dev/null
    echo "sha256 $(sha256sum "$file" | cut -d' ' -f1)  $pkg/$ver/$name"
    ;;
  fetch)
    [[ $# -eq 4 ]] || usage
    pkg="$1"; ver="$2"; name="$3"; dest="$4"
    mkdir -p "$dest"
    echo "Fetching $pkg/$ver/$name"
    curl -sSfL "${auth[@]}" -o "$dest/$name" "$base/$pkg/$ver/$name" || {
      echo "ERROR: $pkg/$ver/$name not in the package registry. Publish it first:" >&2
      echo "  bwce/ci/artifacts.sh publish $pkg $ver /path/to/$name" >&2
      exit 1
    }
    check_archive "$dest/$name"
    echo "sha256 $(sha256sum "$dest/$name" | cut -d' ' -f1)  $name"
    ;;
  *) usage ;;
esac
