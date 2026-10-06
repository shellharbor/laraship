#!/bin/bash
# Prepares a system PostgreSQL or MySQL on THIS machine for the native-database install cases
# (deploy-laravel.sh --db-native). Disposable environments only: it changes the DBMS configuration.
#
#   bash tests/native-db.sh postgres     # listens on all interfaces, admits the Docker subnets
#   bash tests/native-db.sh mysql        # listens on all interfaces, root password Root_e2e_1
#
# This is exactly the administrator's part that the README describes ("Database connection"):
# the script itself never configures the DBMS network access. Idempotent.
set -euo pipefail

MYSQL_ROOT_PASSWORD="Root_e2e_1"

use_systemd() {
    command -v systemctl > /dev/null 2>&1 && [ -d /run/systemd/system ]
}

setup_postgres() {
    local ver conf
    ver="$(ls /etc/postgresql | sort -V | tail -n1)"
    conf="/etc/postgresql/${ver}/main"
    grep -q "^listen_addresses = '\*'" "${conf}/postgresql.conf" || echo "listen_addresses = '*'" >> "${conf}/postgresql.conf"
    grep -q "laraship-e2e" "${conf}/pg_hba.conf" || printf 'host all all 172.16.0.0/12 scram-sha-256 # laraship-e2e\nhost all all 10.0.0.0/8 scram-sha-256 # laraship-e2e\n' >> "${conf}/pg_hba.conf"
    if use_systemd; then
        systemctl restart postgresql
    else
        pg_ctlcluster "${ver}" main restart 2> /dev/null || pg_ctlcluster "${ver}" main start
    fi
    for _ in $(seq 1 30); do
        sudo -u postgres psql -Atc 'select 1' > /dev/null 2>&1 && return 0
        sleep 1
    done
    echo "PostgreSQL did not start" >&2
    exit 1
}

setup_mysql() {
    mkdir -p /etc/mysql/mysql.conf.d /var/run/mysqld
    chown mysql:mysql /var/run/mysqld 2> /dev/null || true
    printf '[mysqld]\nbind-address = 0.0.0.0\n' > /etc/mysql/mysql.conf.d/zz-laraship-e2e.cnf
    # The mysql daemon must read this non-secret fixture even under the report umask.
    chmod 644 /etc/mysql/mysql.conf.d/zz-laraship-e2e.cnf
    if use_systemd; then
        systemctl restart mysql
    else
        service mysql restart 2> /dev/null || service mysql start
    fi
    for _ in $(seq 1 60); do
        if mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e 'select 1' > /dev/null 2>&1; then return 0; fi
        # first run: root is reachable over the socket without a password
        if mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" > /dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "MySQL did not start" >&2
    exit 1
}

case "${1:-}" in
    postgres) setup_postgres ;;
    mysql)    setup_mysql ;;
    *) echo "usage: native-db.sh postgres|mysql" >&2; exit 2 ;;
esac
echo "native ${1} is ready"
