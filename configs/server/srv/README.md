# srv

This is the current modular `srv` command, copied from the installed
`~/.local/bin/srv` implementation. Its modules and help documentation are kept
beside the entry point so the command can locate them after installation.

Select **server → srv** in `./install.sh` to link it to `~/.local/bin/srv`.
Machine state is stored under `.state/` and ignored by Git. Do not copy state
files or saved proxy links into the repository.
