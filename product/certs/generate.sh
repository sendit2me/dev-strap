#!/bin/bash
# =============================================================================
# Certificate Generation Script
# =============================================================================
# Generates a complete PKI chain for HTTPS mock interception:
#   1. Root CA (trusted by the app container)
#   2. Server certificate with SANs for all mocked domains
#   (JKS removed — WireMock runs HTTP-only behind the proxy)
#
# This script runs inside the cert-gen container. It reads domain names
# from /config/domains.txt (one per line), which is assembled by devstack.sh
# from all mocks/*/domains files.
# =============================================================================

set -euo pipefail

CERT_DIR="/certs"
CONFIG_DIR="/config"
DOMAINS_FILE="${CONFIG_DIR}/domains.txt"

# Check if domains have changed since last cert generation
if [ -f "${CERT_DIR}/server.crt" ] && [ "${FORCE_REGEN:-0}" != "1" ]; then
    # Extract current SANs from the existing cert
    current_sans=$(openssl x509 -in "${CERT_DIR}/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:[^,]+' | sort)
    # Build expected SANs from domains.txt
    expected_sans="DNS:localhost"
    if [ -f "${DOMAINS_FILE}" ]; then
        while IFS= read -r domain || [ -n "${domain}" ]; do
            domain=$(echo "${domain}" | tr -d '[:space:]')
            [ -z "${domain}" ] && continue
            [[ "${domain}" == \#* ]] && continue
            expected_sans="${expected_sans}\nDNS:${domain}"
        done < "${DOMAINS_FILE}"
    fi
    expected_sans="${expected_sans}\nDNS:${PROJECT_NAME:-devstack}.local"
    expected_sorted=$(echo -e "${expected_sans}" | sort)

    if [ "${current_sans}" = "${expected_sorted}" ]; then
        echo "[cert-gen] Certificates up to date. Skipping."
        exit 0
    else
        echo "[cert-gen] Domain list changed. Regenerating certificates..."
    fi
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
# Summary
# ---------------------------------------------------------------------------
echo "[cert-gen] Certificate generation complete."
echo "[cert-gen] Files:"
ls -la "${CERT_DIR}"/*.crt "${CERT_DIR}"/*.key 2>/dev/null
echo "[cert-gen] SANs included:"
openssl x509 -in "${CERT_DIR}/server.crt" -noout -ext subjectAltName 2>/dev/null || true
