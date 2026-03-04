# PATH configuration for machine_setting
# Loaded by bashrc.d sourcing loop

# CUDA
if [ -d /usr/local/cuda/bin ]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/cuda/lib64"
    export CUDA_HOME="/usr/local/cuda"
fi

# uv / Python user scripts
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"

# Maven (if installed via SDKMAN)
[ -d "$HOME/.sdkman/candidates/maven/current/bin" ] && \
    export PATH="$HOME/.sdkman/candidates/maven/current/bin:$PATH"
