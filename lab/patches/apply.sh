#!/usr/bin/env bash
# Applies the lab patches in this folder to the NICo tree, by group and extension.
# Reruns are safe, see README.md.
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

# Groups apply in this order. base is what images are built from, later groups are
# deploy time only so the images never need a rebuild for them.
GROUP_ORDER=(base sushy dpf)
# Deploy flavours, a deployment uses exactly one of them on top of base.
FLAVORS=(sushy dpf)
# Paths a non-base group may touch, read at deploy time and never put in an image.
CONFIG_ONLY_PREFIXES=(helm/ helm-prereqs/)

# Data values the overlays read, declared with defaults in values.yaml. Only what
# the caller sets in the environment overrides them.
YTT_VALUES=(-f "$SCRIPT_DIR/values.yaml" -f "$SCRIPT_DIR/lib/toml.star")
# Site specific values, gitignored, NICO_LAB_VALUES points elsewhere.
LOCAL_VALUES="${NICO_LAB_VALUES:-$SCRIPT_DIR/values.local.yaml}"
if [[ -f "$LOCAL_VALUES" ]]; then
  LOCAL_VALUES="$(cd "$(dirname "$LOCAL_VALUES")" && pwd)/$(basename "$LOCAL_VALUES")"
  YTT_VALUES+=(--data-values-file "$LOCAL_VALUES")
fi
[[ -n "${NICO_IMAGE_REGISTRY:-}" ]] && YTT_VALUES+=(--data-value "image_registry=${NICO_IMAGE_REGISTRY}")

DRY_RUN=false
REVERSE=false
FUZZ=false
GROUPS_ARG="${NICO_LAB_GROUPS:-base${NICO_LAB_FLAVOR:+,$NICO_LAB_FLAVOR}}"

usage() {
  cat <<EOF
Apply the lab patches/overlays in ${REL}/<group>/ to ${NICO_ROOT}.

Usage: $(basename "$0") [options] [file ...]

  *.patch     applied with git apply
  *.ytt.yaml  ytt overlay applied in place to the '#! target: <path>' it names

Groups (subdirectories) apply in the order: ${GROUP_ORDER[*]}. base is always
included and at most one flavour (${FLAVORS[*]}) may follow it. Groups other than
base may only touch: ${CONFIG_ONLY_PREFIXES[*]}

Options:
  -g, --group LIST  comma separated groups (default: base plus \$NICO_LAB_FLAVOR)
  -n, --dry-run     report what would happen, change nothing
  -R, --reverse     revert (patch: git apply -R; ytt: git checkout the target)
  -f, --fuzz        patches only: retry with 'patch -p1 --fuzz=3' on clean-apply failure
  -h, --help        this help
EOF
}

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--group|--groups) [[ -n "${2:-}" ]] || { usage >&2; exit 2; }; GROUPS_ARG="$2"; shift ;;
    -n|--dry-run|--check) DRY_RUN=true ;;
    -R|--reverse) REVERSE=true ;;
    -f|--fuzz) FUZZ=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done

# Selected groups in GROUP_ORDER, base always first.
declare -A WANT=([base]=1)
IFS=',' read -r -a _req <<< "$GROUPS_ARG"
for g in "${_req[@]}"; do
  g="${g//[[:space:]]/}"
  [[ -z "$g" ]] && continue
  if [[ ! " ${GROUP_ORDER[*]} " =~ \ ${g}\  ]]; then
    echo "ERROR: unknown group '$g' (known: ${GROUP_ORDER[*]})" >&2; exit 2
  fi
  WANT[$g]=1
done
SEL_GROUPS=()
for g in "${GROUP_ORDER[@]}"; do [[ -n "${WANT[$g]:-}" ]] && SEL_GROUPS+=("$g"); done
_flavors=0
for f in "${FLAVORS[@]}"; do [[ -n "${WANT[$f]:-}" ]] && _flavors=$((_flavors + 1)); done
if [[ "$_flavors" -gt 1 ]]; then
  echo "ERROR: pick one flavour, not '${GROUPS_ARG}' (flavours: ${FLAVORS[*]})" >&2; exit 2
fi

# Absolute paths, so they survive the cd into NICo below.
FILES=()
declare -A FILE_GROUP=()
group_of() { # group a file belongs to, from its parent directory
  local d; d="$(basename "$(dirname "$1")")"
  [[ " ${GROUP_ORDER[*]} " =~ \ ${d}\  ]] && echo "$d" || echo ""
}
if [[ ${#ARGS[@]} -gt 0 ]]; then
  for a in "${ARGS[@]}"; do
    hit=""
    if [[ -f "$a" ]]; then hit="$(cd "$(dirname "$a")" && pwd)/$(basename "$a")"
    elif [[ -f "$SCRIPT_DIR/$a" ]]; then hit="$SCRIPT_DIR/$a"
    else
      for g in "${GROUP_ORDER[@]}"; do
        [[ -f "$SCRIPT_DIR/$g/$a" ]] && { hit="$SCRIPT_DIR/$g/$a"; break; }
      done
    fi
    [[ -n "$hit" ]] || { echo "ERROR: not found: $a" >&2; exit 2; }
    g="$(group_of "$hit")"
    [[ -n "$g" ]] || { echo "ERROR: $a is not inside a group directory" >&2; exit 2; }
    FILES+=("$hit"); FILE_GROUP[$hit]="$g"
  done
else
  for g in "${SEL_GROUPS[@]}"; do
    [[ -d "$SCRIPT_DIR/$g" ]] || continue
    while IFS= read -r f; do FILES+=("$f"); FILE_GROUP[$f]="$g"; done < <(
      find "$SCRIPT_DIR/$g" -maxdepth 1 \
        \( -name '*.patch' -o -name '*.ytt.yaml' -o -name '*.ytt.yml' \) | sort)
  done
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "nothing to apply for groups: ${SEL_GROUPS[*]}"
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
# Targets rendered in this run. The first overlay renders from HEAD, later ones from
# the working file, so a flavour overlay keeps what base did.
declare -A TOUCHED=()

need_ytt() {
  command -v ytt >/dev/null 2>&1 && return 0
  echo "  ytt not found on PATH; install it from https://carvel.dev/ytt/" >&2
  return 1
}

config_only() { # path allowed for a non-base group?
  local p="$1" pre
  for pre in "${CONFIG_ONLY_PREFIXES[@]}"; do [[ "$p" == "$pre"* ]] && return 0; done
  return 1
}

guard() { # refuse a non-base file that reaches outside the config-only paths
  local f="$1" g="${FILE_GROUP[$1]}" name p bad=()
  [[ "$g" == base ]] && return 0
  name="$(basename "$f")"
  case "$f" in
    *.patch) while IFS=$'\t' read -r _ _ p; do config_only "$p" || bad+=("$p"); done \
               < <(git apply --numstat "$f" 2>/dev/null) ;;
    *) p="$(sed -n 's/^#! target:[[:space:]]*//p' "$f" | head -1 | tr -d '[:space:]')"
       config_only "$p" || bad+=("$p") ;;
  esac
  if [[ ${#bad[@]} -gt 0 ]]; then
    echo "  FAIL    $g/$name touches non-config paths: ${bad[*]}"; failed=$((failed + 1)); return 1
  fi
}

apply_patch() {
  local p="$1" name
  name="${FILE_GROUP[$p]}/$(basename "$p")"
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
    # Dry run first, so a failed fuzzy apply leaves nothing half patched.
    if patch -p1 --dry-run --forward --fuzz=3 <"$p" >/dev/null 2>&1; then
      if [[ "$DRY_RUN" == true ]]; then echo "  would apply(fuzz) $name"; applied=$((applied + 1)); return; fi
      patch -p1 --forward --fuzz=3 --no-backup-if-mismatch <"$p" >/dev/null 2>&1
      echo "  apply(fuzz) $name"; applied=$((applied + 1)); return
    fi
  fi
  echo "  FAIL    $name (does not apply cleanly; try --fuzz)"; failed=$((failed + 1))
}

apply_ytt() {
  local o="$1" name target src
  name="${FILE_GROUP[$o]}/$(basename "$o")"
  need_ytt || { failed=$((failed + 1)); return; }
  target="$(sed -n 's/^#! target:[[:space:]]*//p' "$o" | head -1 | tr -d '[:space:]')"
  if [[ -z "$target" ]]; then
    echo "  FAIL    $name (missing '#! target:' header)"; failed=$((failed + 1)); return
  fi
  if ! git cat-file -e "HEAD:$target" 2>/dev/null; then
    echo "  FAIL    $name (target not tracked: $target)"; failed=$((failed + 1)); return
  fi
  if [[ "$REVERSE" == true ]]; then
    [[ -n "${TOUCHED[$target]:-}" ]] && { echo "  skip    $name (target already restored)"; skipped=$((skipped + 1)); return; }
    TOUCHED[$target]=1
    if [[ "$DRY_RUN" == true ]]; then echo "  would restore $target"; applied=$((applied + 1)); return; fi
    git checkout HEAD -- "$target"; echo "  restore $name -> $target"; applied=$((applied + 1)); return
  fi
  if [[ -n "${TOUCHED[$target]:-}" ]]; then src="$target"; else src="-"; fi
  if ! { if [[ "$src" == "-" ]]; then git show "HEAD:$target"; else cat "$target"; fi; } \
      | ytt -f - -f "$o" "${YTT_VALUES[@]}" >"${target}.labtmp" 2>"${target}.laberr"; then
    echo "  FAIL    $name (ytt overlay did not apply to $target)"
    sed 's/^/          /' "${target}.laberr" | grep -v '^ *$' | tail -6
    rm -f "${target}.labtmp" "${target}.laberr"; failed=$((failed + 1)); return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    rm -f "${target}.labtmp" "${target}.laberr"; echo "  would apply $name -> $target"; applied=$((applied + 1)); return
  fi
  rm -f "${target}.laberr"
  mv "${target}.labtmp" "$target"
  TOUCHED[$target]=1
  echo "  apply   $name -> $target"; applied=$((applied + 1))
}

echo "groups: ${SEL_GROUPS[*]}"
for f in "${FILES[@]}"; do
  guard "$f" || continue
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
