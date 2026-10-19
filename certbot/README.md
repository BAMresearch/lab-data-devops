# Certbot setup

## Install

    sudo pacman -S certbot

And disable the default service, if any, it gets replaced:

    sudo systemctl disable certbot-renew.timer
    sudo systemctl disable certbot-renew.service

## Create a local user for isolation

    sudo useradd -m -d /var/lib/cert-upd-bot --shell /usr/sbin/nologin cert-upd-bot
    sudo passwd -d -l cert-upd-bot

or later:

    sudo usermod --shell /usr/sbin/nologin cert-upd-bot
    sudo passwd -l cert-upd-bot

## A group for managing access to certificates

    groupadd letsencrypt -U cert-upd-bot,traefik,...

## Hooks to run on update

The post-hook sets ownership to letsencrypt group for giving access to traefik.
The deploy-hook restarts traefik for ingesting the new certs.

    sudo mkdir -p /etc/letsencrypt/renewal-hooks/{deploy,post}
    ln -s $(realpath certbot-renew-deploy-hook.sh) /etc/letsencrypt/renewal-hooks/deploy/certbot-renew-deploy-hook.sh
    ln -s $(realpath certbot-renew-post-hook.sh) /etc/letsencrypt/renewal-hooks/post/certbot-renew-post-hook.sh
    sudo chown -R cert-upd-bot:cert-upd-bot /etc/letsencrypt/

## Python venv for plugins below

    machinectl shell cert-upd-bot@ /bin/bash
    python3 -m venv --system-site-packages ~/venv_certbot
    ~/venv_certbot/bin/pip install certbot

## Install the service

    REPO=$(realpath .)
    UNITDIR=/etc/systemd/system

    # Link template units (keep the exact file names, otherwise systemd treats them as aliases)
    sudo ln -s "$REPO/certbot-renew@.service" "$UNITDIR/"
    sudo ln -s "$REPO/certbot-renew@.timer"   "$UNITDIR/"

## For Schlundtech

Installing it as a Python module in a custom venv.
Needs to be run from there for loading it.

    git clone https://github.com/wilfriedwolf/certbot-dns-schlundtech.git
    ~/venv_certbot/bin/pip install --no-cache-dir --editable certbot-dns-schlundtech

For renewal config below:

    AUTHENTICATOR=dns-schlundtech

### Credentials file

    cat > ~/dns.ini << EOF
    dns_schlundtech_user = 54321
    dns_schlundtech_password = PASSWORD
    dns_schlundtech_context = 10
    dns_schlundtech_token = SECRET-2FA-TOKEN
    EOF

### systemd drop-in

    sudo mkdir -p "$UNITDIR/certbot-renew@schlundtech.service.d"
    sudo ln -s "$REPO/certbot-renew@schlundtech.service.d/provider.conf" \
            "$UNITDIR/certbot-renew@schlundtech.service.d/"

## ipv64.net

Using *certbot-dns-multi*: it is a DNS plugin for Certbot which integrates with the 117+ DNS providers from the lego ACME client, and lego supports IPv64. The plugin needs to be installed in a venv, similar to schlundtech setup. It may require the *Go* compiler.

    ~/venv_certbot/bin/pip install certbot-dns-multi

For renewal config below:

    AUTHENTICATOR=dns-multi

### Credentials file

    cat > ~/dns.ini << EOF
    # dns.ini (plaintext only temporarily, before encrypting)
    dns_multi_provider = ipv64
    IPV64_API_KEY = xxxxxxxx
    # optional, default is 60 seconds
    IPV64_PROPAGATION_TIMEOUT = 180
    EOF

### systemd drop-in

    sudo mkdir -p "$UNITDIR/certbot-renew@ipv64.service.d"
    sudo ln -s "$REPO/certbot-renew@ipv64.service.d/provider.conf" \
            "$UNITDIR/certbot-renew@ipv64.service.d/"

## First time cert issue

    . /opt/lab-data-devops/host.env  # for $FQDN
    # create the expected directories
    sudo install -d -o cert-upd-bot -g cert-upd-bot -m 0750 /var/{log,lib}/letsencrypt

Get the cert, folders in /etc/letsencrypt are populated, for *schlundtech*:

    ~/venv_certbot/bin/python /usr/bin/certbot certonly -v --server https://acme-v02.api.letsencrypt.org/directory -a dns-schlundtech --dns-schlundtech-credentials ~/dns.ini -d *.$FQDN

For *ipv64.net*:

    ~/venv_certbot/bin/python /usr/bin/certbot certonly -v --server https://acme-v02.api.letsencrypt.org/directory -a dns-multi --dns-multi-credentials ~/dns.ini -d *.$FQDN

## Encrypt credentials file, put in place

    PROVIDER=<ipv64 or schlundtech>

Encrypt the file, root user can use TPM2 for that:

    # put in StateDirectory of the service
    creds_path=/var/lib/certbot-renew/dns-${PROVIDER}.ini
    creds_fn="$(basename "$creds_path")"
    sudo install -d -o cert-upd-bot -g cert-upd-bot -m 0750 "$(dirname "$creds_path")"
    systemd-creds encrypt --with-key=tpm2 ~/dns.ini "$creds_path"
    # let it be owned by cert-upd-bot
    chown cert-upd-bot:cert-upd-bot "$creds_path" && chmod 640 "$creds_path"

Remove the unencrypted credentials file:

    shred -u ~/dns.ini

## Final reload and check

    # Reload and enable the instance by name
    sudo systemctl daemon-reload
    sudo systemctl enable --now certbot-renew@${PROVIDER}.timer

Verify:

    systemctl cat certbot-renew@${PROVIDER}.service   # shows template + drop-in
    systemctl list-timers 'certbot-renew@*'
    sudo systemctl start certbot-renew@${PROVIDER}.service   # test run without waiting for the timer
    journalctl -u certbot-renew@${PROVIDER}.service
