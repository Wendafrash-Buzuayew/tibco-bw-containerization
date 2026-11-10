# Containerizing TIBCO BW6 applications (BWCE on Docker and Kubernetes)

This guide turns existing **BusinessWorks 6** applications into container
images that run on **TIBCO BusinessWorks Container Edition (BWCE)**, on a plain
Docker host or on Kubernetes (Helm). One EAR per image, one Helm release per
application. All commands run from the repo's `bwce/` folder.

It has been used for real BW6 services (REST/HTTPS, JDBC PostgreSQL,
EMS/JMS, TLS backends) on BWCE 2.9.1; see the [case study](case-study.md).
Every error met on the way is in [troubleshooting.md](troubleshooting.md).
New to BWCE? Read [concepts.md](concepts.md) first.

- [How it works](#how-it-works)
- [What you need](#what-you-need)
- [Step 1: base image](#step-1-build-the-base-image-once-per-bwce-version)
- [Step 2: check the EAR](#step-2-check-the-ear)
- [Step 3: profile](#step-3-prepare-the-profile-substvar)
- [Step 4: certificates](#step-4-keystores-and-certificates)
- [Step 5: app image and test run](#step-5-build-the-app-image-and-test-on-a-docker-host)
- [Step 6: Kubernetes](#step-6-deploy-to-kubernetes)
- [Scripts reference](#scripts-reference)
- [Security rules](#security-rules)
- [Checklist for a new app](#checklist-for-a-new-app)

---

## How it works

```
 bwce-runtime-<ver>.zip ──► base image  (TIBCO's start.sh/setup.sh + runtime zip, user bwce uid 2001)
                              │   optional: + EMS client   (add-ems-client.sh)
                              ▼
          your .ear ──► app image  (FROM base, COPY app.ear /)
                              │
   at container start:        ▼
   setup.sh unzips runtime + EAR into /tmp, picks profile $BW_PROFILE
   (or a mounted /<PROFILE>.substvar), resolves #TOKENS# from env vars,
   starts the AppNode in the foreground (logs to stdout)
                              │
   mounted at run time:  keystores, profile with secrets, env vars
```

| Path | What it is |
|---|---|
| `base/` | Base image for **BWCE 6.12+** (TIBCO `bwce-docker` master, unmodified, see `base/UPSTREAM.md`) |
| `base-2.7/` | Base image for **BWCE 2.7.0 - 2.9.x** (TIBCO branch `2.7.0`, unmodified) |
| `build.sh` | Builds the base image (picks `base/` or `base-2.7/` from the zip name) and app images |
| `fix-profile.sh` | Extracts a profile from an EAR, fixes JDBC for BWCE, overrides properties |
| `add-ems-client.sh` | Builds an EMS-enabled base image for apps that use JMS |
| `apps/<app>/` | One folder per app: Dockerfile, values file, README. **EARs are not in Git.** |
| `apps/_template/` | Copy this for a new app |
| `../helm/bwce-app/` | Generic Helm chart, one release per app |
| `local/` | Your keystores, generated profiles, EMS jars. Gitignored. |

TIBCO's scripts are version-specific: the 6.x scripts don't work with a 2.x
runtime and vice versa. Use the version you are licensed for and keep the
TIBCO scripts unmodified, so upgrading is a copy from upstream.

## What you need

- A **Linux Docker host** to build and test (a CI runner, a Linux VM, or
  Docker Desktop with Linux containers). Windows Server Docker can't build
  these images.
- `bwce-runtime-<version>.zip` from TIBCO eDelivery (about 300 MB).
- The app **EAR exported for BWCE** (see step 2).
- The keystores the app references (client truststore, server keystore).
- For JMS apps: the EMS client jars from `<EMS_HOME>/lib` (`tibjms.jar`,
  `tibjmsadmin.jar`, `tibjmsufo.jar`).
- A private registry (e.g. Harbor) for the images. The base image contains
  the licensed TIBCO runtime: never push it to a public registry.
- For Kubernetes: Kubernetes 1.25+, Helm 3.

On Windows, clone with LF line endings (the repo's `.gitattributes` forces
LF for scripts; if you copy files around by hand, make sure `*.sh` stay LF).

## Step 1: build the base image (once per BWCE version)

```bash
cd bwce
./build.sh base /path/to/bwce-runtime-2.9.1.zip  bwce-base:2.9.1
# or 6.12+:
./build.sh base /path/to/bwce-runtime-6.12.0.zip bwce-base:6.12.0
```

`build.sh` validates the zip (a truncated copy fails here, not at runtime),
normalises file permissions (needed on servers with umask 077) and forwards
`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` to the build if set.

Push it to your private registry so other hosts don't need the zip:

```bash
docker tag bwce-base:2.9.1 harbor.example.com/tibco/bwce-base:2.9.1
docker login harbor.example.com
docker push harbor.example.com/tibco/bwce-base:2.9.1
```

If the registry uses an internal CA, the Docker host must trust it
(`/etc/docker/certs.d/<registry>/ca.crt` on Linux; Windows certificate store
plus a Docker Desktop restart on Windows).

**Apps that use JMS (EMS)** need the EMS client inside the runtime. Build an
EMS-enabled variant once:

```bash
mkdir -p local/ems-lib
scp 'user@ems-host:/opt/tibco/ems/10.1/lib/tibjms*.jar' local/ems-lib/
./add-ems-client.sh harbor.example.com/tibco/bwce-base:2.9.1 local/ems-lib bwce-base:2.9.1-ems
```

Expect three `unpacked ... -> ...jmsclient...` lines. Without this, JMS apps
log `Could not load EMS Client library bundles` and fail to start. Putting the
jars in `/resources/addons/jars` does **not** work (see troubleshooting).
A JMS activity anywhere in the app counts, including shared modules (logging,
token checks): check with `unzip -l` on the module jars or just use the `-ems`
base whenever in doubt.

## Step 2: check the EAR

BWCE only runs EARs built for the container edition:

```bash
unzip -p MyApp.ear META-INF/MANIFEST.MF | grep -E 'Edition|Bundle-Version'
#   TIBCO-BW-Edition: bwe,bwcf,bwcloud     <- must contain bwcf
unzip -Z1 MyApp.ear | grep substvar        # available profiles
```

No `bwcf`: open the project in **Business Studio for BWCE**, let it convert,
check every palette/plugin is supported in BWCE, and export the EAR again.
Don't bypass the check with `DISABLE_BWCE_EAR_VALIDATION`. Make sure the copy
on the build host is the converted one (compare `sha256sum` and
`Bundle-Version`).

Then find out what the app talks to. The quickest way is the profile:

```bash
unzip -p MyApp.ear META-INF/UAT.substvar | awk '
/<name>/{n=$0; sub(/.*<name>/,"",n); sub(/<\/name>.*/,"",n)}
/<value>/{v=$0; sub(/.*<value>/,"",v); sub(/<\/value>.*/,"",v);
  if (tolower(n) ~ /pass|pwd|secret|token|key/ && v!="") v="***"; print n " = " v}'
```

Note for each module: listener port (`/HTTP/Port`), keystore paths,
JDBC driver/URL, EMS URL, every backend host:port. Then check reachability
**from the host where the container will run**:

```bash
for hp in db-host:5432 backend.example.com:443 ems-host:7222; do
  timeout 5 bash -c "</dev/tcp/${hp%:*}/${hp#*:}" 2>/dev/null && echo "OK   $hp" || echo "FAIL $hp"
done
```

A TCP check isn't enough for HTTPS: also run
`curl -sk -o /dev/null -w '%{http_code}\n' https://host/`. `000` with a
connection reset means a firewall or allow-list problem, not the app.

## Step 3: prepare the profile (.substvar)

Two reasons you usually can't use the EAR's profile as-is:

1. **JDBC:** BW6 apps often use TIBCO's DataDirect PostgreSQL driver
   (`tibcosoftwareinc.jdbc.postgresql.PostgreSQLDriver`). BWCE rejects it with
   `Missing Required Field [Connection URL]`.
2. **Endpoints:** hosts differ between the old BW6 servers and the container
   network.

`fix-profile.sh` extracts the profile, switches DataDirect to
`org.postgresql.Driver` + `jdbc:postgresql://host:port/db`, and applies
`--set NAME=VALUE` overrides. Nothing else changes.

```bash
./fix-profile.sh apps/my-app/*.ear UAT local/my-app/UAT.substvar \
  --set /Target/Host=token.example.com \
  --set /Target/Port=443
```

- Each `--set` must print `(1 match)`. An unknown name is an error and no file is written.
- A name matches regardless of module prefix. If the same property exists in
  two modules (e.g. `/TargetAPI/TargetHost`), it prints `(2 matches)` and
  changes both: use the full name, e.g. `'//MyModule///TargetAPI/TargetHost=...'`.
- Quote values containing `?`, `&` or spaces.
- Check how the app uses a value before changing it. For example a path
  property the process appends a query to must keep its `?param=` suffix.
- Regenerate the profile whenever the EAR changes. A profile from another
  build fails with `TIBCO-BW-ADMIN-500467: Invalid profile file`.

The output contains the profile's passwords: it goes in `local/` (gitignored)
and is mounted at `/<PROFILE>.substvar`, where BWCE prefers it over the copy
in the EAR. In Kubernetes it becomes a Secret.

Long term, replace hard-coded values in the EAR with `#TOKEN#` values and
supply them as env vars (ConfigMap/Secret). Then no profile file is needed.

## Step 4: keystores and certificates

BW6 profiles usually point to fixed paths, e.g.
`/data/conf/tibco/cert/client/certs.jks` and
`/data/conf/tibco/cert/server/server.p12`. Recreate that layout and
mount it read-only:

```bash
mkdir -p local/my-app/cert/client local/my-app/cert/server
cp certs.jks         local/my-app/cert/client/
cp server.p12 local/my-app/cert/server/
```

The container runs as **uid 2001**. Files must be readable by that uid:

```bash
chown -R 2001:2001 local/my-app
chmod 700 local/my-app/cert local/my-app/cert/*
chmod 600 local/my-app/cert/*/* local/my-app/*.substvar
```

New backend hosts may need their CA in the client truststore
(`PKIX path building failed`):

```bash
openssl s_client -connect host:443 -servername host </dev/null 2>/dev/null | openssl x509 > host.pem
keytool -importcert -noprompt -alias host -file host.pem -keystore local/my-app/cert/client/certs.jks
```

Check the server certificate's expiry too
(`openssl pkcs12 -in server.p12 -nokeys | openssl x509 -noout -enddate`);
clients reject an expired one even if the app starts fine.

## Step 5: build the app image and test on a Docker host

```bash
cp -r apps/_template apps/my-app          # edit Dockerfile EXPOSE, README, values file
cp /path/to/MyApp_1.0.0.ear apps/my-app/  # exactly one .ear in the folder
./build.sh app apps/my-app harbor.example.com/tibco/bwce-base:2.9.1 my-app:1.0.0
#                          ^ or bwce-base:2.9.1-ems for JMS apps

docker run -d --name my-app -p 18443:8443 -p 17777:7777 \
  -e BW_PROFILE=UAT -e BW_LOGLEVEL=INFO \
  -v "$PWD/local/my-app/cert:/data/conf/tibco/cert:ro" \
  -v "$PWD/local/my-app/UAT.substvar:/UAT.substvar:ro" \
  my-app:1.0.0
docker logs -f my-app
```

- Pick free **host** ports (`ss -ltn`); shared servers often already use
  8080/8082/7777. The container ports stay as the app defines them.
- Health: `curl -s http://localhost:17777/_ping/`
  - `Application is running`: started.
  - `Application is Impaired` / `StartFailed`: a resource or module failed;
    `docker logs my-app 2>&1 | grep -nE 'ERROR|WARN|Caused by|Unresolved' | head -40`.
- Then call the API with the same request that works on the BW6 server
  (`curl -k` while the server certificate is self-signed or expired).
- On Git Bash for Windows add `MSYS_NO_PATHCONV=1` before `docker run` and
  use `$(pwd -W)` instead of `$PWD`.
- After changing only the profile: regenerate it and `docker restart my-app`.
  After changing the EAR or base: rebuild the image and recreate the container.

## Step 6: deploy to Kubernetes

Build the app image on a trusted build host and push it to the private
registry, then:

```bash
NS=tibco-uat
kubectl -n $NS create secret generic tibco-certs \
  --from-file=certs.jks=local/my-app/cert/client/certs.jks \
  --from-file=server.p12=local/my-app/cert/server/server.p12
kubectl -n $NS create secret generic my-app-profile --from-file=UAT.substvar=local/my-app/UAT.substvar
kubectl -n $NS create secret docker-registry regcred --docker-server=harbor.example.com \
  --docker-username=... --docker-password=...

helm lint ../helm/bwce-app -f apps/my-app/values-uat.yaml
helm upgrade --install my-app-uat ../helm/bwce-app -n $NS -f apps/my-app/values-uat.yaml
kubectl -n $NS rollout status deploy/my-app
```

The values file (see `apps/_template/values-uat.yaml`) sets the image, the
profile (`bwce.profile`, `externalProfile.secretName`), ports, keystore
mounts (`extraVolumes`/`extraVolumeMounts`) and resources.

In a shared namespace, check for name clashes and an existing pull secret
first, and give the release a distinct name (e.g. a `-bwce` suffix when the
old service still runs in the same namespace):

```bash
kubectl -n $NS get deploy,svc | grep -i <app>
kubectl -n $NS get secrets --field-selector type=kubernetes.io/dockerconfigjson
kubectl -n $NS get secret <pull-secret> -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d \
  | python3 -c 'import json,sys; print(list(json.load(sys.stdin)["auths"]))'   # registry hosts only
```

Render before installing (`helm template ... > /tmp/x.yaml`) and check the
image, `BW_PROFILE`, the `/UAT.substvar` mount and the keystore mounts.

**Verify.** During startup the log shows `Impaired`/`Unresolved` lines while
modules come up one by one; that's normal if `Started BW Application` and
`Running` follow. Then test from inside the cluster (this also proves the
nodes can reach the backends; port-forward may be blocked by RBAC):

```bash
IP=$(kubectl -n $NS get pod -l app.kubernetes.io/instance=<release> -o jsonpath='{.items[0].status.podIP}')
kubectl -n $NS run curltest --rm -i --restart=Never --image=curlimages/curl \
  --env="TOKEN=$TOKEN" --env="IP=$IP" --command -- sh -c '
curl -s -m 5 http://$IP:7777/_ping/; echo
curl -sk -m 60 -w "\nHTTP %{http_code}\n" -X POST https://<service>:<port><path> \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" -d "{...}"'
```

Port 7777 (health) is not in the Service; use the pod IP for `_ping`.

What the chart provides:

- Non-root (uid 2001), all capabilities dropped, `RuntimeDefault` seccomp,
  no service-account token.
- `/tmp` as an `emptyDir` (2Gi) for the unpacked runtime.
- Startup, liveness and readiness probes on `7777` `/_ping/`; the startup
  probe allows 5 minutes.
- Rolling update with `maxUnavailable: 0`, `preStop` delay, 60s grace period.
- `appConfig` (ConfigMap) and `appSecret` (Secret) as env vars for `#TOKEN#`
  values; pods restart when the ConfigMap changes.
- Optional Ingress, HPA, PodDisruptionBudget, topology spread.

Before production: request firewall openings for the **node/egress IPs**
(not just the test host) to every backend, keep `-Xmx` at about 75% of the
memory limit, and confirm your BWCE licence covers the pods and cores.
Check that the readiness probe really fails while the app is `Impaired` on
your BWCE version (`curl -i` on `/_ping/` shows the status code); if it
returns 200, add an `exec` probe that greps the body for `running`.

## Scripts reference

| Command | Does |
|---|---|
| `./build.sh base <bwce-runtime-X.zip> <tag>` | Base image; `base/` for 6.12+, `base-2.7/` for 2.7-2.9. Optional env for 6.12+: `EXCLUDE_GOVERNANCE`, `EXCLUDE_CONFIG_MANAGEMENT`, `EXCLUDE_JDBC=true` |
| `./build.sh app <app-dir> <base-tag> <tag>` | App image from the single `.ear` in `<app-dir>` |
| `./fix-profile.sh <ear> <PROFILE> <out.substvar> [--set N=V ...]` | Profile with BWCE-compatible JDBC and overrides; lists available profiles if `PROFILE` doesn't exist |
| `./add-ems-client.sh <base> <ems-lib-dir> <tag>` | EMS-enabled base: unpacks `tibjms*.jar` into the runtime's placeholder `com.tibco.jms.jmsclient*` bundles |

Runtime environment variables (set by Helm or `docker run -e`):

| Variable | Meaning |
|---|---|
| `BW_PROFILE` | Profile name, e.g. `UAT` (a mounted `/UAT.substvar` wins over the EAR's) |
| `BW_LOGLEVEL` | `ERROR`, `WARN`, `INFO`, `DEBUG` |
| `BW_JAVA_OPTS` | JVM options, e.g. `-Xms256m -Xmx768m` |
| any `NAME` | Resolves `#NAME#` in the profile |

## Security rules

- Never commit EARs, keystores (`.jks`, `.p12`, `.pem`, `.key`), generated
  `.substvar` files or EMS jars. `.gitignore` covers `bwce/apps/**/*.ear`,
  keystore extensions and `bwce/local/`. Stage files by name and check
  `git diff --cached --name-only` before committing.
- Keep the registry project **private**: the base image contains the licensed
  runtime, app images contain the EAR.
- An EAR whose profiles contain passwords puts those passwords in the app
  image. Prefer `#TOKEN#` properties plus Secrets; until then, treat app images
  as secret.
- Don't paste bearer tokens or passwords into tickets or chats; use `$TOKEN`
  variables.
- On shared Docker hosts, don't restart the Docker daemon and don't remove
  other teams' containers; use your own host ports and container names.

## Checklist for a new app

1. EAR has `bwcf` in the manifest (step 2).
2. Listener ports, keystores, JDBC, JMS and backends listed from the profile.
3. Reachability from the run host checked (TCP and HTTPS).
4. Base chosen: plain, or `-ems` if any module uses JMS.
5. `apps/<app>/` created from `_template`, EAR copied in (not committed).
6. Profile generated with `fix-profile.sh`, every `--set` `(1 match)`.
7. Keystores in `local/<app>/cert/{client,server}`, owned by uid 2001.
8. Container runs, `_ping` says `Application is running`.
9. A real request succeeds; backend errors checked in `docker logs`.
10. App README updated with the overrides that work, values file with the
    registry path; firewall requests raised for the cluster IPs.

For how this played out on two real services (one with several REST
backends and JDBC, one adding EMS/JMS), see the [case study](case-study.md).

## Updating TIBCO's scripts

See `base/UPSTREAM.md` and `base-2.7/UPSTREAM.md`. Keep the scripts identical
to upstream; all customisation lives in `build.sh`, `fix-profile.sh`,
`add-ems-client.sh`, mounted files and env vars.
