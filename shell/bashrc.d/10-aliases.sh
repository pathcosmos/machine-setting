# Common aliases

# Python
alias py='python3'
alias pip='pip3'
alias ipy='ipython'

# Git shortcuts
alias gs='git status'
alias gd='git diff'
alias gl='git log --oneline -20'
alias gp='git pull --rebase'

# Machine setting
alias ms='cd ~/machine_setting'
alias mss='make -C ~/machine_setting status'
alias msu='make -C ~/machine_setting update'
alias msp='make -C ~/machine_setting push'

# GPU monitoring
alias gpustat='nvidia-smi --query-gpu=gpu_name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu --format=csv,noheader 2>/dev/null || echo "No GPU"'
