#!/usr/bin/env bash
# Runs nico-admin-cli inside the nico-api pod with the pod's SPIFFE identity over
# mTLS on the lab k0s in nico-system. Pass any admin-cli args, for example
#   lab/scripts/admin-cli.sh machine show
#   lab/scripts/admin-cli.sh machine show -f json
# NICo's own infra-controller/dev/bin/admin-cli.sh targets the old minikube/
# forge-system layout, not this k0s lab, so use this wrapper instead.
set -euo pipefail

NS="${NICO_NS:-nico-system}"
API_PORT="${API_PORT:-1079}"

exec kubectl -n "$NS" exec -i deploy/nico-api -- env \
  API_URL="https://nico-api.${NS}.svc.cluster.local:${API_PORT}" \
  ROOT_CA_PATH=/var/run/secrets/forge-roots/ca.crt \
  CLIENT_CERT_PATH=/var/run/secrets/spiffe.io/tls.crt \
  CLIENT_KEY_PATH=/var/run/secrets/spiffe.io/tls.key \
  /opt/carbide/nico-admin-cli "$@"
