#!/usr/bin/env bash
# Provisions a dpuless machine. Registers the OS image, reuses the live instance or
# allocates one onto the flat VPC, then reboots with custom pxe to image the disk.
# Rerunning only reimages. Recycling or reenrolling a machine is register.sh.
set -euo pipefail

LAB_ENV="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lab.env"
[[ -f "$LAB_ENV" ]] || {
  echo "ERROR: ${LAB_ENV} missing; run env.sh to generate it." >&2
  exit 1
}
# shellcheck disable=SC1090
source "$LAB_ENV"

NS=nico-system
API_PORT=1079
API_DEPLOY=deploy/nico-api

# Ack string for cloud unsafe ops.
CLOUD_UNSAFE_OP="${CLOUD_UNSAFE_OP:-devenv}"

# pin a machine, empty means first Ready one
MACHINE_ID="${MACHINE_ID:-}"
TENANT_ORG="${TENANT_ORG:-devenv_test_org}"
# Flat VPC to allocate into, created by register.sh. The API assigns its id, so it
# is resolved by name below and an empty FLAT_VPC_ID means resolve FLAT_VPC_NAME.
FLAT_VPC_NAME="${FLAT_VPC_NAME:-devenv_flat_vpc}"
FLAT_VPC_ID="${FLAT_VPC_ID:-}"
# used only when OS_IMAGE_URL is empty, no double quotes
IPXE_SCRIPT="${IPXE_SCRIPT:-chain --autofree https://boot.netboot.xyz}"
# Debian generic, not genericcloud, and debian only. An ubuntu cloud image ships a
# virtual kernel with no linux modules extra, so it has no driver for the boot nic.
OS_IMAGE_BUILD="${OS_IMAGE_BUILD:-20260810-2566}"
# Dated build, never latest. Upstream rebuilds latest in place, which moves the digest
# and the root fs uuid out from under an already registered os_image, both silently.
OS_IMAGE_URL="${OS_IMAGE_URL-https://cloud.debian.org/images/cloud/trixie/${OS_IMAGE_BUILD}/debian-13-generic-amd64-${OS_IMAGE_BUILD}.qcow2}"
# digest, empty reads SHA512SUMS next to the url
OS_IMAGE_SHA="${OS_IMAGE_SHA:-}"
# preregistered os_image uuid, derived from url when empty
OS_IMAGE_ID="${OS_IMAGE_ID:-}"
# The debian image labels no filesystem, so the imager finds root by uuid and quietly
# skips the seed when that resolves to nothing. A run probes the image and overrides.
OS_IMAGE_ROOTFS_UUID="${OS_IMAGE_ROOTFS_UUID-6d1bd696-738f-4565-8c0c-b1b51bc7c3d7}"
# The sushy VM boots a single virtio disk, and the imager only autodetects
# nvme0n1/sda, so pin it rather than relying on find_bootdisk.
OS_IMAGE_BOOT_DISK="${OS_IMAGE_BOOT_DISK-/dev/vda}"
# The image ships no sshd host keys and cc_ssh does not always generate them, so
# bootcmd does it early and idempotently before sshd starts.

# The user is created here instead of inherited from the image default, so the keys
# have to live in the user block. Top level keys only reach a default marked user.
# The password is for the serial console only and ssh stays key only. The drop in
# sorts ahead of the cloud init one because sshd keeps the first value it reads.
DEFAULT_USER_DATA=$(cat <<'YAML'
#cloud-config
ssh_pwauth: false
ssh_deletekeys: false
disable_root: true
users:
  - name: debian
    gecos: Debian
    shell: /bin/bash
    lock_passwd: false
    groups: [adm, sudo]
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKLrIiGjB4nPsyKzgzY21asVi/HKlveRnNY77vOhRhOA
      - ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBCPagTtscBi9vEGuH7BgFoURfrDRaC73gyOPdadub8sjUPsLjkMDrEKfVcALtQGLjY8KLr+BusayRYLDcZmgSayjKEgrKAFxJcu8YAfOYC+rptOyWs9uEERLf5RcXJV4Mw==
bootcmd:
  - [ sh, -c, "ssh-keygen -A || true" ]
runcmd:
  - [ sh, -c, "echo 'debian:debian' | chpasswd" ]
  - [ sh, -c, "install -d -m 0755 /etc/ssh/sshd_config.d" ]
  - [ sh, -c, "echo 'PermitRootLogin no' > /etc/ssh/sshd_config.d/00-forge.conf" ]
  - [ sh, -c, "echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config.d/00-forge.conf" ]
  - [ sh, -c, "echo 'KbdInteractiveAuthentication no' >> /etc/ssh/sshd_config.d/00-forge.conf" ]
  - [ sh, -c, "systemctl enable ssh || true" ]
  - [ sh, -c, "systemctl restart ssh || true" ]
  - [ sh, -c, "date -u +%Y-%m-%dT%H:%M:%SZ > /nico-provisioned-at" ]
YAML
)
USER_DATA="${USER_DATA-$DEFAULT_USER_DATA}"
# Only used when there is no instance yet and one has to be allocated.
READY_TIMEOUT="${READY_TIMEOUT:-900}"
# Covers imaging plus the reboots after it.
PROVISION_TIMEOUT="${PROVISION_TIMEOUT:-1800}"
# How long the host gets to start the install, it has to POST and netboot first.
LEAVE_TIMEOUT="${LEAVE_TIMEOUT:-600}"
# How long a freshly allocated machine gets to settle into assigned/ready.
SETTLE_TIMEOUT="${SETTLE_TIMEOUT:-600}"

if [[ -n "$OS_IMAGE_URL" && -z "$OS_IMAGE_ID" ]]; then # stable id per url => idempotent re-runs
  OS_IMAGE_ID=$(python3 -c 'import sys,uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, sys.argv[1]))' "$OS_IMAGE_URL")
fi

# Builds the OS config JSON for instance allocate. OS_IMAGE_ID does a disk
# install, otherwise an inline iPXE live boot. OS_JSON overrides it.
if [[ -z "${OS_JSON:-}" ]]; then
  if [[ -n "$OS_IMAGE_ID" ]]; then
    OS_JSON=$(printf \
      '{"variant":{"OsImageId":{"value":"%s"}},"phone_home_enabled":false,"run_provisioning_instructions_on_every_boot":false}' \
      "$OS_IMAGE_ID")
  else
    OS_JSON=$(printf \
      '{"variant":{"Ipxe":{"ipxe_script":"%s"}},"phone_home_enabled":false,"run_provisioning_instructions_on_every_boot":true}' \
      "$IPXE_SCRIPT")
  fi
  if [[ -n "$USER_DATA" ]]; then
    OS_JSON=$(printf '%s' "$OS_JSON" | python3 -c \
      'import sys,json; d=json.load(sys.stdin); d["user_data"]=sys.argv[1]; print(json.dumps(d))' "$USER_DATA")
  fi
fi

admin() {
  # admin cli reads API_URL / ROOT_CA_PATH / CLIENT_CERT_PATH / CLIENT_KEY_PATH.
  kubectl -n "$NS" exec -i "$API_DEPLOY" -- env \
    API_URL="https://nico-api.${NS}.svc.cluster.local:${API_PORT}" \
    ROOT_CA_PATH=/var/run/secrets/forge-roots/ca.crt \
    CLIENT_CERT_PATH=/var/run/secrets/spiffe.io/tls.crt \
    CLIENT_KEY_PATH=/var/run/secrets/spiffe.io/tls.key \
    /opt/carbide/nico-admin-cli "$@"
}

jqa() { # admin cli json through a jq filter, empty on any failure
  admin -f json "${@:2}" 2>/dev/null | jq -r "$1" 2>/dev/null || true
}

machine_state() { # composite state as the api reports it, e.g. assigned/ready
  jqa ".machines[] | select(.id == \"$1\") | .state | ascii_downcase" machine show
}

image_rootfs_uuid() {
  # Prints the ext4 root uuid of a remote qcow2, empty when it cannot be read. The
  # image is not downloaded, qemu-io asks for byte ranges, about 2 MiB per probe.
  local url="$1" opts hdr entries entry sb uuid count size start i
  [[ "$url" == *://* ]] && command -v qemu-io >/dev/null 2>&1 || return 1
  opts="driver=qcow2,file.driver=${url%%://*},file.url=$url"

  qio() { # hex of a byte range, 16 byte columns per line, ascii column dropped
    qemu-io -r --image-opts "$opts" -c "read -v $1 $2" 2>/dev/null |
      awk '$1 ~ /^[0-9a-f]{8,}:$/ && NF >= 17 { for (i = 2; i <= 17; i++) printf "%s", $i }'
  }
  le() { # little endian field at hex offset $2, $3 hex digits long, as decimal
    local hex="${1:$2:$3}" out="" i
    for ((i = ${#hex}; i > 0; i -= 2)); do out+="${hex:i-2:2}"; done
    printf '%d' "0x$out"
  }

  hdr=$(qio 512 512)                                       # GPT header, lba 1
  [[ "${hdr:0:16}" == "4546492050415254" ]] || return 1    # "EFI PART"
  count=$(le "$hdr" 160 8)                                 # entry count, 0x50
  size=$(le "$hdr" 168 8)                                  # entry size, 0x54
  ((count > 0 && size >= 128)) || return 1
  entries=$(qio 1024 $((count * size < 16384 ? count * size : 16384)))

  # Debian ships the root as the one ext4 partition, next to BIOS boot and the ESP.
  for ((i = 0; i < count; i++)); do
    entry="${entries:i*size*2:size*2}"
    ((${#entry} == size * 2)) || break
    [[ "${entry:0:32}" == "00000000000000000000000000000000" ]] && continue
    start=$(le "$entry" 64 16)                             # first lba, 0x20
    sb=$(qio $((start * 512 + 1024)) 1024)                 # ext superblock, 1 KiB in
    [[ "${sb:112:4}" == "53ef" ]] || continue              # s_magic 0xef53, 0x38
    uuid="${sb:208:32}"                                    # s_uuid, 0x68
    printf '%s-%s-%s-%s-%s\n' "${uuid:0:8}" "${uuid:8:4}" "${uuid:12:4}" \
      "${uuid:16:4}" "${uuid:20:12}"
    return 0
  done
  return 1
}

echo "[1/4] looking for a live instance..."
# Reusing the instance is the common path. Allocating is only for a fresh machine,
# and releasing is deliberately not done here because it triggers the full scrub.
INSTANCE_ID=""
if [[ -n "$MACHINE_ID" ]]; then
  INSTANCE_ID=$(jqa ".instances[] | select(.machine_id == \"$MACHINE_ID\") | .id" instance show | head -1)
else
  # Not read from a process substitution, an empty list gives it EOF, which returns
  # non zero and set -e then kills the script with no output at all.
  pair=$(jqa '.instances[] | "\(.id) \(.machine_id)"' instance show | head -1)
  if [[ -n "$pair" ]]; then
    read -r INSTANCE_ID MACHINE_ID <<<"$pair"
  fi
fi
REUSED=false
if [[ -n "$INSTANCE_ID" ]]; then
  REUSED=true
  echo "  reusing instance $INSTANCE_ID on machine $MACHINE_ID"
else
  echo "  (none, will allocate)"
fi

echo "[2/4] ensuring OS image..."
if [[ -n "$OS_IMAGE_URL" ]]; then
  if probed=$(image_rootfs_uuid "$OS_IMAGE_URL"); then
    if [[ "$probed" != "$OS_IMAGE_ROOTFS_UUID" ]]; then
      echo "  root uuid ${OS_IMAGE_ROOTFS_UUID:-<unset>} -> $probed, read from the image"
      OS_IMAGE_ROOTFS_UUID="$probed"
    fi
  else
    echo "  WARNING: could not read the root uuid from ${OS_IMAGE_URL##*/}. This needs" >&2
    echo "  qemu-io from qemu-utils plus its curl module, which debian splits out into" >&2
    echo "  qemu-block-extra. Falling back to ${OS_IMAGE_ROOTFS_UUID:-<unset>}." >&2
  fi

  have=$(jqa ".[] | select(.attributes.id.value == \"$OS_IMAGE_ID\")
    | [.attributes.rootfs_id // \"\", .attributes.boot_disk // \"\"] | @tsv" os-image show)
  if [[ -n "$have" ]]; then
    IFS=$'\t' read -r have_uuid have_disk <<<"$have"
    echo "  $OS_IMAGE_ID already registered"
    # Neither is settable after create, so both are ignored from the second run on. A
    # wrong rootfs uuid is the quiet one, the imager never mounts root and drops the seed.
    for got_want in "rootfs_uuid:$have_uuid:$OS_IMAGE_ROOTFS_UUID" "boot_disk:$have_disk:$OS_IMAGE_BOOT_DISK"; do
      IFS=: read -r field got want <<<"$got_want"
      [[ "$got" == "$want" ]] && continue
      echo "  WARNING: registered $field is '${got:-<unset>}' but this run wants '${want:-<unset>}'." >&2
      echo "  os-image update cannot change it, delete and recreate the image:" >&2
      echo "  $(dirname "$0")/admin-cli.sh os-image delete -i $OS_IMAGE_ID -t $TENANT_ORG" >&2
    done
  else
    if [[ -z "$OS_IMAGE_SHA" ]]; then
      # Debian publishes SHA512SUMS only, the imager picks the hash by digest length.
      OS_IMAGE_SHA=$(curl -sfL --max-time 60 "${OS_IMAGE_URL%/*}/SHA512SUMS" |
        awk -v f="${OS_IMAGE_URL##*/}" '$2 == f || $2 == ("*" f) {print $1; exit}' || true)
      [[ -n "$OS_IMAGE_SHA" ]] || {
        echo "ERROR: no OS_IMAGE_SHA and no SHA512SUMS next to ${OS_IMAGE_URL##*/}." >&2
        exit 1
      }
    fi
    create_args=(-i "$OS_IMAGE_ID" -u "$OS_IMAGE_URL" -m "$OS_IMAGE_SHA" -t "$TENANT_ORG"
      -n "${OS_IMAGE_URL##*/}")
    [[ -n "$OS_IMAGE_ROOTFS_UUID" ]] && create_args+=(-f "$OS_IMAGE_ROOTFS_UUID")
    [[ -n "$OS_IMAGE_BOOT_DISK" ]] && create_args+=(-b "$OS_IMAGE_BOOT_DISK")
    admin os-image create "${create_args[@]}"
    echo "  registered $OS_IMAGE_ID (${OS_IMAGE_URL##*/}, sha ${OS_IMAGE_SHA:0:12}…)"
  fi
elif [[ -n "$OS_IMAGE_ID" ]]; then
  [[ -n "$(jqa ".[] | select(.attributes.id.value == \"$OS_IMAGE_ID\") | .attributes.id.value" os-image show)" ]] || {
    echo "ERROR: os_image $OS_IMAGE_ID not registered (set OS_IMAGE_URL to register it)." >&2
    exit 1
  }
else
  echo "  (inline iPXE — skipped)"
fi

if [[ -z "$INSTANCE_ID" ]]; then
echo "[3/4] waiting up to ${READY_TIMEOUT}s for a Ready machine..."
FOUND=""
for ((t = 0; t < READY_TIMEOUT; t += 10)); do
  if [[ -n "$MACHINE_ID" ]]; then
    [[ "$(machine_state "$MACHINE_ID")" == "ready" ]] && FOUND="$MACHINE_ID"
  else
    # Any Ready machine that no live instance already claims.
    claimed=$(jqa '.instances[].machine_id' instance show)
    for cand in $(jqa '.machines[] | select(.state == "Ready") | .id' machine show); do
      grep -qxF "$cand" <<<"$claimed" || { FOUND="$cand"; break; }
    done
  fi
  [[ -n "$FOUND" ]] && break
  st_now=$(jqa '.machines[0].state' machine show)
  if [[ -n "$st_now" && "$st_now" != "${prev_st:-}" ]]; then
    echo "  state: $st_now"
    prev_st="$st_now"
  fi
  sleep 10
done
if [[ -z "$FOUND" ]]; then
  echo "ERROR: no Ready machine within ${READY_TIMEOUT}s." >&2
  echo "Run register.sh first, or watch discovery with:" >&2
  echo "  $(dirname "$0")/admin-cli.sh machine show" >&2
  exit 1
fi
MACHINE_ID="$FOUND"
echo "  machine $MACHINE_ID is Ready"

# The VPC id is API-assigned (register.sh created it), so resolve it by name.
if [[ -z "$FLAT_VPC_ID" ]]; then
  FLAT_VPC_ID=$(admin -f json vpc show --name "$FLAT_VPC_NAME" 2>/dev/null |
    jq -r '(.vpcs // [])[0].id | (.value? // .) // empty')
fi
[[ -n "$FLAT_VPC_ID" ]] || {
  echo "ERROR: no ${FLAT_VPC_NAME} VPC found; run register.sh first." >&2
  exit 1
}

echo "[4/4] allocating zero-DPU instance '${BMH_NAME}_0' (flat_vpc=$FLAT_VPC_ID, os=${OS_IMAGE_ID:-inline-ipxe})..."
# Allocates onto the flat VPC with auto networking (the dpuless HostInband
# path). The instance is named "${BMH_NAME}_0" and the org comes from the VPC.
alloc_out=$(admin --cloud-unsafe-op "$CLOUD_UNSAFE_OP" instance allocate \
  --machine-id "$MACHINE_ID" \
  --flat-vpc-id "$FLAT_VPC_ID" \
  --prefix-name "$BMH_NAME" \
  --os "$OS_JSON" 2>&1) || true
printf '%s\n' "$alloc_out"

INSTANCE_ID=$(jqa ".instances[] | select(.machine_id == \"$MACHINE_ID\") | .id" instance show | head -1)
if [[ -z "$INSTANCE_ID" ]]; then
  echo "ERROR: no instance appeared for machine $MACHINE_ID — allocate failed (see output above)." >&2
  if grep -q 'found unknown segments' <<<"$alloc_out"; then
    cat >&2 <<HINT

"found unknown segments" means this machine has more than one host nic on the same
network segment. Allocate makes one instance interface per nic but looks the segments up
with an IN query, so two nics on one segment count as one segment against two interfaces
and it refuses. Nothing is actually missing. List them with:

  $(dirname "$0")/admin-cli.sh machine-interfaces show

Every Data row sharing a segment with the primary has to go. machine-interfaces delete
refuses while a machine is attached, so the extra row is removed in the database, address
row first. The lasting fix is to stop the second port netbooting so it never registers.
HINT
  fi
  exit 1
fi
echo "  instance $INSTANCE_ID created"
fi

# A reused instance still carries the os config it was allocated with, so changing the
# image or the user data here would otherwise reimage with the old one.
if [[ "$REUSED" == "true" ]]; then
  echo "applying current OS config to the existing instance..."
  admin --cloud-unsafe-op "$CLOUD_UNSAFE_OP" instance update-os \
    --instance "$INSTANCE_ID" --os "$OS_JSON"
fi

# A freshly allocated machine is still walking Ready to PreAssignedMeasuring to
# Assigned, so settle first or the leave check below passes on the first poll.
echo "waiting up to ${SETTLE_TIMEOUT}s for assigned/ready before requesting the install..."
settled=""
for ((t = 0; t < SETTLE_TIMEOUT; t += 10)); do
  st=$(machine_state "$MACHINE_ID")
  if [[ "$st" == "assigned/ready" ]]; then
    settled=1
    break
  fi
  if [[ -n "$st" && "$st" != "${prev_settle:-}" ]]; then
    echo "  state: $st"
    prev_settle="$st"
  fi
  sleep 10
done
if [[ -z "$settled" ]]; then
  echo "ERROR: machine did not reach assigned/ready within ${SETTLE_TIMEOUT}s (last: ${st:-unknown})." >&2
  exit 1
fi

# Allocation alone leaves the machine at assigned/ready serving exit instructions, so
# the OS install only runs on a boot requested with custom pxe, which is all a rerun needs.

# The instance user_data is only served while the machine is Assigned/Ready and the
# imager fetches its seed mid install, so the boot override is what that path reads.
if [[ -n "$USER_DATA" ]]; then
  # Every host nic, not just the primary. The override is keyed on the interface and
  # the api picks it from the source ip, so the other port would find no override.
  mapfile -t BOOT_IFACES < <(jqa ".machines[] | select(.id == \"$MACHINE_ID\") | .interfaces[] | select(.is_bmc == false) | .id" machine show)
  # jqa hides every failure, so an empty list can also mean the filter stopped matching.
  # Provisioning on into the discovery template wastes a full install, so stop here.
  if ((${#BOOT_IFACES[@]} == 0)) || [[ -z "${BOOT_IFACES[0]}" ]]; then
    echo "ERROR: no non-BMC interface found for machine $MACHINE_ID, refusing to image." >&2
    echo "Without an override the imager seeds the discovery template, not USER_DATA. Check:" >&2
    echo "  $0 is filtering on .is_bmc == false, confirm that field is still emitted" >&2
    echo "  kubectl -n $NS exec $API_DEPLOY -- /opt/carbide/nico-admin-cli -f json machine show" >&2
    exit 1
  fi
  # The cli reads user data from a file and runs inside the api pod, so stage it there.
  UD_PATH=/tmp/forge-user-data.yaml
  printf '%s' "$USER_DATA" | kubectl -n "$NS" exec -i "$API_DEPLOY" -- sh -c "cat > $UD_PATH"
  # A slice of the payload, enough to prove the override really carries it back.
  UD_PROBE=$(printf '%s' "$USER_DATA" | awk 'NF && $0 !~ /^#/ {print substr($0, 1, 24); exit}')
  [[ -n "$UD_PROBE" ]] || {
    echo "ERROR: USER_DATA has no payload line to verify the boot override against." >&2
    exit 1
  }
  for iface in "${BOOT_IFACES[@]}"; do
    [[ -z "$iface" ]] && continue
    echo "seeding user-data via boot override on interface $iface..."
    admin boot-override set "$iface" -u "$UD_PATH" >/dev/null
    # set exits 0 even when nothing lands, and the cli logs the readback through
    # tracing, so fold stderr in before matching.
    if ! admin boot-override get "$iface" 2>&1 | grep -qF -- "$UD_PROBE"; then
      echo "ERROR: boot override on interface $iface came back without the user-data." >&2
      echo "  kubectl -n $NS exec $API_DEPLOY -- /opt/carbide/nico-admin-cli boot-override get $iface" >&2
      exit 1
    fi
    echo "  override verified on $iface"
  done
  kubectl -n "$NS" exec "$API_DEPLOY" -- rm -f "$UD_PATH" >/dev/null 2>&1 || true
fi

echo "requesting custom-pxe reboot to run the OS install..."
admin --cloud-unsafe-op "$CLOUD_UNSAFE_OP" instance reboot \
  --instance "$INSTANCE_ID" --custom-pxe

# On a rerun the machine is already assigned/ready, so waiting for that state alone
# matches on the first poll. Wait for it to leave first, that is the install starting.
echo "waiting for the host to leave assigned/ready (install starting)..."
for ((t = 0; t < LEAVE_TIMEOUT; t += 10)); do
  [[ "$(machine_state "$MACHINE_ID")" != "assigned/ready" ]] && break
  sleep 10
done
if [[ "$(machine_state "$MACHINE_ID")" == "assigned/ready" ]]; then
  echo "ERROR: host never left assigned/ready within ${LEAVE_TIMEOUT}s, the install did not start." >&2
  echo "NICo is likely serving exit instructions; check the pxe log for a qcow-imager fetch:" >&2
  echo "  kubectl -n $NS logs deploy/nico-pxe --since=10m | grep qcow-imager" >&2
  exit 1
fi

echo "waiting up to ${PROVISION_TIMEOUT}s for assigned/ready (Redfish power-cycle + iPXE boot)..."
echo "  (watch the boot live: ssh $(id -un)@${BMC_IP} sudo virsh console ${BMC_REDFISH_ID})"
prev=""
state=""
for ((t = 0; t < PROVISION_TIMEOUT; t += 10)); do
  state=$(machine_state "$MACHINE_ID" || true)
  if [[ -n "$state" && "$state" != "$prev" ]]; then
    echo "  state: $state"
    prev="$state"
  fi
  [[ "$state" == "assigned/ready" ]] && break
  sleep 10
done
if [[ "$state" != "assigned/ready" ]]; then
  echo "ERROR: machine did not reach assigned/ready within ${PROVISION_TIMEOUT}s (last: ${state:-unknown})." >&2
  echo "Debug:" >&2
  echo "  kubectl -n $NS logs $API_DEPLOY --since=10m | grep -iE 'instance|power|ipxe|libredfish'" >&2
  exit 1
fi

ADDRESSES=$(jqa ".machines[] | select(.id == \"$MACHINE_ID\") | .interfaces[] | select(.is_bmc == false) | .address[]?" machine show | paste -sd, -)

cat <<EOF

Done. Instance ${BMH_NAME}_0 is provisioned:

  instance:  $INSTANCE_ID
  machine:   $MACHINE_ID
  addresses: ${ADDRESSES:-<none allocated>}

Inspect / follow up:

  $(basename "$0"): rerun to reimage the same instance
  register.sh:  reenroll the machine from scratch
  nico-admin-cli:  instance show $INSTANCE_ID
  console:    ssh $(id -un)@${BMC_IP} sudo virsh console ${BMC_REDFISH_ID}
  api logs:   kubectl -n $NS logs $API_DEPLOY --since=5m | grep -iE 'instance|power|ipxe|libredfish'
EOF
