# BWCE troubleshooting

Every entry below was hit while containerizing real BW6 apps. Find the
message, apply the fix. Commands assume you're in `bwce/`.

First look at the log in a focused way:

```bash
docker logs my-app 2>&1 | grep -nE 'ERROR|WARN|Caused by|CausedBy|Unresolved|Impaired|StartFailed|Started BW' \
  | grep -vE 'FrameworkEvent|unknown cipher|memoryCalculator|cgroup' | head -40
curl -s http://localhost:<health-port>/_ping/; echo
```

## Building images

| Symptom | Cause | Fix |
|---|---|---|
| `./build.sh: No such file or directory` / `bad interpreter: /bin/bash^M` | Scripts checked out with CRLF line endings | `git config core.autocrlf false`, re-clone; or `sed -i 's/\r$//' *.sh`. `.gitattributes` forces LF. |
| `ERROR: runtime zip not found` | Wrong path, or the zip is named differently | Pass the path to `bwce-runtime-<ver>.zip`; the name must start with `bwce-runtime`. |
| `ERROR: ... is not a valid zip (truncated or corrupt upload?)` | Copy interrupted (often a full disk) | Compare `sha256sum` and size on both machines, copy again. Or push the base image to the registry from a host that has it. |
| apt-get `Could not connect to deb.debian.org` during `build.sh base` | No internet from the build host | Set `HTTPS_PROXY`/`HTTP_PROXY` (forwarded automatically) or build on a host with access. |
| `x509: certificate signed by unknown authority` on `docker push/pull` | Registry uses an internal CA | Linux: put the CA in `/etc/docker/certs.d/<registry>/ca.crt`. Windows: import into the Root store, restart Docker Desktop. |
| `No space left on device` | Docker data or the clone on a small partition (e.g. `/home`) | Clone to a large disk (`/data`); `docker system df`, `docker builder prune`. |
| `ERROR: <dir> must contain exactly one .ear` | Zero or several EARs in the app folder | Keep exactly one; remove old versions. |

## Container won't start

| Symptom | Cause | Fix |
|---|---|---|
| `stat /scripts/start.sh: permission denied` | Built on a host with umask 077: files root-only, container runs as uid 2001 | Rebuild with current `build.sh` (it normalises permissions). |
| `Application [X] is not supported in TIBCO BusinessWorks Container Edition` | EAR manifest lacks `bwcf` (classic BW6 export), or the build host has an older EAR | Export from Business Studio for BWCE; check `unzip -p x.ear META-INF/MANIFEST.MF \| grep Edition` on the build host. |
| Runtime unpack errors with a 2.x zip on the 6.x scripts (or vice versa) | Script/runtime version mismatch | Use `build.sh base`, which picks `base/` (6.12+) or `base-2.7/` (2.7-2.9) from the zip name. |
| `End-of-central-directory signature not found` at start | Truncated runtime zip inside the image | Rebuild the base from a good zip (`build.sh` now rejects bad ones). |
| `TIBCO-BW-ADMIN-500467: Invalid profile file from [/tmp/tmp/pcf.substvar]. [{1}] doesnt exist in the profile` | Mounted profile doesn't match the EAR (generated from another build), or is empty | Regenerate with `fix-profile.sh` from the EAR in the image. Compare names: `diff <(unzip -p app.ear META-INF/UAT.substvar \| grep -o '<name>[^<]*' \| sort) <(grep -o '<name>[^<]*' local/app/UAT.substvar \| sort)` |
| `Missing Required Field [Connection URL] ... Tibco drivers` | DataDirect JDBC driver in the profile | `fix-profile.sh` (switches to `org.postgresql.Driver`). |
| `FileNotFoundException` for a `.jks`/`.p12` | Keystores not mounted at the path the profile expects | Mount `cert/client` and `cert/server` as in guide step 4; check paths with the profile dump. |
| `AccessDeniedException` / can't read keystore or profile | Mounted files not readable by uid 2001 | `chown -R 2001:2001 local/<app>`, `chmod 600` files. |
| `Found a duplicate bundle within the same folder .../hotfix/shared/tibjms.jar` | EMS jars put in `/resources/addons/jars` (non-OSGi jars, no bundle name) | Remove that mount. Use `add-ems-client.sh` and the `-ems` base. |
| `Could not load EMS Client library bundles` (WARN) followed by `Failed to initialize the activity [JMSSendMessage] ... NullPointerException`, many processes `Unresolved`, `_ping` says `Impaired`/`StartFailed` | No EMS client in the runtime (only placeholder bundles) | `add-ems-client.sh <base> local/ems-lib <base>-ems`, rebuild the app on it. Verify: `docker run --rm --entrypoint sh <image> -c 'unzip -l /resources/bwce-runtime/bwce*.zip \| grep -c "jmsclient_.*/com/tibco/"'` > 0. |
| `add-ems-client.sh`: `Nothing added` / `classes not found` | Old script version | `git pull`; the current one unpacks classes into the bundle root and checks the result. |
| `Bind for 0.0.0.0:<port> failed: port is already allocated` | Another container on the host uses that host port | Map a different host port (`-p 18082:8082`); `docker ps --filter publish=<port>` shows who has it. Remove the created container first (`docker rm <name>`). |
| `memoryCalculator` / cgroup warning on start (BWCE 2.x) | Old script reads cgroup v1 | Harmless; set `BW_JAVA_OPTS` explicitly. |

## Running, but requests fail

| Symptom | Cause | Fix |
|---|---|---|
| curl `wrong version number` | You hit a plain-HTTP port (often another container on the same host port) | Use the host port mapped to the app's HTTPS port. |
| curl `SSL_ERROR_SYSCALL` to the app | App listener not started (app `Impaired`) | Check `_ping` and the log; fix the startup problem first. |
| curl `SEC_E_CERT_EXPIRED` / `certificate has expired` | Server keystore certificate expired | `curl -k` for testing; renew `server.p12` before production. |
| HTTP `415` | Missing `Content-Type: application/json` | Add the header. |
| HTTP `401` | Token missing/expired, or `Authorization: Bearer <placeholder>` sent literally | Get a fresh token; `TOKEN=...` then `-H "Authorization: Bearer $TOKEN"`. |
| `Connection timed out` / `Connection refused` to a backend (`IOException`, app-specific error code) | Backend not reachable from this host | TCP check from the host; override the host with `fix-profile.sh --set`, or raise a firewall request. |
| `4xx response for invocation at resource path https://.../...` (e.g. 404 from envoy) | Right host, wrong path, or a host override sends a path to a gateway that doesn't serve it | Compare the full URL in the log with a working one; override the path property (keep any `?param=` the process appends to). |
| One property drives two calls that need different hosts | Both calls share one HTTP Client shared resource | Can't be fixed with properties: give one call its own HTTP Client in Business Studio, rebuild the EAR. |
| `Connection reset` during TLS handshake to a backend; `openssl s_client` from the host also gets `errno=104` for every TLS version | Network: firewall/app-inspection or source-IP allow-list | Firewall request for the host (and cluster egress) IPs. Meanwhile point that backend to `127.0.0.1:9` if it's non-critical (e.g. logging) so calls fail fast. |
| `PKIX path building failed` | Backend CA not in the client truststore | Import it with `keytool` (guide step 4). |
| Event logger / other async calls time out, flow still completes | Non-critical backend unreachable; each call waits for the connect timeout | Fix the URL or fail fast as above; don't leave it timing out under load. |
| EMS: one server of `tcp://a:7222,tcp://b:7222` unreachable | FT pair; client uses the active one | Works while the reachable one is active; open the other for failover. |

## Kubernetes

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Image not pushed, or the pull secret doesn't cover the registry | Push the image; check the secret's `auths` hosts (guide step 6). |
| `CreateContainerConfigError` | A referenced Secret (profile, certs) is missing or misnamed | `kubectl -n <ns> get secret <names>`; names must match the values file. |
| Pod `0/1 Running` for minutes | Readiness probe failing: app `Impaired`/`StartFailed` | `kubectl logs` with the grep at the top; same causes as on Docker. |
| `Impaired ... Unresolved` lines, then `Started BW Application` | Normal startup sequence | Nothing to do. |
| curl `HTTP 000` through port-forward, shell prints `[1]+ Done kubectl ... port-forward` | Port-forward exited (RBAC, local port in use, pod restart) | Run it in the foreground to see the error, or test from a `curlimages/curl` pod inside the cluster. |
| Works on the Docker host, backend timeouts in the cluster | Firewall rules cover the test host, not the node/egress IPs | Run the reachability check from a pod; raise rules for `kubectl get nodes -o wide` IPs. |
| `scp ... usage:` | scp needs source *and* target | `scp user@host:/path/file local/dir/`; files owned by uid 2001 need root or a tar made as root. |

## Windows / Git Bash specifics

- `docker run -v /data/...` becomes `C:/Program Files/Git/data/...`: prefix
  with `MSYS_NO_PATHCONV=1`, use `$(pwd -W)` for host paths.
- `pwd -W: invalid option` on Linux: use `$PWD` there.
- Windows Server 2019 Docker can't build Linux images; use Docker Desktop
  (Linux containers) or a Linux host.
