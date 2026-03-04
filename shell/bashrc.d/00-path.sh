# PATH configuration for machine_setting
# Cross-platform: Linux + macOS (bash & zsh compatible)

_MS_OS="$(uname -s)"

# --- macOS: Homebrew ---
if [ "$_MS_OS" = "Darwin" ]; then
    # Apple Silicon Homebrew lives in /opt/homebrew
    if [ -d /opt/homebrew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" 2>/dev/null || true
    fi
    # Intel Mac Homebrew
    if [ -d /usr/local/Homebrew ]; then
        eval "$(/usr/local/bin/brew shellenv 2>/dev/null)" 2>/dev/null || true
    fi
fi

# --- Linux: CUDA ---
if [ "$_MS_OS" = "Linux" ] && [ -d /usr/local/cuda/bin ]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/cuda/lib64"
    export CUDA_HOME="/usr/local/cuda"
fi

# --- Common: uv / Python user scripts ---
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# --- Maven (if installed via SDKMAN) ---
[ -d "$HOME/.sdkman/candidates/maven/current/bin" ] && \
    export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH"

unset _MS_OS
