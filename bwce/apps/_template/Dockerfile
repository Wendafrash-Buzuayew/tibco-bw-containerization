# <AppName>: BW6 app on BWCE. Copy this folder to apps/<app-name>.
#
# The EAR is not in Git (it contains environment config and credentials).
# Before building, copy exactly one EAR here, e.g.:
#   cp /path/to/MyApp_1.0.0.ear .
#
# Build (pick the -ems base if any module uses JMS):
#   ./build.sh app apps/<app-name> <registry>/bwce-base:2.9.1 <app-name>:<ver>
ARG BWCE_BASE_IMAGE=bwce-base:2.9.1
FROM ${BWCE_BASE_IMAGE}

COPY *.ear /

# Replace 8443 with the app's listener port(s) from the profile (/HTTP/Port).
# 7777 = BWCE health check (/_ping/).
EXPOSE 8443 7777
