#!/usr/bin/env bash
# description: Install shared shell config, Powerlevel10k, and autosuggestions
# default: false
set -euo pipefail
command -v git >/dev/null || { echo 'Install Git first' >&2; exit 1; }
mkdir -p "$HOME/.local/share/zsh/plugins"
clone_or_update() { local url="$1" path="$2"; if [[ -d "$path/.git" ]]; then git -C "$path" pull --ff-only; else git clone --depth 1 "$url" "$path"; fi; }
clone_or_update https://github.com/romkatv/powerlevel10k.git "$HOME/.local/share/zsh/powerlevel10k"
clone_or_update https://github.com/zsh-users/zsh-autosuggestions.git "$HOME/.local/share/zsh/plugins/zsh-autosuggestions"
source "$BOOTSTRAP_ROOT/lib/common.sh"
install_config_link "$BOOTSTRAP_ROOT/configs/default/shell/shellrc" "$HOME/.config/shell/shellrc"
install_config_link "$BOOTSTRAP_ROOT/configs/desktop/zsh/plugins.zsh" "$HOME/.config/zsh/plugins.zsh"
install_config_link "$BOOTSTRAP_ROOT/configs/desktop/zsh/p10k.zsh" "$HOME/.p10k.zsh"
ensure_source_line "$HOME/.zshrc" '[[ -r "$HOME/.config/shell/shellrc" ]] && source "$HOME/.config/shell/shellrc"'
ensure_source_line "$HOME/.zshrc" '[[ -r "$HOME/.config/zsh/plugins.zsh" ]] && source "$HOME/.config/zsh/plugins.zsh"'
