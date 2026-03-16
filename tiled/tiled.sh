#!/bin/sh
# generate some test data after siteconfig was created by loadSiteConfig() below
# svc=tiled; mkdir -p le-dummy/\*.sub.example.com && openssl rand -hex 128 > le-dummy/\*.sub.example.com/fullchain.cer; openssl rand -hex 128 > le-dummy/\*.sub.example.com/\*.sub.example.com.key && mkdir -p /tmp/tempdata && sed -i -e "s#LE_BASE_PATH=.*#LE_BASE_PATH=$(readlink -f le-dummy)#" -e "s#TILED_DATA=.*#TILED_DATA=/tmp/tempdata#" -e "s#TILED_FQDN=.*#TILED_FQDN=$svc.\$DOMAINBASE#" siteconfig/general.rc

scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
scriptname="$(basename "$scriptpath")"

. "$scriptdir/../utils/deploy"
. "$scriptdir/../utils/postgres"
. "$scriptdir/../utils/ingress"

loadSiteConfig TILED_DATA TILED_FQDN TILED_PUB TILED_KEY TILED_APIKEY TILED_DB_ADMIN_PASS || exit 1

SVC_NAME="${scriptname%.*}"  # script name without extension
SECRET_NAME="${SVC_NAME}.tls"

BASEPATH="$TILED_DATA"  # of persistent data storage
# Create a podman network
NETWORK_NAME=tiled-network
podmanNetwork "$NETWORK_NAME"

startTiled() {
    local cname="$1"
    local tag="$2"
    local basepath="$3"
    local network="$4"
    local dbname="$5"
    local dbAdminPass="$6"
    local apikey="$7"
    isContainerRunning "$cname" && return
    # starting the container
    local DB_IP="$(podman inspect "$dbname" | jq -r ".[0].NetworkSettings.Networks.[\"$network\"].IPAddress")"
    # echo "DB_IP=$DB_IP"
    local CFG_PATH="$basepath/config"
    mkdir -p "$CFG_PATH"
    local CFG_FILE="$CFG_PATH/single_catalog_single_user.yml"
    if [ ! -f "$CFG_FILE" ]; then
        # Download the file using curl from GitHub repository
        curl -s -o "$CFG_FILE" "https://raw.githubusercontent.com/bluesky/tiled/main/example_configs/single_catalog_single_user.yml"
    fi
    sed -i -e '/^\s*uri/i\      uri:              '"postgresql://postgres:${dbAdminPass}@$DB_IP:5432" -e '/^\s*uri/d' "$CFG_FILE"
    sed -i -e '/^\s*writable_storage/i\      writable_storage: '"postgresql://postgres:${dbAdminPass}@$DB_IP:5432/tiled_storage" -e '/^\s*writable_storage/d' "$CFG_FILE"
    podman exec "$dbname" psql -U postgres -c "CREATE DATABASE tiled_storage;"
    local STORAGE_PATH="$basepath/storage"
    mkdir -p "$STORAGE_PATH"
    podman run --detach --name "$cname" --hostname "$cname" --network "$network" \
        -p 8020:8000 \
        -e TILED_SINGLE_USER_API_KEY="$apikey" \
        -e TILED_DATABASE_PASSWORD=${dbAdminPass} \
        -v "$CFG_PATH":/deploy/config:ro \
        -v "$STORAGE_PATH":/storage \
        ghcr.io/bluesky/tiled:"$tag"
        #-it --rm --entrypoint bash \
}

CONT_DB_NAME=tiled-db
CONT_APP_NAME=tiled-srv
if [ "$1" = up ]; then

    startPostgres "$CONT_DB_NAME" 16 "$TILED_DATA" "$NETWORK_NAME" "$TILED_DB_ADMIN_PASS"

    startTiled "$CONT_APP_NAME" latest "$TILED_DATA" "$NETWORK_NAME" \
        "$CONT_DB_NAME" "$TILED_DB_ADMIN_PASS" "$TILED_APIKEY"

    setupIngress "$SVC_NAME" "${scriptpath%.*}.yaml" "$TILED_PUB" "$TILED_KEY" "$TILED_FQDN"

elif [ "$1" = down ]; then # clean up in reversed order
    teardownIngress "$SVC_NAME" "$CONT_APP_NAME"
    stopContainer "$CONT_APP_NAME"
    stopContainer "$CONT_DB_NAME"
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
