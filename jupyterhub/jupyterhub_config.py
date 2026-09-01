import sys, os, tomllib
from pathlib import Path

c.JupyterHub.bind_url = "http://:8000"
c.JupyterHub.hub_ip = "0.0.0.0"
c.JupyterHub.hub_connect_ip = "jupyterhub"
c.JupyterHub.db_url = "sqlite:////data/jupyterhub.sqlite"
# False for production, allows to restart jhub while notebook containers stay alive
c.JupyterHub.cleanup_servers = False
c.JupyterHub.shutdown_on_logout = True

c.JupyterHub.spawner_class = "dockerspawner.DockerSpawner"
c.DockerSpawner.network_name = "CONT_NETWORK"
c.DockerSpawner.use_internal_ip = True
c.DockerSpawner.remove = True
c.DockerSpawner.pull_policy = "never"
c.DockerSpawner.mem_limit = "4G"
c.DockerSpawner.cpu_limit = 2.0
c.DockerSpawner.cmd = ["jupyterhub-singleuser"]

REPOS = {}
with open(Path("REPOS_PATH").expanduser(), "rb") as fd:
    REPOS = tomllib.load(fd).get("repo", [])
    REPOS = {repo["label"]: repo for repo in REPOS}
print(f"{REPOS=}", file=sys.stderr)


# it depends on DockerSpawner applying user_options["image"] in start()
def set_default_url(spawner):
    spawner.log.info("user_options=%r", spawner.user_options)
    selected = spawner.user_options.get("image", "")
    spawner.log.info(f"{selected=}")
    spawner.default_url = REPOS.get(selected, {}).get("index_ipynb", "/lab")
    spawner.log.info(f"{spawner.default_url=}")


c.Spawner.pre_spawn_hook = set_default_url

c.DockerSpawner.allowed_images = {
    repo["label"]: f"{repo['image']}" for repo in REPOS.values()
}

c.DockerSpawner.read_only_volumes = {
    # "/host-mountpoint/network/share": "/container/path",
    JHUB_VOL_RO
}
c.DockerSpawner.volumes = {
    # "/host-storage/jupyterhub/{username}": "/home/jupyterhub/outputs",
    JHUB_VOL
}
c.JupyterHub.services = [
    {
        "name": "idle-culler",
        #    "command": [sys.executable, "-m", "jupyterhub_idle_culler",
        #                "--timeout=3600", "--cull-every=300", "--max-age=43200"],
    }
]
c.JupyterHub.load_roles = [
    {
        "name": "idle-culler",
        "scopes": [
            "list:users",
            "read:users:activity",
            "read:servers",
            "delete:servers",
        ],
        "services": ["idle-culler"],
    }
]
c.Spawner.default_url = "/lab"
c.Spawner.args = [
    "--ServerApp.MappingKernelManager.cull_idle_timeout=1800",
    "--ServerApp.MappingKernelManager.cull_interval=120",
]

c.JupyterHub.authenticator_class = "gitlab"

c.GitLabOAuthenticator.gitlab_url = "https://GITLAB_FQDN"
c.GitLabOAuthenticator.oauth_callback_url = "https://JHUB_FQDN/hub/oauth_callback"
c.GitLabOAuthenticator.client_id = os.environ["GITLAB_CLIENT_ID"]
c.GitLabOAuthenticator.client_secret = os.environ["GITLAB_CLIENT_SECRET"]

c.GitLabOAuthenticator.scope = ["read_user"]
# c.GitLabOAuthenticator.allowed_gitlab_groups = {"GITLAB_GROUP"}
c.GitLabOAuthenticator.allow_all = True

c.GitLabOAuthenticator.login_service = "GITLAB_FQDN"
c.Authenticator.admin_users = {"JHUB_ADMIN"}
