#!/bin/sh
# generate some test data after siteconfig was created by loadSiteConfig() below
# svc=tiled; mkdir -p le-dummy/\*.sub.example.com && openssl rand -hex 128 > le-dummy/\*.sub.example.com/fullchain.cer; openssl rand -hex 128 > le-dummy/\*.sub.example.com/\*.sub.example.com.key && mkdir -p /tmp/tempdata && sed -i -e "s#LE_BASE_PATH=.*#LE_BASE_PATH=$(readlink -f le-dummy)#" -e "s#TILED_DATA=.*#TILED_DATA=/tmp/tempdata#" -e "s#TILED_FQDN=.*#TILED_FQDN=$svc.\$DOMAINBASE#" siteconfig/general.rc
#
# https://blueskyproject.io/tiled/how-to/docker.html

scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
scriptname="$(basename "$scriptpath")"

. "$scriptdir/../utils/deploy"
. "$scriptdir/../utils/postgres"
. "$scriptdir/../utils/ingress"

loadSiteConfig TILED_DATA TILED_FQDN TILED_PUB TILED_KEY || exit 1

SVC_NAME="${scriptname%.*}"  # script name without extension
BASEPATH="$TILED_DATA"  # of persistent data storage
# Create a podman network
NETWORK_NAME=tiled-network
podmanNetwork "$NETWORK_NAME"
CONT_DB_NAME="${SVC_NAME}-db"
CONT_SRV_NAME="${SVC_NAME}-srv"

genTiledSvc()
{
    local cname="$1"
    local tag="$2"
    local basepath="$3"
    local network="$4"
    local dbname="$5"
    #local dbAdminPass="$6"
    #local apikey="$7"
    shift 5
    systemctl --user is-active --quiet "$cname" && return
    # get internal IP of postgres, shouldn't be necessary but name resolution didnt work before
    local CFG_PATH="$basepath/config"
    mkdir -p "$CFG_PATH"
    local CFG_FILE="$CFG_PATH/single_catalog_single_user.yml"
    if [ ! -f "$CFG_FILE" ]; then
        # Download the file using curl from GitHub repository
        curl -s -o "$CFG_FILE" "https://raw.githubusercontent.com/bluesky/tiled/main/example_configs/single_catalog_single_user.yml"
    fi
    dbAdminPass="$(getPodmanSecret "${dbname}-pass")"
    sed -i -e '/^\s*uri/i\      uri:              '"postgresql://postgres:\${TILED_DATABASE_PASSWORD}@$dbname:5432" -e '/^\s*uri/d' "$CFG_FILE"
    sed -i -e '/^\s*writable_storage/i\      writable_storage: '"postgresql://postgres:\${TILED_DATABASE_PASSWORD}@$dbname:5432/tiled_storage" -e '/^\s*writable_storage/d' "$CFG_FILE"
    # wait for the DB to get ready
    until podman exec "$dbname" psql -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1
    do
        sleep 1
    done
    # create the db if it does not exist yet
    podman exec "$dbname" psql -U postgres -d postgres \
        -tAc "SELECT 1 FROM pg_database WHERE datname='tiled_storage'" | grep -q 1 \
        || podman exec "$dbname" psql -U postgres -c "CREATE DATABASE tiled_storage"
    local STORAGE_PATH="$basepath/storage"
    mkdir -p "$STORAGE_PATH"

    # generate an apikey if none exists
    local apikey="${cname}-apikey"
    local sec;
    if ! podman secret exists "$apikey"; then
        openssl rand -hex 32 | tr -d '\n' | podman secret create "$apikey" -
    fi

    local contpath="$HOME/.config/containers/systemd"
    mkdir -p "$contpath"

cat > "$contpath/$cname.container" << EOF
[Unit]
Description=Tiled Server
After=network-online.target

[Container]
ContainerName=$cname
Image=ghcr.io/bluesky/tiled:$tag
Volume=$CFG_PATH:/deploy/config:ro,Z
Volume=$STORAGE_PATH:/storage:rw,Z
$(echo "$@" | sed -E 's/([[:space:]])([A-Z_][A-Z0-9_]*=)/\n\2/g' | sed '/^$/d; s/.*/Environment=&/')
Secret=${dbname}-pass,type=env,target=TILED_DATABASE_PASSWORD
Secret=$apikey,type=env,target=TILED_SINGLE_USER_API_KEY
PublishPort=8020:8000
Network=$network

[Service]
Restart=always
RestartSec=5s

[Install]
WantedBy=default.target
EOF
    chmod o-rwx "$contpath/$cname.container"
    # make the new container (or updates) know to systemctl
    systemctl --user daemon-reload
}

if [ "$1" = up ]; then

    genPostgresSvc "$CONT_DB_NAME" 16 "$TILED_DATA/db-data" "$NETWORK_NAME" \
        POSTGRES_USER=postgres \
        POSTGRES_HOST_AUTH_METHOD="" \
        PGDATA=/var/lib/postgresql/data/pgdata
    systemctl --user restart "$CONT_DB_NAME"
    # wait a moment to get ready
    while ! systemctl --user is-active --quiet "$CONT_DB_NAME"; do sleep 1; done

    genTiledSvc "$CONT_SRV_NAME" latest "$TILED_DATA" "$NETWORK_NAME" "$CONT_DB_NAME"
    systemctl --user restart "$CONT_SRV_NAME"

    setupIngress "$SVC_NAME" "${scriptpath%.*}.yaml" "$TILED_PUB" "$TILED_KEY" "$TILED_FQDN"

elif [ "$1" = down ];then # clean up in reversed order

    teardownIngress "$SVC_NAME" "$CONT_SRV_NAME"
    systemctl --user stop  "$CONT_SRV_NAME"
    #stopContainer "$CONT_SRV_NAME"
    #stopContainer "$CONT_DB_NAME"
    systemctl --user stop "$CONT_DB_NAME"

elif [ "$1" = reset ]; then
    "$0" down
    sleep 1
    if [ -d "$BASEPATH" ]; then
       echo "Deleting files ..."
       find "$BASEPATH" -mindepth 1 -maxdepth 1 -type d -exec sudo rm -R {} \;
    fi
    "$0" up
else
    echo "No action given, please provide 'up' or 'down'."
    exit 1
fi
