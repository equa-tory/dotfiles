Desktop modules are installed from `configs/desktop/<module>/install.sh`.
Torii cloning is available only through the explicit `desktop/torii` menu item.
Desktop packages, Zsh plugins, login shell, and the cloud helper each have separate modules.

Select individual modules under `desktop/mirrors`: Pacman uses port 3142, Nexus
clients use port 8090, and Docker registry mirrors use ports 8091 and 8093.
`MIRROR_HOST` overrides the default host (`192.168.1.50`). Apt is unchanged because
Torii does not provide an Apt endpoint.
