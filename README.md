# TIBCO BW6 containerization (BWCE on Docker and Kubernetes)

Practical tooling and a step-by-step guide for moving existing **TIBCO
BusinessWorks 6** applications into containers with **BusinessWorks Container
Edition (BWCE)**, first on a plain Docker host, then on Kubernetes with Helm.

It comes from a real migration of production-style BW6 services (HTTPS REST
APIs, JDBC to PostgreSQL, TLS backends, EMS/JMS) and documents every problem
met on the way, so you don't have to rediscover them.

> This is a community/educational project. It is not affiliated with or
> endorsed by TIBCO Software Inc. You need your own licensed BWCE runtime from
> TIBCO eDelivery; no TIBCO binaries are included here.

## What's inside

| Path | What it is |
|---|---|
| [`docs/guide.md`](docs/guide.md) | **Start here.** Step-by-step: base image, EAR checks, profile, certificates, test run, Kubernetes |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Symptom → cause → fix for real errors (build, startup, runtime, Kubernetes) |
| [`docs/case-study.md`](docs/case-study.md) | How a real BW6 migration went, in order, with the lessons learned |
| [`docs/concepts.md`](docs/concepts.md) | BW6 vs BWCE in five minutes: EAR, profile, AppNode, edition check, OSGi |
| `bwce/base/` | Base image for **BWCE 6.12+** (TIBCO's official scripts, unmodified) |
| `bwce/base-2.7/` | Base image for **BWCE 2.7.0 - 2.9.x** (TIBCO's official scripts, unmodified) |
| `bwce/build.sh` | Builds the base image (picks the right scripts from the runtime zip name) and app images |
| `bwce/fix-profile.sh` | Extracts a profile from an EAR, converts DataDirect JDBC to the standard driver, overrides properties |
| `bwce/add-ems-client.sh` | Builds an EMS-enabled base image (the container equivalent of `bwinstall ems-driver`) |
| `bwce/apps/_template/` | Dockerfile, Helm values and README to copy for each app |
| `helm/bwce-app/` | Generic Helm chart: one BWCE application per release |

## How it fits together

```
 bwce-runtime-<ver>.zip ──► base image   (TIBCO start.sh/setup.sh + runtime, user uid 2001)
                              │  (+ EMS client for JMS apps: add-ems-client.sh)
                              ▼
          your app.ear ──► app image  (FROM base, COPY app.ear /)
                              │
   container start:           ▼
   setup.sh unpacks runtime + EAR into /tmp, selects profile $BW_PROFILE
   (or a mounted /<PROFILE>.substvar), resolves #TOKENS# from env vars,
   runs the AppNode in the foreground, logs to stdout, health on :7777/_ping/
                              │
   supplied at run time:  keystores, profile with secrets, env vars (Secrets/ConfigMaps on Kubernetes)
```

## Quick start

On a Linux Docker host, with `bwce-runtime-2.9.1.zip` (or 6.12+) from TIBCO
eDelivery and an EAR exported from Business Studio for BWCE:

```bash
git clone https://github.com/Wendafrash-Buzuayew/tibco-bw-containerization.git
cd tibco-bw-containerization/bwce

./build.sh base ~/Downloads/bwce-runtime-2.9.1.zip bwce-base:2.9.1

cp -r apps/_template apps/my-app && cp ~/MyApp_1.0.0.ear apps/my-app/
./fix-profile.sh apps/my-app/*.ear UAT local/my-app/UAT.substvar
./build.sh app apps/my-app bwce-base:2.9.1 my-app:1.0.0

docker run -d --name my-app -p 8443:8443 -p 7777:7777 -e BW_PROFILE=UAT \
  -v "$PWD/local/my-app/UAT.substvar:/UAT.substvar:ro" my-app:1.0.0
curl -s http://localhost:7777/_ping/        # Application is running
```

Then follow [`docs/guide.md`](docs/guide.md) for certificates, JMS, and
Kubernetes.

## Supported versions

| BWCE runtime | Scripts used | Notes |
|---|---|---|
| 6.12 and later | `bwce/base` (TIBCO `bwce-docker` master) | |
| 2.7.0 - 2.9.x | `bwce/base-2.7` (TIBCO `bwce-docker` branch `2.7.0`) | tested with 2.9.1 |

TIBCO's scripts are version-specific; `build.sh` selects them from the zip
name. Tested with Kubernetes 1.25 and Helm 4.

## Licensing

- `bwce/base/` and `bwce/base-2.7/` contain TIBCO's BWCE Docker scripts,
  redistributed unchanged under their 3-clause BSD licence (`License.md` in
  each folder; source: https://github.com/TIBCOSoftware/bwce-docker).
- Everything else is under the MIT licence ([`LICENSE`](LICENSE)).
- The BWCE runtime itself is licensed by TIBCO and is not part of this repo.
  Images built from it contain licensed software: keep them in a private
  registry.

## Contributing

Issues and pull requests are welcome, especially new entries for
`docs/troubleshooting.md` from other BWCE versions and plugins. Please never
include EARs, keystores, profiles with passwords, or internal hostnames in
issues or PRs.
