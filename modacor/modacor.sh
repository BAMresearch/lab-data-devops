#!/bin/sh
# create shell for nologin user modacor:
#   machinectl shell modacor@ /bin/bash

scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
scriptname="$(basename "$scriptpath")"

. "$scriptdir/../utils/deploy"
. "$scriptdir/../utils/postgres"
. "$scriptdir/../utils/ingress"

loadSiteConfig MODACOR_FQDN MODACOR_PUB MODACOR_KEY || exit 1

SVC_NAME="${scriptname%.*}"  # script name without extension
# Create a podman network
NETWORK_NAME="${SVC_NAME}-network"
podmanNetwork "$NETWORK_NAME"
CONT_SRV_NAME="${SVC_NAME}-srv"

genMoDaCorSvc()
{
    local cname="$1"
    local tag="$2"
    local network="$3"
    shift 3
    systemctl --user is-active --quiet "$cname" && return

    local contpath="$HOME/.config/containers/systemd"
    mkdir -p "$contpath"

cat > "$contpath/$cname.container" << EOF
[Unit]
Description=$(python3 -c "print('$SVC_NAME'.title())") Server
After=network-online.target

[Container]
ContainerName=$cname
Image=${SVC_NAME}:$tag
$(echo "$@" | sed -E 's/([[:space:]])([A-Z_][A-Z0-9_]*=)/\n\2/g' | sed '/^$/d; s/.*/Environment=&/')
PublishPort=8700:8700
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

    genMoDaCorSvc "$CONT_SRV_NAME" latest "$NETWORK_NAME"
    systemctl --user restart "$CONT_SRV_NAME"

    setupIngress "$SVC_NAME" "${scriptpath%.*}.yaml" "$MODACOR_PUB" "$MODACOR_KEY" "$MODACOR_FQDN"

elif [ "$1" = down ];then # clean up in reversed order

    teardownIngress "$SVC_NAME" "$CONT_SRV_NAME"
    systemctl --user stop "$CONT_SRV_NAME"

elif [ "$1" = reset ]; then
    "$0" down
    sleep 1
    "$0" up
else
    echo "No action given, please provide 'up' or 'down'."
    exit 1
fi
