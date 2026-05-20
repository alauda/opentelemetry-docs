#!/usr/bin/env bash
#
# Update the Alauda Build of OpenTelemetry version in all .mdx files
# under ./docs/en/.
#
# Compatible with both macOS (BSD sed/grep, bash 3.2) and Linux (GNU sed/grep).
#
# Usage:
#   ./hack/update-otel-version.sh <old-version> <new-version>
#
# Example:
#   ./hack/update-otel-version.sh 0.146.0-r0 0.147.0-r0

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <old-version> <new-version>" >&2
  echo "Example: $0 0.146.0-r0 0.147.0-r0" >&2
  exit 1
fi

OLD_VERSION="$1"
NEW_VERSION="$2"

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$'
if ! [[ "$OLD_VERSION" =~ $VERSION_RE ]]; then
  echo "Error: old version '$OLD_VERSION' does not match format X.Y.Z-rN" >&2
  exit 1
fi
if ! [[ "$NEW_VERSION" =~ $VERSION_RE ]]; then
  echo "Error: new version '$NEW_VERSION' does not match format X.Y.Z-rN" >&2
  exit 1
fi

if [[ "$OLD_VERSION" == "$NEW_VERSION" ]]; then
  echo "Old and new versions are identical; nothing to do."
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$REPO_ROOT/docs/en"

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "Error: docs directory not found: $DOCS_DIR" >&2
  exit 1
fi

# Escape regex metacharacters in the old version for the sed pattern.
ESCAPED_OLD="$(printf '%s' "$OLD_VERSION" | sed 's/[.[\*^$/]/\\&/g')"
# Escape replacement-side specials (& and \) in the new version.
ESCAPED_NEW="$(printf '%s' "$NEW_VERSION" | sed 's/[&\\/]/\\&/g')"

# Collect matching files (bash 3.2 compatible: no mapfile).
FILES=()
while IFS= read -r line; do
  [[ -n "$line" ]] && FILES+=("$line")
done < <(grep -rl --include='*.mdx' -F "$OLD_VERSION" "$DOCS_DIR" || true)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No .mdx files under docs/en/ contain '$OLD_VERSION'. Nothing to update."
  exit 0
fi

echo "Updating ${#FILES[@]} file(s): $OLD_VERSION -> $NEW_VERSION"
for file in "${FILES[@]}"; do
  # `sed -i.bak` is the portable in-place form accepted by both BSD and GNU sed.
  sed -i.bak "s/${ESCAPED_OLD}/${ESCAPED_NEW}/g" "$file"
  rm -f "${file}.bak"
  echo "  updated: ${file#${REPO_ROOT}/}"
done

echo "Done."
