Desktop modules are installed from `configs/desktop/<module>/install.sh`.
Torii dotfiles are cloned from GitHub at install time; this repository does not copy their files.
The mirrors module runs Torii's `packages/mirrors.sh`: pacman cache on port 3142,
Nexus on 8090, and Docker registry mirrors on 8091 and 8093. It also writes npm,
pip, and NuGet client configuration. Torii does not define an apt mirror endpoint,
so apt sources are left unchanged.
