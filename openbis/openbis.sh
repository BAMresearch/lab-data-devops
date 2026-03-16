#!/bin/sh

scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
scriptname="$(basename "$scriptpath")"

. "$scriptdir/../utils/deploy"
. "$scriptdir/../utils/postgres"
. "$scriptdir/../utils/ingress"

# make sure the passwords are defined
loadSiteConfig OPENBIS_INSTANCE OPENBIS_DATA OPENBIS_FQDN OPENBIS_PUB OPENBIS_KEY \
    OPENBIS_ADMIN_PASS OPENBIS_DB_ADMIN_PASS OPENBIS_DB_APP_PASS || exit 1

SVC_NAME="${scriptname%.*}"  # script name without extension
SECRET_NAME="${SVC_NAME}.tls"

BASEPATH="$OPENBIS_DATA"  # of persistent data storage
# Create a podman network
NETWORK_NAME=openbis-network
podmanNetwork "$NETWORK_NAME"

startOpenBISLanding() {
    local cname="$1"
    local staticpath="$2"
    isContainerRunning "$cname" && return
    # render landing page to the static files dir
    local tmpfn="$staticpath/index.html"
    cp "$staticpath/../landingpage.html" "$tmpfn"
    formatTextFile "$tmpfn" OPENBIS_FQDN OPENBIS_INSTANCE
    podman run -d --name "$cname" -p 8085:80 -v "$staticpath":/usr/share/nginx/html:ro nginx
}

CONT_DB_NAME=openbis-db
CONT_APP_NAME=openbis-app
CONT_IDX_NAME=openbis-landing
if [ "$1" = up ]; then

    startPostgres "$CONT_DB_NAME" 15 "$OPENBIS_DATA" "$NETWORK_NAME" "$OPENBIS_DB_ADMIN_PASS"

    startOpenBISLanding "$CONT_IDX_NAME" "$scriptdir/static"

    if ! isContainerRunning "$CONT_APP_NAME"; then
        set -x
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
        # get custom certificate in the container, needed for harvester connection only probably
        certpath="$(find "$scriptdir" -name '*.pem' -type f | head -n1)"
        if [ ! -f "$certpath" ]; then
            echo "Missing certificate .pem file!"
            exit 1
        fi
        cp "$certpath" "$OPENBIS_APP_CONFIG_PATH/"
        fn="$(basename "$certpath")"
        chmod 644 "$OPENBIS_APP_CONFIG_PATH/$fn"
        podman exec -it "$CONT_APP_NAME" bash -c "
            cd /root/;
            awk '/BEGIN CERT/{i++}{print > \"cert\"i\".pem\"}' '/etc/openbis/$fn';
            ls -la;
            for keystore in /etc/openbis/{as,dss}/openBIS.keystore; do
                for cert in cert*.pem; do
                    keytool -keystore \"\$keystore\" -storepass changeit -importcert -trustcacerts -alias \"customcert-\$cert\" -file \$cert -noprompt;
                done;
            done
        "
        # set up port forwarding localhost:5432 to openbis-db:5432
        podman exec $CONT_APP_NAME sh -c 'apt-get update && apt-get install -y socat'
        podman exec $CONT_APP_NAME sh -c 'socat TCP-LISTEN:5432,fork,reuseaddr TCP:openbis-db:5432 &'
        podman exec $CONT_APP_NAME sh -c "cat > /usr/local/bin/port_forward.sh << EOF
#!/bin/sh
# Start port forwarding
socat TCP-LISTEN:5432,fork,reuseaddr TCP:$CONT_DB_NAME:5432 &
# Original entrypoint execution
exec \"\$@\"
EOF"
        podman exec $CONT_APP_NAME chmod 755 /usr/local/bin/port_forward.sh
        # old entrypoint
        entrypoint="$(podman inspect "$CONT_APP_NAME" | jq -r .[0].Config.Entrypoint)"
        # FIXME: copy service for creating internal property to separate plugin
        # use notebook code to create property
        # copy over the harvester plugin after missing property was created FIXME
        uid=$(stat -c%u "$OPENBIS_APP_CONFIG_PATH/core-plugins/")
        gid=$(stat -c%g "$OPENBIS_APP_CONFIG_PATH/core-plugins/")
        cp -R "$scriptdir/harvester" "$OPENBIS_APP_CONFIG_PATH/core-plugins/"
        chown -R $uid:$gid "$OPENBIS_APP_CONFIG_PATH/core-plugins/harvester"
        chmod o-rwx "$OPENBIS_APP_CONFIG_PATH/core-plugins/harvester"
        # run customized image
        # podman run --detach --name "$CONT_APP_NAME" --hostname "$CONT_APP_NAME" --network "$NETWORK_NAME"             --pid host -p 8080:8080 -p 8081:8081             -v "$OPENBIS_APP_DATA_PATH":/data             -v "$OPENBIS_APP_CONFIG_PATH":/etc/openbis             -v "$OPENBIS_APP_LOGS_PATH":/var/log/openbis             -e OPENBIS_ADMIN_PASS             -e OPENBIS_DATA="/data/openbis"             -e OPENBIS_DB_ADMIN_PASS             -e OPENBIS_DB_ADMIN_USER="postgres"             -e OPENBIS_DB_APP_PASS             -e OPENBIS_DB_APP_USER="openbis"             -e OPENBIS_DB_HOST="$CONT_DB_NAME"             -e OPENBIS_ETC="/etc/openbis"             -e OPENBIS_HOME="/home/openbis"             -e OPENBIS_LOG="/var/log/openbis"             -e OPENBIS_FQDN="$OPENBIS_FQDN"  --entrypoint /usr/local/bin/port_forward.sh          openbis-app-fwd $(podman inspect docker.io/openbis/openbis-app:20.10.11 | jq -r .[0].Config.Entrypoint[0])
    fi
    setupIngress "$SVC_NAME" "${scriptpath%.*}.yaml" "$OPENBIS_PUB" "$OPENBIS_KEY" "$OPENBIS_FQDN"

elif [ "$1" = down ]; then # clean up in reversed order
    teardownIngress "$SVC_NAME" "openbis-landing openbis-app openbis-dss"
    stopContainer "$CONT_IDX_NAME"
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
