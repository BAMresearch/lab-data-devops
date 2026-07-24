# Setting up a Binder-like service on a local Ubuntu server

The following commands should be run manually to handle any failures.
It assumes, rootless podman is already set up.

    sudo useradd jupyterhub
    sudo passwd -d jupyterhub
    sudo adduser jupyterhub users  # important for accessing network shares
    sudo loginctl enable-linger jupyterhub
    sudo machinectl shell jupyterhub@ /bin/bash
    systemctl --user start podman.socket

    python3 -m venv ~/.venvs/r2d
    ~/.venvs/r2d/bin/pip install jupyter-repo2docker
    # a test to verify building works:
    ~/.venvs/r2d/bin/jupyter-repo2docker --no-run \
        --image-name localhost/binder-sales:latest \
        https://github.com/binder-examples/requirements

## Fix `oom_score`

> Unprivileged processes can only raise `oom_score_adj`, never lower it. The Docker API populates `OomScoreAdj: 0` by default, but Podman's service process is running at some positive value inherited from `systemd --user` — so crun tries to write 0, which is a lowering, and the kernel says no.

    sudo mkdir -p /etc/systemd/system/user@.service.d
    printf '[Service]\nOOMScoreAdjust=0\n' | sudo tee /etc/systemd/system/user@.service.d/oom.conf
    sudo systemctl daemon-reload
    sudo systemctl restart "user@$(id -u jupyterhub).service"

