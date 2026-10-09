#!/bin/sh
# restart traefik if it exists
sudo machinectl -q shell traefik-pod@.host /bin/sh -c \
    '/usr/bin/systemctl --user is-active --quiet traefik && /usr/bin/systemctl --user restart traefik'
