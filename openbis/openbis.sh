#!/bin/sh
# Verification
# https://openbis.readthedocs.io/en/20.10.12-plus/system-documentation/docker/verification.html

scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
scriptname="$(basename "$scriptpath")"

. "$scriptdir/../utils/deploy"
. "$scriptdir/../utils/postgres"
. "$scriptdir/../utils/webserver"
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

genOpenBISSvc()
{
    local cname="$1"
    local tag="$2"
    local basepath="$3"
    local network="$4"
    local dbcname="$5"
    #local dbAdminPass="$6"
    #local apikey="$7"
    shift 5
    systemctl --user is-active --quiet "$cname" && return

    genPodmanSecret ${dbcname}-app-pass
    genPodmanSecret ${cname}-admin-pass
    local cfg_host_path="$basepath/app-etc"
    mkdir -p "$basepath/app-data" "$cfg_host_path" "$basepath/app-logs"

    # prepare the custom plugin, put a copy to the work data
    [ -d "$basepath/create-system-props" ] || cp -R "$scriptdir/create-system-props" "$basepath/"
    #sed -i "'s/\\(enabled-modules\\s=\\s\\)/\\1create-system-props, /" core-plugins.properties
    [ -f "$basepath/core-plugins.properties" ] || cp -R "$scriptdir/core-plugins.properties" "$basepath/"

    # prepare the container definition
    local contpath="$HOME/.config/containers/systemd"
    mkdir -p "$contpath"

cat > "$contpath/$cname.container" << EOF
[Unit]
Description=OpenBIS Server
After=network-online.target

[Container]
ContainerName=$cname
Image=docker.io/openbis/openbis-app:$tag
Volume=$basepath/app-data:/data:rw,Z
Volume=$cfg_host_path:/etc/openbis:rw,Z
Volume=$basepath/app-logs:/var/log/openbis:rw,Z
Volume=$basepath/create-system-props:/home/openbis/servers/core-plugins/create-system-props:rw,Z
Volume=$basepath/core-plugins.properties:/home/openbis/servers/core-plugins/core-plugins.properties:rw,Z
Environment=OPENBIS_DB_HOST=$dbcname
Environment=OPENBIS_DATA=/data/openbis
Environment=OPENBIS_ETC=/etc/openbis
Environment=OPENBIS_HOME=/home/openbis
Environment=OPENBIS_LOG=/var/log/openbis
$(echo "$@" | sed -E 's/([[:space:]])([A-Z_][A-Z0-9_]*=)/\n\2/g' | sed '/^$/d; s/.*/Environment=&/')
Secret=${dbcname}-admin-pass,type=env,target=OPENBIS_DB_ADMIN_PASS
Secret=${dbcname}-app-pass,type=env,target=OPENBIS_DB_APP_PASS
Secret=${cname}-admin-pass,type=env,target=OPENBIS_ADMIN_PASS
PublishPort=8080:8080
PublishPort=8081:8081
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

CONT_DB_NAME=openbis-db
CONT_APP_NAME=openbis-app
CONT_IDX_NAME=openbis-landing
if [ "$1" = up ]; then

    genPostgresSvc "$CONT_DB_NAME" 15 "$OPENBIS_DATA/db-data" "$NETWORK_NAME" \
        POSTGRES_USER=postgres \
        POSTGRES_HOST_AUTH_METHOD="" \
        PGDATA=/var/lib/postgresql/data/pgdata
    systemctl --user restart "$CONT_DB_NAME"
    # wait a moment to get ready
    while ! systemctl --user is-active --quiet "$CONT_DB_NAME"; do sleep 1; done

    # render landing page to the static files dir and put it on port 8085
    tmpfn="$scriptdir/static/index.html"
    cp "$scriptdir/landingpage.html" "$tmpfn"
    formatTextFile "$tmpfn" OPENBIS_FQDN OPENBIS_INSTANCE
    genWebServerSvc "$CONT_IDX_NAME" "$scriptdir/static" 8085
    systemctl --user restart "$CONT_IDX_NAME"
    # wait a moment to get ready
    while ! systemctl --user is-active --quiet "$CONT_IDX_NAME"; do sleep 1; done

    if ! systemctl --user is-active --quiet "$CONT_APP_NAME"; then
        genOpenBISSvc "$CONT_APP_NAME" 20.10.11 "$OPENBIS_DATA" "$NETWORK_NAME" "$CONT_DB_NAME" \
            OPENBIS_DB_ADMIN_USER="postgres" \
            OPENBIS_DB_APP_USER="openbis" \
            OPENBIS_FQDN="$OPENBIS_FQDN"
        systemctl --user restart "$CONT_APP_NAME"
        podman exec -it "$CONT_APP_NAME" chown -R openbis:openbis /home/openbis/servers/core-plugins
        podman exec -it "$CONT_APP_NAME" chmod -R g+w /home/openbis/servers/core-plugins
        # wait a moment to get ready
        while ! systemctl --user is-active --quiet "$CONT_APP_NAME"; do sleep 1; done
        # creating internal property $ANNOTATIONS_STATE by installed custom plugin
        export $(podman exec -it "$CONT_APP_NAME" env | grep OPENBIS_ADMIN_PASS)
        python3 -m venv "$OPENBIS_DATA/venv"
        "$OPENBIS_DATA/venv/bin/pip" install -q pybis
        while ! "$OPENBIS_DATA/venv/bin/python" "$scriptdir/create_annotations_state.py"; do
            sleep 3  # retry until the server becomes ready
        done
    fi
    exit
    if ! isContainerRunning "$CONT_APP_NAME"; then
        set -x
        # Run application container
        export OPENBIS_TAG="20.10.11"
        export OPENBIS_APP_DATA_PATH="$BASEPATH/app-data"
        export OPENBIS_APP_CONFIG_PATH="$BASEPATH/app-etc"
        export OPENBIS_APP_LOGS_PATH="$BASEPATH/app-logs"
        mkdir -p "$OPENBIS_APP_DATA_PATH" "$OPENBIS_APP_CONFIG_PATH" "$OPENBIS_APP_LOGS_PATH"
        export OPENBIS_DB_ADMIN_PASS="$(getPodmanSecret ${CONT_DB_NAME}-pass)"
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
        exit # FIXME
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
    systemctl --user stop "$CONT_IDX_NAME"
    systemctl --user stop "$CONT_APP_NAME"
    systemctl --user stop "$CONT_DB_NAME"
elif [ "$1" = reset ]; then
    "$0" down
    sleep 1
    if [ -d "$BASEPATH" ]; then
       echo "Deleting files in '$BASEPATH' ..."
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
