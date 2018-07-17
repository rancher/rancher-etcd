#!/bin/bash
if [ "$RANCHER_DEBUG" == "true" ]; then set -x; fi

META_URL="http://169.254.169.250/2015-12-19"

# loop until metadata wakes up...
STACK_NAME=$(wget -q -O - ${META_URL}/self/stack/name)
while [ "$STACK_NAME" == "" ]; do
  sleep 1
  STACK_NAME=$(wget -q -O - ${META_URL}/self/stack/name)
done
# Get etcd service certificates

mkdir -p /etc/etcd/ssl
cd /etc/etcd/ssl
while  [ -z "$ACTION" ] || [ "$ACTION" == "null" ]
do
    sleep 1
    UUID=$(curl -s http://rancher-metadata/2015-12-19/stacks/Kubernetes/services/etcd/uuid)
    ACTION=$(curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY "$CATTLE_URL/services?uuid=$UUID" | jq -r '.data[0].actions.certificate')
done
curl -s -u $CATTLE_ACCESS_KEY:$CATTLE_SECRET_KEY -X POST $ACTION > certs.zip
unzip -o certs.zip
cd $OLDPWD

export ETCD_CA_FILE="/etc/etcd/ssl/ca.pem"
export ETCD_KEY_FILE="/etc/etcd/ssl/key.pem"
export ETCDCTL_CA_FILE="/etc/etcd/ssl/ca.pem"
export ETCD_CERT_FILE="/etc/etcd/ssl/cert.pem"
export ETCDCTL_KEY_FILE="/etc/etcd/ssl/key.pem"
export ETCDCTL_CERT_FILE="/etc/etcd/ssl/cert.pem"

SCALE=$(giddyup service scale etcd)

while [ ! "$(echo $IP | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$')" ]; do
    sleep 1
    IP=$(wget -q -O - ${META_URL}/self/container/primary_ip)
    ETCD_CONTAINER_NAME=$(curl -s http://rancher-metadata/2015-12-19/self/container/name)
done

CREATE_INDEX=$(wget -q -O - ${META_URL}/self/container/create_index)
SERVICE_INDEX=$(wget -q -O - ${META_URL}/self/container/service_index)
HOST_UUID=$(wget -q -O - ${META_URL}/self/host/uuid)

# be very careful that all state goes into the data container
LEGACY_DATA_DIR=/data
DATA_DIR=/pdata
DR_FLAG=$DATA_DIR/DR
export ETCD_DATA_DIR=$DATA_DIR/data.current
export ETCDCTL_ENDPOINT=https://etcd.${STACK_NAME}:2379

# member name should be dashed-IP (piggyback off of retain_ip functionality)
NAME=$(echo $IP | tr '.' '-')


# giddyup doesn't do https auth, so we are doing this
# probe_https URL loop|noloop MIN MAX BACKOFF
probe_https() {
  url=${1}
  loop=${2:-"noloop"}
  min=${3:-1}
  max=${4:-15}
  backoff=${5:-1}
  # start a time counter
  SECONDS=0

  delay=$min
  if [ $loop == "loop" ]
  then
    while true
    do
      if [ $(echo  $delay\>$max | bc) -eq 1 ]
      then
        delay=$max
      else
        delay=$(echo $delay*$backoff| bc)
      fi
      curl -s -k --cacert $ETCD_CA_FILE \
        --cert $ETCD_CERT_FILE\
        --key $ETCD_KEY_FILE \
        $url | grep -q '{"health": "true"}'
      if [ $? -eq 0 ]
      then
        return 0
      fi
      # check the time counter, how long have we been trying!
      [ "$RANCHER_DEBUG" == "true" ] && echo "seconds=" $SECONDS
      if [ $SECONDS -gt 60 ]
      then
        return $SECONDS
      fi
      sleep $delay
    done
  else
    curl -s -k --cacert $ETCD_CA_FILE \
      --cert $ETCD_CERT_FILE\
      --key $ETCD_KEY_FILE \
      $url | grep -q '{"health": "true"}'
    return $?
  fi
}

switch_node_to_https() {
  member_id=""
  while [ "$member_id" == "" ]
  do
    member_id=$(etcdctl_one member list | grep $NAME | cut -d ":" -f 1)
    sleep 1
  done
  # etcd says it is healthy, but writes fail for a while...so keep trying until it works
  etcdctl --endpoints=https://127.0.0.1:2379 member update $member_id https://${ETCD_CONTAINER_NAME}:2380
  while [ "$?" != "0" ]; do
      sleep 1
      etcdctl --endpoints=https://127.0.0.1:2379 member update $member_id https://${ETCD_CONTAINER_NAME}:2380
  done

}

etcdctl_quorum() {
    target_ip=0
    for container in $(giddyup service containers); do
        primary_ip=$(wget -q -O - ${META_URL}/self/service/containers/${container}/primary_ip)

        probe_https https://${container}:2379/health &> /dev/null
        if [ "$?" == "0" ]; then
            target_ip=$primary_ip
            container_name=$container
            break
        fi
    done
    if [ "$target_ip" == "0" ]; then
        echo No etcd nodes available
    else
        etcdctl --endpoints https://${container}:2379 $@
    fi
}

# may only be used for quorum=false reads
etcdctl_one() {
    target_ip=0
    container_name=""
    for container in $(giddyup service containers); do
        primary_ip=$(wget -q -O - ${META_URL}/self/service/containers/${container}/primary_ip)

        giddyup probe tcp://${primary_ip}:2379 &> /dev/null
        if [ "$?" == "0" ]; then
            target_ip=$primary_ip
            container_name=$container
            break
        fi
    done
    if [ "$target_ip" == "0" ]; then
        echo No etcd nodes available
    else
        etcdctl --endpoints https://${container_name}:2379 $@
    fi
}

healthcheck_proxy() {
    WAIT=${1:-60s}
    etcdwrapper healthcheck-proxy --port=:2378 --wait=$WAIT --debug=false
}

create_backup() {
    backup_type=$1
    target_dir=$2

    backup_dir=${DATA_DIR}/data.$(date +"%Y%m%d.%H%M%S").${backup_type}

    etcdctl backup \
        --data-dir $target_dir \
        --backup-dir $backup_dir

    echo $backup_dir
}

rolling_backup() {
    EMBEDDED_BACKUPS=${EMBEDDED_BACKUPS:-true}

    if [ "$EMBEDDED_BACKUPS" == "true" ]; then
        BACKUP_PERIOD=${BACKUP_PERIOD:-5m}
        BACKUP_RETENTION=${BACKUP_RETENTION:-24h}

        giddyup leader elect --proxy-tcp-port=2160 \
            etcdwrapper rolling-backup \
                --period=$BACKUP_PERIOD \
                --retention=$BACKUP_RETENTION \
                --index=$SERVICE_INDEX
    fi
}

cleanup() {
    exitcode=$1
    timestamp=$(date -R)
    echo "Exited ($exitcode)"

    if [ "$exitcode" == "0" ]; then
        rm -rf $ETCD_DATA_DIR
        echo "$timestamp -> Exit (0), member removed. Deleted data" >> $DATA_DIR/events

    elif [ "$exitcode" == "2" ]; then
        rm -rf $ETCD_DATA_DIR
        echo "$timestamp -> Exit (2), log corrupted, truncated, lost. Deleted data" >> $DATA_DIR/events

    else
        echo "$timestamp -> Exit ($exitcode), unknown. No action taken" >> $DATA_DIR/events
    fi

    # It's important that we return the exit code of etcd, otherwise scheduler might not delete/recreate
    # failed containers, leading to stale create_index which messes up `giddyup leader check`
    exit $exitcode
}

standalone_node() {
    # write IP to data directory for reference
    echo $IP > $ETCD_DATA_DIR/ip

    healthcheck_proxy 0s &
    rolling_backup &
    etcd \
        --name ${NAME} \
        --listen-client-urls https://0.0.0.0:2379 \
        --advertise-client-urls https://${ETCD_CONTAINER_NAME}:2379 \
        --listen-peer-urls https://0.0.0.0:2380 \
        --initial-advertise-peer-urls https://${ETCD_CONTAINER_NAME}:2380 \
        --initial-cluster ${NAME}=https://${ETCD_CONTAINER_NAME}:2380 \
        --initial-cluster-state new \
        --client-cert-auth \
        --peer-client-cert-auth \
        --trusted-ca-file $ETCD_CA_FILE \
        --key-file $ETCD_KEY_FILE \
        --cert-file $ETCD_CERT_FILE \
        --peer-trusted-ca-file $ETCD_CA_FILE \
        --peer-cert-file $ETCD_CERT_FILE \
        --peer-key-file $ETCD_KEY_FILE

    cleanup $?
}

restart_node() {
    healthcheck_proxy &
    rolling_backup &
    etcd \
        --name ${NAME} \
        --listen-client-urls https://0.0.0.0:2379 \
        --advertise-client-urls https://${ETCD_CONTAINER_NAME}:2379 \
        --listen-peer-urls https://0.0.0.0:2380 \
        --initial-advertise-peer-urls https://${ETCD_CONTAINER_NAME}:2380 \
        --initial-cluster-state existing \
        --client-cert-auth \
        --peer-client-cert-auth \
        --trusted-ca-file $ETCD_CA_FILE \
        --key-file $ETCD_KEY_FILE \
        --cert-file $ETCD_CERT_FILE \
        --peer-trusted-ca-file $ETCD_CA_FILE \
        --peer-cert-file $ETCD_CERT_FILE \
        --peer-key-file $ETCD_KEY_FILE

    cleanup $?
}

# Scale Up
runtime_node() {
    rm -rf $ETCD_DATA_DIR/*
    timestamp=$(date -R)
    echo "$timestamp -> Scaling up. Deleted stale data" >> $DATA_DIR/events

    # Get leader create_index
    # Wait for nodes with smaller service index to become healthy
    for container in $(giddyup service containers --exclude-self); do
        echo Waiting for lower index nodes to all be active
        ctx_index=$(wget -q -O - ${META_URL}/self/service/containers/${container}/create_index)
        primary_ip=$(wget -q -O - ${META_URL}/self/service/containers/${container}/primary_ip)
        if [ "${ctx_index}" -lt "${CREATE_INDEX}" ]; then
            probe_https https://${container}:2379/health loop 1 15 1.2
            if [ $? -ne 0 ]
            then
              echo "Failed to get a healthy response. Giving up.."
              exit 1
            fi
        fi
    done

    # We can almost use giddyup here, need service index templating {{service_index}}
    # giddyup ip stringify --prefix etcd{{service_index}}=http:// --suffix :2380
    # etcd1=http://10.42.175.109:2380,etcd2=http://10.42.58.73:2380,etcd3=http://10.42.96.222:2380
    for container in $(giddyup service containers); do
        ctx_index=$(wget -q -O - ${META_URL}/self/service/containers/${container}/create_index)

        # simulate step-scale policy by ignoring create_indeces greater than our own
        if [ "${ctx_index}" -gt "${CREATE_INDEX}" ]; then
            continue
        fi

        cip=$(wget -q -O - ${META_URL}/self/service/containers/${container}/primary_ip)
        cname=$(echo $cip | tr '.' '-')
        if [ "$cluster" != "" ]; then
            cluster=${cluster},
        fi
        cluster=${cluster}${cname}=https://${container}:2380
    done

    etcdctl_quorum member add $NAME https://${ETCD_CONTAINER_NAME}:2380

    # write container IP to data directory for reference
    echo $IP > $ETCD_DATA_DIR/ip

    healthcheck_proxy &
    rolling_backup &
    etcd \
        --name ${NAME} \
        --listen-client-urls https://0.0.0.0:2379 \
        --advertise-client-urls https://${ETCD_CONTAINER_NAME}:2379 \
        --listen-peer-urls https://0.0.0.0:2380 \
        --initial-advertise-peer-urls https://${ETCD_CONTAINER_NAME}:2380 \
        --initial-cluster-state existing \
        --initial-cluster $cluster \
        --client-cert-auth \
        --peer-client-cert-auth \
        --trusted-ca-file $ETCD_CA_FILE \
        --key-file $ETCD_KEY_FILE \
        --cert-file $ETCD_CERT_FILE \
        --peer-trusted-ca-file $ETCD_CA_FILE \
        --peer-cert-file $ETCD_CERT_FILE \
        --peer-key-file $ETCD_KEY_FILE
    cleanup $?
}

# recoverable failure scenario
recover_node() {
    rm -rf $ETCD_DATA_DIR/*
    timestamp=$(date -R)
    echo "$timestamp -> Recovering. Deleted stale data" >> $DATA_DIR/events

    # figure out which node we are replacing
    oldnode=$(etcdctl_quorum member list | grep "$IP" | tr ':' '\n' | head -1 | sed 's/\[unstarted\]//')

    # remove the old node
    etcdctl_quorum member remove $oldnode

    # create cluster parameter based on etcd state (can't use rancher metadata)
    while read -r member; do
        name=$(echo $member | tr ' ' '\n' | grep name | tr '=' '\n' | tail -1)
        peer_url=$(echo $member | tr ' ' '\n' | grep peerURLs | tr '=' '\n' | tail -1)
        if [ "$cluster" != "" ]; then
            cluster=${cluster},
        fi
        cluster=${cluster}${name}=${peer_url}
    done <<< "$(etcdctl_quorum member list | grep -v unstarted)"
    cluster=${cluster},${NAME}=https://${ETCD_CONTAINER_NAME}:2380

    etcdctl_quorum member add $NAME https://${ETCD_CONTAINER_NAME}:2380

    # write container IP to data directory for reference
    echo $IP > $ETCD_DATA_DIR/ip

    healthcheck_proxy &
    rolling_backup &
    etcd \
        --name ${NAME} \
        --listen-client-urls https://0.0.0.0:2379 \
        --advertise-client-urls https://${ETCD_CONTAINER_NAME}:2379 \
        --listen-peer-urls https://0.0.0.0:2380 \
        --initial-advertise-peer-urls https://${ETCD_CONTAINER_NAME}:2380 \
        --initial-cluster-state existing \
        --initial-cluster $cluster \
        --client-cert-auth \
        --peer-client-cert-auth \
        --trusted-ca-file $ETCD_CA_FILE \
        --key-file $ETCD_KEY_FILE \
        --cert-file $ETCD_CERT_FILE \
        --peer-trusted-ca-file $ETCD_CA_FILE \
        --peer-cert-file $ETCD_CERT_FILE \
        --peer-key-file $ETCD_KEY_FILE
    cleanup $?
}

disaster_node() {
    RECOVERY_DIR=${DATA_DIR}/$(cat $DR_FLAG)

    # always backup the current dir
    if [ "$RECOVERY_DIR" == "${DATA_DIR}/data.current" ]; then
        RECOVERY_DIR=$(create_backup DR $RECOVERY_DIR)
    fi

    echo "Sanitizing backup..."
    etcd \
        --name ${NAME} \
        --data-dir $RECOVERY_DIR \
        --advertise-client-urls https://${ETCD_CONTAINER_NAME}:2379 \
        --listen-client-urls https://0.0.0.0:2379 \
        --client-cert-auth \
        --trusted-ca-file $ETCD_CA_FILE \
        --key-file $ETCD_KEY_FILE \
        --cert-file $ETCD_CERT_FILE \
        --force-new-cluster &
    PID=$!

    # wait until etcd reports healthy
    probe_https https://127.0.0.1:2379/health loop 1 15 1.2

    # Disaster recovery ignores peer-urls flag, so we update it

    # query etcd for its old member ID
    while [ "$oldnode" == "" ]; do
        oldnode=$(etcdctl --endpoints=https://127.0.0.1:2379 member list | grep "$NAME" | tr ':' '\n' | head -1)
        sleep 1
    done

    # etcd says it is healthy, but writes fail for a while...so keep trying until it works
    etcdctl --endpoints=https://127.0.0.1:2379 member update $oldnode https://${ETCD_CONTAINER_NAME}:2380
    while [ "$?" != "0" ]; do
        sleep 1
        etcdctl --endpoints=https://127.0.0.1:2379 member update $oldnode https://${ETCD_CONTAINER_NAME}:2380
    done

    # shutdown the node cleanly
    while kill -0 $PID &> /dev/null; do
        kill $PID
        sleep 1
    done

    echo "Copying sanitized backup to data directory..."
    mkdir -p ${ETCD_DATA_DIR}
    rm -rf ${ETCD_DATA_DIR}/*
    cp -rf $RECOVERY_DIR/* ${ETCD_DATA_DIR}/

    # remove the DR flag
    rm -rf $DR_FLAG

    # TODO (llparse) kill all other etcd nodes

    # become a new standalone node
    standalone_node
}

node() {
    mkdir -p $ETCD_DATA_DIR

    if [ -d "$LEGACY_DATA_DIR/member" ] && [ ! -d "$LEGACY_DATA_DIR/data.current" ]; then
        echo "Upgrading FS structure from version <= etcd:v2.3.6-4 to etcd:v2.3.7-6"
        mkdir -p $LEGACY_DATA_DIR/data.current
        rm -rf $LEGACY_DATA_DIR/data.current/*
        cp -rf $LEGACY_DATA_DIR/member $LEGACY_DATA_DIR/data.current/
        node

    elif [ -d "$LEGACY_DATA_DIR/data.current" ] && [ ! -d "$ETCD_DATA_DIR/member" ]; then
        echo "Upgrading FS structure from version = rancher/etcd:v2.3.7-6 to current"
        mkdir -p $ETCD_DATA_DIR
        rm -rf $ETCD_DATA_DIR/*
        cp -rf $LEGACY_DATA_DIR/data.current/member $ETCD_DATA_DIR/
        echo $IP > $ETCD_DATA_DIR/ip
        node

    # if the DR flag is set, enter disaster recovery
    elif [ -f "$DR_FLAG" ]; then
        echo Disaster Recovery
        disaster_node

    # if we have a data volume and it was served by a container with same IP
    elif [ -d "$ETCD_DATA_DIR/member" ] && [ "$(cat $ETCD_DATA_DIR/ip)" == "$IP" ]; then
        echo Restarting Existing Node
        # to handle upgrade to ssl cases
        switch_node_to_https &
        restart_node

    # if this member is already registered to the cluster but no data volume, we are recovering
    elif [ "$(etcdctl_one member list | grep $IP)" ]; then
        echo Recovering existing node data directory
        recover_node

    # if we are the first etcd to start
    elif giddyup leader check; then

        # if we have an old data dir, trigger an automatic disaster recovery (tee-hee)
        if [ -d "$ETCD_DATA_DIR/member" ]; then
            echo data.current > $DR_FLAG
            disaster_node

        # otherwise, start a new cluster
        else
            echo Bootstrapping Cluster
            standalone_node
        fi

    # we are scaling up
    else
        echo Adding Node
        runtime_node
    fi
}

if [ $# -eq 0 ]; then
    echo No command specified, running in standalone mode.
    standalone_node
else
    eval $1
fi
