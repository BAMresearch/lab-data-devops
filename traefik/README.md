# Traefik reverse proxy setup

## Create a local user for isolation

    sudo useradd -m --shell /usr/sbin/nologin traefik
    sudo usermod -G letsencrypt traefik
    sudo passwd -d -l traefik
    sudo loginctl enable-linger traefik

Use that account to setup traefik.

## Enable the podman socket

    sudo machinectl shell traefik@ /bin/bash
    systemctl --user enable --now podman.socket

## Put config files in place

    # as traefik user
    mkdir -p .config/containers/systemd
    ln -s $(realpath containers.conf) ~/.config/containers/
    ln -s $(realpath traefik.container) ~/.config/containers/systemd/

    # as root
    sudo chown -R root:root $(realpath etc)
    sudo ln -sf $(realpath etc) /etc/traefik
    systemctl enable ./traefik-port-forward.service
    systemctl start ./traefik-port-forward.service

And **copy** other service files to /etc/traefik/conf.d/,
a symlink will not work because it can't be resolve in the container
unless its target exists under the exact same path.

## Reload systemctl and restart

    sudo machinectl shell traefik@ /bin/bash
    systemctl --user daemon-reload
    systemctl --user restart traefik.service

## Open port 443 in ufw

    sudo ufw allow 443/tcp
    sudo ufw allow 80/tcp   # for the http->https redirect

### and port 61080 for the dashboard

    sudo ufw allow 61080/tcp

## forward privileged ports to unpriv. ports for traefik to run as user

    # ufw doesn't do port forwarding natively, but you can add nft rules
    # in /etc/ufw/before.rules, add at the top before *filter:
    *nat
    :PREROUTING ACCEPT [0:0]
    -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080
    -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
    COMMIT

## Test

    curl https://test.sub.example.com

or check redirect works

    curl -I http://test.sub.example.com

    curl -k https://test.sub.example.com

If that doesn't work, check Traefik can resolve the container name:

    podman exec traefik wget -q -O- http://webtest:80

