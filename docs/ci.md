# CI/CD pipeline for BWCE apps

`.gitlab-ci.yml` (repo root) automates what [the guide](guide.md) does by hand. Paths below are relative to `bwce/`.

```
validate ──► base (manual, rare) ──► build ──► deploy-uat (manual) + smoke test
guard-secrets   bwce-base:<v>        per app:    per app:
lint-scripts    bwce-base:<v>-ems    fetch EAR   profile Secret from EAR + overrides
lint-chart                           check-ear   helm upgrade --wait (auto-rollback)
                                     build, scan /_ping/ must say "Application is running"
                                     push Harbor
```

| Piece | Where | Why |
|---|---|---|
| EARs, runtime zip, EMS jars | GitLab **Package Registry** of this project (`ci/artifacts.sh`) | Not in Git (credentials, licence, size), but versioned and access-controlled |
| Build settings per app | `apps/<app>/app.env` | Version, EAR name, base flavour, release, Secret name |
| Endpoint overrides | `apps/<app>/profile-overrides-uat.txt` | One reviewed source instead of commands copied from READMEs |
| Image tags | `APP_VERSION` | Immutable: an existing tag is never rebuilt or overwritten |

## One-time setup

### 1. Runners (shell executor)

| Tag | Host | Needs |
|---|---|---|
| `bwce-build` | Linux Docker host that already builds images (trusts the Harbor CA) | `docker`, `unzip`, `curl`, `python3`, `git`; runner user in the `docker` group |
| `bwce-deploy` | Jump host with cluster access | `kubectl`, `helm`, `unzip`, `curl`, `awk` |

Create each runner in GitLab (*Settings → CI/CD → Runners → New project runner*,
tag as above, untagged jobs off), then on the host:

```bash
sudo gitlab-runner register --url https://<gitlab> --token <glrt-token> --executor shell
```

On a shared Docker host the `docker` group is root-equivalent: agree this with
the host owners, or use a dedicated build VM.

For deploys, give the runner its own kubeconfig with a ServiceAccount limited
to the target namespace (Role on deployments, services, secrets, configmaps,
pods, PDB, HPA, serviceaccounts) rather than a personal one.

### 2. CI/CD variables (*Settings → CI/CD → Variables*, masked + protected)

| Variable | Value |
|---|---|
| `HARBOR_USER` | Harbor **robot account** with push/pull on the project |
| `HARBOR_PASSWORD` | its secret |

Defaults like `REGISTRY_PROJECT`, `BWCE_VERSION`, `UAT_NAMESPACE` are at the top
of `.gitlab-ci.yml`. Protect the default branch: only protected branches see
protected variables.

### 3. Upload the binaries (from `bwce/`, with a token that has `api` scope)

```bash
export GITLAB_URL=https://gitlab.example.com GITLAB_PROJECT=group%2Fproject
read -rs GITLAB_TOKEN; export GITLAB_TOKEN   # api scope; keeps it out of shell history
./ci/artifacts.sh publish bwce-runtime 2.9.1 /path/to/bwce-runtime-2.9.1.zip
for j in tibjms.jar tibjmsadmin.jar tibjmsufo.jar; do
  ./ci/artifacts.sh publish ems-client 10.1 /path/to/ems/10.1/lib/$j
done
./ci/artifacts.sh publish my-app 1.0.0 /path/to/MyApp_1.0.0.ear
```

### 4. Base images

*Build → Pipelines → Run pipeline*, then start the manual `base-image` job.
It builds and pushes `bwce-base:<v>` and `bwce-base:<v>-ems`. Only needed again
for a new runtime version or a base-script change.

## Releasing a new EAR version

1. `./ci/artifacts.sh publish <IMAGE_NAME> <new-version> <ear>`
2. In `apps/<app>/app.env` bump `APP_VERSION` and `EAR_FILE`; adjust
   `profile-overrides-uat.txt` if endpoints changed. Merge request → main.
3. Pipeline on main: `build-image` builds and pushes the new tag.
4. Click `deploy-uat: [<app>]`. It regenerates the profile Secret, runs
   `helm upgrade --wait` (rolls back automatically if pods don't get ready) and
   the smoke test.

Run for one app only: *Run pipeline* with variable `APP=<folder>`.

## Adding an app

1. `cp -r apps/_template apps/<app>`; fill in `Dockerfile` ports,
   `values-uat.yaml`, `app.env`, `profile-overrides-uat.txt`.
2. Add `<app>` to the `APP_DIR` list in `.gitlab-ci.yml`.
3. Publish the EAR (step 3 above), create the keystore Secret once (guide.md, Kubernetes step).

## What the checks catch

| Job / script | Catches |
|---|---|
| `guard-secrets` | EAR, keystore, `.substvar` or zip committed to Git |
| `check-ear.sh` | EAR without `bwcf` (classic BW6 export), missing profile, JMS modules on the plain base (warning), DataDirect driver (info) |
| `artifacts.sh` | Truncated download/upload (zip check), overwriting a released version |
| `fix-profile.sh` | Override name that doesn't exist in the profile (typo, renamed property) |
| `helm --wait` + rollback | Pods that never become ready |
| `smoke-test.sh` | Pods "ready" but the app `Impaired`/`StartFailed` |

## Not automated (yet)

- Keystore Secret (`tibco-certs`): created once by hand; renew with the certificate.
- PROD: add a `deploy-prod` job with `values-prod.yaml`, a protected
  environment and approval, deploying the **same image tag** tested in UAT.
- Passwords still come from the EAR profiles. Moving them to `#TOKEN#`
  properties + Kubernetes Secrets removes them from images and Secrets-by-EAR.
