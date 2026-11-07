# vm-bootstrap

One-shot, idempotent bootstrap for fresh VPS / VM deploys. Debian/Ubuntu first; Fedora/Arch best-effort.

## First boot (as root)

```bash
curl -fsSL https://raw.githubusercontent.com/patrickcarmichael/vm-bootstrap/main/bootstrap.sh -o bootstrap.sh
TS_AUTHKEY=tskey-auth-… CF_TUNNEL_TOKEN=… HOSTNAME_NEW=my-vm bash bootstrap.sh
```

Creates user `patrick` (NOPASSWD sudo, SSH keys from `github.com/patrickcarmichael.keys`), then re-runs itself as that user.

Pin to a known-good release instead of `main` for anything automated:

```bash
curl -fsSL https://raw.githubusercontent.com/patrickcarmichael/vm-bootstrap/v2/bootstrap.sh
```

## Re-run later (as patrick)

```bash
bash ~/bootstrap.sh
```

Safe to repeat -- every step is guarded.

## What it does

| Area | Details |
|---|---|
| System | user + sudo, GitHub SSH keys, sshd keys-only (port 22 stays public), unattended upgrades, hostname/timezone, swapfile, ufw (22/tcp, mosh UDP, tailscale0) |
| Base | curl git build-essential tmux mosh zsh unzip jq htop vim … |
| mise | herdr atuin gh zoxide fzf ripgrep fd bat eza starship lazygit delta yq uv node@lts |
| Agents | Claude Code (native installer), `@openai/codex` via mise (`WITH_AGENTS=1`) |
| Net | Tailscale (`TS_AUTHKEY` → `tailscale up --ssh`), cloudflared (`CF_TUNNEL_TOKEN` → systemd service), optional wrangler |
| Shell | mise/atuin/zoxide/starship wired into `.bashrc` + `.zshrc`, `chsh` → zsh, tmux.conf, git + delta config |
| Log | `~/bootstrap-<timestamp>.log` |

## Env toggles

| Var | Default | |
|---|---|---|
| `BOOTSTRAP_USER` | `patrick` | user to create / run as |
| `GITHUB_USER` | `patrickcarmichael` | source of `authorized_keys` |
| `WITH_TAILSCALE` / `WITH_CLOUDFLARED` / `WITH_HERDR` / `WITH_AGENTS` / `WITH_ZSH` / `WITH_UFW` / `WITH_SWAP` | `1` | |
| `WITH_DOCKER` / `WITH_WRANGLER` | `0` | |
| `SWAP_GB` | `2` | skipped if swap already exists |
| `HOSTNAME_NEW` | -- | `hostnamectl set-hostname` |
| `TZ_NEW` | `America/New_York` | |
| `GIT_NAME` / `GIT_EMAIL` | -- | or `gh auth setup-git` later |
| `DOTFILES_REPO` | -- | e.g. `github.com/you/dotfiles`, runs its `install.sh` |
| `TS_AUTHKEY` | -- | non-interactive tailnet join |
| `CF_TUNNEL_TOKEN` | -- | Zero Trust → Tunnels → token |

## Pinned tool versions

After a clean run, the script copies `~/.config/mise/config.toml` to `~/mise.config.toml.pinned`.
Commit it as `config/mise.config.toml` so the next VM gets identical versions.

## Layout

```
bootstrap.sh                 the script (single file, curl-able)
config/mise.config.toml      pinned mise versions (optional)
.github/workflows/ci.yml     shellcheck + smoke run in Ubuntu/Debian containers
```

## After the first run

```
exec $SHELL -l
gh auth login && gh auth setup-git
atuin register        # or atuin login
claude                # Claude Code login
codex                 # Codex login
sudo tailscale up --ssh         # if TS_AUTHKEY wasn't set
cloudflared tunnel login        # if CF_TUNNEL_TOKEN wasn't set
```

Tighten `PermitRootLogin` to `no` in `/etc/ssh/sshd_config.d/10-bootstrap.conf` once Tailscale SSH is confirmed working.
