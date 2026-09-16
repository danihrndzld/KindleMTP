#!/bin/bash
# Runs the --probe smoke test. Exit 0 = a device was found and probed;
# exit 1 = no device attached (expected on a CI runner); anything else
# means the MTP layer itself broke.
set -uo pipefail
out=$(./KindleMTP.app/Contents/MacOS/KindleMTP --probe 2>&1)
code=$?
echo "$out"
if [ "$code" -gt 1 ]; then
  echo "::error::probe crashed (exit $code)"
  exit 1
fi
