#!/bin/sh
# Copy the built .next into the writable /app/.next and substitute the NEXT_PUBLIC_* placeholders there.
set -eu
cd /app
rm -rf .next/* .next/.[!.]* 2>/dev/null || true
cp -R .next.dist/. .next/
: "${NEXT_PUBLIC_API_URL:?NEXT_PUBLIC_API_URL must be set to the public URL of the Mem0 API}"
: "${NEXT_PUBLIC_INSTANCE_NAME:=Mem0}"
for key in NEXT_PUBLIC_API_URL NEXT_PUBLIC_INSTANCE_NAME; do
  eval "value=\$$key"
  escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
  grep -rlF "$key" .next | while read -r f; do sed -i "s|$key|$escaped|g" "$f"; done
done
echo "dashboard: API at $NEXT_PUBLIC_API_URL"
exec "$@"
