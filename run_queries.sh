#!/usr/bin/env bash
# Runs the data-quality checks and every analysis query, saving the
# output to results/ so it can be browsed on GitHub.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p results

psql -q -P footer=off -f validation/data_quality_checks.sql > results/00_data_quality_checks.txt
echo "validation/data_quality_checks.sql -> results/00_data_quality_checks.txt"

for f in queries/*.sql; do
    out="results/$(basename "${f%.sql}").txt"
    psql -q -P footer=off -f "$f" > "$out"
    echo "$f -> $out"
done
