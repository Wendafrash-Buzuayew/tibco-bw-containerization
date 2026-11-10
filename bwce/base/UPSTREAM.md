# Upstream source

Everything in this directory except this file comes unchanged from TIBCO's
official BWCE Docker scripts. Only the line endings were normalised to LF.

- Repository: https://github.com/TIBCOSoftware/bwce-docker
- Branch: `master` (the branch for BWCE **6.12.0 and later**)
- Commit: `8435aac6d8ea500bf8580e729f401addd900634d` (2026-08-18)
- License: 3-clause BSD (see `License.md`)

Don't edit `scripts/` or `Dockerfile` here. Customise the image through
`resources/addons/` (certs, jars, plugins, ...) or in the app image instead.
Keeping these files unchanged lets you re-sync them with a new BWCE release:

```bash
git clone https://github.com/TIBCOSoftware/bwce-docker /tmp/bwce-docker
cp -r /tmp/bwce-docker/{Dockerfile,.dockerignore,License.md,scripts} bwce/base/
# then update the commit hash above
```

For BWCE versions before 6.12, use the matching upstream branch instead
(`2.10.0`, `2.7.0`, ...). The scripts are not compatible across versions.
