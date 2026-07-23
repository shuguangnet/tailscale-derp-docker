#!/bin/sh
set -eu

chown 65532:65532 /var/lib/derper
exec su-exec 65532:65532 /usr/local/bin/derper "$@"
