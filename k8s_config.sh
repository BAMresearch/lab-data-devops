#!/bin/sh

# learn about some utility functions before heading on ...
scriptpath="$(readlink -f "$0")"
scriptdir="$(dirname "$scriptpath")"
#. "$scriptdir/services/deploytools"
. /home/buildbot/scicat/deploy/services/deploytools

# get provided command line flags
#nopwd="$(getScriptFlags nopwd "$@")"

loadSiteConfig

checkVars SC_OPENBIS_PUB SC_OPENBIS_KEY || exit 1
SVC_NAME=openbis
SECRET_NAME="${SVC_NAME}.tls"
NS=openbis

if [ "$1" = up ];
then
    namespaceExists "$NS" || kubectl create ns "$NS"
    createTLSsecret "$NS" "$SECRET_NAME" "$SC_REGISTRY_PUB" "$SC_REGISTRY_KEY"
    tmpfn="$(mktemp)"
    cp openbis_ingress.yaml "$tmpfn"
    for name in SC_OPENBIS_FQDN SECRET_NAME DOMAINBASE; do
        set | grep -q "^$name=" || continue
        value="$(eval echo \$$name)"
        #echo "name: $name, value: $value"
        sed -i "s/\\b$name\\b/$value/" "$tmpfn"
    done
    echo "updated config: $tmpfn"
    kubectl apply -n "$NS" -f "$tmpfn" && rm -f "$tmpfn"
elif [ "$1" = down ]; # clean up
then
    kubectl delete secret -n "$NS" "$SECRET_NAME"
    kubectl delete service -n "$NS" openbis-landing openbis-app openbis-dss
    kubectl delete ingress -n "$NS" openbis-local-backend
    kubectl delete ns "$NS"
    echo "done."
else
    echo "No action given, please provide 'up' or 'down'."
    exit 1
fi
