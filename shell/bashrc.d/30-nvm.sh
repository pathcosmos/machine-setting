# NVM loader (lazy - only loads when nvm/node/npm is called)

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

_load_nvm() {
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
}

# Lazy load: override nvm/node/npm commands to load NVM on first use
if [ -d "$NVM_DIR" ]; then
    for cmd in nvm node npm npx; do
        eval "${cmd}() { unset -f nvm node npm npx 2>/dev/null; _load_nvm; ${cmd} \"\$@\"; }"
    done
fi
