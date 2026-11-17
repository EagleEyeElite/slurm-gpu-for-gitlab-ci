#!/bin/bash
# bootstrap/install.sh — set up your account from this checkout: nix (a
# system install if there is one, nix-portable otherwise), home-manager, and
# the first switch. Everything after it is `hm-switch`.
#
#   git clone https://github.com/<you>/slurm-gpu-for-gitlab-ci.git ~/slurm-gpu-for-gitlab-ci
#   bash ~/slurm-gpu-for-gitlab-ci/bootstrap/install.sh               # SLURM login node
#   bash ~/slurm-gpu-for-gitlab-ci/bootstrap/install.sh restricted-pod  # a container without Docker
#
# It starts nothing that runs on its own: the runner and the BuildKit daemon
# are opt-in in ~/.config/slurm-gitlab-ci/local.nix, which this creates from
# local.example.nix if it does not exist.
#
# Safe to run again: it skips what is already installed and switches again.
set -euo pipefail

ATTR="${1:-slurm-frontend}"
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/slurm-gitlab-ci"
export SLURM_CI_REPO_DIR="$REPO"
# The release whose bundled nix (2.20) this setup is tested with; "latest"
# would change under every new account.
NIX_PORTABLE_URL="${NIX_PORTABLE_URL:-https://github.com/DavHau/nix-portable/releases/download/v012/nix-portable-$(uname -m)}"
# Flakes, also where the system nix.conf does not enable them.
export NIX_CONFIG="${NIX_CONFIG:+$NIX_CONFIG
}extra-experimental-features = nix-command flakes"

step() { printf '\n==> %s\n' "$*"; }

# A nix store on NFS now and then answers "disk I/O error" from SQLite.
# Every step that uses it is safe to repeat.
retry() {
    local n
    for n in 1 2 3; do
        "$@" && return 0
        [ "$n" = 3 ] || { echo "failed (attempt $n of 3), trying again in 10 s" >&2; sleep 10; }
    done
    return 1
}

# Run a command where /nix/store exists: right here with a system nix (or
# already inside the wrap), else inside nix-portable's wrap. Wrapping twice
# fails with "setting up a private mount namespace".
in_nix() {
    if [ -d /nix/store ]; then
        /usr/bin/env bash -c "$1"
    else
        env NIX_PORTABLE_SHELL=1 "$HOME/bin/nix-portable" debug /usr/bin/env bash -c "$1"
    fi
}
# Under nix-portable, its bundled nix first on PATH (a newer one from the
# store would write a cache schema the bundled one cannot read).
PATH_SETUP='if [ -n "${NIX_PORTABLE_SHELL:-}" ]; then
  np="$(ls -d /nix/store/*-nix-2.20.*/bin 2>/dev/null | head -1)"
  export PATH="${np:+$np:}$HOME/.nix-portable/bin:$PATH"
fi
export PATH="$HOME/.nix-profile/bin:$PATH"'

case "$ATTR" in
    slurm-frontend|restricted-pod) ;;
    *) echo "usage: $0 [slurm-frontend|restricted-pod]" >&2; exit 2 ;;
esac

step "nix"
if [ -d /nix/store ] && command -v nix >/dev/null 2>&1; then
    echo "system nix: $(nix --version)"
    USE_PORTABLE=0
elif [ -x "$HOME/bin/nix-portable" ]; then
    echo "nix-portable already installed"
    USE_PORTABLE=1
else
    mkdir -p "$HOME/bin"
    curl -fsSL "$NIX_PORTABLE_URL" -o "$HOME/bin/nix-portable.part"
    chmod +x "$HOME/bin/nix-portable.part"
    mv "$HOME/bin/nix-portable.part" "$HOME/bin/nix-portable"
    echo "installed nix-portable ($NIX_PORTABLE_URL)"
    USE_PORTABLE=1
fi
if [ "$USE_PORTABLE" = 1 ]; then
    [ -e "$HOME/.nix-profile" ] || ln -sfn "$HOME/.local/state/nix/profiles/profile" "$HOME/.nix-profile"
fi

step "Your settings: $CONF_DIR/local.nix"
mkdir -p "$CONF_DIR"
if [ -f "$CONF_DIR/local.nix" ]; then
    echo "exists, kept"
else
    cp "$REPO/local.example.nix" "$CONF_DIR/local.nix"
    if [ "$USE_PORTABLE" = 0 ]; then
        sed -i 's|# nixPortable = false; |nixPortable = false;   |' "$CONF_DIR/local.nix"
    fi
    echo "created from local.example.nix -- set gitlabUrl (and, later, the daemons) there"
fi

step "home-manager"
if in_nix "$PATH_SETUP; command -v home-manager" >/dev/null 2>&1; then
    echo "already installed"
else
    # `nix profile install`, not `nix run`: nix-portable's sandbox cannot
    # nest the mount namespace `nix run nixpkgs#home-manager` needs.
    echo "installing (a few minutes on a new account)"
    retry in_nix "$PATH_SETUP; nix profile install nixpkgs#home-manager"
fi

step "First switch: $ATTR as $USER"
retry in_nix "$PATH_SETUP"'
    cd "$SLURM_CI_REPO_DIR" && home-manager switch -b pre-hm --impure --flake .#'"$ATTR"

step "Done"
cat <<EOF
From now on: edit $CONF_DIR/local.nix, then run ~/bin/hm-switch.
EOF
if [ "$USE_PORTABLE" = 1 ]; then
    echo "Tools from the nix profile run inside nix-portable's wrap: ~/bin/np-shell opens a shell there."
fi
if [ "$ATTR" = slurm-frontend ]; then
    echo "Next: docs/setup.md (register a runner, enable the daemons, the cron lines)."
fi
