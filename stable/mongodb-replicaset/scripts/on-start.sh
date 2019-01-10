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

set -e pipefail
set -x

port=27017
replica_set="$REPLICA_SET"
RUN_DIR="/run/mongodb"
SECONDS=0
timeout="${TIMEOUT:-900}"

my_hostname=$(hostname)
peers=($(cat "${RUN_DIR}/peers"))
service_name=$(cat "${RUN_DIR}/service")

if [[ -n "${ADMIN_USER}" ]]; then
    admin_creds=(-u "${ADMIN_USER}" -p "${ADMIN_PASSWORD}")
fi

if [[ -f /etc/mongodb/ca/tls.crt ]]; then
    ssl_args=(--ssl --sslCAFile /etc/mongodb/ca/tls.crt --sslPEMKeyFile "${RUN_DIR}/mongo.pem")
fi

log() {
    local msg="$1"
    local timestamp=$(date --iso-8601=ns)
    echo "[$timestamp] $msg" >> "${RUN_DIR}/on-start.log"
}

retry_until() {
    local host="${1}"
    local command="${2}"
    local expected="${3}"
    local creds=("${admin_creds[@]}")

    # Don't need credentials for admin user creation and pings that run on localhost
    if [[ "${host}" =~ ^localhost ]]; then
        creds=()
    fi

    until [[ $(mongo admin --host "${host}" "${creds[@]}" "${ssl_args[@]}" --quiet --eval "${command}") == "${expected}" ]]; do
        sleep 1

        if [[ "${SECONDS}" -ge "${timeout}" ]]; then
            log "Timed out after ${timeout}s attempting to bootstrap mongod"
            exit 1
        fi

        log "Retrying ${command} on ${host}"
    done
}

log "Bootstrapping MongoDB replica set member: $my_hostname"
log "Peers: ${peers[*]}"
log "Waiting for MongoDB to be ready..."
retry_until "localhost" "db.adminCommand('ping').ok" "1"
log "Initialized."

# try to find a master
for peer in "${peers[@]}"; do
    log "Checking if ${peer} is primary"
    # Check rs.status() first since it could be in primary catch up mode which db.isMaster() doesn't show
    if [[ $(mongo admin --host "${peer}" "${admin_creds[@]}" "${ssl_args[@]}" --quiet --eval "rs.status().myState") == "1" ]]; then
        retry_until "${peer}" "db.isMaster().ismaster" "true"
        log "Found primary: ${peer}"
        primary="${peer}"
        break
    fi
done

if [[ "${primary}" = "${service_name}" ]]; then
    log "This replica is already PRIMARY"
elif [[ -n "${primary}" ]]; then
    if [[ $(mongo admin --host "${primary}" "${admin_creds[@]}" "${ssl_args[@]}" --quiet --eval "rs.conf().members.findIndex(m => m.host == '${service_name}:${port}')") == "-1" ]]; then
      log "Adding myself (${service_name}) to replica set..."
      if (mongo admin --host "${primary}" "${admin_creds[@]}" "${ssl_args[@]}" --eval "rs.add('${service_name}')" | grep 'Quorum check failed'); then
          log 'Quorum check failed, unable to join replicaset. Exiting prematurely.'
          exit 1
      fi
    fi

    sleep 3
    log 'Waiting for replica to reach SECONDARY state...'
    retry_until "${service_name}" "rs.status().myState" "2"
    log '✓ Replica reached SECONDARY state.'

elif (mongo "${ssl_args[@]}" --eval "rs.status()" | grep "no replset config has been received"); then
    log "Initiating a new replica set with myself ($service_name)..."
    mongo "${ssl_args[@]}" --eval "rs.initiate({'_id': '$replica_set', 'members': [{'_id': 0, 'host': '$service_name'}]})"

    sleep 3
    log 'Waiting for replica to reach PRIMARY state...'
    retry_until "localhost" "db.isMaster().ismaster" "true"
    primary="${service_name}"
    log '✓ Replica reached PRIMARY state.'

    if [[ -n "${ADMIN_USER}" ]]; then
        log "Creating admin user..."
        mongo admin "${ssl_args[@]}" --eval "db.createUser({user: '${ADMIN_USER}', pwd: '${ADMIN_PASSWORD}', roles: [{role: 'root', db: 'admin'}]})"
    fi
fi

# User creation
if [[ -n "${primary}" && -n "${METRICS_USER}" ]]; then
    metric_user_count=$(mongo admin --host "${primary}" "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.system.users.find({user: '${METRICS_USER}'}).count()" --quiet)
    if [[ "${metric_user_count}" == "0" ]]; then
        log "Creating clusterMonitor user..."
        mongo admin --host "${primary}" "${admin_creds[@]}" "${ssl_args[@]}" --eval "db.createUser({user: '${METRICS_USER}', pwd: '${METRICS_PASSWORD}', roles: [{role: 'clusterMonitor', db: 'admin'}, {role: 'read', db: 'local'}]})"
    fi
fi

log "MongoDB bootstrap complete"
exit 0

