#!/usr/bin/env bash
# Build the BWCE base image and, optionally, an application image on top of it.
#
# Must run on a Linux Docker host (or Docker Desktop / CI runner with Linux
# containers). Windows Server 2019 Docker cannot build these images.
#
# Usage:
#   ./build.sh base <path/to/bwce-runtime-6.x.x.zip> <base-image-tag>
#   ./build.sh app  <app-dir> <base-image-tag> <app-image-tag>
#
# Examples:
#   ./build.sh base ~/Downloads/bwce-runtime-6.12.0.zip registry.example.com/tibco/bwce-base:6.12.0
#   ./build.sh app  apps/http-sample registry.example.com/tibco/bwce-base:6.12.0 \
#                   registry.example.com/tibco/http-sample:1.0.0
#
# The base directory is chosen from the version in the zip name:
#   BWCE 6.12+       -> base/      (TIBCO bwce-docker master)
#   BWCE 2.7.0-2.9.x -> base-2.7/  (TIBCO bwce-docker branch 2.7.0)
#
# Optional env for "base" (BWCE 6.12+ only):
#   EXCLUDE_GOVERNANCE=true|false, EXCLUDE_CONFIG_MANAGEMENT=true|false,
#   EXCLUDE_JDBC=true|false  (strip unused runtime features to shrink the image)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# Forward corporate proxy settings from the shell into the build so apt-get
# inside the image can reach the Debian mirrors. Docker accepts these as
# predefined build args without a matching ARG in the Dockerfile.
proxy_args=()
for v in HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
  if [[ -n "${!v:-}" ]]; then proxy_args+=(--build-arg "$v=${!v}"); fi
done
if [[ ${#proxy_args[@]} -gt 0 ]]; then echo "Using proxy settings from environment for the build"; fi

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  base)
    [[ $# -eq 2 ]] || usage
    zip="$1"; tag="$2"
    [[ -f "$zip" ]] || { echo "ERROR: runtime zip not found: $zip" >&2; exit 1; }
    case "$(basename "$zip")" in
      bwce-runtime*.zip) ;;
      *) echo "ERROR: expected a file named bwce-runtime-<version>.zip, got $(basename "$zip")" >&2; exit 1 ;;
    esac
    # A truncated upload (e.g. disk full) only fails at container start with
    # "End-of-central-directory signature not found". Catch it here instead.
    if ! unzip -l "$zip" >/dev/null 2>&1; then
      echo "ERROR: $zip is not a valid zip (truncated or corrupt upload?). Size: $(wc -c < "$zip") bytes." >&2
      echo "       Compare with the original (sha256sum on both machines) and copy it again." >&2
      exit 1
    fi
    # TIBCO's scripts are version-specific: pick the matching base directory
    # from the version in the zip name (bwce-runtime[-arch]-<version>.zip).
    ver="$(basename "$zip" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    major="${ver%%.*}"; rest="${ver#*.}"; minor="${rest%%.*}"
    build_args=()
    if [[ -z "$ver" ]]; then
      echo "ERROR: can't read a version from $(basename "$zip")" >&2; exit 1
    elif (( major >= 6 )); then
      base_dir="$here/base"          # BWCE 6.12+  (upstream master)
      build_args=(
        --build-arg EXCLUDE_GOVERNANCE="${EXCLUDE_GOVERNANCE:-false}"
        --build-arg EXCLUDE_CONFIG_MANAGEMENT="${EXCLUDE_CONFIG_MANAGEMENT:-false}"
        --build-arg EXCLUDE_JDBC="${EXCLUDE_JDBC:-false}"
      )
    elif (( major == 2 && minor >= 7 && minor <= 9 )); then
      base_dir="$here/base-2.7"      # BWCE 2.7.0 - 2.9.x (upstream branch 2.7.0)
    else
      echo "ERROR: BWCE $ver is not supported here. Supported: 2.7.0-2.9.x (base-2.7) and 6.12+ (base)." >&2
      echo "       For other versions, vendor the matching branch of github.com/TIBCOSoftware/bwce-docker." >&2
      exit 1
    fi
    echo "BWCE $ver -> using $(basename "$base_dir")/"
    rt_dir="$base_dir/resources/bwce-runtime"
    # Only one runtime zip may be present; setup.sh globs bwce*.zip.
    find "$rt_dir" -maxdepth 1 -name 'bwce*.zip' -delete
    cp -f "$zip" "$rt_dir/"
    # The base Dockerfile uses ADD/COPY, which keep host permissions. With a
    # strict umask (e.g. 077 for root on hardened servers) /scripts and
    # /resources end up root-only and the container user (bwce, uid 2001)
    # fails with "stat /scripts/start.sh: permission denied". Normalise first.
    chmod -R u+rwX,go+rX "$base_dir"
    docker build ${proxy_args[@]+"${proxy_args[@]}"} ${build_args[@]+"${build_args[@]}"} -t "$tag" "$base_dir"
    ;;
  app)
    [[ $# -eq 3 ]] || usage
    app_dir="$1"; base_tag="$2"; tag="$3"
    n_ear=$(find "$app_dir" -maxdepth 1 -name '*.ear' | wc -l)
    [[ "$n_ear" -eq 1 ]] || { echo "ERROR: $app_dir must contain exactly one .ear (found $n_ear)" >&2; exit 1; }
    # The EAR must be readable by the container user (uid 2001); COPY keeps
    # host permissions, so a 600 EAR would be unreadable at runtime.
    chmod go+rx "$app_dir"; chmod go+r "$app_dir"/*.ear
    docker build ${proxy_args[@]+"${proxy_args[@]}"} --build-arg BWCE_BASE_IMAGE="$base_tag" -t "$tag" "$app_dir"
    ;;
  *) usage ;;
esac

echo "Built $tag"
