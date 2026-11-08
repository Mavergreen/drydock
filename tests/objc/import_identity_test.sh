#!/bin/sh
# platform: host-agnostic
# spec: the analyzer is imported from shipyard unchanged; IMPORTED.sha256
# holds the hashes taken in the shipyard checkout, not from the copies.
set -eu
cd "$(dirname "$0")/../.."
shasum -a 256 -c tests/objc/IMPORTED.sha256
