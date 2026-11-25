# ansible

Personal Ansible configuration for provisioning and configuring machines — an Ubuntu server/workstation setup and a macOS workstation setup, kept in one repo.

## Layout

- `run.sh` — bootstrap + entry point for **both Ubuntu and macOS**. Installs Ansible if missing (via `apt` on Ubuntu, via Homebrew on macOS — installing Homebrew itself first if it's missing), installs the collections in `requirements.yml` (currently just `community.openwrt`), sets up an SSH key and adds it to `authorized_keys`, registers `127.0.0.1` as an Ansible host, grants the current user passwordless sudo, then runs the OS-appropriate playbook (`ubuntu.yml` or `mac.yml`) in check mode (dry run).
- `ubuntu.yml` / `ubuntu/` — playbooks for Ubuntu: base packages & OS hardening, Python (via `pyenv`), Ruby (via `rbenv`), Docker (plus the NVIDIA driver and container toolkit on hosts with an NVIDIA GPU), Samba (and the shares' group), `.gitconfig` and `.my.cnf` (whose password comes from server-stack's `.env`), `trcc-linux` and its daemon for the CPU cooler's LCD, security tooling (`lynis`, `fail2ban`, `auditd`, sysctl/limits hardening), `syslog-ng`, `collectd` monitoring, `logrotate`, Vim (`vim-plug`), Zsh (`oh-my-zsh`, Starship, `fzf`), and personal scripts in `~/bin` (from `ubuntu/files/bin/`: `docker-update-all` to update the server-stack containers, `kodi-library-scan` to start a Kodi library scan, `openwrt-backup` to back up the router and APs, `snap-clean`, plus `git-repos-check` from `files/bin/`, which fast-forwards the oh-my-zsh, fzf, pyenv and rbenv checkouts, and `dhcp-stragglers` from `openwrt/tools/`), along with the user crontab entries that run them.
- `mac.yml` / `mac/` — playbooks for macOS: base packages (via Homebrew), `.gitconfig`, Python, Ruby, Vim, Zsh, and `git-repos-check` in `~/bin` (run daily by a launchd agent).
- `openwrt.yml` / `openwrt/` — playbooks for the OpenWrt router + APs: package management (upgrade + shared/router-only package sets), `collectd` monitoring, `/etc/config/system` (hostname, timezone, logging, NTP, AP LEDs), `/etc/config/uhttpd` (LuCI web server; cert generation excluded — certs are injected via a separate Let's Encrypt cron process), `/etc/config/luci` (LuCI web UI settings, identical across all hosts), `/etc/config/dropbear` (SSH daemon, identical across all hosts), `/etc/config/adblock`/`/etc/config/banip` (router only), `blocklists-mqtt` (router only: adblock/banIP status, counts and on/off switches for Home Assistant over MQTT), `/etc/config/firewall` (AP zones committed directly; the router's zones/rules/port-forwards live in `local/router-firewall.conf` since they're too revealing to commit even sanitised), `/etc/config/dhcp` (dnsmasq/odhcpd; router-vs-AP structure driven by `group_vars`, with a `local/router-dhcp-extra.conf` hook reserved for the router's static DHCP leases), and `/etc/config/network` (VLANs/bridges/WAN; one template per device profile under `openwrt/files/` — `network.router.conf` / `network.ap_dual_led.conf` / `network.ap_wan_led.conf`, targeted by the same profile groups used for LEDs, never a hardcoded AP hostname — since the physical port layout differs per hardware model, not just router-vs-AP; deliberately has no restart handler, see `openwrt/network.yml`), and `/etc/config/wireless` (radios defined per hardware model in `group_vars`, SSIDs and keys shared by every device for 802.11r roaming; hosts without radio definitions are skipped, and like `network.yml` it has no restart handler), and `/etc/rc.local` (router only: the `ethtool` workaround for the router's tx/rx queue hangs), via the `community.openwrt` collection.
- `files/` — shared assets deployed on both platforms (`vimrc`, `zshrc.j2`, `gitconfig.j2`, and the `slack-notify` script installed to `/usr/local/bin/slack-notify` for posting messages to a Slack incoming webhook).
- `local/` — holds every not-committed-but-critical config file (see `.gitignore`); each real file has a committed `.example` counterpart documenting its format.
  - `local/secrets.yml` — host/user-specific values referenced by several playbooks (e.g. `main_user_account` for Zsh/Samba, `collectd` server settings, the `slack_notify_webhook_url` used by `default.yml` on both platforms, and the router/AP addresses used by `openwrt/inventory.yml`). See `local/secrets.yml.example` for the full list of expected keys and their format — copy it to `local/secrets.yml` and fill in real values before running playbooks that read it (via play-level `vars_files` for `ubuntu`/`mac`, which never print the values; auto-loaded for `openwrt` via a `group_vars/all/secrets.yml` symlink).
  - `local/router-firewall.conf` / `local/router-dhcp-extra.conf` — plain UCI text files holding router-only config bodies too revealing of the internal network to commit even sanitised, read verbatim via `lookup('file', ...)` by `openwrt/firewall.yml` and `openwrt/dhcp.yml` respectively. Separate from `secrets.yml` since it's whole config bodies rather than individual private values, and plain UCI text (not YAML) so there's no indentation translation step to clash with what LuCI itself writes back to the device — see `local/router-firewall.conf.example` / `local/router-dhcp-extra.conf.example` for the format.
- `ubuntu/reference/` — files kept for reference and not deployed: the server's `fstab`, with secrets.yml keys in place of its mount points.

## Usage

```
./run.sh
```

On Ubuntu this installs Ansible via `apt` if missing; on macOS it installs Homebrew (if missing) and then Ansible via `brew`. Either way, `run.sh` then bootstraps the machine and creates a `local/secrets.yml` with local configuration. This file must be updated before running Ansible for the first time! Once ready, apply changes with:

```
ansible-playbook -v ubuntu.yml   # Ubuntu
ansible-playbook -v mac.yml      # macOS
```

### OpenWrt

`run.sh` doesn't configure the router/APs — they're remote devices, not the machine running Ansible — but it does install the `community.openwrt` collection from `requirements.yml` that these playbooks need. There's no committed inventory file either: `openwrt/inventory.yml` reads the router/AP addresses out of `local/secrets.yml` and registers them via `add_host` at runtime, so network topology never lands in the repo. After `run.sh`, run directly:

```
ansible-playbook -CD openwrt.yml   # dry run
ansible-playbook -v openwrt.yml    # apply
```

`community.openwrt` requires `ansible-core>=2.18`; if `ansible --version` reports older (e.g. the `apt install ansible` package on some Ubuntu releases ships 2.16), you'll get a "does not support Ansible version" warning. It may still run, but isn't tested by the collection at that version — upgrade with `python3 -m pip install --user "ansible-core>=2.18"` (or `pipx`) if you hit real breakage.

Hardware that differs per-AP (currently just LEDs, in `openwrt/system.yml`) is selected by a `profile` field on each `openwrt_ap_hosts` entry in `local/secrets.yml`, matched against `openwrt/group_vars/ap_<profile>.yml` — this keeps real AP names out of the repo while still letting each physical device get its own config.

`openwrt/firewall.yml` also needs `local/router-firewall.conf` (copy `local/router-firewall.conf.example` and fill it in) — the router's actual firewall rules are kept out of the repo entirely, separately from `local/secrets.yml`.

`openwrt/tools/dhcp-stragglers` (run from the Ansible machine, not by any playbook) lists devices the router can see that have no static DHCP lease, with a quick look at each: router ping and neighbour state, lease, MAC vendor, reverse DNS, and an nmap scan of common ports (`-v` for one field per line, `-O` for nmap OS detection via sudo). `--uci` prints `config host` blocks for `local/router-dhcp-extra.conf` instead: `openwrt/tools/dhcp-stragglers --uci >> local/router-dhcp-extra.conf`. Each device gets the next free address in a static range outside the DHCP pool (default `.80`-`.99`, `--static-range A-B`), and moves there at its next renewal. It needs `ssh router` to work and `nmap` installed (in `ubuntu/default.yml`).

`openwrt/network.yml` pushes `/etc/config/network` but never restarts anything — a bad bridge/VLAN/IP push there can sever SSH/LuCI access to the device outright, so it's applied by hand, one device at a time, with console/physical access on standby (e.g. `uci commit network && /etc/init.d/network reload`, or a reboot).

To run a single OpenWrt config playbook instead of the full `openwrt.yml` chain, pass `inventory.yml` first — it's what builds the router/AP hosts for that run, so `dhcp.yml` (etc.) on its own would match no hosts:

```
ansible-playbook -CD openwrt/inventory.yml openwrt/dhcp.yml   # dry run
ansible-playbook -v openwrt/inventory.yml openwrt/dhcp.yml    # apply
```
