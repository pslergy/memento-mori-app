#!/usr/bin/env bash
# Копирует репозиторий в целевую папку, удаляет пути из exclude-from-public.txt,
# подставляет заглушку MainActivity. Исходный .git не копируется (rsync --exclude).
#
# Usage: ./scripts/export_public_mirror.sh /path/to/memento_mori_public

set -euo pipefail
DEST="${1:?Usage: $0 <destination_dir>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/tools/opensource/exclude-from-public.txt"
STUB="$REPO_ROOT/tools/opensource/stubs/MainActivity.public.kt"
NOTICE_SRC="$REPO_ROOT/tools/opensource/PUBLIC_SNAPSHOT_NOTICE.txt"

if [[ ! -f "$MANIFEST" ]]; then echo "Missing $MANIFEST"; exit 1; fi
if [[ ! -f "$STUB" ]]; then echo "Missing $STUB"; exit 1; fi
if [[ ! -f "$NOTICE_SRC" ]]; then echo "Missing $NOTICE_SRC"; exit 1; fi

if [[ -e "$DEST" ]]; then
  echo "Destination already exists: $DEST"
  exit 1
fi

mkdir -p "$DEST"

if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude='.git' --exclude='.dart_tool' --exclude='build' \
    --exclude='.idea' --exclude='ios/Pods' --exclude='node_modules' \
    --exclude='_public_export' --exclude='public_mirror_out' \
    --exclude='/sdk/' --exclude='/sdk_products/' \
    "$REPO_ROOT/" "$DEST/"
else
  echo "rsync not found; install rsync or use export_public_mirror.ps1 on Windows"
  exit 1
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  target="$DEST/$line"
  if [[ -e "$target" ]]; then
    rm -rf "$target"
    echo "  removed: $line"
  fi
done < "$MANIFEST"

# Публично не публикуем ни один .md
while IFS= read -r -d '' f; do
  rm -f "$f"
  echo "  removed: ${f#$DEST/}"
done < <(find "$DEST" -type f -name '*.md' -print0)
while IFS= read -r -d '' f; do
  rm -f "$f"
  echo "  removed: ${f#$DEST/}"
done < <(find "$DEST" -type f -name '*.vmd' -print0 2>/dev/null)

MAIN_DEST="$DEST/android/app/src/main/kotlin/com/example/memento_mori_app/MainActivity.kt"
if [[ ! -f "$MAIN_DEST" ]]; then
  mkdir -p "$(dirname "$MAIN_DEST")"
  cp "$STUB" "$MAIN_DEST"
  echo "  stub: MainActivity.kt"
fi

mkdir -p "$DEST/docs"
cp "$NOTICE_SRC" "$DEST/docs/PUBLIC_SNAPSHOT_NOTICE.txt"
echo "  copied: docs/PUBLIC_SNAPSHOT_NOTICE.txt"

echo "Done. In $DEST: git init && git add -A && git commit -m 'Public snapshot'"
echo "See docs/OPENSOURCE_PUBLIC_MIRROR.md in private repo"
