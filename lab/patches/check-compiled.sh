#!/usr/bin/env bash
# Lists patches that reach outside helm/ and helm-prereqs/ into image sources.
# The set and hashes must equal base/COMPILED, else the images need a rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/base/COMPILED"
CONFIG_ONLY_PREFIXES=(helm/ helm-prereqs/)

config_only() {
  local p="$1" pre
  for pre in "${CONFIG_ONLY_PREFIXES[@]}"; do [[ "$p" == "$pre"* ]] && return 0; done
  return 1
}

found=()
while IFS= read -r f; do
  rel="${f#"$SCRIPT_DIR"/}"
  case "$f" in
    *.patch) paths=$(cd / && git apply --numstat "$f" | cut -f3) ;; # outside any repo, git apply filters by cwd
    *) paths=$(sed -n 's/^#! target:[[:space:]]*//p' "$f" | head -1 | tr -d '[:space:]') ;;
  esac
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    config_only "$p" || { found+=("$rel"); break; }
  done <<< "$paths"
done < <(find "$SCRIPT_DIR" -mindepth 2 -maxdepth 2 \
  \( -name '*.patch' -o -name '*.ytt.yaml' -o -name '*.ytt.yml' \) | sort)

# Hashes catch an edited patch as well as a new or missing one.
expected=$(grep -v '^[[:space:]]*\(#\|$\)' "$MANIFEST" | sort -k2)
actual=$(cd "$SCRIPT_DIR" && for r in "${found[@]}"; do sha256sum "$r"; done | sort -k2)

echo "files reaching into image sources:"
echo "${actual:-  (none)}" | sed 's/^[0-9a-f]*  /  /'
if [[ "$actual" != "$expected" ]]; then
  echo "MISMATCH with ${MANIFEST#"$SCRIPT_DIR"/}:" >&2
  diff <(echo "$expected") <(echo "$actual") >&2 || true
  exit 1
fi
echo "ok: matches ${MANIFEST#"$SCRIPT_DIR"/}"
