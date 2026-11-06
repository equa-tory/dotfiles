# Sourced by bash and zsh. Keep this portable: no arrays, no external requirements.
alias ..='cd ..'
alias ...='cd ../..'
alias grep='grep --color=auto'
if command -v eza >/dev/null 2>&1; then
  alias ll='eza -lah'
else
  alias ll='ls -lah'
fi
if command -v nvim >/dev/null 2>&1; then
  alias v='nvim'
elif command -v vim >/dev/null 2>&1; then
  alias v='vim'
else
  alias v='vi'
fi
if command -v rg >/dev/null 2>&1; then
  alias rgrep='rg'
fi
if command -v fd >/dev/null 2>&1; then
  alias f='fd'
elif command -v fdfind >/dev/null 2>&1; then
  alias f='fdfind'
else
  alias f='find . -name'
fi
# Don't alias 'cd' to zoxide: it can break shell startup and scripts.
# Optional zoxide initialization can be added in a separate desktop module.
