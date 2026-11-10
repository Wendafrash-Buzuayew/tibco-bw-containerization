# <AppName> on BWCE

`<METHOD> <path>` on HTTPS **<port>**. Base: `bwce-base:2.9.1` (or `-ems`
if the app uses JMS). Steps: [docs/guide.md](../../../docs/guide.md).

Not in Git:

| What | Where the app expects it | Source |
|---|---|---|
| EAR | `/` (copied into the image) | `<App>_<ver>.ear` |
| Client truststore | `/data/conf/tibco/cert/client/certs.jks` | |
| Server keystore | `/data/conf/tibco/cert/server/server.p12` | |
| Fixed profile | `/UAT.substvar` | `fix-profile.sh` |

## Test on a Docker host

```bash
cd bwce
cp /path/to/<App>_<ver>.ear apps/<app>/
mkdir -p local/<app>/cert/client local/<app>/cert/server
cp /path/to/certs.jks local/<app>/cert/client/ && cp /path/to/server.p12 local/<app>/cert/server/

./fix-profile.sh apps/<app>/*.ear UAT local/<app>/UAT.substvar \
  --set /Some/Host=reachable.example.com
chown -R 2001:2001 local/<app> && chmod 600 local/<app>/UAT.substvar local/<app>/cert/*/*

./build.sh app apps/<app> <registry>/bwce-base:2.9.1 <app>:<ver>
docker run -d --name <app> -p <host-port>:<port> -p <host-health>:7777 \
  -e BW_PROFILE=UAT -e BW_LOGLEVEL=INFO \
  -v "$PWD/local/<app>/cert:/data/conf/tibco/cert:ro" \
  -v "$PWD/local/<app>/UAT.substvar:/UAT.substvar:ro" \
  <app>:<ver>
curl -s http://localhost:<host-health>/_ping/
```

## Sample request

```bash
curl -k -i -X POST https://localhost:<host-port><path> \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{ ... }'
```

## Backend endpoints (UAT profile)

| Property | Default (UAT) | Override that works | Used for |
|---|---|---|---|
| | | | |

Record every override that was needed and why, so the next person (and the
Kubernetes Secret) uses the same values.
