#!/usr/bin/env bash

# Copyright 2018 The Kubernetes Authors. All rights reserved.
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

set -e pipefail
set -x

PORT=27018
RUN_DIR="/run/mongodb"

shutdown_mongo() {
    echo "Shutting down MongoDB"
    if (! mongo admin "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.shutdownServer({force: true})"); then
      echo "db.shutdownServer() failed, sending the terminate signal"
      kill -TERM "${pid}"
    fi
}

if [[ ! -f /bin/mongodb/initMongodStandalone.js ]]; then
  echo "Skipping init mongod standalone script"
  return 0
elif [[ -z "$(ls -1A /data/db)" ]]; then
  echo "mongod standalone script currently not supported on initial install"
  return 0
fi

if [[ -n "${ADMIN_USER}" ]]; then
    auth_args=("--auth" "--keyFile=${RUN_DIR}/key.txt")
    cred_args=(-u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}")
fi

if [[ -f /etc/mongodb/ca/tls.crt ]]; then
    ssl_args=(--ssl --sslCAFile /etc/mongodb/ca/tls.crt --sslPEMKeyFile "${RUN_DIR}/mongo.pem")
fi

echo "Starting a standalone MongoDB instance"
mongod --config /etc/mongodb/config/mongod.conf --dbpath=/data/db "${auth_args[@]}" "${ssl_args[@]}" --port "${PORT}" --bind_ip=0.0.0.0 2>&1 | tee -a "${RUN_DIR}/standalone.log" 1>&2 &
export pid=$!
trap shutdown_mongo EXIT

echo "Waiting for MongoDB to be ready"
until [[ $(mongo admin --port "${PORT}" "${cred_args[@]}" "${ssl_args[@]}" --quiet --eval "db.adminCommand('ping').ok") == "1" ]]; do
  sleep 1
done

echo "Running init js script on standalone mongod"
mongo admin --port "${PORT}" "${cred_args[@]}" "${ssl_args[@]}" /init/initMongodStandalone.js

echo "MongoDB standalone complete"
exit 0

