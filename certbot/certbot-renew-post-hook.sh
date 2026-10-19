#!/bin/sh
# set group ownership for certificates needed by other services, such as traefik
chown -R :letsencrypt \
    /etc/letsencrypt/live \
    /etc/letsencrypt/archive
chmod g+rx
    /etc/letsencrypt/live \
    /etc/letsencrypt/archive
chmod g+r \
    /etc/letsencrypt/archive/*/privkey*.pem
