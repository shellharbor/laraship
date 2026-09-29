#!/bin/bash
set -e

# This script runs only on first initialization
# It ensures the user password is set correctly
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- Ensure user exists with correct password
    ALTER USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';
EOSQL

echo "PostgreSQL initialization completed successfully"
