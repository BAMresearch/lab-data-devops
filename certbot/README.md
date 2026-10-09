# Certbot setup

## Install

    sudo pacman -S certbot

And disable the default service, if any, it gets replaced:

    sudo systemctl disable certbot-renew.timer
    sudo systemctl disable certbot-renew.service

## Create a local user for isolation

    sudo useradd -m --shell /usr/sbin/nologin cert-upd-bot
    sudo passwd -d -l cert-upd-bot
    sudo loginctl enable-linger cert-upd-bot

or later:

    sudo usermod --shell /usr/sbin/nologin cert-upd-bot
    sudo passwd -l cert-upd-bot

Set the domain for this configuration:

    export FQDN=<your domain>

## A group for managing access to certificates

    groupadd letsencrypt -U cert-upd-bot,traefik,...

## Hooks to run on update

    ln -s $(realpath certbot-renew-deploy-hook.sh) /etc/letsencrypt/renewal-hooks/deploy/certbot-renew-deploy-hook.sh
    ln -s $(realpath certbot-renew-post-hook.sh) /etc/letsencrypt/renewal-hooks/post/certbot-renew-post-hook.sh

## Install the service

    REPO=$(realpath .)
    UNITDIR=/etc/systemd/system

    # 1. Link template units (keep the exact file names, otherwise systemd treats them as aliases)
    sudo ln -s "$REPO/certbot-renew@.service" "$UNITDIR/"
    sudo ln -s "$REPO/certbot-renew@.timer"   "$UNITDIR/"

    # 2. Drop-in: real directory, symlinked .conf inside
    sudo mkdir -p "$UNITDIR/certbot-renew@schlundtech.service.d"
    sudo ln -s "$REPO/certbot-renew@schlundtech.service.d/provider.conf" \
            "$UNITDIR/certbot-renew@schlundtech.service.d/"

    # 3. Reload and enable the instance by name
    sudo systemctl daemon-reload
    sudo systemctl enable --now certbot-renew@schlundtech.timer

Verify:

    systemctl cat certbot-renew@schlundtech.service   # shows template + drop-in
    systemctl list-timers 'certbot-renew@*'
    sudo systemctl start certbot-renew@schlundtech.service   # test run without waiting for the timer
    journalctl -u certbot-renew@schlundtech.service

## For Schlundtech

Installing it as a Python module in a custom venv.
Needs to be run from there for loading it.

    cd /usr/src/
    git clone https://github.com/wilfriedwolf/certbot-dns-schlundtech.git
    uv venv --system-site-packages ~/venv_certbot
    . ~/venv_certbot/bin/activate
    uv pip install --no-cache-dir --editable /usr/src/certbot-dns-schlundtech

### Credentials file

    cat > ~/dns.ini << EOF
    dns_schlundtech_user = 54321
    dns_schlundtech_password = PASSWORD
    dns_schlundtech_context = 10
    dns_schlundtech_token = SECRET-2FA-TOKEN
    EOF

Encrypt the file, root user can use TPM2 for that:

    creds_path=/var/lib/certbot-renew/dns-schlundtech.ini
    creds_fn="$(basename "$creds_path")"
    sudo install -d -o cert-upd-bot -g cert-upd-bot -m 0750 "$(dirname "$creds_path")"
    systemd-creds encrypt --with-key=tpm2 ~/dns.ini "$creds_path"
    shred -u dns.ini

## ipv64.de

Using *certbot-dns-multi*: it is a DNS plugin for Certbot which integrates with the 117+ DNS providers from the lego ACME client, and lego supports IPv64. The plugin needs to be installed in a venv, similar to schlundtech setup. It requires *Go* compiler.

    sudo pacman -S --needed go          # pip builds the plugin from Go sources
    uv venv --system-site-packages ~/venv_certbot
    ~/venv_certbot/bin/pip install certbot-dns-multi

### Credentials file

    cat > ~/dns.ini << EOF
    # dns.ini (plaintext only temporarily, before encrypting)
    dns_multi_provider = ipv64
    IPV64_API_KEY = xxxxxxxx
    # optional, default is 60 seconds
    IPV64_PROPAGATION_TIMEOUT = 180
    EOF

Encrypt the file, root user can use TPM2 for that:

    creds_path=/var/lib/certbot-renew/dns-ipv64.ini
    creds_fn="$(basename "$creds_path")"
    sudo install -d -o cert-upd-bot -g cert-upd-bot -m 0750 "$(dirname "$creds_path")"
    systemd-creds encrypt --with-key=tpm2 ~/dns.ini "$creds_path"
    shred -u dns.ini

## first time run

    certbot certonly -v --server https://acme-v02.api.letsencrypt.org/directory -a dns-schlundtech --dns-schlundtech-credentials ./dns-schlundtech-creds.ini -d *.$FQDN

    systemctl start certbot-renew.timer
