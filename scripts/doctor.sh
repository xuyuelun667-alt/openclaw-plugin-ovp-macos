#!/usr/bin/env bash
# Permission + engine preflight for OVP on macOS.
# Checks: engine present, Accessibility granted, Screen Recording granted, capture smoke test.
set -uo pipefail
cd "$(dirname "$0")/.."

if [ ! -f dist/doctor.js ]; then
  echo "dist/doctor.js missing — run: npm install && npm run build" >&2
  exit 2
fi

node --input-type=module -e '
import { runDoctor, formatDoctor } from "./dist/doctor.js";
const report = await runDoctor({ pluginRoot: process.cwd() });
console.log(formatDoctor(report));
process.exit(report.ok ? 0 : 1);
'
