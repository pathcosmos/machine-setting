# Non-secret environment variables
# Secrets go in ~/.bashrc.local (gitignored)

export EDITOR="${EDITOR:-vim}"

# Locale by terminal type:
#   SSH / terminal emulator / tmux -> MS_LOCALE_REMOTE  (default ko_KR.UTF-8: Korean messages)
#   Linux console (direct tty)     -> MS_LOCALE_CONSOLE (default en_US.UTF-8: the console cannot draw Hangul)
# A locale that is not generated on this machine is never selected (that would print setlocale
# warnings in every shell); the order of fallbacks is console locale, then C.UTF-8.
# Generate the locales with scripts/install-locale.sh. Override in ~/.bashrc.local, e.g.
#   export MS_LOCALE_REMOTE=en_US.UTF-8   (set before this file runs, or just export LANG there)
_ms_locales="$(locale -a 2>/dev/null)"
_ms_has_locale() { printf '%s\n' "$_ms_locales" | grep -qiE "^${1%.*}\.utf-?8$"; }
_ms_remote="${MS_LOCALE_REMOTE:-ko_KR.UTF-8}"
_ms_console="${MS_LOCALE_CONSOLE:-en_US.UTF-8}"
_ms_want="$_ms_remote"
case "$(tty 2>/dev/null)" in /dev/tty[0-9]*|/dev/console) _ms_want="$_ms_console" ;; esac
[ "${TERM:-}" = "linux" ] && _ms_want="$_ms_console"
if _ms_has_locale "$_ms_want"; then
    export LANG="$_ms_want"
elif _ms_has_locale "$_ms_console"; then
    export LANG="$_ms_console"
else
    export LANG="${LANG:-C.UTF-8}"
fi
# LANGUAGE picks the message catalogue (with English as fallback); LC_ALL would override everything
case "$LANG" in
    C.*|C|POSIX) unset LANGUAGE ;;
    en_*)        export LANGUAGE="en" ;;
    *)           export LANGUAGE="${LANG%%_*}:en" ;;
esac
unset LC_ALL _ms_locales _ms_remote _ms_console _ms_want
unset -f _ms_has_locale

# Python
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1

# HuggingFace cache
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

# Torch
export TORCH_HOME="${TORCH_HOME:-$HOME/.cache/torch}"

# Reduce telemetry
export WANDB_SILENT=true
export DO_NOT_TRACK=1
