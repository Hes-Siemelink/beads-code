#!/bin/bash
# entrypoint.sh -- Beads server entrypoint
#
# 1. Initialize the database if needed
# 2. Start dolt sql-server with remotesapi enabled

set -euo pipefail

# Initialize the database
/init-db.sh

echo "[beads-server] Starting Dolt SQL server..."
echo "[beads-server] SQL port:       3306"
echo "[beads-server] RemotesAPI port: 50051"
echo "[beads-server] Database:       ${BEADS_DB_NAME:-bc}"

exec dolt sql-server --config /config.yaml
