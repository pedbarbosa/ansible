# ansible

Personal Ansible configuration for provisioning and configuring machines — an Ubuntu server/workstation setup and a macOS workstation setup, kept in one repo.

## Layout

- `run.sh` — bootstrap + entry point for **both Ubuntu and macOS**. Installs Ansible if missing (via `apt` on Ubuntu, via Homebrew on macOS — installing Homebrew itself first if it's missing), sets up an SSH key and adds it to `authorized_keys`, registers `127.0.0.1` as an Ansible host, grants the current user passwordless sudo, then runs the OS-appropriate playbook (`ubuntu.yml` or `mac.yml`) in check mode (dry run).
- `ubuntu.yml` / `ubuntu/` — playbooks for Ubuntu: base packages & OS hardening, Python (via `pyenv`), Ruby (via `rbenv`), Docker, Samba, security tooling (`lynis`, `fail2ban`, `auditd`, sysctl/limits hardening), `syslog-ng`, `collectd` monitoring, `logrotate`, Vim (`vim-plug`), and Zsh (`oh-my-zsh`, Powerlevel10k, `fzf`).
- `mac.yml` / `mac/` — playbooks for macOS: base packages (via Homebrew), `.gitconfig`, Python, Ruby, Vim, and Zsh.
- `files/` — shared assets deployed on both platforms (`vimrc`, `zshrc.j2`, and the `slack-notify` script installed to `/usr/local/bin/slack-notify` for posting messages to a Slack incoming webhook).
- `secrets.yml` — **not committed** (see `.gitignore`); holds host/user-specific values referenced by several playbooks (e.g. `main_user_account` for Zsh/Samba, `collectd` server settings, the `slack_notify_webhook_url` used by `default.yml` on both platforms). See `secrets.yml.example` for the full list of expected keys and their format — copy it to `secrets.yml` and fill in real values before running playbooks that `include_vars` it.

## Usage

```
./run.sh
```

On Ubuntu this installs Ansible via `apt` if missing; on macOS it installs Homebrew (if missing) and then Ansible via `brew`. Either way, `run.sh` then bootstraps the machine and does a dry run (`ansible-playbook -CD ubuntu.yml` / `mac.yml`), printing a diff of what would change. To actually apply the changes:

```
ansible-playbook -v ubuntu.yml   # Ubuntu
ansible-playbook -v mac.yml      # macOS
```
