# Upstream source (BWCE 2.7.0 – 2.9.x)

Everything in this directory except this file comes unchanged from TIBCO's
official BWCE Docker scripts. Only the line endings were normalised to LF.

- Repository: https://github.com/TIBCOSoftware/bwce-docker
- Branch: `2.7.0` (the branch for BWCE **2.7.0 up to 2.9.x**)
- Commit: `c8c9e56d691e6fe519db4a59ea249c0b216204b4` (2023-08-16)
- License: 3-clause BSD (see `License.md`)

`../build.sh` picks this directory automatically for a `bwce-runtime-2.7.x`
to `2.9.x` zip. For BWCE 6.12+, it uses `../base` instead.

Differences from the 6.12+ base: Debian bookworm-slim instead of
trixie-slim, no `EXCLUDE_*` build options, and the scripts use `xsltproc` for
logger overrides. The user (bwce, uid 2001) and the unpack location (`/tmp`)
are the same, so the same Helm chart works for both.
