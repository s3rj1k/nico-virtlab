#!/usr/bin/env bash
set -euo pipefail

# Registers a dpuless VM as an ExpectedMachine on a flat dev env and seeds its
# BMC and UEFI creds so site explorer ingests it. Needs lab.env from env.sh.

LAB_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lab.env"
[[ -f "$LAB_ENV" ]] || {
  echo "ERROR: ${LAB_ENV} missing; run env.sh to generate it." >&2
  exit 1
}
# shellcheck disable=SC1090
source "$LAB_ENV"

if [[ "${BMC_MAC,,}" == "${BOOT_MAC,,}" ]]; then
  echo "ERROR: BMC_MAC ($BMC_MAC) must differ from BOOT_MAC ($BOOT_MAC)." >&2
  exit 1
fi

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# NICo lives in the submodule, this repo only carries the lab around it.
NICO_DIR="${NICO_DIR:-$REPO_DIR/infra-controller}"
NS=nico-system
API_PORT=1079
API_DEPLOY=deploy/nico-api

# Ack string for cloud unsafe ops. Lab only, never use against production.
CLOUD_UNSAFE_OP="${CLOUD_UNSAFE_OP:-register}"

# One flat VPC plus one HostInband segment for the dpuless host. The API assigns
# the VPC id, so it is resolved by name below (empty FLAT_VPC_ID means resolve).
HOST_PREFIX="${HOST_PREFIX:-192.168.42.0/24}"
HOST_GW="${HOST_GW:-192.168.42.1}"
RESERVE_FIRST="${RESERVE_FIRST:-220}"
SEG_MTU="${SEG_MTU:-1500}"
ORG_ID="${ORG_ID:-devenv_test_org}"
FLAT_VPC_NAME="${FLAT_VPC_NAME:-devenv_flat_vpc}"
FLAT_VPC_ID="${FLAT_VPC_ID:-}"
# Empty so the API assigns it. A deleted segment keeps its row until the drain
# finishes, so a fixed id collides with its own tombstone.
SEG_ID="${SEG_ID:-}"
# grpcurl is dropped into the api pod for verbs the admin cli lacks and for reads
# that must include soft deleted objects.
GRPCURL_VERSION="${GRPCURL_VERSION:-1.9.3}"

echo "[0/8] unseal vault (idempotent)..."
bash "$NICO_DIR/helm-prereqs/unseal_vault.sh" >/dev/null 2>&1 ||
  echo "  (unseal helper returned non-zero; continuing — pod may already be ready)"

# Only nico-api needs a restart to pick up a new image. Rolling dhcp, pxe and dns
# too takes the provisioning path down while a host may be booting.
ROLLOUT_WORKLOADS="${ROLLOUT_WORKLOADS:-deployment.apps/nico-api}"
if [[ "$ROLLOUT_WORKLOADS" == "all" ]]; then
  mapfile -t WORKLOADS < <(kubectl -n "$NS" get deploy,statefulset -o name)
else
  read -r -a WORKLOADS <<< "$ROLLOUT_WORKLOADS"
fi

echo "[1/8] refresh ${WORKLOADS[*]} (imagePullPolicy=Always + rollout)..."
for w in "${WORKLOADS[@]}"; do
  kubectl -n "$NS" patch "$w" --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]' \
    >/dev/null
done
for w in "${WORKLOADS[@]}"; do kubectl -n "$NS" rollout restart "$w" >/dev/null; done
for w in "${WORKLOADS[@]}"; do kubectl -n "$NS" rollout status "$w" --timeout=180s; done

# Completed job pods never reach Ready, so only wait on the running ones.
echo "[1/8] waiting for ${NS} pods to be Ready..."
kubectl -n "$NS" wait --for=condition=Ready pod --all \
  --field-selector=status.phase=Running --timeout=300s >/dev/null

# rollout status returns before the LoadBalancer endpoints repopulate, and a host
# that PXE boots in that gap gets no answer and falls through to disk.
# nico-pxe-external-80 is waited on as well. Patch 0015 puts newrootfs on the
# kernel line, without it the loader falls back to port 80 on carbide-static-pxe.forge
echo "[1/8] waiting for the dhcp and pxe endpoints..."
for _svc in nico-dhcp-external nico-pxe-external nico-pxe-external-80; do
  for _i in $(seq 1 60); do
    [[ -n "$(kubectl -n "$NS" get endpoints "$_svc" \
      -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]] && break
    sleep 2
  done
done

admin() {
  # admin cli reads API_URL / ROOT_CA_PATH / CLIENT_CERT_PATH / CLIENT_KEY_PATH.
  kubectl -n "$NS" exec -i "$API_DEPLOY" -- env \
    API_URL="https://nico-api.${NS}.svc.cluster.local:${API_PORT}" \
    ROOT_CA_PATH=/var/run/secrets/forge-roots/ca.crt \
    CLIENT_CERT_PATH=/var/run/secrets/spiffe.io/tls.crt \
    CLIENT_KEY_PATH=/var/run/secrets/spiffe.io/tls.key \
    /opt/carbide/nico-admin-cli "$@"
}

# Tolerate reruns. "already exists" and "Not support to reset" are noops.
_seed_cred() {
  local out
  if out=$(admin "$@" 2>&1); then return 0; fi
  if printf '%s' "$out" | grep -qE 'already exists|Not support to reset'; then
    echo "  (already seeded — skipping: $*)"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

# Tolerate reruns. Fixed ids make create calls return already exists.
admin_ok() {
  local out
  if out=$(admin "$@" 2>&1); then
    if [[ -n "$out" ]]; then printf '%s\n' "$out"; fi
    return 0
  fi
  if printf '%s' "$out" | grep -qiE 'already exists|alreadyexists|duplicate'; then
    echo "  (already exists — skipping)"
    return 0
  fi
  printf '%s\n' "$out" >&2
  return 1
}

# Installs a static grpcurl into the api pod (ephemeral) so we can call gRPC
# verbs the admin-cli lacks, like DeleteVpc. Echoes the pod name. Lab dev only.
ensure_grpcurl_pod() {
  local pod tmp
  pod=$(kubectl -n "$NS" get pod -o name 2>/dev/null | sed 's|^pod/||' | grep '^nico-api-' | head -1) || return 1
  [[ -n "$pod" ]] || return 1
  if kubectl -n "$NS" exec "$pod" -c nico-api -- grpcurl --version >/dev/null 2>&1; then
    printf '%s' "$pod"
    return 0
  fi
  echo "  installing grpcurl into ${pod}..." >&2
  tmp=$(mktemp -d) || return 1
  if ! curl -fsSL "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" | tar -xz -C "$tmp" grpcurl; then
    rm -rf "$tmp"
    return 1
  fi
  kubectl -n "$NS" cp "${tmp}/grpcurl" "${pod}:/usr/local/bin/grpcurl" -c nico-api >&2 || {
    rm -rf "$tmp"
    return 1
  }
  kubectl -n "$NS" exec "$pod" -c nico-api -- chmod +x /usr/local/bin/grpcurl >&2 || {
    rm -rf "$tmp"
    return 1
  }
  rm -rf "$tmp"
  printf '%s' "$pod"
}

# UEFI creds are write once and cannot be reset, so wait until nico api
# actually serves before seeding.
echo "[+] waiting for nico-api to accept admin calls..."
for _i in $(seq 1 30); do
  admin machine show >/dev/null 2>&1 && break
  [[ "$_i" -eq 30 ]] && {
    echo "ERROR: nico-api not accepting admin calls after 60s; aborting." >&2
    exit 1
  }
  sleep 2
done

# runtime log filter that traces every Redfish call nico makes for 24h
echo "[+] enabling libredfish=debug log filter..."
admin set log-filter --filter "info,libredfish=debug" --expiry 24h >/dev/null 2>&1 ||
  echo "  (log-filter set failed; continuing)"

echo "[2/8] dropping all registered machines..."
mapfile -t MACHINE_IDS < <(
  kubectl exec -n postgres nico-pg-cluster-0 -c postgres -- \
    psql -U postgres -d nico_system_nico -tAc 'SELECT id FROM machines;' 2>/dev/null
)
# A failed delete parks the machine in forcedeletion, which the state controller ignores
# by design. Verify the row is gone rather than trusting the exit code, and stop if not.
for id in "${MACHINE_IDS[@]}"; do
  [[ -z "$id" ]] && continue
  echo "  force-delete $id"
  still=1
  for attempt in 1 2 3; do
    out=$(admin machine force-delete --machine "$id" \
      --delete-interfaces --delete-bmc-interfaces --delete-bmc-credentials \
      --allow-delete-with-instance 2>&1) || true
    still=$(kubectl exec -n postgres nico-pg-cluster-0 -c postgres -- \
      psql -U postgres -d nico_system_nico -tAc "SELECT 1 FROM machines WHERE id = '$id';" 2>/dev/null)
    [[ -z "$still" ]] && break
    echo "    attempt ${attempt} left it in place, retrying"
    sleep 5
  done
  if [[ -n "$still" ]]; then
    echo "ERROR: $id still present after 3 force-delete attempts." >&2
    printf '%s\n' "$out" | tail -5 >&2
    exit 1
  fi
done

echo "[3/8] wiping expected_machines + cached explored_endpoints..."
admin expected-machine erase --confirm >/dev/null 2>&1 ||
  echo "  (expected_machines already empty; continuing)"
kubectl exec -n postgres nico-pg-cluster-0 -c postgres -- \
  psql -U postgres -d nico_system_nico -c \
  'TRUNCATE explored_endpoints, machine_interfaces RESTART IDENTITY CASCADE;' >/dev/null

echo "[4/8] seeding sitewide BMC + UEFI credentials in Vault..."
# One shot creds that cannot be reset. A bad seed needs a Vault wipe, so
# refuse an empty password.
[[ -n "${BMC_PASSWORD}" ]] || {
  echo "ERROR: BMC_PASSWORD is empty; refusing to seed." >&2
  exit 1
}
_seed_cred credential add-bmc --kind=site-wide-root --username root --password "$BMC_PASSWORD"
_seed_cred credential add-uefi --kind=dpu --password="$BMC_PASSWORD"
_seed_cred credential add-uefi --kind=host --password="$BMC_PASSWORD"

if [[ "$BMC_PORT" != "443" ]]; then
  echo "[5/8] bmc_proxy = PortOnly($BMC_PORT) (cluster-wide)..."
  admin set bmc-proxy --enabled true --proxy ":${BMC_PORT}" >/dev/null
else
  echo "[5/8] bmc_proxy left as-is (BMC_PORT=443)"
fi

echo "[6/8] enabling create-machines..."
admin set create-machines --enable >/dev/null

echo "[7/8] creating Flat-VPC + HostInband segment (admin-cli)..."
# HostInband segments need a subdomain for DHCP, so default to the first
# domain. Override with SUBDOMAIN_ID.
SUBDOMAIN_ID="${SUBDOMAIN_ID:-}"
if [[ -z "$SUBDOMAIN_ID" ]]; then
  SUBDOMAIN_ID=$(admin -f json domain show 2>/dev/null |
    jq -r '(.domains // .)[0].id | (.value? // .)' 2>/dev/null || true)
fi
[[ -n "$SUBDOMAIN_ID" && "$SUBDOMAIN_ID" != "null" ]] || {
  echo "ERROR: no domain found for --subdomain-id (set SUBDOMAIN_ID or create a domain first)." >&2
  exit 1
}

# Matches the networks entry nico api seeds from the prereqs values at startup.
# Same name lets us adopt that segment instead of duplicating it.
SEG_NAME="${SEG_NAME:-devenv_host_inband}"

# Drain defaults to 5m and rearms while IPs stay allocated, so allow slack.
PREFIX_DRAIN_TIMEOUT="${PREFIX_DRAIN_TIMEOUT:-480}"

# Reads go through grpcurl because the segment finders do not filter on deleted
# unlike the VPC lookups, and draining segments still own their prefix.
GRPC_POD="$(ensure_grpcurl_pod)" || {
  echo "ERROR: could not prepare grpcurl in the nico-api pod; step 7 needs it." >&2
  exit 1
}

grpc() {
  kubectl -n "$NS" exec "$GRPC_POD" -c nico-api -- grpcurl \
    --cacert /var/run/secrets/forge-roots/ca.crt \
    --cert /var/run/secrets/spiffe.io/tls.crt \
    --key /var/run/secrets/spiffe.io/tls.key \
    -d "$2" \
    "nico-api.${NS}.svc.cluster.local:${API_PORT}" "forge.Forge/$1"
}

# Every segment, tombstones included. grpcurl emits lowerCamelCase field names.
_segments() {
  local _ids _n
  _ids=$(grpc FindNetworkSegmentIds '{}' 2>/dev/null |
    jq -c '{networkSegmentsIds: (.networkSegmentsIds // [])}') || return 1
  [[ -n "$_ids" ]] || return 1
  _n=$(jq '.networkSegmentsIds | length' <<<"$_ids")
  if [[ "$_n" == "0" ]]; then
    printf '{"networkSegments":[]}'
    return 0
  fi
  grpc FindNetworkSegmentsByIds "$_ids" 2>/dev/null
}

# Anything on our prefix, live or draining. Used for progress and error output.
_prefix_holders() {
  _segments 2>/dev/null | jq -r --arg p "$HOST_PREFIX" '
    .networkSegments[]?
    | select(any(.config.prefixes[]?; .prefix == $p))
    | "\(.metadata.name) [\(.config.segmentType)] " +
      (if .deleted == null then "live" else "deleting since \(.deleted)" end)' 2>/dev/null
}

SEGS="$(_segments)" || {
  echo "ERROR: could not list network segments over gRPC." >&2
  exit 1
}

# Adopt by name rather than recreate. create_initial_networks refuses to seed with
# two live VPCs of one name, so prune extras and keep the oldest.
if [[ -z "$FLAT_VPC_ID" ]]; then
  mapfile -t _live_vpcs < <(admin -f json vpc show --name "$FLAT_VPC_NAME" 2>/dev/null |
    jq -r '(.vpcs // []) | sort_by(.created)[] | .id | (.value? // .) // empty')
  if ((${#_live_vpcs[@]} > 0)) && [[ -n "${_live_vpcs[0]}" ]]; then
    FLAT_VPC_ID="${_live_vpcs[0]}"
    echo "  adopting existing VPC ${FLAT_VPC_ID}"
    for _vid in "${_live_vpcs[@]:1}"; do
      [[ -z "$_vid" ]] && continue
      # admin cli has no vpc delete verb, so DeleteVpc goes over gRPC. Lab only.
      if grpc DeleteVpc "{\"id\":{\"value\":\"${_vid}\"}}" >/dev/null 2>&1; then
        echo "  pruned duplicate VPC ${_vid}"
      else
        echo "  (could not prune duplicate VPC ${_vid}; continuing)" >&2
      fi
    done
  else
    admin_ok --cloud-unsafe-op="$CLOUD_UNSAFE_OP" vpc create \
      --name "$FLAT_VPC_NAME" \
      --description "Flat VPC for zero-DPU HostInband" \
      --org-id "$ORG_ID" \
      --virtualization-type flat
    FLAT_VPC_ID=$(admin -f json vpc show --name "$FLAT_VPC_NAME" 2>/dev/null |
      jq -r '(.vpcs // [])[0].id | (.value? // .) // empty')
    echo "  created VPC ${FLAT_VPC_ID}"
  fi
fi
[[ -n "$FLAT_VPC_ID" ]] || {
  echo "ERROR: could not resolve the ${FLAT_VPC_NAME} VPC id." >&2
  exit 1
}

# Adopt only on a full field match, so overriding HOST_PREFIX, HOST_GW, SEG_MTU or
# RESERVE_FIRST still forces a rebuild that matches the seeded defaults.
SEG_ADOPTED=$(jq -r \
  --arg n "$SEG_NAME" --arg v "$FLAT_VPC_ID" --arg p "$HOST_PREFIX" --arg g "$HOST_GW" \
  --argjson m "$SEG_MTU" --argjson r "$RESERVE_FIRST" '
  .networkSegments[]?
  | select(.deleted == null)
  | select(.metadata.name == $n)
  | select(.config.segmentType == "HOST_INBAND")
  | select((.config.vpcId.value // "") == $v)
  | select((.config.mtu // 0) == $m)
  | select((.config.prefixes | length) == 1)
  | select(.config.prefixes[0].prefix == $p)
  | select((.config.prefixes[0].gateway // "") == $g)
  | select((.config.prefixes[0].reserveFirst // 0) == $r)
  | .id.value' <<<"$SEGS" 2>/dev/null | head -1)

if [[ -n "$SEG_ADOPTED" ]]; then
  echo "  adopting existing segment ${SEG_NAME} (${SEG_ADOPTED}), fields already match"
  SEG_ID="$SEG_ADOPTED"
else
  # Delete only real blockers, a live segment on our name or prefix. Leave UNDERLAY
  # so the static assignment anchor that site explorer needs for the BMC survives.
  mapfile -t _conflicts < <(jq -r --arg n "$SEG_NAME" --arg p "$HOST_PREFIX" '
    .networkSegments[]?
    | select(.deleted == null)
    | select(.config.segmentType != "UNDERLAY")
    | select(.metadata.name == $n or any(.config.prefixes[]?; .prefix == $p))
    | .id.value' <<<"$SEGS" 2>/dev/null)
  for _seg in "${_conflicts[@]}"; do
    [[ -z "$_seg" ]] && continue
    if admin --cloud-unsafe-op="$CLOUD_UNSAFE_OP" network-segment delete --id "$_seg" >/dev/null 2>&1; then
      echo "  deleted conflicting segment ${_seg}"
    else
      echo "  (could not delete segment ${_seg}; continuing)" >&2
    fi
  done

  # A delete only tombstones the segment and its prefix stays allocated until the
  # controller drains it, so retry the create until the prefix overlap clears.
  _deadline=$((SECONDS + PREFIX_DRAIN_TIMEOUT))
  while :; do
    if _out=$(admin --cloud-unsafe-op="$CLOUD_UNSAFE_OP" network-segment create \
      --name "$SEG_NAME" \
      ${SEG_ID:+--id "$SEG_ID"} \
      --vpc-id "$FLAT_VPC_ID" \
      --subdomain-id "$SUBDOMAIN_ID" \
      --segment-type host-inband \
      --mtu "$SEG_MTU" \
      --prefix "$HOST_PREFIX" \
      --gateway "$HOST_GW" \
      --reserve-first "$RESERVE_FIRST" 2>&1); then
      break
    fi
    if ! grep -qi 'prefix overlaps' <<<"$_out"; then
      printf '%s\n' "$_out" >&2
      exit 1
    fi
    if ((SECONDS >= _deadline)); then
      echo "ERROR: ${HOST_PREFIX} still held after ${PREFIX_DRAIN_TIMEOUT}s by:" >&2
      _prefix_holders >&2 || true
      echo "       raise PREFIX_DRAIN_TIMEOUT, or lower network_segment_drain_time" >&2
      echo "       under network_segment_state_controller in the nico-api config." >&2
      exit 1
    fi
    echo "  ${HOST_PREFIX} still draining: $(_prefix_holders | tr '\n' ';')"
    sleep 15
  done

  SEG_ID=$(_segments | jq -r --arg n "$SEG_NAME" '
    [.networkSegments[]? | select(.deleted == null) | select(.metadata.name == $n) | .id.value][0] // empty')
  echo "  created segment ${SEG_NAME} (${SEG_ID:-id unknown})"
fi

# DHCP leases come from this segment, so wait for ready before step 8 registers a
# machine that needs an address.
for _i in $(seq 1 40); do
  _seg_state=$(_segments | jq -r --arg i "$SEG_ID" '
    [.networkSegments[]? | select(.id.value == $i) | .status.lifecycle.state][0] // empty' 2>/dev/null)
  [[ "$_seg_state" == *'"ready"'* ]] && break
  if [[ "$_i" -eq 40 ]]; then
    echo "  (segment not ready after 120s: ${_seg_state:-unknown}; continuing)" >&2
    break
  fi
  sleep 3
done

# `expected-machine add` has no upsert, so a rerun collides with the row already
# there. Delete by BMC MAC first and treat a miss on the first run as fine.
if admin expected-machine delete "$BMC_MAC" >/dev/null 2>&1; then
  echo "[8/8] removed existing ExpectedMachine for $BMC_MAC"
fi

echo "[8/8] registering ExpectedMachine $BMH_NAME (bmc=$BMC_MAC, boot=$BOOT_MAC @ ${BMC_IP}:${BMC_PORT}, host=$HOST_IP)..."
HOST_NICS_JSON=$(printf '[{"mac_address":"%s","fixed_ip":"%s","primary":true}]' "$BOOT_MAC" "$HOST_IP")
add_args=(
  --bmc-mac-address "$BMC_MAC"
  --bmc-ip-address "$BMC_IP"
  --bmc-username "$BMC_USERNAME"
  --bmc-password "$BMC_PASSWORD"
  --bmc-retain-credentials true
  --chassis-serial-number "$SERIAL"
  --dpu-mode no-dpu
  --dpf-enabled false
  --disable-lockdown true
  --host_nics "$HOST_NICS_JSON"
  --meta-name "$BMH_NAME"
  --meta-description "registered by register.sh"
)
admin expected-machine add "${add_args[@]}"

cat <<EOF

Done. Watch site-explorer for the next ~60s:

  kubectl -n nico-system logs deploy/nico-api --since=2m \\
    | grep -E '^level=' \\
    | grep -iE 'explore_site|${BMC_IP}|created_machines|Unsupported|vendor|skipping BMC'

And the machines:

  watch -n 5 '${REPO_DIR}/lab/scripts/admin-cli.sh machine show'
EOF

# Optional. Provision an instance once the machine reaches Ready.
if [[ "${ALLOCATE_INSTANCE:-false}" == "true" ]]; then
  exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/provision-instance.sh"
fi
