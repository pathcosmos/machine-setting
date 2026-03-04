# SDKMAN loader (lazy - only loads when sdk/java/javac is called)

export SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"

_load_sdkman() {
    [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
}

# Lazy load: override commands to load SDKMAN on first use
if [ -d "$SDKMAN_DIR" ]; then
    for cmd in sdk java javac mvn gradle; do
        eval "${cmd}() { unset -f sdk java javac mvn gradle 2>/dev/null; _load_sdkman; ${cmd} \"\$@\"; }"
    done
fi
