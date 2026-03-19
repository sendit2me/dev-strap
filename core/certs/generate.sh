#!/bin/bash
# =============================================================================
# Certificate Generation Script
# =============================================================================
# Generates a complete PKI chain for HTTPS mock interception:
#   1. Root CA (trusted by the app container)
#   2. Server certificate with SANs for all mocked domains
#   3. JKS keystore for WireMock
#
# This script runs inside the cert-gen container. It reads domain names
# from /config/domains.txt (one per line), which is assembled by devstack.sh
# from all mocks/*/domains files.
# =============================================================================

set -euo pipefail

CERT_DIR="/certs"
CONFIG_DIR="/config"
DOMAINS_FILE="${CONFIG_DIR}/domains.txt"

# If certs already exist and no force flag, skip
if [ -f "${CERT_DIR}/server.crt" ] && [ "${FORCE_REGEN:-0}" != "1" ]; then
    echo "[cert-gen] Certificates already exist. Skipping generation."
    echo "[cert-gen] Set FORCE_REGEN=1 to regenerate."
    exit 0
fi

echo "[cert-gen] Starting certificate generation..."

# ---------------------------------------------------------------------------
# Collect SANs from domains file
# ---------------------------------------------------------------------------
SAN_ENTRIES="DNS:localhost"
IP_ENTRIES="IP:127.0.0.1"

if [ -f "${DOMAINS_FILE}" ]; then
    while IFS= read -r domain || [ -n "${domain}" ]; do
        domain=$(echo "${domain}" | tr -d '[:space:]')
        [ -z "${domain}" ] && continue
        [[ "${domain}" == \#* ]] && continue
        SAN_ENTRIES="${SAN_ENTRIES},DNS:${domain}"
    done < "${DOMAINS_FILE}"
fi

# Add the project-local hostname
PROJECT_NAME="${PROJECT_NAME:-devstack}"
SAN_ENTRIES="${SAN_ENTRIES},DNS:${PROJECT_NAME}.local"

ALL_SANS="${SAN_ENTRIES},${IP_ENTRIES}"
echo "[cert-gen] SANs: ${ALL_SANS}"

# ---------------------------------------------------------------------------
# Generate OpenSSL config
# ---------------------------------------------------------------------------
cat > "${CERT_DIR}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = Dev
L = DevStack
O = DevStack CA
CN = ${PROJECT_NAME}-gateway

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = ${ALL_SANS}

[v3_ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer

[v3_server]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${ALL_SANS}
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# ---------------------------------------------------------------------------
# 1. Root CA
# ---------------------------------------------------------------------------
echo "[cert-gen] Generating Root CA..."
openssl genrsa -out "${CERT_DIR}/ca.key" 2048 2>/dev/null
openssl req -x509 -new -nodes \
    -key "${CERT_DIR}/ca.key" \
    -sha256 -days 3650 \
    -out "${CERT_DIR}/ca.crt" \
    -subj "/C=US/ST=Dev/L=DevStack/O=DevStack Root CA/CN=DevStack Internal Root" \
    -extensions v3_ca \
    -config "${CERT_DIR}/openssl.cnf"

# ---------------------------------------------------------------------------
# 2. Server Certificate
# ---------------------------------------------------------------------------
echo "[cert-gen] Generating server certificate..."
openssl genrsa -out "${CERT_DIR}/server.key" 2048 2>/dev/null
openssl req -new \
    -key "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.csr" \
    -config "${CERT_DIR}/openssl.cnf"

openssl x509 -req \
    -in "${CERT_DIR}/server.csr" \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/server.crt" \
    -days 365 \
    -sha256 \
    -extensions v3_server \
    -extfile "${CERT_DIR}/openssl.cnf"

# ---------------------------------------------------------------------------
# 3. JKS Keystore for WireMock
# ---------------------------------------------------------------------------
echo "[cert-gen] Generating JKS keystore for WireMock..."
openssl pkcs12 -export \
    -in "${CERT_DIR}/server.crt" \
    -inkey "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.p12" \
    -name wiremock \
    -passout pass:password

keytool -importkeystore \
    -srckeystore "${CERT_DIR}/server.p12" \
    -srcstoretype PKCS12 \
    -srcstorepass password \
    -destkeystore "${CERT_DIR}/wiremock.jks" \
    -deststoretype JKS \
    -deststorepass password \
    -noprompt 2>/dev/null

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "[cert-gen] Certificate generation complete."
echo "[cert-gen] Files:"
ls -la "${CERT_DIR}"/*.crt "${CERT_DIR}"/*.key "${CERT_DIR}"/*.jks 2>/dev/null
echo "[cert-gen] SANs included:"
openssl x509 -in "${CERT_DIR}/server.crt" -noout -ext subjectAltName 2>/dev/null || true
