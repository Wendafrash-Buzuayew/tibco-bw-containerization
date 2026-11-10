# Case study: two BW6 services to BWCE and Kubernetes

What actually happened when two existing BW6 REST services were moved to
BWCE 2.9.1, first on a shared Linux Docker host in the test network, then on
a Kubernetes cluster. Names, hosts and data are left out; the problems and
fixes are real and in the order they appeared.

| | Service A | Service B |
|---|---|---|
| API | HTTPS REST (JSON), token-protected | HTTPS REST (JSON), token-protected |
| Modules | main module + shared token-check, request-validator, event-logger modules | same shared modules + a location/notification module |
| Backends | 1 PostgreSQL, 5 REST APIs over TLS | 2 PostgreSQL, 4 REST APIs over TLS, **EMS** (JMS send) |
| Profiles in the EAR | default, DR, PROD, UAT, ... | same |

## Phase 1: the platform

1. **Base image.** The licensed runtime was BWCE **2.9.1**, but the current
   TIBCO `bwce-docker` scripts are for 6.12+. The 2.x runtime needs the
   scripts from the `2.7.0` branch. Both are kept unmodified side by side and
   `build.sh` picks one from the zip name.
2. **Line endings.** The repo was edited on Windows; scripts with CRLF fail in
   the container. `.gitattributes` now forces LF.
3. **Hardened build server.** root's umask was 077, so files copied into the
   image were root-only and the container user (uid 2001) got
   `permission denied` on `start.sh`. `build.sh` normalises permissions.
4. **A truncated 300 MB upload** of the runtime zip only failed at container
   start. `build.sh` now validates the zip. Long term the fix was to build the
   base image once and push it to the private registry; other hosts just pull.
5. **Internal registry CA.** `docker push` failed with `x509: unknown
   authority` until the corporate CA was trusted by Docker.

## Phase 2: Service A on Docker

1. **Edition check:** the EAR had `bwcf` (exported from Business Studio for
   BWCE), so it passed. A later EAR copied from the old BW6 server had only
   `bwe` and was rejected; always check the copy on the build host.
2. **Keystores:** `FileNotFoundException`. The profile referenced keystores
   under fixed client/server paths; mounting the same folder layout fixed it.
3. **JDBC:** `Missing Required Field [Connection URL]`. The profile used
   TIBCO's DataDirect PostgreSQL driver, which BWCE doesn't have.
   `fix-profile.sh` rewrites it to `org.postgresql.Driver` and a
   `jdbc:postgresql://host:port/db` URL and mounts the result as
   `/UAT.substvar`.
4. **Client errors that weren't the app:** an expired server certificate
   (`curl -k` for testing, renew before production) and a missing
   `Content-Type` header (HTTP 415).
5. **Backends unreachable.** From a laptop, most backends timed out. Testing
   moved to a host inside the test network. Several backends had new host
   names there; `fix-profile.sh --set` overrides them without touching the EAR.
6. **Same property, two calls.** Two different backend calls shared one HTTP
   Client shared resource, so one host property controlled both. A property
   can't split them; that needs a second HTTP Client in Business Studio.
7. **Replacement backend with a different contract.** A new gateway for one
   lookup accepted only **POST**, while the process does a **GET** with a
   query string (`?processParams=...`). The path could be changed by
   property, but the HTTP method and body format are part of the process.
   Either keep calling the original API or change the EAR. Lesson: before
   pointing an app at a "new URL", compare method, path, query, body and
   response format, not only the host.
8. **Event logger timeouts.** A non-critical logging backend was unreachable;
   each call waited for the full connect timeout (about 2 minutes) while the
   main flow continued. Later the replacement host accepted TCP but reset
   every TLS handshake: a firewall/allow-list issue, confirmed with
   `openssl s_client` from the host. Pointing it to `127.0.0.1:9` made calls
   fail instantly until the firewall was opened.

## Phase 3: Service B (adds EMS)

1. **Port clash** on the shared host (another team's container held the host
   port). Fixed by mapping a different host port; container ports unchanged.
2. **Profile/EAR mismatch:** `TIBCO-BW-ADMIN-500467 ... doesnt exist in the
   profile` after the EAR was re-exported. Regenerating the profile from the
   EAR actually in the image fixed it.
3. **EMS, attempt 1:** mounting `tibjms.jar` and `jms-2.0.jar` into
   `/resources/addons/jars` gave `Found a duplicate bundle within the same
   folder`. Those jars aren't OSGi bundles and both land in `hotfix/shared`.
4. **EMS, attempt 2:** without the jars, the app started but the JMS activity
   failed with a `NullPointerException`, and because the token-check and
   logging modules also contain JMS activities, **every** process became
   `Unresolved` and the HTTPS listener never opened (`_ping`:
   `Impaired`/`StartFailed`, curl: `SSL_ERROR_SYSCALL`). The log line that
   gave it away was a WARN, not an ERROR: `Could not load EMS Client library
   bundles`.
5. **The fix:** the runtime ships empty placeholder bundles
   `com.tibco.jms.jmsclient*_8.1.100.001` (only a `MANIFEST.MF`, no
   `Bundle-ClassPath`). The EMS classes must be unpacked into the bundle root,
   which is what `add-ems-client.sh` does, producing an `-ems` base image.
   The EMS 10.1 client jars work with these 8.1 placeholders.
6. **EMS fault-tolerant pair:** only one of the two EMS servers was reachable.
   The client uses whichever is active; the other needs a firewall rule for
   failover.

## Phase 4: Kubernetes

1. **Shared namespace.** The old versions of both services were running in the
   same namespace under similar names. The new releases got a `-bwce` suffix so
   nothing existing was touched. An existing pull secret already covered the
   private registry; checking its `auths` hosts avoided creating another.
2. **Secrets:** keystores and the generated profiles were created as Secrets
   from files copied off the test host (binary transfer, deleted afterwards).
3. **Render first:** `helm lint` and `helm template` before installing; the
   rendered Deployment was checked for the image, `BW_PROFILE`, the profile
   mount and the keystore mounts.
4. **Startup logs** show a burst of `Impaired ... Unresolved` lines; they're
   normal as long as `Started BW Application` follows.
5. **Testing:** `kubectl port-forward` kept exiting (curl `HTTP 000`); a
   throwaway `curlimages/curl` pod inside the namespace was simpler and also
   proved that the **nodes** (not just the test host) could reach the
   backends.

## Lessons

- **Test on a host inside the target network early.** Most "application"
  errors were network errors.
- **Keep TIBCO's scripts unmodified** and put every adaptation in your own
  scripts, mounted files and env vars. Upgrading is then a copy.
- **Never commit EARs, keystores or generated profiles.** BW6 profiles contain
  passwords. Long term, replace them with `#TOKEN#` properties and Secrets.
- **Read WARN lines** during startup; the root cause of a fully `Unresolved`
  app may only be a warning.
- **Check every module for JMS/JDBC usage**, including shared utility modules,
  before choosing the base image.
- **Record every override that works** in the app's README; the Kubernetes
  Secret has to be generated with the same values.
