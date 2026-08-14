#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
  CREATE ROLE codelead LOGIN PASSWORD '${APP_DB_PW}';
  CREATE DATABASE codelead OWNER codelead;
EOSQL