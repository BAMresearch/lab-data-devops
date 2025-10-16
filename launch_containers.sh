#!/bin/sh

. /home/buildbot/scicat/deploy/services/deploytools
loadSiteConfig
# make sure the passwords are defined
checkVars OPENBIS_DATA OPENBIS_FQDN OPENBIS_DB_ADMIN_PASS OPENBIS_ADMIN_PASS OPENBIS_DB_APP_PASS || exit 1

makepass() {
    dd if=/dev/urandom bs=1 count=20 status=none | base64 | sed 's/.$//'
}
isContainerRunning() {
    local cname="$1"
    podman ps -a --format "{{.ID}}  {{.Image}} {{.Names}}" | grep -q "$cname\$"
}
stopContainer() {
    local cname="$1"
    if isContainerRunning "$cname"; then
        echo "Stop and remove existing $cname container first"
        podman stop "$cname" && podman rm "$cname"
    fi
}

BASEPATH="$OPENBIS_DATA"  # of persistent data storage
# Create a podman network
NETWORK_NAME=openbis-network
if ! podman network ls -qn | grep -q "$NETWORK_NAME"; then
    echo "Creating network $NETWORK_NAME"
    podman network create "$NETWORK_NAME" --driver bridge
fi

CONT_DB_NAME=openbis-db
CONT_APP_NAME=openbis-app
CONT_IDX_NAME=openbis-landing
if [ "$1" = up ]; then
    if ! isContainerRunning "$CONT_DB_NAME"; then
        # Set up the database
        export OPENBIS_DB_PATH="$BASEPATH/db-data"
        mkdir -p "$OPENBIS_DB_PATH"
        podman run --detach --name "$CONT_DB_NAME" --hostname "$CONT_DB_NAME" --network "$NETWORK_NAME" \
            -v "$OPENBIS_DB_PATH":/var/lib/postgresql/data \
            -e PGDATA=/var/lib/postgresql/data/pgdata \
            -e POSTGRES_HOST_AUTH_METHOD="" \
            -e POSTGRES_PASSWORD="$OPENBIS_DB_ADMIN_PASS" \
            postgres:15
        # wait for DB to be ready
        finalmsg=' [1] LOG:  database system is ready to accept connections'
        while ! podman logs openbis-db 2>&1 | tail -n3 | grep -qF "$finalmsg"; do
            sleep 1
        done
    fi

    if ! isContainerRunning "$CONT_IDX_NAME"; then
        # render landing page
        tmpfn=static/index.html
        cp landingpage.html "$tmpfn"
        for name in OPENBIS_FQDN OPENBIS_INSTANCE; do
            set | grep -q "^$name=" || continue
            value="$(eval echo \$$name)"
            #echo "name: $name, value: $value"
            sed -i "s/\\b$name\\b/$value/" "$tmpfn"
        done
        podman run -d --name "$CONT_IDX_NAME" -p 8085:80 -v ./static:/usr/share/nginx/html:ro nginx
    fi

    if ! isContainerRunning "$CONT_APP_NAME"; then
        # Run application container
        export OPENBIS_TAG="20.10.11"
        export OPENBIS_APP_DATA_PATH="$BASEPATH/app-data"
        export OPENBIS_APP_CONFIG_PATH="$BASEPATH/app-etc"
        export OPENBIS_APP_LOGS_PATH="$BASEPATH/app-logs"
        mkdir -p "$OPENBIS_APP_DATA_PATH" "$OPENBIS_APP_CONFIG_PATH" "$OPENBIS_APP_LOGS_PATH"
        podman run --detach --name "$CONT_APP_NAME" --hostname "$CONT_APP_NAME" --network "$NETWORK_NAME" \
            --pid host -p 8080:8080 -p 8081:8081 \
            -v "$OPENBIS_APP_DATA_PATH":/data \
            -v "$OPENBIS_APP_CONFIG_PATH":/etc/openbis \
            -v "$OPENBIS_APP_LOGS_PATH":/var/log/openbis \
            -e OPENBIS_ADMIN_PASS \
            -e OPENBIS_DATA="/data/openbis" \
            -e OPENBIS_DB_ADMIN_PASS \
            -e OPENBIS_DB_ADMIN_USER="postgres" \
            -e OPENBIS_DB_APP_PASS \
            -e OPENBIS_DB_APP_USER="openbis" \
            -e OPENBIS_DB_HOST="$CONT_DB_NAME" \
            -e OPENBIS_ETC="/etc/openbis" \
            -e OPENBIS_HOME="/home/openbis" \
            -e OPENBIS_LOG="/var/log/openbis" \
            -e OPENBIS_FQDN="$OPENBIS_FQDN" \
            openbis/openbis-app:$OPENBIS_TAG
    fi

elif [ "$1" = down ]; then # clean up in reversed order
    stopContainer "$CONT_IDX_NAME"
    stopContainer "$CONT_APP_NAME"
    stopContainer "$CONT_DB_NAME"
else
    echo "No action given, please provide 'up' or 'down'."
    exit 1
fi

# ### Troubleshooting
#
# 1. Server does not come up and `$OPENBIS_APP_LOGS_PATH/openbis_log.txt` complains about:
#
#         Password file '/home/openbis/servers/openBIS-server/jetty/etc/passwd' is not writable.
#
#     It got the ownership of the user@host running *podman* instead of the user *openbis* inside the container.
#     Quick fix, change ownership to the same as the other files, the mapped ownership id:
#
#         sudo chown 101000:101000 $OPENBIS_APP_CONFIG_PATH/as/passwd
