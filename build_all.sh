#!/bin/bash
# Legacy v1/v2 binary snapshots remain in firmware/ for the proven transport demo.
# The source now requires signing; avoid silently overwriting those snapshots.
echo 'Disabled for signed-OTA development: use ./build_secure.sh for v3/v4.' >&2
echo 'For the old unsigned build, check out the main branch/old transport commit.' >&2
exit 1
