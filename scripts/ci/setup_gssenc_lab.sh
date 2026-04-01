#!/usr/bin/env bash
set -euo pipefail

REALM="${KRB5_REALM:-QAIL.TEST}"
HOST_ALIAS="${QAIL_GSSENC_HOST_ALIAS:-pgkerb.local}"
CLIENT_PRINCIPAL="${KRB5_CLIENT_PRINCIPAL:-ci}"
CLIENT_PASSWORD="${KRB5_CLIENT_PASSWORD:-ci-password}"
MASTER_PASSWORD="${KRB5_MASTER_PASSWORD:-master-password}"
SERVICE_NAME="${QAIL_KRB5_SERVICE:-postgres}"
PG_USER="${PGUSER:-ci}"
PG_DATABASE="${PGDATABASE:-postgres}"
PG_PORT="${PGPORT:-5432}"
CCACHE_PATH="${RUNNER_TEMP:-/tmp}/qail-krb5cc"

restart_service() {
  local service_name="$1"
  sudo systemctl restart "${service_name}" 2>/dev/null ||
    sudo service "${service_name}" restart ||
    start_service "${service_name}"
}

start_service() {
  local service_name="$1"
  sudo systemctl start "${service_name}" 2>/dev/null || sudo service "${service_name}" start
}

echo "::group::Install Kerberos and PostgreSQL packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libgssapi-krb5-2 \
  krb5-kdc \
  krb5-admin-server \
  krb5-user \
  postgresql \
  postgresql-client
ldconfig -p | grep gssapi || true
echo "::endgroup::"

if ! grep -q "[[:space:]]${HOST_ALIAS}\$" /etc/hosts; then
  echo "127.0.0.1 ${HOST_ALIAS}" | sudo tee -a /etc/hosts >/dev/null
fi

echo "::group::Configure Kerberos realm"
cat <<EOF | sudo tee /etc/krb5.conf >/dev/null
[libdefaults]
    default_realm = ${REALM}
    dns_lookup_kdc = false
    dns_lookup_realm = false
    rdns = false
    ticket_lifetime = 24h
    forwardable = true
    udp_preference_limit = 0

[realms]
    ${REALM} = {
        kdc = localhost
        admin_server = localhost
    }

[domain_realm]
    .${HOST_ALIAS} = ${REALM}
    ${HOST_ALIAS} = ${REALM}
EOF

sudo mkdir -p /etc/krb5kdc
cat <<EOF | sudo tee /etc/krb5kdc/kdc.conf >/dev/null
[kdcdefaults]
    kdc_ports = 88

[realms]
    ${REALM} = {
        acl_file = /etc/krb5kdc/kadm5.acl
        dict_file = /usr/share/dict/words
        admin_keytab = /etc/krb5kdc/kadm5.keytab
        max_life = 24h
        max_renewable_life = 7d
        supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal
    }
EOF

cat <<EOF | sudo tee /etc/krb5kdc/kadm5.acl >/dev/null
*/admin@${REALM} *
EOF

sudo rm -f /var/lib/krb5kdc/principal* /etc/krb5kdc/stash*
sudo kdb5_util create -s -P "${MASTER_PASSWORD}"
sudo kadmin.local -q "addprinc -pw ${CLIENT_PASSWORD} ${CLIENT_PRINCIPAL}@${REALM}"
sudo kadmin.local -q "addprinc -randkey ${SERVICE_NAME}/${HOST_ALIAS}@${REALM}"
echo "::endgroup::"

PG_MAJOR="$(psql --version | awk '{print $3}' | cut -d. -f1)"
PG_ETC_DIR="/etc/postgresql/${PG_MAJOR}/main"
PG_CONF_D_DIR="${PG_ETC_DIR}/conf.d"
PG_HBA="${PG_ETC_DIR}/pg_hba.conf"
PG_KEYTAB="${PG_ETC_DIR}/postgres.keytab"
PG_LOG="/var/log/postgresql/postgresql-${PG_MAJOR}-main.log"

echo "::group::Configure PostgreSQL for GSSENC"
sudo kadmin.local -q "ktadd -k ${PG_KEYTAB} ${SERVICE_NAME}/${HOST_ALIAS}@${REALM}"
sudo chown postgres:postgres "${PG_KEYTAB}"
sudo chmod 600 "${PG_KEYTAB}"

sudo mkdir -p "${PG_CONF_D_DIR}"
cat <<EOF | sudo tee "${PG_CONF_D_DIR}/qail-gssenc-ci.conf" >/dev/null
listen_addresses = '127.0.0.1'
krb_server_keyfile = '${PG_KEYTAB}'
log_connections = on
EOF

cat <<EOF | sudo tee "${PG_HBA}" >/dev/null
local   all             postgres                                peer
local   all             all                                     peer
hostgssenc ${PG_DATABASE} ${PG_USER} 127.0.0.1/32              gss include_realm=0 krb_realm=${REALM}
hostnogssenc ${PG_DATABASE} ${PG_USER} 127.0.0.1/32            reject
host    all             all             127.0.0.1/32            reject
EOF

restart_service krb5-kdc
restart_service postgresql

sudo -u postgres psql -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}') THEN
        CREATE ROLE ${PG_USER} LOGIN SUPERUSER;
    END IF;
END
\$\$;
SQL

sudo -u postgres pg_isready -h /var/run/postgresql -p "${PG_PORT}" -d postgres
echo "::endgroup::"

echo "::group::Acquire Kerberos client ticket"
rm -f "${CCACHE_PATH}"
export KRB5_CONFIG=/etc/krb5.conf
export KRB5CCNAME="FILE:${CCACHE_PATH}"
printf '%s\n' "${CLIENT_PASSWORD}" | kinit "${CLIENT_PRINCIPAL}@${REALM}"
klist
echo "::endgroup::"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  {
    echo "KRB5_CONFIG=/etc/krb5.conf"
    echo "KRB5CCNAME=FILE:${CCACHE_PATH}"
    echo "PGHOST=${HOST_ALIAS}"
    echo "PGPORT=${PG_PORT}"
    echo "PGUSER=${PG_USER}"
    echo "PGDATABASE=${PG_DATABASE}"
    echo "QAIL_KRB5_SERVICE=${SERVICE_NAME}"
    echo "QAIL_KRB5_TARGET_NAME=${SERVICE_NAME}@${HOST_ALIAS}"
    echo "QAIL_GSSENC_PG_MAJOR=${PG_MAJOR}"
    echo "QAIL_GSSENC_PG_LOG=${PG_LOG}"
  } >> "${GITHUB_ENV}"
fi
