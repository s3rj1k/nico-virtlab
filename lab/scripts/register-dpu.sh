#!/usr/bin/env bash
# Registers DPU hosts as DPF-managed ExpectedMachines, wiping nothing.
# One host from env, or every entry of an expected_machines JSON file (NICo format).
#   DPU_HOST_BMC_MAC=aa:bb:.. DPU_HOST_SERIAL=XYZ DPU_HOST_BMC_PASSWORD=.. lab/scripts/register-dpu.sh
#   DPU_HOSTS_FILE=expected-machines.json lab/scripts/register-dpu.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADMIN="${HERE}/admin-cli.sh"

# Args: name bmc_mac serial user password bmc_ip dpu_serials_csv interfaces_json
register_one() {
  local name="${1:-dpuhost-$3}" mac="$2" serial="$3" user="$4" pass="$5" ip="$6" serials="$7" ifaces="$8"
  # No upsert, so drop this host's own row first. A miss on the first run is fine.
  "$ADMIN" expected-machine delete "$mac" >/dev/null 2>&1 &&
    echo "removed existing ExpectedMachine for $mac"
  local args=(
    --bmc-mac-address "$mac"
    --bmc-username "$user"
    --bmc-password "$pass"
    --chassis-serial-number "$serial"
    --dpf-enabled true
    --dpu-policy manage
    --disable-lockdown "${DPU_HOST_DISABLE_LOCKDOWN:-false}"
    --meta-name "$name"
    --meta-description "registered by register-dpu.sh"
  )
  [[ -n "$ip" ]] && args+=(--bmc-ip-address "$ip")
  [[ -n "$ifaces" && "$ifaces" != "null" ]] && args+=(--interfaces "$ifaces")
  local s _serials
  IFS=',' read -r -a _serials <<< "$serials"
  for s in "${_serials[@]}"; do [[ -n "$s" ]] && args+=(--fallback-dpu-serial-number "$s"); done
  echo "registering ExpectedMachine $name (bmc=$mac${ip:+ @ $ip} serial=$serial dpf=true)..."
  "$ADMIN" expected-machine add "${args[@]}"
}

"$ADMIN" set create-machines --enable >/dev/null

if [[ -n "${DPU_HOSTS_FILE:-}" ]]; then
  n="$(jq '.expected_machines | length' "$DPU_HOSTS_FILE")"
  for ((i = 0; i < n; i++)); do
    e="$(jq -c ".expected_machines[$i]" "$DPU_HOSTS_FILE")"
    f() { jq -r "$1 // empty" <<< "$e"; }
    register_one \
      "$(f '.metadata.name')" "$(f '.bmc_mac_address')" "$(f '.chassis_serial_number')" \
      "$(f '.bmc_username')" "$(f '.bmc_password')" "$(f '.bmc_ip_address')" \
      "$(jq -r '(.fallback_dpu_serial_numbers // []) | join(",")' <<< "$e")" \
      "$(jq -c '.interfaces // empty' <<< "$e")"
  done
else
  register_one \
    "${DPU_HOST_NAME:-dpuhost1}" \
    "${DPU_HOST_BMC_MAC:?set DPU_HOST_BMC_MAC, the host BMC MAC}" \
    "${DPU_HOST_SERIAL:?set DPU_HOST_SERIAL, the chassis serial}" \
    "${DPU_HOST_BMC_USERNAME:-root}" \
    "${DPU_HOST_BMC_PASSWORD:?set DPU_HOST_BMC_PASSWORD}" \
    "${DPU_HOST_BMC_IP:-}" "${DPU_HOST_DPU_SERIALS:-}" "${DPU_HOST_INTERFACES:-}"
fi
echo "watch it with: lab/scripts/admin-cli.sh machine show"
