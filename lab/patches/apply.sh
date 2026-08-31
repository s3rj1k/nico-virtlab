#!/usr/bin/env bash
# Applies the lab tweaks in this folder to the NICo working tree, dispatched by
# extension. Reruns are safe. See README.md for details.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIRTLAB_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: not inside a git repository." >&2
  exit 1
}
REL="${SCRIPT_DIR#"$VIRTLAB_ROOT"/}"

# The patches target NICo, not this repo, so everything below runs in the
# submodule. Override NICO_ROOT to patch a checkout kept somewhere else.
NICO_ROOT="${NICO_ROOT:-$VIRTLAB_ROOT/infra-controller}"
# An uninitialised submodule leaves an empty directory, and git would then walk up
# and resolve to this repo, applying every patch to the wrong tree. So require
# NICO_ROOT to be a checkout's own top level, not merely somewhere inside one.
NICO_TOP="$(git -C "$NICO_ROOT" rev-parse --show-toplevel 2>/dev/null)" || NICO_TOP=""
if [[ -z "$NICO_TOP" || "$NICO_TOP" != "$(cd "$NICO_ROOT" 2>/dev/null && pwd -P)" ]]; then
  echo "ERROR: ${NICO_ROOT} is not the root of a git checkout." >&2
  echo "       run 'git submodule update --init' in ${VIRTLAB_ROOT}." >&2
  exit 1
fi

DRY_RUN=false
REVERSE=false
FUZZ=false

usage() {
  cat <<EOF
Apply the lab patches/overlays in ${REL}/ to ${NICO_ROOT}.

Usage: $(basename "$0") [options] [file ...]

  *.patch     applied with git apply
  *.ytt.yaml  ytt overlay applied in place to the '#! target: <path>' it names

Options:
  -n, --dry-run   report what would happen, change nothing
  -R, --reverse   revert (patch: git apply -R; ytt: git checkout the target)
  -f, --fuzz      patches only: retry with 'patch -p1 --fuzz=3' on clean-apply failure
  -h, --help      this help
EOF
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run|--check) DRY_RUN=true ;;
    -R|--reverse) REVERSE=true ;;
    -f|--fuzz) FUZZ=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

FILES=()
if [[ ${#ARGS[@]} -gt 0 ]]; then
  for a in "${ARGS[@]}"; do
    if [[ -f "$a" ]]; then FILES+=("$a")
    elif [[ -f "$SCRIPT_DIR/$a" ]]; then FILES+=("$SCRIPT_DIR/$a")
    else echo "ERROR: not found: $a" >&2; exit 2; fi
  done
else
  mapfile -t FILES < <(find "$SCRIPT_DIR" -maxdepth 1 \
    \( -name '*.patch' -o -name '*.ytt.yaml' -o -name '*.ytt.yml' \) | sort)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "nothing to apply in ${REL}/"
  exit 0
fi

# Revert in reverse order.
if [[ "$REVERSE" == true ]]; then
  mapfile -t FILES < <(printf '%s\n' "${FILES[@]}" | tac)
fi

cd "$NICO_ROOT"

applied=0
skipped=0
failed=0

need_ytt() {
  command -v ytt >/dev/null 2>&1 && return 0
  echo "  ytt not found on PATH; install it from https://carvel.dev/ytt/" >&2
  return 1
}

apply_patch() {
  local p="$1" name
  name="$(basename "$p")"
  if [[ "$REVERSE" == true ]]; then
    if git apply --check "$p" >/dev/null 2>&1; then
      echo "  skip    $name (not applied)"; skipped=$((skipped + 1)); return
    fi
    if ! git apply --reverse --check "$p" >/dev/null 2>&1; then
      echo "  FAIL    $name (does not reverse cleanly)"; failed=$((failed + 1)); return
    fi
    if [[ "$DRY_RUN" == true ]]; then echo "  would revert $name"; applied=$((applied + 1)); return; fi
    git apply --reverse "$p"; echo "  revert  $name"; applied=$((applied + 1)); return
  fi
  if git apply --reverse --check "$p" >/dev/null 2>&1; then
    echo "  skip    $name (already applied)"; skipped=$((skipped + 1)); return
  fi
  if git apply --check "$p" >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == true ]]; then echo "  would apply $name"; applied=$((applied + 1)); return; fi
    git apply "$p"; echo "  apply   $name"; applied=$((applied + 1)); return
  fi
  if [[ "$FUZZ" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      patch -p1 --dry-run --forward --fuzz=3 <"$p" >/dev/null 2>&1 &&
        { echo "  would apply(fuzz) $name"; applied=$((applied + 1)); return; }
    elif patch -p1 --forward --fuzz=3 --no-backup-if-mismatch <"$p" >/dev/null 2>&1; then
      echo "  apply(fuzz) $name"; applied=$((applied + 1)); return
    fi
  fi
  echo "  FAIL    $name (does not apply cleanly; try --fuzz)"; failed=$((failed + 1))
}

apply_ytt() {
  local o="$1" name target
  name="$(basename "$o")"
  need_ytt || { failed=$((failed + 1)); return; }
  target="$(sed -n 's/^#! target:[[:space:]]*//p' "$o" | head -1 | tr -d '[:space:]')"
  if [[ -z "$target" ]]; then
    echo "  FAIL    $name (missing '#! target:' header)"; failed=$((failed + 1)); return
  fi
  if ! git cat-file -e "HEAD:$target" 2>/dev/null; then
    echo "  FAIL    $name (target not tracked: $target)"; failed=$((failed + 1)); return
  fi
  if [[ "$REVERSE" == true ]]; then
    if [[ "$DRY_RUN" == true ]]; then echo "  would restore $target"; applied=$((applied + 1)); return; fi
    git checkout HEAD -- "$target"; echo "  restore $name -> $target"; applied=$((applied + 1)); return
  fi
  # Regenerate the target from its committed version + overlay (idempotent).
  if ! git show "HEAD:$target" | ytt -f - -f "$o" >"${target}.labtmp" 2>/dev/null; then
    rm -f "${target}.labtmp"
    echo "  FAIL    $name (ytt overlay did not apply to $target)"; failed=$((failed + 1)); return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    rm -f "${target}.labtmp"; echo "  would apply $name -> $target"; applied=$((applied + 1)); return
  fi
  mv "${target}.labtmp" "$target"
  echo "  apply   $name -> $target"; applied=$((applied + 1))
}

for f in "${FILES[@]}"; do
  case "$f" in
    *.patch) apply_patch "$f" ;;
    *.ytt.yaml|*.ytt.yml) apply_ytt "$f" ;;
    *) echo "  skip    $(basename "$f") (unknown type)"; skipped=$((skipped + 1)) ;;
  esac
done

verb="applied"; [[ "$REVERSE" == true ]] && verb="reverted"
echo
echo "done: ${applied} ${verb}, ${skipped} skipped, ${failed} failed"
[[ "$failed" -eq 0 ]]
