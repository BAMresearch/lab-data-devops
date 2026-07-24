This is a collection of scripts using the same mechanisms to set up systemd user-space services with backend containers via podman. The services are part of measurement orchestration, data processing and testing environments:

- [Tiled API](https://github.com/bluesky/tiled) - A data access service for data-aware portals and data science tools
- [MoDaCor](https://github.com/BAMresearch/MoDaCor) - New modular data corrections for any neutron or xray technique that produces 1D or 2D scattering/diffraction/imaging data, via FastAPI
- [JupyterHub](https://jupyter.org/hub) - A multi-user version of the notebook designed for companies, classrooms and research labs  
  → Ephemeral jupyterhub launching a set of Jupyter-Notebook containers prebuilt from Github repositories read-only with access to network shares for data analysis
- [OpenBIS](https://openbis.ch) - Digital notebook, Data management and Inventory management, for integration and acceptance testing  
  → Launches the OpenBIS container from DockerHub, together with a Postgres database container and a landing page with links to the ELN and the Admin interface of OpenBIS.

Currently, it uses the ingress of an existing kubernetes setup for mapping domain names to port numbers of the containers and as TLS endpoint. This is subject to change, Traefik possibly, at a later point.

