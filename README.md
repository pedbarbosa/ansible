# ansible

Personal Ansible configuration for provisioning and configuring machines — an Ubuntu server/workstation setup and a macOS workstation setup, kept in one repo.

## Layout

- `run.sh` — bootstrap + entry point for **both Ubuntu and macOS**. Installs Ansible if missing (via `apt` on Ubuntu, via Homebrew on macOS — installing Homebrew itself first if it's missing), sets up an SSH key and adds it to `authorized_keys`, registers `127.0.0.1` as an Ansible host, grants the current user passwordless sudo, then runs the OS-appropriate playbook (`ubuntu.yml` or `mac.yml`) in check mode (dry run).
- `ubuntu.yml` / `ubuntu/` — playbooks for Ubuntu: base packages & OS hardening, Python (via `pyenv`), Ruby (via `rbenv`), Docker, Samba, security tooling (`lynis`, `fail2ban`, `auditd`, sysctl/limits hardening), `syslog-ng`, `collectd` monitoring, `logrotate`, Vim (`vim-plug`), and Zsh (`oh-my-zsh`, Powerlevel10k, `fzf`).
- `mac.yml` / `mac/` — playbooks for macOS: base packages (via Homebrew), `.gitconfig`, Python, Ruby, Vim, and Zsh.
- `openwrt.yml` / `openwrt/` — playbooks for the OpenWrt router + APs: package management (upgrade + shared/router-only package sets) and `collectd` monitoring, via the `community.openwrt` collection. Individual configuration (DNS, firewall, VLANs, wifi) will follow.
- `files/` — shared assets deployed on both platforms (`vimrc`, `zshrc.j2`, and the `slack-notify` script installed to `/usr/local/bin/slack-notify` for posting messages to a Slack incoming webhook).
- `secrets.yml` — **not committed** (see `.gitignore`); holds host/user-specific values referenced by several playbooks (e.g. `main_user_account` for Zsh/Samba, `collectd` server settings, the `slack_notify_webhook_url` used by `default.yml` on both platforms, and the router/AP addresses used by `openwrt/inventory.yml`). See `secrets.yml.example` for the full list of expected keys and their format — copy it to `secrets.yml` and fill in real values before running playbooks that `include_vars` it.

## Usage

```
./run.sh
```

On Ubuntu this installs Ansible via `apt` if missing; on macOS it installs Homebrew (if missing) and then Ansible via `brew`. Either way, `run.sh` then bootstraps the machine and does a dry run (`ansible-playbook -CD ubuntu.yml` / `mac.yml`), printing a diff of what would change. To actually apply the changes:

```
ansible-playbook -v ubuntu.yml   # Ubuntu
ansible-playbook -v mac.yml      # macOS
```

### OpenWrt

`run.sh` doesn't cover the router/APs — they're remote devices, not the machine running Ansible. There's no committed inventory file either: `openwrt/inventory.yml` reads the router/AP addresses out of `secrets.yml` and registers them via `add_host` at runtime, so network topology never lands in the repo. Install the collection once, then run directly:

```
ansible-galaxy collection install -r requirements.yml
ansible-playbook -CD openwrt.yml   # dry run
ansible-playbook -v openwrt.yml    # apply
```

`community.openwrt` requires `ansible-core>=2.18`; if `ansible --version` reports older (e.g. the `apt install ansible` package on some Ubuntu releases ships 2.16), you'll get a "does not support Ansible version" warning. It may still run, but isn't tested by the collection at that version — upgrade with `python3 -m pip install --user "ansible-core>=2.18"` (or `pipx`) if you hit real breakage.
