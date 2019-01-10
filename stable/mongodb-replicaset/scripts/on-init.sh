#!/usr/bin/env bash

# Copyright 2019 The Kubernetes Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -xe

CONF="/etc/mongodb"
CA_CRT="${CONF}/ca/tls.crt"
CA_KEY="${CONF}/ca/tls.key"
PEERS=()
PEM="mongo.pem"
RUN_DIR="/run/mongodb"
SERVICE_NAME=""

mkdir -p "${RUN_DIR}"
pushd "${RUN_DIR}"

while read -ra line; do
    if [[ "${line}" == *"${HOSTNAME}"* ]]; then
        SERVICE_NAME="${line}"
    fi
    PEERS+=("${line}")
done

echo -n "${PEERS[*]}" > "${RUN_DIR}/peers"
echo -n "${SERVICE_NAME}" > "${RUN_DIR}/service"

# MongoDB requires no group or world permissions for the key file and using fsGroup always adds group permission
cp "${CONF}/key/key.txt" key.txt
chmod 600 key.txt

if [[ -f "${CA_CRT}" ]]; then
  echo "Generating certificate"
  cat > openssl.cnf <<EOL
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = $(echo -n "${HOSTNAME}" | sed s/-[0-9]*$//)
DNS.2 = ${HOSTNAME}
DNS.3 = ${SERVICE_NAME}
DNS.4 = localhost
DNS.5 = 127.0.0.1
EOL

  openssl genrsa -out mongo.key 2048
  openssl req -new -key mongo.key -out mongo.csr -subj "/OU=MongoDB/CN=${HOSTNAME}" -config openssl.cnf
  openssl x509 -req -in mongo.csr -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAserial ./tls.srl -CAcreateserial -out mongo.crt -days 3650 -extensions v3_req -extfile openssl.cnf

  cat mongo.crt mongo.key > "${PEM}"
  rm mongo.csr mongo.key mongo.crt openssl.cnf tls.srl
fi

exit 0

