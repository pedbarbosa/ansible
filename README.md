# ansible

Personal Ansible configuration for provisioning and configuring machines — an Ubuntu server/workstation setup and a macOS workstation setup, kept in one repo.

## Layout

- `run.sh` — bootstrap + entry point for **Ubuntu**. Installs Ansible if missing, sets up an SSH key and adds it to `authorized_keys`, registers `127.0.0.1` as an Ansible host, grants the current user passwordless sudo, then runs `ubuntu.yml` in check mode (dry run).
- `ubuntu.yml` / `ubuntu/` — playbooks for Ubuntu: base packages & OS hardening, Python (via `pyenv`), Ruby (via `rbenv`), Docker, Samba, security tooling (`lynis`, `fail2ban`, `auditd`, sysctl/limits hardening), `syslog-ng`, `collectd` monitoring, `logrotate`, Vim (`vim-plug`), and Zsh (`oh-my-zsh`, Powerlevel10k, `fzf`).
- `mac.yml` / `mac.md` / `mac/` — playbooks for macOS: base packages (via Homebrew), `.gitconfig`, Python, Ruby, Vim, and Zsh. Run manually following the steps in `mac.md` (there is no `run.sh` equivalent for macOS).
- `files/` — shared dotfiles templated onto both platforms (`vimrc`, `zshrc.j2`).
- `secrets.yml` — **not committed** (see `.gitignore`); holds host/user-specific values referenced by several playbooks (e.g. `main_user_account` for Zsh, Samba share config, `collectd` server settings). Create this file locally before running the playbooks that `include_vars` it.

## Usage

### Ubuntu

```
./run.sh
```

This bootstraps the machine and does a dry run (`ansible-playbook -CD ubuntu.yml`), printing a diff of what would change. To actually apply the changes:

```
ansible-playbook -v ubuntu.yml
```

### macOS

See `mac.md` — install Homebrew and Ansible, then:

```
ansible-playbook -CD mac.yml   # dry run
ansible-playbook -v mac.yml    # apply
```
