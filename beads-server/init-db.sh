#!/bin/bash
# init-db.sh -- Initialize the beads database on first run
#
# Creates the database directory and sets up initial permissions.
# The CLONE_ADMIN privilege is required for clients to push/pull
# via the remotesapi.

set -euo pipefail

DB_NAME="${BEADS_DB_NAME:-bc}"
DATA_DIR="/var/lib/dolt"
INIT_MARKER="$DATA_DIR/.initialized"

# Only init if not already done
if [ ! -f "$INIT_MARKER" ]; then
  echo "[beads-server] First run -- initializing..."

  # Create the database directory with dolt init
  mkdir -p "$DATA_DIR/$DB_NAME"
  cd "$DATA_DIR/$DB_NAME"
  dolt init --name "beads-server" --email "beads-server@beads.dev"

  echo "[beads-server] Database '$DB_NAME' initialized."

  # Start server briefly to set up permissions, then stop it
  echo "[beads-server] Setting up permissions..."
  dolt sql-server --config /config.yaml &
  SERVER_PID=$!

  # Wait for server to be ready
  for i in $(seq 1 30); do
    if dolt --host 127.0.0.1 --port 3306 --user root --password "" --no-tls sql -q "SELECT 1;" >/dev/null 2>&1; then
      break
    fi
    sleep 0.5
  done

  # Grant CLONE_ADMIN to root@% (allows remote push/pull via remotesapi)
  dolt --host 127.0.0.1 --port 3306 --user root --password "" --no-tls sql -q "
    CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
    GRANT CLONE_ADMIN ON *.* TO 'root'@'%';
  " 2>&1

  echo "[beads-server] Permissions configured."

  # Stop the temporary server
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true

  touch "$INIT_MARKER"
  echo "[beads-server] Initialization complete."
else
  echo "[beads-server] Already initialized, skipping."
fi
