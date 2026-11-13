#!/usr/bin/env bash
# Deploys NICo Core. Re-applies base plus the lab.env flavour, then runs setup.sh without
# REST and RMS, and with DPF only for the dpf flavour. Extra args pass through.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIRTLAB_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
NICO_DIR="${NICO_DIR:-$VIRTLAB_ROOT/infra-controller}"
LAB_ENV="${HERE}/lab.env"
REGISTRY_ENV="${REGISTRY_ENV:-$VIRTLAB_ROOT/lab/registry.env}"

[[ -f "$LAB_ENV" ]] || {
  echo "ERROR: ${LAB_ENV} missing; run env.sh to generate it." >&2
  exit 1
}
# Same files .local_envrc sources, so this works without direnv too.
# shellcheck disable=SC1090
[[ -f "$REGISTRY_ENV" ]] && source "$REGISTRY_ENV"
# shellcheck disable=SC1090
source "$LAB_ENV"

FLAVOR="${NICO_LAB_FLAVOR:-sushy}"
GROUPS_SEL="base,${FLAVOR}"
echo "=== lab patch groups: ${GROUPS_SEL} ==="
NICO_ROOT="$NICO_DIR" "$VIRTLAB_ROOT/lab/patches/apply.sh" -g "$GROUPS_SEL"

ARGS=(--skip-rest --skip-rms)
if [[ "$FLAVOR" != dpf ]]; then
  ARGS+=(--skip-dpf)
else
  DPF_ENV="${DPF_ENV:-$VIRTLAB_ROOT/lab/dpf.env}"
  # shellcheck disable=SC1090
  [[ -f "$DPF_ENV" ]] && source "$DPF_ENV"
  # DPUServices come from our registry, nvcr.io stays anonymous unless a key is set.
  export NICO_DPF_LAB_REGISTRY="${NICO_DPF_LAB_REGISTRY:-$NICO_IMAGE_REGISTRY}"
  export NICO_DPF_NGC_API_KEY="${NICO_DPF_NGC_API_KEY-}"
  # k0s labels its controller control-plane=true, keepalived for the DPU VIP selects on it.
  export NICO_DPF_CP_LABEL_VALUE="${NICO_DPF_CP_LABEL_VALUE-true}"
fi

cd "$NICO_DIR"
exec helm-prereqs/setup.sh "${ARGS[@]}" "$@"
