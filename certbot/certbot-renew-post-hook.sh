#!/bin/sh
# set group ownership for certificates needed by other services, such as traefik
chown -R :letsencrypt /etc/letsencrypt/{live,archive}
