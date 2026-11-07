#!/usr/bin/env bash
# bootstrap.sh -- new VPS / VM bootstrap (Debian/Ubuntu; Fedora/Arch best-effort)
#
# First boot, as root (most VPS images):
#   curl -fsSL https://raw.githubusercontent.com/patrickcarmichael/vm-bootstrap/main/bootstrap.sh -o bootstrap.sh
#   bash bootstrap.sh
#   # -> creates user `patrick` w/ GitHub keys + NOPASSWD sudo, then re-runs itself as patrick.
#
# Later, as patrick (idempotent; safe to re-run):
#   bash bootstrap.sh
#
# Env toggles (1/0):
#   BOOTSTRAP_USER=patrick  GITHUB_USER=patrickcarmichael
#   WITH_TAILSCALE=1  WITH_CLOUDFLARED=1  WITH_HERDR=1  WITH_AGENTS=1  WITH_ZSH=1
#   WITH_DOCKER=0     WITH_WRANGLER=0     WITH_UFW=1    WITH_SWAP=1    SWAP_GB=2
#   HOSTNAME_NEW=""   TZ_NEW="America/New_York"  GIT_NAME=""  GIT_EMAIL=""
#   DOTFILES_REPO=""  TS_AUTHKEY=""  CF_TUNNEL_TOKEN=""  MOSHI_TOKEN=""  WITH_MOSHI=1
#
# What you get:
#   system: user+sudo, github ssh keys, sshd hardening (keys only, port 22 stays public),
#           unattended upgrades, hostname/timezone, swapfile, ufw (ssh + mosh + tailscale0)
#   base:   curl git build-essential tmux mosh zsh unzip jq htop …
#   mise:   herdr atuin gh zoxide fzf ripgrep fd bat eza starship lazygit delta yq uv node
#           + claude-code + codex (WITH_AGENTS)
#   net:    tailscale (TS_AUTHKEY → auto-join w/ --ssh), cloudflared (CF_TUNNEL_TOKEN → systemd service)
#   shell:  mise/atuin/zoxide/starship in ~/.bashrc & ~/.zshrc, chsh zsh, tmux.conf, git config
#   mobile: tmux tuned for Moshi/Blink (C-a prefix, auto-attach "main" on ssh/mosh), moshi-hook daemon, micro editor
#   log:    ~/bootstrap-<date>.log, open tasks -> ~/bootstrap-todo.md

set -euo pipefail
# $USER/$HOME are unset in containers, cloud-init and cron — derive them.
USER="${USER:-$(id -un)}"; export USER
HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"; export HOME

BOOTSTRAP_USER="${BOOTSTRAP_USER:-patrick}"
GITHUB_USER="${GITHUB_USER:-patrickcarmichael}"
WITH_TAILSCALE="${WITH_TAILSCALE:-1}"
WITH_CLOUDFLARED="${WITH_CLOUDFLARED:-1}"
WITH_HERDR="${WITH_HERDR:-1}"
WITH_AGENTS="${WITH_AGENTS:-1}"
WITH_ZSH="${WITH_ZSH:-1}"
WITH_DOCKER="${WITH_DOCKER:-0}"
WITH_WRANGLER="${WITH_WRANGLER:-0}"
WITH_UFW="${WITH_UFW:-1}"
WITH_SWAP="${WITH_SWAP:-1}"
SWAP_GB="${SWAP_GB:-2}"
HOSTNAME_NEW="${HOSTNAME_NEW:-}"
TZ_NEW="${TZ_NEW:-America/New_York}"
GIT_NAME="${GIT_NAME:-}"
GIT_EMAIL="${GIT_EMAIL:-}"
DOTFILES_REPO="${DOTFILES_REPO:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
CF_TUNNEL_TOKEN="${CF_TUNNEL_TOKEN:-}"
MOSHI_TOKEN="${MOSHI_TOKEN:-}"
WITH_MOSHI="${WITH_MOSHI:-1}"

# ---------- helpers ----------
c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
info() { echo "${c_info}==>${c_off} $*"; }
ok()   { echo "${c_ok} ✓ ${c_off} $*"; }
warn() { echo "${c_warn} ! ${c_off} $*" >&2; }
die()  { echo "${c_err}xx${c_off} $*" >&2; exit 1; }
has()  { command -v "$1" >/dev/null 2>&1; }
TODO=(); todo() { TODO+=("$*"); }

# Append $3 to file $1 once, keyed on marker $2.
append_once() {
  local file="$1" marker="$2" content="$3"
  mkdir -p "$(dirname "$file")"; touch "$file"
  grep -qF "$marker" "$file" || printf '\n%s\n%s\n' "$marker" "$content" >> "$file"
}

# Set key=value in an sshd_config-style file (replace or append).
set_kv() { # file key value
  local f="$1" k="$2" v="$3"
  if grep -qiE "^\s*#?\s*${k}\b" "$f"; then
    $SUDO sed -i -E "s|^\s*#?\s*${k}\b.*|${k} ${v}|I" "$f"
  else
    echo "${k} ${v}" | $SUDO tee -a "$f" >/dev/null
  fi
}

# ---------- detect OS ----------
. /etc/os-release
case "${ID:-}${ID_LIKE:+ $ID_LIKE}" in
  *debian*|*ubuntu*) PKG=apt ;;
  *fedora*|*rhel*)   PKG=dnf ;;
  *arch*)            PKG=pacman ;;
  *) die "unsupported distro: ${ID:-?}" ;;
esac

# ---------- stage 0: root → create user, then re-exec as that user ----------
if [[ $EUID -eq 0 && "$USER" != "$BOOTSTRAP_USER" ]]; then
  SUDO=""
  info "running as root: provisioning user '$BOOTSTRAP_USER'"
  if ! id "$BOOTSTRAP_USER" >/dev/null 2>&1; then
    case $PKG in
      apt)    useradd -m -s /bin/bash -G sudo "$BOOTSTRAP_USER" ;;
      dnf)    useradd -m -s /bin/bash -G wheel "$BOOTSTRAP_USER" ;;
      pacman) useradd -m -s /bin/bash -G wheel "$BOOTSTRAP_USER" ;;
    esac
    ok "user $BOOTSTRAP_USER"
  fi
  has sudo || { case $PKG in apt) apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo;; dnf) dnf install -y -q sudo;; pacman) pacman -S --noconfirm --needed sudo;; esac; }
  mkdir -p /etc/sudoers.d
  echo "$BOOTSTRAP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$BOOTSTRAP_USER"
  chmod 0440 "/etc/sudoers.d/90-$BOOTSTRAP_USER"
  ok "sudoers NOPASSWD"

  # ssh keys from github
  H="/home/$BOOTSTRAP_USER"; install -d -m 700 -o "$BOOTSTRAP_USER" -g "$BOOTSTRAP_USER" "$H/.ssh"
  has ssh-import-id || { case $PKG in apt) apt-get install -y -qq ssh-import-id >/dev/null 2>&1 || true;; esac; }
  touch "$H/.ssh/authorized_keys"; chown "$BOOTSTRAP_USER:$BOOTSTRAP_USER" "$H/.ssh/authorized_keys"
  if has ssh-import-id && sudo -u "$BOOTSTRAP_USER" -H ssh-import-id "gh:${GITHUB_USER}" >/dev/null 2>&1; then
    ok "ssh-import-id gh:${GITHUB_USER}"
  elif keys="$(curl -fsSL "https://github.com/${GITHUB_USER}.keys")" && [[ -n $keys ]]; then
    while IFS= read -r k; do grep -qF "$k" "$H/.ssh/authorized_keys" || echo "$k" >> "$H/.ssh/authorized_keys"; done <<< "$keys"
  else
    die "could not fetch keys for github.com/${GITHUB_USER} -- refusing to lock root out"
  fi
  [[ -f /root/.ssh/authorized_keys ]] && while IFS= read -r k; do [[ -n $k ]] && ! grep -qF "$k" "$H/.ssh/authorized_keys" && echo "$k" >> "$H/.ssh/authorized_keys"; done < /root/.ssh/authorized_keys
  chmod 600 "$H/.ssh/authorized_keys"; chown "$BOOTSTRAP_USER:$BOOTSTRAP_USER" "$H/.ssh/authorized_keys"
  ok "authorized_keys: $(grep -c . "$H/.ssh/authorized_keys") keys"

  # hand off: copy script, re-run as the user with the same env
  if [[ -f "$0" ]]; then cp "$0" "$H/bootstrap.sh"
  else curl -fsSL "${BOOTSTRAP_URL:-https://raw.githubusercontent.com/patrickcarmichael/vm-bootstrap/main/bootstrap.sh}" -o "$H/bootstrap.sh"; fi
  chown "$BOOTSTRAP_USER:$BOOTSTRAP_USER" "$H/bootstrap.sh"
  info "re-running as $BOOTSTRAP_USER"
  exec sudo -u "$BOOTSTRAP_USER" -H --preserve-env=BOOTSTRAP_USER,GITHUB_USER,WITH_TAILSCALE,WITH_CLOUDFLARED,WITH_HERDR,WITH_AGENTS,WITH_ZSH,WITH_DOCKER,WITH_WRANGLER,WITH_UFW,WITH_SWAP,SWAP_GB,HOSTNAME_NEW,TZ_NEW,GIT_NAME,GIT_EMAIL,DOTFILES_REPO,TS_AUTHKEY,CF_TUNNEL_TOKEN,MOSHI_TOKEN,WITH_MOSHI \
    bash "$H/bootstrap.sh"
fi

# ---------- stage 1: as $BOOTSTRAP_USER ----------
has sudo || die "need sudo"
SUDO="sudo"
if ! sudo -n true 2>/dev/null; then
  [[ -t 0 ]] || die "sudo needs a password and stdin isn't a tty -- run as root first, or 'sudo -v' then re-run"
  sudo -v
fi

LOG="$HOME/bootstrap-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1
ARCH="$(uname -m)"
info "os=${PRETTY_NAME:-$ID} pkg=$PKG arch=$ARCH user=$USER log=$LOG"

# ---------- base packages ----------
info "base packages"
case $PKG in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq --no-install-recommends \
      ca-certificates curl wget git gnupg lsb-release build-essential \
      tmux mosh unzip zip tar xz-utils jq htop less vim tree \
      locales openssh-client ufw unattended-upgrades apt-listchanges ssh-import-id
    [[ $WITH_ZSH == 1 ]] && $SUDO apt-get install -y -qq --no-install-recommends zsh
    $SUDO sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
    $SUDO locale-gen >/dev/null 2>&1 || true
    $SUDO update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true
    ;;
  dnf)
    $SUDO dnf install -y -q ca-certificates curl wget git gnupg2 gcc gcc-c++ make \
      tmux mosh unzip zip tar xz jq htop less vim tree openssh-clients dnf-automatic
    [[ $WITH_ZSH == 1 ]] && $SUDO dnf install -y -q zsh
    ;;
  pacman)
    $SUDO pacman -Syu --noconfirm --needed base-devel curl wget git gnupg \
      tmux mosh unzip zip tar xz jq htop less vim tree openssh
    [[ $WITH_ZSH == 1 ]] && $SUDO pacman -S --noconfirm --needed zsh
    ;;
esac
ok "base packages"

# ---------- hostname / timezone ----------
if [[ -n $HOSTNAME_NEW ]]; then $SUDO hostnamectl set-hostname "$HOSTNAME_NEW" && ok "hostname $HOSTNAME_NEW"; fi
if [[ -n $TZ_NEW ]];       then $SUDO timedatectl set-timezone "$TZ_NEW" 2>/dev/null && ok "timezone $TZ_NEW" || warn "timezone not set"; fi

# ---------- swap ----------
if [[ $WITH_SWAP == 1 ]] && [[ "$(swapon --show --noheadings | wc -l)" -eq 0 ]]; then
  info "swapfile ${SWAP_GB}G"
  $SUDO fallocate -l "${SWAP_GB}G" /swapfile || $SUDO dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB*1024)) status=none
  $SUDO chmod 600 /swapfile && $SUDO mkswap /swapfile >/dev/null && $SUDO swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab >/dev/null
  echo 'vm.swappiness=10' | $SUDO tee /etc/sysctl.d/90-swappiness.conf >/dev/null; $SUDO sysctl -q -p /etc/sysctl.d/90-swappiness.conf
  ok "swap"
fi

# ---------- unattended upgrades ----------
info "automatic security updates"
case $PKG in
  apt)
    $SUDO tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    $SUDO tee /etc/apt/apt.conf.d/52unattended-upgrades-local >/dev/null <<'EOF'
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    $SUDO systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true ;;
  dnf)
    $SUDO sed -i 's/^apply_updates.*/apply_updates = yes/; s/^upgrade_type.*/upgrade_type = security/' /etc/dnf/automatic.conf
    $SUDO systemctl enable --now dnf-automatic.timer >/dev/null 2>&1 || true ;;
  pacman) warn "arch: no unattended upgrades configured (by design)" ;;
esac
ok "unattended upgrades"

# ---------- sshd hardening (keys only; port 22 stays public as fallback) ----------
info "sshd hardening"
[[ -s "$HOME/.ssh/authorized_keys" ]] || die "no ~/.ssh/authorized_keys for $USER -- add keys before disabling password auth"
SSHD_D=/etc/ssh/sshd_config.d
if [[ -d $SSHD_D ]]; then
  $SUDO tee "$SSHD_D/10-bootstrap.conf" >/dev/null <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 4
ClientAliveInterval 60
ClientAliveCountMax 3
AcceptEnv LANG LC_*
EOF
else
  for kv in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "ChallengeResponseAuthentication no" \
            "PermitRootLogin prohibit-password" "PubkeyAuthentication yes" "X11Forwarding no" "MaxAuthTries 4"; do
    set_kv /etc/ssh/sshd_config "${kv% *}" "${kv#* }"
  done
fi
# cloud-init on Ubuntu ships 50-cloud-init.conf with PasswordAuthentication yes; ours must win (lower number = first = wins)
if $SUDO sshd -t; then
  $SUDO systemctl reload ssh 2>/dev/null || $SUDO systemctl reload sshd 2>/dev/null || true
  ok "sshd: keys only, root prohibit-password, port 22 open"
else
  warn "sshd config test failed -- not reloading; inspect $SSHD_D/10-bootstrap.conf"
fi

# ---------- mise ----------
info "mise"
[[ -x "$HOME/.local/bin/mise" ]] || curl -fsSL https://mise.run | sh
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
eval "$("$HOME/.local/bin/mise" activate bash --shims)"
ok "mise $(mise --version)"

MISE_TOOLS=(
  gh atuin zoxide fzf ripgrep fd bat eza starship lazygit delta yq uv node@lts micro
)
[[ $WITH_HERDR == 1 ]]    && MISE_TOOLS+=(herdr)
[[ $WITH_WRANGLER == 1 ]] && MISE_TOOLS+=(npm:wrangler)
[[ $WITH_AGENTS == 1 ]]   && MISE_TOOLS+=(npm:@openai/codex)   # claude-code via native installer below (npm backend skips its postinstall)

info "mise tools: ${MISE_TOOLS[*]}"
for t in "${MISE_TOOLS[@]}"; do
  if mise use -g -y "$t" >/dev/null 2>&1; then ok "$t"; else warn "mise failed: $t (skipping)"; fi
done
mise reshim >/dev/null 2>&1 || true

if [[ $WITH_HERDR == 1 ]] && ! has herdr; then
  curl -fsSL https://herdr.dev/install.sh | sh && ok "herdr (installer)" || warn "herdr install failed"
fi
if [[ $WITH_AGENTS == 1 ]]; then
  # remove a hollow mise/npm shim if one exists from an earlier run
  mise ls npm:@anthropic-ai/claude-code >/dev/null 2>&1 && mise uninstall -y npm:@anthropic-ai/claude-code >/dev/null 2>&1 || true
  if [[ -x "$HOME/.local/bin/claude" ]]; then ok "claude $("$HOME/.local/bin/claude" --version 2>/dev/null | head -1)"
  else
    for i in 1 2 3; do
      curl -fsSL --http1.1 https://claude.ai/install.sh | bash && { ok "claude (native installer)"; break; }
      [[ $i -lt 3 ]] && { warn "claude installer attempt $i failed; retrying"; sleep 5; } || warn "claude install failed (3 attempts)"
    done
  fi
fi

# ---------- moshi-hook (Moshi iOS: Live Activity + approvals for Claude/Codex) ----------
if [[ $WITH_MOSHI == 1 ]]; then
  info "moshi-hook"
  has moshi-hook || { curl -fsSL https://getmoshi.app/install.sh | sh && ok "moshi-hook installed" || warn "moshi-hook install failed"; }
  export PATH="$HOME/.local/bin:$PATH"; hash -r
  if has moshi-hook; then
    if [[ -n $MOSHI_TOKEN ]]; then
      moshi-hook pair --token "$MOSHI_TOKEN" --store file >/dev/null 2>&1 && ok "moshi-hook paired" || warn "moshi-hook pair failed"
    fi
    moshi-hook install >/dev/null 2>&1 && ok "moshi-hook: agent hooks written" || warn "moshi-hook install (hooks) failed -- rerun after agents are logged in"
    mkdir -p "$HOME/.config/systemd/user"
    [[ -f "$HOME/.config/systemd/user/moshi-hook.service" ]] || cat > "$HOME/.config/systemd/user/moshi-hook.service" <<EOF
[Unit]
Description=moshi-hook daemon (Moshi agent hooks)
After=network-online.target
[Service]
ExecStart=$(command -v moshi-hook) serve
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
EOF
    $SUDO loginctl enable-linger "$USER" >/dev/null 2>&1 || true
    if systemctl --user daemon-reload >/dev/null 2>&1 && systemctl --user enable --now moshi-hook >/dev/null 2>&1; then
      ok "moshi-hook.service (user, lingering)"
    else
      warn "moshi-hook.service not started (no user systemd?) -- run: moshi-hook serve"
    fi
    [[ -z $MOSHI_TOKEN ]] && todo 'Pair Moshi: `moshi-hook pair --token <Moshi > Settings > Agent Hooks> --store file` then `moshi-hook install`'
  fi
fi

# ---------- tailscale ----------
if [[ $WITH_TAILSCALE == 1 ]]; then
  info "tailscale"
  has tailscale || curl -fsSL https://tailscale.com/install.sh | sh
  $SUDO systemctl enable --now tailscaled >/dev/null 2>&1 || true
  if [[ -n $TS_AUTHKEY ]]; then
    $SUDO tailscale up --authkey "$TS_AUTHKEY" --ssh && ok "tailscale up --ssh"
  elif $SUDO tailscale status >/dev/null 2>&1; then
    ok "tailscale already up"
  else
    warn "run: sudo tailscale up --ssh"; todo 'Join tailnet: `sudo tailscale up --ssh --accept-routes`'
  fi
fi

# ---------- cloudflared ----------
if [[ $WITH_CLOUDFLARED == 1 ]]; then
  info "cloudflared"
  if ! has cloudflared; then
    case $PKG in
      apt)
        $SUDO mkdir -p --mode=0755 /usr/share/keyrings
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
          | $SUDO tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq cloudflared ;;
      dnf)
        curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo | $SUDO tee /etc/yum.repos.d/cloudflared.repo >/dev/null
        $SUDO dnf install -y -q cloudflared ;;
      pacman) $SUDO pacman -S --noconfirm --needed cloudflared ;;
    esac
  fi
  has cloudflared && ok "cloudflared $(cloudflared --version 2>/dev/null | head -1)"
  if [[ -n $CF_TUNNEL_TOKEN ]] && ! systemctl is-enabled cloudflared >/dev/null 2>&1; then
    $SUDO cloudflared service install "$CF_TUNNEL_TOKEN" && ok "cloudflared systemd service" || warn "cloudflared service install failed"
  elif [[ -z $CF_TUNNEL_TOKEN ]]; then
    warn "tunnel: set CF_TUNNEL_TOKEN (Zero Trust > Tunnels > token) or run: cloudflared tunnel login"
    todo 'Cloudflare tunnel: `cloudflared tunnel login` or re-run with CF_TUNNEL_TOKEN=... (Zero Trust > Networks > Tunnels)'
  fi
fi

# ---------- docker (optional) ----------
if [[ $WITH_DOCKER == 1 ]] && ! has docker; then
  info "docker"
  curl -fsSL https://get.docker.com | sh
  $SUDO usermod -aG docker "$USER" && ok "docker (re-login for group)"; todo "Docker: log out/in so the docker group applies"
fi

# ---------- firewall ----------
if [[ $WITH_UFW == 1 ]] && has ufw; then
  info "ufw"
  $SUDO ufw default deny incoming >/dev/null
  $SUDO ufw default allow outgoing >/dev/null
  $SUDO ufw allow 22/tcp comment 'ssh (public fallback)' >/dev/null
  $SUDO ufw allow 60000:61000/udp comment 'mosh' >/dev/null
  [[ $WITH_TAILSCALE == 1 ]] && $SUDO ufw allow in on tailscale0 comment 'tailnet' >/dev/null
  $SUDO ufw --force enable >/dev/null && ok "ufw: 22/tcp + mosh udp + tailscale0 (check provider firewall too)"
fi

# ---------- ssh key for $USER ----------
info "ssh key"
install -d -m 700 "$HOME/.ssh"
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
  ssh-keygen -t ed25519 -N "" -C "${USER}@$(hostname -s)" -f "$HOME/.ssh/id_ed25519" >/dev/null && ok "generated ~/.ssh/id_ed25519"
else
  ok "~/.ssh/id_ed25519 exists"
fi
PUBKEY="$(cat "$HOME/.ssh/id_ed25519.pub")"
append_once "$HOME/.ssh/config" "# >>> bootstrap.sh >>>" "Host github.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
Host *
  ServerAliveInterval 30
  ServerAliveCountMax 3
  AddKeysToAgent yes
# <<< bootstrap.sh <<<"
chmod 600 "$HOME/.ssh/config"
todo "Add this host's key to GitHub: \`gh ssh-key add ~/.ssh/id_ed25519.pub --title $(hostname -s)\`  (\`$PUBKEY\`)"

# ---------- git ----------
info "git config"
[[ -n $GIT_NAME ]]  && git config --global user.name  "$GIT_NAME"
[[ -n $GIT_EMAIL ]] && git config --global user.email "$GIT_EMAIL"
git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
if has delta; then
  git config --global core.pager delta
  git config --global interactive.diffFilter 'delta --color-only'
  git config --global delta.navigate true
  git config --global delta.line-numbers true
  git config --global merge.conflictstyle zdiff3
fi
[[ -z $GIT_NAME || -z $GIT_EMAIL ]] && { warn "git user.name/email not set (GIT_NAME / GIT_EMAIL) -- or run: gh auth setup-git"; todo 'git identity: `gh auth setup-git` (after gh auth login) or `git config --global user.name/user.email`'; }
ok "git"

# ---------- shell wiring ----------
info "shell config"
MARK='# >>> bootstrap.sh >>>'
read -r -d '' BASH_BLOCK <<'EOF' || true
export PATH="$HOME/.local/bin:$PATH"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export EDITOR="$(command -v micro >/dev/null && echo micro || echo vim)"; export VISUAL="$EDITOR"
command -v mise     >/dev/null && eval "$(mise activate bash)"
command -v starship >/dev/null && eval "$(starship init bash)"
command -v zoxide   >/dev/null && eval "$(zoxide init bash)"
command -v atuin    >/dev/null && eval "$(atuin init bash --disable-up-arrow)"
command -v fzf      >/dev/null && eval "$(fzf --bash 2>/dev/null)"
alias ls='eza --group-directories-first' ll='eza -la --git' cat='bat -pp' lg='lazygit'
# auto-attach tmux "main" on ssh/mosh logins (Moshi/Blink friendly); NO_TMUX=1 to skip
if [[ $- == *i* && -z "${TMUX:-}" && -n "${SSH_CONNECTION:-}" && -z "${VSCODE_INJECTION:-}" && -z "${NO_TMUX:-}" ]] && command -v tmux >/dev/null; then
  exec tmux new-session -A -s main
fi
# <<< bootstrap.sh <<<
EOF
append_once "$HOME/.bashrc" "$MARK" "$BASH_BLOCK"
ok "~/.bashrc"
if [[ $WITH_ZSH == 1 ]] && has zsh; then
  append_once "$HOME/.zshrc" "$MARK" "${BASH_BLOCK//bash/zsh}"
  if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]]; then
    $SUDO chsh -s "$(command -v zsh)" "$USER" && ok "login shell → zsh" || warn "chsh failed"
  fi
  ok "~/.zshrc"
fi

mkdir -p "$HOME/.config"
[[ -f "$HOME/.config/starship.toml" ]] || cat > "$HOME/.config/starship.toml" <<'EOF'
add_newline = false
format = "$hostname$directory$git_branch$git_status$cmd_duration$character"
[hostname]
ssh_only = false
format = "[$hostname]($style) "
style = "bold yellow"
[directory]
truncation_length = 3
EOF

# tmux: one config for phone (Moshi/Blink) and desktop
# prefix C-a, mouse/touch, Alt-arrow panes & Alt-number windows (no prefix), readable status, sessions survive reboots (tpm/resurrect/continuum)
if [[ ! -f "$HOME/.tmux.conf" ]] || ! grep -q 'bootstrap.sh' "$HOME/.tmux.conf"; then
cat > "$HOME/.tmux.conf" <<'EOF'
# managed by bootstrap.sh -- edit freely; re-runs won't overwrite
unbind C-b
set -g prefix C-a
bind C-a send-prefix
bind a last-window

set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*:Tc"
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -s escape-time 0
set -g focus-events on
set -g set-clipboard on
set -g display-time 2000
set -ga update-environment " MOSHI_CLIENT SSH_CONNECTION"

# panes: Alt+arrows move, Alt+Shift+arrows resize, | and - split (keep cwd)
bind -n M-Left  select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up    select-pane -U
bind -n M-Down  select-pane -D
bind -n M-S-Left  resize-pane -L 5
bind -n M-S-Right resize-pane -R 5
bind -n M-S-Up    resize-pane -U 3
bind -n M-S-Down  resize-pane -D 3
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
bind z resize-pane -Z

# windows: Alt+1..5 jump, Alt+n/p cycle
bind -n M-1 select-window -t 1
bind -n M-2 select-window -t 2
bind -n M-3 select-window -t 3
bind -n M-4 select-window -t 4
bind -n M-5 select-window -t 5
bind -n M-n next-window
bind -n M-p previous-window
bind , command-prompt -I "#W" "rename-window '%%'"
bind r source-file ~/.tmux.conf \; display "tmux reloaded"
bind d detach-client
bind S choose-session
bind X confirm-before -p "kill window #W? (y/n)" kill-window

# copy mode: vi keys
setw -g mode-keys vi
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel "tmux save-buffer -"

# status: top, one line, big targets, readable at 390px
set -g status-position top
set -g status-interval 5
set -g status-style "bg=default,fg=colour244"
set -g status-left-length 20
set -g status-left "#[fg=yellow,bold] #S #[default]"
set -g status-right-length 40
set -g status-right "#[fg=colour244]#h #[fg=yellow]%H:%M "
setw -g window-status-format " #I #W "
setw -g window-status-current-format "#[fg=black,bg=yellow,bold] #I #W #[default]"
set -g pane-border-style "fg=colour238"
set -g pane-active-border-style "fg=yellow"

# plugins (tpm)
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @resurrect-capture-pane-contents 'on'
set -g @continuum-restore 'on'
set -g @continuum-save-interval '10'
run '~/.tmux/plugins/tpm/tpm'
EOF
fi
if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
  git clone -q --depth 1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" \
    && "$HOME/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1 && ok "tpm + plugins" || warn "tpm install failed -- press C-a I inside tmux"
fi

mkdir -p "$HOME/.config/atuin"
[[ -f "$HOME/.config/atuin/config.toml" ]] || cat > "$HOME/.config/atuin/config.toml" <<'EOF'
auto_sync = true
sync_frequency = "5m"
search_mode = "fuzzy"
filter_mode = "global"
style = "compact"
inline_height = 20
enter_accept = true
EOF
ok "starship.toml atuin/config.toml"

# ---------- dotfiles (optional) ----------
if [[ -n $DOTFILES_REPO && ! -d "$HOME/.dotfiles" ]]; then
  info "dotfiles: $DOTFILES_REPO"
  git clone --depth 1 "https://${DOTFILES_REPO#https://}" "$HOME/.dotfiles" \
    && { [[ -x "$HOME/.dotfiles/install.sh" ]] && "$HOME/.dotfiles/install.sh" || true; } \
    && ok "dotfiles" || warn "dotfiles clone failed"
fi

# ---------- pin versions ----------
# mise writes exact versions to this file; copy it into dotfiles/gist to make the next VM identical.
MISE_CFG="$HOME/.config/mise/config.toml"
[[ -f $MISE_CFG ]] && { cp "$MISE_CFG" "$HOME/mise.config.toml.pinned"; ok "pinned tool versions → ~/mise.config.toml.pinned"; }

# ---------- summary ----------
echo
info "installed"
for b in mise tmux mosh zsh herdr claude codex atuin gh tailscale cloudflared zoxide fzf rg fd bat eza starship lazygit delta uv node; do
  if has "$b"; then printf '  %-12s %s\n' "$b" "$(command -v "$b")"; else printf '  %-12s %s\n' "$b" "${c_warn}missing${c_off}"; fi
done
echo
[[ -f /var/run/reboot-required ]] && { warn "REBOOT REQUIRED (kernel/libc updated): sudo reboot"; todo 'Reboot (kernel/libc updated): `sudo reboot`'; }

# standing logins, only if not already done
gh auth status >/dev/null 2>&1          || todo 'GitHub CLI: `gh auth login`'
[[ -f "$HOME/.config/atuin/session" ]]  || todo 'Atuin history sync: `atuin register` (first host) or `atuin login`'
[[ -f "$HOME/.claude/.credentials.json" ]] || todo 'Claude Code: run `claude` once to log in'
[[ -f "$HOME/.codex/auth.json" ]]       || todo 'Codex: run `codex` once to log in'
has herdr && todo 'Start the agent runtime: `herdr`'
[[ $WITH_TAILSCALE == 1 ]] && todo 'Tighten later: PermitRootLogin no in /etc/ssh/sshd_config.d/10-bootstrap.conf once Tailscale SSH is confirmed'

TODO_FILE="$HOME/bootstrap-todo.md"
TS_IP="$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')"
{
  echo "# bootstrap todo -- $(hostname -s) -- $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  echo "Open items after \`bootstrap.sh\` (log: \`$LOG\`). Delete lines as you finish them; re-running the script regenerates this file."
  echo
  if ((${#TODO[@]})); then for t in "${TODO[@]}"; do echo "- [ ] $t"; done; else echo "- [x] nothing left -- everything was configured non-interactively"; fi
  echo
  echo "## Connect"
  echo
  echo '```'
  echo "mosh $USER@$(hostname -s)    # or over tailnet: mosh $USER@$TS_IP"
  echo "ssh  $USER@$(hostname -s)    # lands in tmux session 'main'; NO_TMUX=1 ssh ... to skip"
  echo '```'
  echo
  echo "## tmux (prefix = Ctrl-a)"
  echo
  echo "| keys | action |"
  echo "|---|---|"
  echo "| Alt+arrows | move between panes (no prefix) |"
  echo "| Alt+1..5, Alt+n/p | jump / cycle windows |"
  echo "| C-a \| / C-a - | split right / below |"
  echo "| C-a c / C-a , | new window / rename |"
  echo "| C-a z | zoom pane |"
  echo "| C-a d | detach (session keeps running) |"
  echo "| C-a S | pick session |"
  echo "| C-a I | install plugins (first time) |"
  echo "| C-a r | reload config |"
} > "$TODO_FILE"
ok "open tasks -> $TODO_FILE (${#TODO[@]} items)"

info "next steps"
cat <<EOF
  exec \$SHELL -l                      # pick up PATH + prompt (zsh if enabled)
  gh auth login && gh auth setup-git   # github
  atuin register   # or: atuin login   # history sync
  claude                               # claude code login
  codex                                # codex login
  $( [[ -z $TS_AUTHKEY ]] && echo "sudo tailscale up --ssh              # tailnet" )
  $( [[ -z $CF_TUNNEL_TOKEN ]] && echo "cloudflared tunnel login             # cloudflare tunnel" )
  herdr                                # agent runtime
  mosh $USER@<this-host>               # from your laptop
  log: $LOG
EOF
