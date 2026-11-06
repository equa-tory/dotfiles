# Use a known terminal definition when the remote host lacks the requested one.
if [[ -n $TERM ]] && (( $+commands[infocmp] )) &&
   ! command infocmp "$TERM" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi
