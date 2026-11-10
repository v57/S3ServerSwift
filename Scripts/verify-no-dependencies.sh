#!/bin/sh
set -eu

# The package is the repository root
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
description=$(cd "$package_dir" && swift package describe --type json)

if ! printf '%s\n' "$description" | /usr/bin/python3 -c \
  'import json,sys; data=json.load(sys.stdin); raise SystemExit(0 if data.get("dependencies") == [] else 1)'
then
  echo "error: S3ServerSwift must not declare external package dependencies" >&2
  exit 1
fi

if find "$package_dir" -maxdepth 1 -name Package.resolved -print -quit | grep -q .
then
  echo "error: Package.resolved is unexpected in this dependency-free package" >&2
  exit 1
fi

echo "Verified: S3ServerSwift declares no package dependencies."
