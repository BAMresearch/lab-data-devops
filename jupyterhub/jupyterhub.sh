#!/bin/sh
# create shell for nologin user jupyterhub:
#   machinectl shell jupyterhub@ /bin/bash
# run this in the users home-dir, like this:
#   sh /opt/lab-data-devops/jupyterhub/jupyterhub.sh up

scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
scriptname="$(basename "$scriptpath")"

. "$scriptdir/../utils/deploy"
. "$scriptdir/../utils/ingress"

loadSiteConfig JHUB_FQDN JHUB_PUB JHUB_KEY JHUB_ADMIN GITLAB_FQDN GITLAB_GROUP || exit 1

SVC_NAME="${scriptname%.*}"  # script name without extension
CONT_SRV_NAME="${SVC_NAME}"

addContConfig()
{
    local text="$1"
    local contcfg="$2"
    touch "$contcfg"
    grep -Fq "$text" "$contcfg" || echo "$text" >> "$contcfg"
}

genJHubSvc()
{
    local cname="$1"
    local tag="$2"
    CONT_NETWORK="$3"
    shift 3
    systemctl --user is-active --quiet "$cname" && return
    systemctl --user is-active --quiet podman.socket || \
        systemctl --user restart podman.socket

    mkdir -p ~/jupyterhub/config ~/jupyterhub/data
    local hubcfg="$HOME/jupyterhub/config/jupyterhub_config.py"
    cp "$scriptdir/jupyterhub_config.py" "$hubcfg"
    formatTextFile "$hubcfg" CONT_NETWORK JHUB_FQDN JHUB_ADMIN GITLAB_FQDN GITLAB_GROUP

    # apply settings which can't be ingested by other means
    local contcfg="$HOME/.config/containers/containers.conf"
    addContConfig '[containers]' "$contcfg"
    addContConfig 'annotations = ["run.oci.keep_original_groups=1"]' "$contcfg"
    addContConfig "userns = \"keep-id:uid=$(id -u),gid=100\"" "$contcfg"

    if [ ! -f ~/jupyterhub/gitlab.env ]; then
        echo "GITLAB_CLIENT_ID="  > ~/jupyterhub/gitlab.env
        echo "GITLAB_CLIENT_SECRET=" >> ~/jupyterhub/gitlab.env
        chmod 600 ~/jupyterhub/gitlab.env
    fi

    local contpath="$HOME/.config/containers/systemd"
    mkdir -p "$contpath"

cat > "$contpath/$cname.container" << EOF
[Unit]
Description=$(python3 -c "print('$SVC_NAME'.title())") Server
After=network-online.target

[Container]
ContainerName=$cname
Image=${SVC_NAME}-custom:$tag
Volume=%h/jupyterhub/config:/srv/jupyterhub:Z
Volume=%h/jupyterhub/data:/data:Z
Volume=%t/podman/podman.sock:/run/podman/podman.sock:Z
Environment=DOCKER_HOST=unix:///run/podman/podman.sock
EnvironmentFile=%h/jupyterhub/gitlab.env
Exec=jupyterhub -f /srv/jupyterhub/jupyterhub_config.py
# environment vars
$(echo "$@" | sed -E 's/([[:space:]])([A-Z_][A-Z0-9_]*=)/\n\2/g' | sed '/^$/d; s/.*/Environment=&/')
# data mount point
#Volume=/mnt/vsi-db:/mnt/vsi-db:rw,Z
# user running the container has access by group membership
PodmanArgs=--group-add keep-groups

PublishPort=8900:8000
Network=$CONT_NETWORK

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

    # Create a podman network
    NETWORK_NAME="${SVC_NAME}-network"
    podmanNetwork "$NETWORK_NAME"

    if [ "$2" != ingress ]; then
        genJHubSvc "$CONT_SRV_NAME" latest "$NETWORK_NAME"
        systemctl --user restart "$CONT_SRV_NAME"
    fi

    setupIngress "$SVC_NAME" "${scriptpath%.*}.yaml" "$JHUB_PUB" "$JHUB_KEY" "$JHUB_FQDN"

elif [ "$1" = down ];then # clean up in reversed order

    teardownIngress "$SVC_NAME" "$CONT_SRV_NAME"
    if [ "$2" != ingress ]; then
        systemctl --user stop "$CONT_SRV_NAME"
    fi

elif [ "$1" = reset ]; then
    "$0" down
    sleep 1
    "$0" up
else
    echo "No action given, please provide 'up' or 'down'."
    exit 1
fi
