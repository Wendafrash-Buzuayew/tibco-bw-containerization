# BW6 vs BWCE in five minutes

If you know BusinessWorks 6 on-premises (domains, AppSpaces, AppNodes,
`bwadmin`), these are the differences that matter when you containerize.

## The pieces

| Term | What it is | In a container |
|---|---|---|
| **EAR** | The deployable archive exported from Business Studio: module jars, process diagrams, `META-INF/*.substvar` profiles, `MANIFEST.MF` | Copied into the app image at `/` |
| **Profile (`.substvar`)** | XML list of module/application properties per environment (`default`, `UAT`, `PROD`, ...) | Selected with `BW_PROFILE`; a file mounted at `/<PROFILE>.substvar` overrides the one in the EAR |
| **Module property** | A named value used by processes and shared resources (host, port, path, password) | Comes from the profile, or from an env var if the value is `#TOKEN#` |
| **Shared resource** | HTTP connector, HTTP client, JDBC connection, JMS connection, SSL client/server, keystore provider | Configured by module properties; if one fails to initialise, every process using it is `Unresolved` |
| **AppNode** | The JVM that runs the application | One per container, started by TIBCO's `setup.sh`/`start.sh` |
| **Domain / AppSpace / bwadmin** | On-prem management layer | **Not used.** The container is the unit of deployment; Kubernetes does placement, scaling and restarts |

## Why a BW6 EAR may not run as-is

1. **Edition.** BWCE checks `TIBCO-BW-Edition` in the EAR's `MANIFEST.MF`
   for `bwcf`. Classic BW6 exports have only `bwe`. Open the project in
   Business Studio for BWCE, let it convert, and export again. Palettes and
   plugins must be supported in BWCE.
2. **Drivers.** TIBCO's bundled DataDirect JDBC drivers aren't available in
   BWCE; profiles must use the vendor driver (e.g. `org.postgresql.Driver`).
3. **Optional client libraries.** The EMS client is not shipped with the
   runtime. The runtime contains *placeholder* OSGi bundles that must be filled
   with the EMS jars (on-prem: `bwinstall ems-driver`; here:
   `add-ems-client.sh`).
4. **File paths.** Profiles often reference keystores at fixed paths on the
   old servers. In a container they're mounted at the same paths.
5. **Network.** Backends that the old servers could reach may be firewalled
   from the Docker host or the Kubernetes nodes.

## What happens at container start

1. `start.sh` sets `BWCE_HOME=/tmp` and calls `setup.sh`.
2. `setup.sh` unzips the BWCE runtime (the zip inside the base image) and the
   EAR into `/tmp`, validates the EAR edition, copies add-ons
   (`/resources/addons/...`), picks the profile, resolves `#TOKENS#` from
   environment variables.
3. The AppNode starts in the foreground. Modules come up one by one; the log
   shows transient `Impaired` / `Unresolved` states until
   `Started BW Application` and `Running`.
4. Health: `http://<container>:7777/_ping/` returns `Application is running`,
   `Application is Impaired` or `Application is StartFailed`.

Because the runtime is unpacked at every start, `/tmp` needs about 1-2 GB and
startup takes 30-90 seconds. The Helm chart accounts for both.

## OSGi in one paragraph

BW6/BWCE runs on an OSGi framework (Equinox). Libraries are *bundles* with a
`MANIFEST.MF` declaring `Bundle-SymbolicName`, `Export-Package`,
`Import-Package` and optionally `Bundle-ClassPath`. Two consequences when you
add libraries: a plain jar dropped into a bundle folder isn't a bundle (two
of them in the same folder can even clash as "duplicate bundles"), and a
bundle without `Bundle-ClassPath` expects its classes directly in the bundle
root. That's why `add-ems-client.sh` unpacks the EMS jars into the existing
placeholder bundles instead of copying jars around.
