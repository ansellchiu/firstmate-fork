#!/usr/bin/env bash
# Redact account identity from quota-axi output in evidence files.
sed -E -i '' -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}/<redacted-email>/g' -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<redacted-id>/g' "$@"
