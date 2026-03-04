# Non-secret environment variables
# Secrets go in ~/.bashrc.local (gitignored)

export EDITOR="${EDITOR:-vim}"
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

# Python
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

# HuggingFace cache
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
export TRANSFORMERS_CACHE="$HF_HOME/hub"

# Torch
export TORCH_HOME="${TORCH_HOME:-$HOME/.cache/torch}"

# Reduce telemetry
export WANDB_SILENT=true
export DO_NOT_TRACK=1
