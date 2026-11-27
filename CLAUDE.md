# ansible

Personal Ansible config for provisioning/configuring machines: an Ubuntu
server/workstation setup and a macOS workstation setup, one repo, run via
`./run.sh`. See README.md for the full layout description.

## Secrets

- `local/` holds every not-committed-but-critical config file: real
  secrets and router-only config bodies. Nothing an assistant creates
  should ever be written into it except by copying a `.example` file.
- `local/secrets.yml` is gitignored and must never be created or committed
  by an assistant — it holds real host/user-specific values (hostnames,
  webhook URLs, mount paths, etc).
- `local/secrets.yml.example` is the canonical list of every expected key.
  Each entry is commented with the playbook/file(s) that consume it. When a
  change introduces a new secret-derived variable, update this file too.
- For `ubuntu`/`mac`, vars sourced from secrets are only available in plays
  that load them with `vars_files: [../local/secrets.yml]` at play level —
  group_vars files can reference them (e.g. `is_corporate` in
  `mac/group_vars/all.yml` depends on `personal_hostnames` from secrets),
  but the value only resolves in plays that load secrets, due to
  Ansible's lazy variable evaluation.
  - Use `vars_files`, never an `include_vars` task: at `-v` an
    `include_vars` task prints every value it loaded, passwords included,
    and its facts also leak into later plays in the run, hiding a play that
    forgot to load secrets. `vars_files` prints nothing and fails clearly
    when the file is missing (`no_log` on the task would hide that error).
- `openwrt` is the exception: `openwrt/group_vars/all/secrets.yml` is a
  symlink to `../../../local/secrets.yml`, so it's auto-loaded by Ansible's
  normal group_vars mechanism for every host in the play — no
  `vars_files` needed in any `openwrt/*.yml` playbook. This only
  works because every `openwrt` play lives in a file under `openwrt/`,
  which is what fixes the group_vars lookup's base directory to
  `openwrt/group_vars/`.
- Exception: connection vars like `ansible_host` are needed *before* Ansible
  can reach a host, so they can't wait on a play-level var (`vars_files`
  or group_vars) to resolve inside the play that targets it — see
  `openwrt/inventory.yml`'s `add_host` bootstrap below for the pattern used
  when secret data has to become inventory, not just task-level vars.

## Dry-run convention

`ansible.cfg` turns off `display_ok_hosts` and `display_skipped_hosts`, so
output shows only tasks that change something or fail; the default callback
then holds back each task's banner until it has a result worth printing.
When asking the user to paste output, remember that ok and skipped tasks
won't be in it (they can add `ANSIBLE_DISPLAY_OK_HOSTS=true` and
`ANSIBLE_DISPLAY_SKIPPED_HOSTS=true`). Ansible reads only the first config
file it finds, so this one replaces any `~/.ansible.cfg` or
`/etc/ansible/ansible.cfg` when run from the repo root.

Every play has a `name:` of `<dir>/<file>` (e.g. `ubuntu/collectd`), with a
short suffix in brackets when a file has more than one play. With the quiet
output, the `PLAY [...]` banners are what shows progress through a run of
many playbooks, and an unnamed play just prints its host pattern (`all`).

`run.sh` always runs `ansible-playbook -CD <playbook>.yml` (check + diff)
first and prints a reminder to re-run with `-v` to apply. Keep this
"preview by default" behavior in mind when adding tasks:

- `ansible.builtin.command`/`shell`/`uri` tasks are **skipped** under `-C`
  check mode unless `check_mode: false` is set. This repo already forces a
  few tasks to always run (the `uri` release lookups in `ubuntu/pms.yml`,
  the starship release lookup, version check and download in
  `ubuntu/zsh.yml`, the `~/.vim/autoload` folder in `mac/vim.yml` and
  `ubuntu/vim.yml`, the `packaging` bootstrap in `mac/default.yml`, the
  `python3-debian` install in `ubuntu/default.yml`) because later tasks in
  the same play depend on their result to evaluate correctly in check
  mode. Forcing a task like this means it has real side effects even
  during a dry run — only do it for idempotent, non-destructive
  bootstrapping.
  - Referencing a **top-level** field on a skipped task's registered
    result (e.g. `some_command_result.stdout`) is tolerated — Jinja's
    Undefined compares without raising, so `when: x.stdout != "foo"`
    just evaluates true. But **chained/nested** attribute access on a
    skipped `uri` result (e.g. `some_uri_result.json.assets`) raises
    `'dict object' has no attribute ...` immediately, because `.json`
    itself is Undefined and `|selectattr`/further attribute access on
    it isn't tolerated the way a bare comparison is. This is why the
    `uri` release-lookup tasks need `check_mode: false` but the
    `dpkg-query` version-check `command` tasks don't.
  - `get_url` is different again: it already **supports** check mode, so
    it is not skipped — it _simulates_ (reports `changed` without
    writing the file). A later task in the same play that needs the
    real file on disk (e.g. `apt: deb=...` reading the downloaded
    `.deb`) will fail with a missing-file error unless the `get_url`
    task is also forced with `check_mode: false` so the download
    actually happens.
  - For a file `get_url` keeps up to date in place (no `checksum`), a dry
    run always reports a change: check mode sends only a `HEAD` request,
    so it compares the existing file with an empty download. `vim.yml`
    (both platforms) fetches `plug.vim` with `uri` (`check_mode: false`,
    a read) and writes it with `copy: content:`, which compares properly
    in check mode. Registered results aren't templated again, so content
    with `{{` in it is written as is.
  - `deb822_repository` fails outright without `python3-debian` on the
    target, even under `-C` (ansible-core 2.19 has no option to install it
    for you), so `ubuntu/default.yml` installs it with `check_mode: false`.

## Ubuntu apt repositories

- Third-party repos (Docker, Lynis, syslog-ng) use
  `ansible.builtin.deb822_repository` (`.sources` files), not
  `apt_repository` or a copied `.list`. `apt_repository` only reads one-line
  `.list` files, so mixing the two re-creates a `.list` beside the
  `.sources` and apt sees every repo twice — or errors outright if their
  `Signed-By` values differ.
- Give `signed_by` the key's URL: the module downloads it to
  `/etc/apt/keyrings/<name>.asc|.gpg` and pins it to that repo only. Never
  put keys in `/etc/apt/trusted.gpg.d/`, which trusts them for every repo.
- The file names come from `name`, lowercased with `_`/spaces turned into
  `-` (`docker` → `docker.sources`, `/etc/apt/keyrings/docker.asc`).
- There are no cleanup tasks for the old `.list` files or `trusted.gpg.d`
  keys these replaced: the one server they existed on has been migrated.
  A host still carrying them needs them removed by hand (or via
  `apt modernize-sources`), or apt will see those repos twice.

## Agent execution constraints

- Never run `ansible-playbook` yourself — not even a check-mode/dry-run
  (`-C`/`-CD`, `run.sh`'s default). The router and APs aren't reachable from
  this environment, so any invocation just fails or hangs; it also isn't
  your call to make against live network gear. Prepare/edit the playbooks
  and templates, then hand off the exact command for the user to run on a
  host that actually has access.

## Personal scripts in `~/bin` (`ubuntu/scripts.yml`, `mac/scripts.yml`)

- Ubuntu-only scripts live in `ubuntu/files/bin/`; `git-repos-check`, used
  on both, lives in the top-level `files/bin/` (see the shared files section
  below). Each play copies its list to the login user's `~/bin`, which
  `zshrc.j2` puts on the `PATH`. They came from the old `pedbarbosa/scripts`
  repo, which is being retired. Add new ones to the `loop` of the play(s)
  that should get them.
- `~/bin` used to be a symlink to a clone of that repo. Both plays remove the
  symlink (never its target) before creating the real directory. Without
  that, `copy` would follow the link and write into the old clone.
- Shared convention: silent by default except for what's worth a message
  (failures, and the containers `docker-update-all` restarted). `-v` prints
  progress to the console *and* always sends a Slack summary, even when
  there was nothing to do, so it doubles as a Slack connectivity check.
  `-h` prints usage; an unknown option is an error. Exceptions:
  `kodi-library-scan` never uses Slack, and `dhcp-stragglers` is an
  interactive tool whose `-v` means "one field per line".
- They run unattended from cron and report failures through `slack-notify`
  (installed to `/usr/local/bin` by `ubuntu/default.yml` and
  `mac/default.yml`). Cron's `PATH` may not include `/usr/local/bin`, so the
  scripts fall back to that full path.
- `ubuntu/scripts.yml` also owns the login user's crontab entries for
  these scripts (plus server-stack's `update_certs`), via
  `ansible.builtin.cron`. It only manages entries under its own
  `#Ansible: <name>` markers, so don't expect it to remove hand-added lines;
  change a schedule in the play, not with `crontab -e`. Since every job
  reports to Slack itself, no cron line pipes into `slack-notify`.
- On macOS, `mac/scripts.yml` schedules `git-repos-check` with a launchd
  agent (`~/Library/LaunchAgents/local.git-repos-check.plist`, from
  `mac/files/git-repos-check.plist.j2`) rather than cron, because launchd
  runs a job missed during sleep when the Mac wakes. launchd's default `PATH`
  lacks Homebrew, which `slack-notify`'s `python3` (with `requests`) needs,
  so the plist sets `PATH` and passes `dotfile_env`'s proxy/CA variables for
  corporate Macs. A handler reloads the agent (`launchctl bootout` +
  `bootstrap`) when the plist changes. Output goes to
  `~/Library/Logs/git-repos-check.log`.
- `git-repos-check` also runs on macOS, where cron may use `/bin/bash` 3.2:
  no associative arrays, `mapfile` or `${var,,}`, and expand possibly-empty
  arrays under `set -u` as `${a[@]+"${a[@]}"}`. On a Mac, pyenv and rbenv
  come from Homebrew, so their directories aren't git checkouts and the
  script skips them.
- Settings that are private (paths, hostnames) stay out of the scripts:
  `openwrt-backup` sources `~/.openwrt-backup`, which the play renders
  (mode 0600) from `files/openwrt-backup.conf.j2` using `storage_mount` and
  the AP names in `openwrt_ap_hosts`. The router's ssh name is the literal
  `router`, same as `openwrt/inventory.yml`'s `openwrt_hostname`. The
  backup directory itself isn't created by Ansible: the script deliberately
  fails if it's missing, so an unmounted pool doesn't fill the root disk.
- `disk-errors` (every 15 minutes) reads the kernel log through a journal
  cursor in `~/.local/state/disk-errors/cursor`, so each line is reported
  once. journalctl moves the cursor on in a temporary copy, which replaces
  the real one only after Slack accepts the message, so a failed send is
  retried on the next run. `-n` is a dry run that prints the message and
  leaves the cursor alone. Reading the system journal needs the
  `systemd-journal` group, which the play adds. Without it journalctl
  succeeds with no kernel lines, so the script checks its stderr for the
  permissions hint (it doesn't pass `-q`, which hides that hint). Its
  pattern leaves out a bare "SATA link down", which empty ports log at
  every boot.

## Shared files across mac/ubuntu

- When a file is identical (or near-identical) between `mac/` and `ubuntu/`
  playbooks — e.g. `vimrc`, `zshrc.j2` — the canonical copy lives in the
  top-level `files/` directory, not duplicated under `mac/files/` and
  `ubuntu/files/`.
- Reference it with `src: "{{ playbook_dir }}/../files/<name>"`. A plain
  relative `src: files/<name>` resolves against *that play's own*
  `<os>/files/` directory, not the repo-root `files/` — it silently looks
  in the wrong place (or 404s) without the `playbook_dir` prefix.
- If the shared file needs a handful of OS-specific lines (see the
  Mac-only blocks in `files/zshrc.j2`), gate them with a boolean group var
  defined per-OS (e.g. `zsh_is_mac: true`/`false` in
  `mac/group_vars/all.yml` / `ubuntu/group_vars/all.yml`) rather than
  forking the file back into two copies.
- Don't force this pattern onto files that only *look* similar —
  `default.yml`/`python.yml`/`ruby.yml` exist in both `mac/` and `ubuntu/`
  but were deliberately kept separate: different `hosts`/`become` model,
  different package manager (`package` vs `apt`), and mostly
  non-overlapping tasks (ubuntu's is server-hardening, mac's is desktop
  tooling). Merging those would mean threading OS conditionals through
  nearly every task for two playbooks that are conceptually different,
  not the same thing expressed twice.

## OpenWrt playbooks (`openwrt.yml` / `openwrt/`)

- No committed inventory file — `openwrt/inventory.yml` runs first (against
  `localhost`), reads `openwrt_router_host`/`openwrt_ap_hosts` from
  `local/secrets.yml` (auto-loaded, see `## Secrets` above — no
  `vars_files` needed even here), and `add_host`s the router + APs into
  the `openwrt`/`router`/`ap` groups at runtime. This keeps real
  IPs/hostnames out of the repo without a second gitignored file alongside
  `local/secrets.yml`. `group_vars`
  (`all/`, `router.yml`) still apply normally to hosts added this way.
  - The router's hostname is `router` (`openwrt_hostname`, set on the
    device by `openwrt/system.yml`). Only its Ansible *inventory* name is
    `gateway`, which is what plays print (`ok: [gateway]`). Ansible warns
    ("Found both group and host with same name") if a host is added to a
    group sharing its exact name, and the `router` *group* name stays as
    is since `group_vars/router.yml` and the `'router' in group_names`
    checks depend on it. Don't refer to the device itself as `gateway`
    anywhere else. The AP inventory names (from `openwrt_ap_hosts[].name`
    in secrets, e.g. `ap1`) don't collide with the `ap` group name,
    so they're unaffected.
- `openwrt/default.yml` runs an explicit `apk update` as a `pre_task`,
  before the `community.openwrt.init` role. This repo now targets OpenWrt
  25.x, which replaced `opkg` with `apk` — the role detects whichever
  package manager is present (`roles/init/tasks/main.yml` in
  `community.openwrt`) and, on `apk`, its recommended-packages step
  (`packages-apk.yml`, installing `coreutils-base64`/`-md5sum`/`-sha1sum`
  compat shims when `openssl` is missing) does *no* cache-freshness check
  of its own — unlike the old `opkg` path, which had its own (buggy)
  staleness check that could swallow a failed refresh and fail later with a
  confusing "Unknown package" instead of the real cause. Under `apk` the
  explicit `pre_task` is the only thing ensuring the index is fresh before
  that role step runs, so don't drop it thinking the role has it covered.
- `community.openwrt` requires `ansible-core>=2.18` (see its
  `meta/runtime.yml`) — an older `ansible-core` (e.g. some distros' `apt
  install ansible` package) prints a "does not support Ansible version"
  warning but has so far still run correctly; see README for the upgrade
  command if something actually breaks.
- Uses the `community.openwrt` collection (declared in `requirements.yml`), not
  `ansible.builtin`/`community.general` modules — it's shell-based
  (`community.openwrt.apk`/`uci`/`service`/`file`/`command`, etc.) so it
  works without Python installed on the router/APs.
- This is the repo's first external collection. `run.sh` installs
  `requirements.yml` via `ansible-galaxy collection install -r` right after
  ensuring Ansible itself is present (a no-op when already satisfied), so a
  fresh control machine is ready for `openwrt.yml` after one `run.sh`.
  It still doesn't run or otherwise touch `openwrt.yml` (the router/APs
  aren't the machine running Ansible). Any new collection a playbook needs
  goes in `requirements.yml`, not a separate install step.
- When bumping the version pin in `requirements.yml`, check the collection's
  actual GitHub *tags/releases* (or `galaxy.yml` at that tag), not the
  version in its `main` branch's `galaxy.yml` — `main` bumps the version
  ahead of what's published to Galaxy, so pinning to it produces an
  unsatisfiable `ansible-galaxy collection install` requirement.
- Check-mode support varies per module, same "force `check_mode: false` only
  for idempotent bootstrapping" rule as the mac/ubuntu gotcha above:
  `community.openwrt.apk`, `service`, and `file` support check mode fully
  and are left alone; `community.openwrt.command` does not (`check_mode:
  support: none`) and is skipped under `-C` unless forced. `openwrt/default.yml`
  no longer has any `command` tasks — the old `wget`-based `opkg-upgrade`
  bootstrap and its `-f` upgrade step were removed when this repo moved to
  `apk` (OpenWrt 25.x): `apk` has a native `apk upgrade`, but OpenWrt's own
  docs warn against using it for full-system upgrades (it can miss
  dependency/priority handling that Attended Sysupgrade does correctly), so
  there's deliberately no upgrade-all step here — full-system upgrades are
  left to ASU/sysupgrade tooling.
- `community.openwrt.apk`'s `name` argument is `type: str` only (no list
  support like `ansible.builtin.apt`/`package`) — package lists in
  `group_vars` are real YAML lists and get `| join(',')` at the point of use.
- `openwrt/collectd.yml` pushes a single `/etc/config/collectd` rendered from
  `openwrt/files/collectd.conf` via `community.openwrt.template`, rather than
  one `community.openwrt.uci` task per option — same reasoning as the
  mac/ubuntu playbooks' use of `template` over many individual edits: one
  task, a readable whole-file diff under `-D`, and full check-mode support.
  Which plugins render (`conntrack`/`dns`/`thermal` are router-only) is
  driven by `openwrt_collectd_plugins` in `group_vars`, mirroring the
  `openwrt_packages_common`/`openwrt_packages_router` split above — keep
  both splits in sync (a collectd plugin needs its `collectd-mod-*` package
  installed by `openwrt/default.yml` first). The collectd server address
  (`openwrt_collectd_server_host`) lives in `local/secrets.yml`, same as the
  router/AP addresses, since it's also a real network detail.
  `openwrt/files/collectd.conf` itself is kept free of commented-out lines
  (other than the top "file managed" header) since every option in it is
  actually in effect; the stock `collectd-mod-*` package default (all
  plugins disabled, everything else commented out) is kept for reference at
  `openwrt/reference/collectd.conf.upstream-default`, which isn't deployed
  by any playbook.
  - All collectd config stays in that one UCI file: no raw collectd config
    or `Include` directories. `/etc/init.d/collectd` renders each
    `config plugin` section as a bare `LoadPlugin <name>`, so plugins can't
    have their own reporting `Interval` and everything reports on the
    global one (the UCI ping `Interval` option is the time between pings,
    not how often results are reported). The generator also handles
    nested blocks for some plugins natively, e.g. `mqtt` via
    `config mqtt_block` sections.
- `openwrt/system.yml` (`/etc/config/system`) covers hostname, timezone,
  logging, and NTP, all driven by `group_vars` (router vs. AP) same as the
  playbooks above — plus AP-only LED sections, which are genuinely
  per-physical-device rather than per-group. Those are keyed by a `profile`
  field added to each `openwrt_ap_hosts` entry in `local/secrets.yml` (e.g.
  `ap_dual_led`/`ap_wan_led`), which `openwrt/inventory.yml` adds as an
  extra `add_host` group; the actual LED definitions live in a committed
  `openwrt/group_vars/ap_<profile>.yml`. This indirection exists solely so
  real AP names never need to appear in the repo as `host_vars/<name>.yml`
  filenames — adding a new physical AP means adding/reusing a `profile` in
  secrets and, if its hardware is new, a new `ap_<profile>.yml`.
  `zonename` reuses the IANA `timezone` secret from `ubuntu/default.yml`
  (a secret despite being low-sensitivity, per explicit request rather than
  the IP/hostname reasoning above). The POSIX `timezone` string isn't a
  secret of its own: `openwrt_timezone` in `group_vars/all/vars.yml`
  derives it from `timezone` by reading the last line (the POSIX TZ footer)
  of `/usr/share/zoneinfo/<zone>` on the controller via a `pipe` lookup,
  so the two can't drift and DST rules come out right.
- `openwrt/uhttpd.yml` (`/etc/config/uhttpd`) is a single static template
  (`openwrt/files/uhttpd.conf`, no per-host variables) since the only
  difference across the router/APs was the cert `defaults` section's `days`
  value — and that section is dropped entirely rather than templated, since
  these devices don't generate their own certs; Let's Encrypt certs are
  injected via a separate cron process outside Ansible's management.
- `openwrt/luci.yml` (`/etc/config/luci`) is likewise a single static
  template (`openwrt/files/luci.conf`) — identical across the router and
  both APs, no group/host variation at all. No restart handler: LuCI reads
  this config live per-request rather than via a long-running service.
- `openwrt/dropbear.yml` (`/etc/config/dropbear`) is also a single static
  template (`openwrt/files/dropbear.conf`), identical across all hosts —
  restarts `dropbear` on change, since (unlike LuCI) it's a long-running
  daemon that needs to reload for e.g. a `Port` change to take effect.
- `openwrt/attendedsysupgrade.yml` (`/etc/config/attendedsysupgrade`) is
  likewise a single static template (`openwrt/files/attendedsysupgrade.conf`),
  identical across all hosts. No restart handler: like LuCI, ASU/`owut` only
  run on demand rather than as a long-running daemon.
- `openwrt/adblock.yml` (`/etc/config/adblock`) targets `hosts: router`
  directly (not `openwrt` gated by a `group_names` check) since it's the
  only file so far that doesn't apply to the APs at all. `adb_mailreceiver`/
  `adb_mailsender` are `admin@{{ domain }}`/`router@{{ domain }}`, using the
  shared `domain` secret (also used by `banip.yml` and `dhcp.yml`; it was
  first added for the since-removed collectd Apache plugin) rather than
  adding a new one, per explicit request.
- `openwrt/banip.yml` (`/etc/config/banip`) is router-only (same `hosts:
  router` / `domain`-secret reasoning as `openwrt/adblock.yml` above).
- `openwrt/blocklists_mqtt.yml` (router only) installs `blocklists-mqtt`, a
  procd service with two instances. `watch` publishes Home Assistant MQTT
  discovery (`switch.router_adblock`, `switch.router_banip` and their
  `sensor.router_*_blocked` counts) and each service's state to
  `router/<svc>/state`, then uses `inotifywait` on `/var/run/adblock` and
  `/var/run/banIP` to republish whenever a runtime JSON is rewritten. There's
  no polling: both services rewrite that file on every start, stop, reload,
  suspend and resume, whoever triggers it. `listen` subscribes to
  `router/<svc>/set` and runs `adblock suspend`/`resume` and `banip
  stop`/`start`, and to
  `homeassistant/status`, republishing everything when HA comes back online in
  case the broker lost its retained messages. A switch command is
  acknowledged at once: `request()` records it in
  `/var/run/blocklists-mqtt/<svc>` and publishes the requested state with
  status `switching`, and `publish()` keeps reporting that, ignoring the
  services' in-between states, until the service reaches it or 90s pass
  (then it reports the real state). Without this, HA's toggle bounces back
  after ~2s while adblock resumes or banIP loads. "Off" is deliberately temporary
  (a reboot or the daily cron reload can turn them back on). The script and init file are deployed
  with `community.openwrt.copy`, not `template`, because the script holds Home
  Assistant's own `{{ value_json... }}` templates; only
  `/etc/blocklists-mqtt.conf` (broker and credentials, mode 0600) is a
  template. It reuses collectd's broker and MQTT user
  (`openwrt_collectd_mqtt_host`/`_user`/`_password`): a separate user would
  isolate nothing, since both credentials live in plaintext on the same router.
  On a first check-mode run the init script's `copy` only simulates, so the
  `service` module would fail with "does not exist". A `stat` of
  `/etc/init.d/blocklists-mqtt` gates the service task and the restart handler
  (`when: not ansible_check_mode or blocklists_mqtt_init.stat.exists`), so the
  preview skips them cleanly instead of failing.
- `openwrt/firewall.yml` (`/etc/config/firewall`) is the one file so far
  split by content sensitivity rather than by host group: the AP zones are
  identical/simple enough to commit directly in
  `openwrt/files/firewall.conf` (a `{% if 'router' in group_names %}`
  branch), but the router's actual zones/rules/port-forwards are too
  revealing of the internal network to commit even sanitised — so that
  entire file's content lives verbatim in `local/router-firewall.conf`
  (gitignored, `local/router-firewall.conf.example` has the format), pulled
  in with `{{ lookup('file', '../local/router-firewall.conf') }}` inside
  the `{% if 'router' in group_names %}` branch. It's a plain UCI text file
  rather than a YAML var on purpose, for two reasons: it's a separate
  concern from `local/secrets.yml` (which covers individual private
  *values* —
  IPs, hostnames — plugged into otherwise-committed templates, whereas this
  is a whole config *body* describing the network's structure and exposed
  services), and — the bigger reason — a YAML block scalar forces every
  line to carry both the YAML indent *and* the real UCI tab, which drifted
  out of sync with what LuCI itself writes back to the device (LuCI
  regenerates these files with zero indent on `config` lines and exactly
  one tab on `option`/`list` lines). A flat file holding raw UCI text can
  be copied in from the device (or from LuCI's own output) with no
  translation step, so it can't drift.
- `openwrt/dhcp.yml` (`/etc/config/dhcp`) covers `dnsmasq`/`dhcp`/`odhcpd`
  sections, branched on `'router' in group_names` inside
  `openwrt/files/dhcp.conf` — the router runs the actual DHCP server (`lan`/
  `iot`/`wan` sections, `authoritative`/`sequential_ip`/`nonegcache`) and is
  the only host authorised to answer DNS or DHCP. APs are fully passive:
  `option port '0'` disables dnsmasq's own resolver (it previously marked
  `/lan/` as a strictly-local domain via `option local`, which made it
  NXDOMAIN local hostnames it had no records for instead of forwarding them —
  the router is now the sole DNS answerer), and both `lan` and `iot` sections
  carry `ignore '1'`/`ra 'disabled'`/`dhcpv6 'disabled'` so DHCP for both
  VLANs is fully delegated to the router and IPv6 RA/DHCPv6 stay off
  network-wide (APs no longer run their own independent
  `ra`/`dhcpv6`/`ra_slaac` server as they did before). `domain` is the
  same `domain` secret reused by `openwrt/adblock.yml`/`banip.yml`. Since the
  template neuters both daemons everywhere except the router's dnsmasq,
  `openwrt/dhcp.yml` also disables the now-useless services outright rather
  than leaving do-nothing daemons running: `odhcpd` is stopped and disabled
  unconditionally on every host (IPv6/`maindhcp` are off everywhere, so it
  has nothing left to do anywhere), and `dnsmasq` is stopped and disabled on
  APs specifically (`'router' not in group_names`) — the restart handler for
  `dnsmasq` is likewise gated to `'router' in group_names` only. The template
  also has a `local/router-dhcp-extra.conf` hook
  (read via `lookup('file', ..., errors='ignore')`, so a missing file just
  renders as empty — appended verbatim after `odhcpd` with a blank line
  before it) for the router's `config domain`/`config host` static-lease
  entries — not yet populated, but reserved so they can go straight into
  that file (same reasoning as `local/router-firewall.conf`: real internal
  hostnames, too
  revealing to commit, and plain UCI text so there's no YAML-indentation
  drift against what LuCI writes) without touching the template again.
- `openwrt/network.yml` (`/etc/config/network`) breaks from every other
  OpenWrt playbook's structure: instead of one `group_names`-branched
  template, each device profile gets its own plain file under
  `openwrt/files/` (`network.router.conf`/`network.ap_dual_led.conf`/
  `network.ap_wan_led.conf`, three separate `hosts:` plays targeting the
  `router`/`ap_dual_led`/`ap_wan_led` groups) because the physical
  port/switch layout genuinely differs per hardware model — the
  `ap_dual_led` profile trunks a single `eth0`, `ap_wan_led` repurposes its
  `wan` port into the VLAN trunk, the router fans out across 5 ports — not
  just router-vs-AP the way `dhcp.conf`/`firewall.conf` do. It targets the
  same `ap_dual_led`/`ap_wan_led` profile groups `openwrt/system.yml` uses
  for LEDs, never a specific AP's inventory hostname — that name is
  whatever's set in `local/secrets.yml`'s `openwrt_ap_hosts[].name` and must
  never be hardcoded here. `host` on
  each `openwrt_ap_hosts` entry (and `openwrt_router_host`) now does double
  duty as `ansible_host` *and* the `lan` interface's `ipaddr` in these
  templates, so it must be the device's real static LAN IP, not just
  whatever address ansible happens to reach it on — keep that in sync if
  either ever changes. IPv6 is disabled network-wide via `option ipv6 '0'`
  on every bridge `device` section (the router's `wan` interface disables it
  too, since it's PPPoE not a bridge). No restart handler, unlike every
  other playbook here: a bad bridge/VLAN/IP push can sever SSH/LuCI access
  to the device outright, so this only ever stages the file — apply by
  hand, one device at a time, with console/physical access on standby.
- `openwrt/wireless.yml` (`/etc/config/wireless`) splits the file by what
  varies. The `wifi-device` sections depend on the hardware (path, band,
  htmode, txpower), so each group defines `openwrt_wifi_radios` in its own
  group_vars (`router.yml`, `ap_<profile>.yml`). The `wifi-iface`
  sections must be the same everywhere for roaming, so they're defined once
  in `openwrt_wifi_ifaces` (`group_vars/all/vars.yml`), with SSIDs, keys,
  the 802.11r mobility domain and the country code from `local/secrets.yml`.
  - Each iface lists the `bands` it's on, and the template puts it on every
    radio with that band. It matches by band, not by radio name, because
    `radio0` isn't the 2.4 GHz radio on every device. Section names are
    `<iface>_<radio>` (e.g. `default_radio1`), unless the radio's
    `iface_sections` maps the iface to the name LuCI already gave it on that
    device (the router's IoT SSID stays `wifinet4`). Only the label changes,
    since nothing else refers to these sections, but keeping it gives a
    clean diff against the device.
  - The template writes sections in LuCI's order, also for a clean diff:
    SSIDs in `openwrt_wifi_ifaces` order, each radio's `wifi-device` just
    before its first SSID, and radios without SSIDs at the end. On the
    router that puts `wifinet4` last, where LuCI appended it. Within a
    radio, SSIDs keep the same relative order either way, so the
    `phyN-apM` interface names don't change.
  - Option order within a section follows LuCI too. SSIDs OpenWrt set up
    itself (`default_radio*`) have `network` right after `device`, while
    ones added in LuCI (`wifinet4`) have it last, after `key`. The
    iface's `network_last: true` picks the second order.
  - The router's file was matched exactly, but the APs' weren't. LuCI left
    each AP with its own option and section order (e.g. `band` before
    `channel`, `network` after `mode`), and matching that would take a
    per-device flag for almost every option. The APs were reordered once on
    their first run instead. uci keeps the existing order when LuCI edits a
    section, so it stays stable afterwards. Don't add more order flags for
    the APs.
  - `nasid` (802.11r NAS ID) is the same on every device, so it's one
    map by band, `openwrt_wifi_nasid` in `group_vars/all/vars.yml`. Its
    values reuse the SSID secrets (2g: LAN SSID, 5g: IoT SSID), because
    that's what the devices were already set to. NAS IDs don't need to
    differ between APs here: with `ft_psk_generate_local` each AP derives
    the roaming keys from the PSK itself. It's rendered just above
    `mobility_domain`, on roaming ifaces only. A radio whose band isn't in
    the map is a template error.
  - A host with no `openwrt_wifi_radios` stops at a `meta: end_host`, so the
    playbook never pushes a file with no radios (which would wipe its wifi).
    Adding an AP means adding its radios to its `ap_<profile>.yml`.
  - The task has `no_log: true` because the file holds the keys. That also
    hides the `-D` diff, same as `network.yml`'s router task.
  - The file is `0600`, unlike OpenWrt's default `0644`, because it holds
    the keys.
  - No restart handler: `wifi reload` is `ubus call network reload`, a full
    netifd reload that would also apply any `/etc/config/network` change
    `network.yml` staged in the same run. Run `wifi reload` by hand.
- `openwrt/rc_local.yml` (`/etc/rc.local`, router only) carries
  `ethtool -K eth0 rx-gro-list off`, the fix for the router's tx/rx queues
  stalling on every core and on eth0/eth1. Turning off tso/gso/gro and
  irqbalance didn't help, so they're left out (irqbalance stays off, since
  `packet_steering '2'` in `network.router.conf` already spreads the load).
  `ethtool` is in `openwrt_packages_router`. The file is static and
  deployed with `copy`. On change, a handler runs it straight away with
  `community.openwrt.command`, which a dry run skips. Keep everything in
  `rc.local` safe to run twice for that reason.
- snapraidd's `notify_result` (`ubuntu/files/snapraidd.conf`) is
  `snapraidd-notify --narrow`, installed to `/usr/local/bin` by
  `ubuntu/pms.yml`. snapraidd sends a report every time a SMART attribute's
  normalised value changes, and Spin_Up_Time changes on every spin-up, so
  with `spindown_idle_minutes` set it posted several times a day. The filter
  drops a report only when it is nothing but `IGNORED` attribute changes on
  a nominal array (no sync, scrub or error section), with the value at or
  above `MIN_NORM`. Anything else goes to `slack-notify`, including reports
  it can't parse and any it fails on. `--narrow` pins the layout it parses
  (snapraidd strips the flag before running the command).
- `ubuntu/tools/unmanaged-config` (not installed anywhere, run from the
  clone on the server) lists what was set up by hand and isn't in the
  ubuntu playbooks: hand-added crontab lines, systemd units and config files
  no package installed, changed package conffiles, packages installed by
  hand, home dotfiles, mounts, users and groups. It parses the playbooks to
  skip what they manage, so keep it in step when adding a module type that
  deploys files. It's read-only and redacts its output (secrets.yml and
  server-stack `.env` values, host/user names, IPs, MACs, UUIDs, tokens).
  - It skips dotfiles identical to `/etc/skel`'s and those in
    `DOTFILE_IGNORE` (kept out of Ansible on purpose, e.g. `.videolib.yml`),
    and users and groups any `user`/`group` task names.
  - Mounts are compared with `ubuntu/reference/fstab`, which it renders with
    secrets.yml. Update that file when a disk is added or replaced: no
    playbook deploys fstab.
- Tasks that change config with a `command` (or anything the tool doesn't
  parse) aren't seen as managing a file, so prefer `copy`/`template` with
  the known result: `/etc/docker/daemon.json` is copied with what
  `nvidia-ctk runtime configure --runtime=docker` writes, rather than
  running it.
- `ubuntu/dotfiles.yml` reads `MYSQL_ROOT_PASSWORD` from
  `~/git/server-stack/.env` on the server for `~/.my.cnf`, so the password
  lives in one place and not in secrets.yml. The extraction avoids regex
  backreferences, so there's no YAML-plus-Jinja backslash escaping to get
  right. `no_log` hides those tasks' diffs.
- `ubuntu/trcc.yml` installs `trcc-linux` from its latest GitHub release
  (the plain `_all.deb`; the `.legacy` one is for Ubuntu 24.04 and older)
  and runs `trccd` as a systemd user unit. That needs lingering
  (`loginctl enable-linger`) and the user in the package's `trcc` group,
  since udev's `uaccess` only covers a local seat. The lingering user
  manager keeps the groups it started with, so adding the group notifies a
  handler that restarts `user@<uid>.service`; without it `trccd` finds no
  device. Releases before the group existed didn't create it, so a dry run
  checks for it with `getent` before adding the user.
- `openwrt/tools/dhcp-stragglers` is a standalone Python 3 script (stdlib
  only), not a playbook. `ubuntu/scripts.yml` copies it into `~/bin` on
  Ubuntu and installs `nmap` for it, so edit it here, not the copy. It runs a BusyBox `sh` heredoc on the router over
  `ssh <host> sh -s` to list MACs in the neighbour table or lease file that
  have no `config host`/`/etc/ethers` entry. Then, from the local machine,
  it adds the MAC vendor (offline, nmap's or ieee-data's OUI list), reverse
  DNS and an nmap scan. Nothing is sent to outside services.
  - The router-side part has to stay BusyBox-compatible: no `<(...)`, and
    no awk variable named `exp` (a built-in function).
  - The lease file's first field is the lease *expiry*, not when it was
    handed out.
  - IoT vendors (`IOT_VENDORS`) override the ping-TTL OS guess: some ESP8266
    firmware uses TTL 128, which the TTL heuristic reads as Windows.
  - `--uci` writes only UCI to stdout and notes to stderr, so it can be
    appended straight to `local/router-dhcp-extra.conf`. That file is copied
    verbatim to the router, and LuCI drops comments when it saves, so
    comments in it would show up as drift. Randomised MACs are skipped, since
    a static lease on one can stop matching.
  - `--uci` doesn't keep a device's current address, which comes from the
    dynamic pool. It assigns the next free one in `--static-range` (default
    `.80`-`.99`) on the same /24. "Free" means not in any `config host`,
    `/etc/ethers`, neighbour entry, router interface or lease. It also warns
    if the range overlaps a pool. A pool runs from `start` to
    `start + limit - 1`: `limit` is a count, so start 100 with limit 150 is
    `.100`-`.249`.

## Gotchas learned the hard way

- **`is defined` doesn't catch a missing secret one level down.** If a
  var's value is a template referring to a missing var (e.g. a dict entry
  `nasid: "{{ some_missing_secret }}"`), Ansible treats the value as
  undefined, so `x.nasid is defined` is just false and the option is
  silently dropped. This happened with an AP's NAS ID. To make a missing
  secret fail the run, check for the key (`'nasid' in x`) or render the
  value unconditionally.

- **zsh's builtin `printf` is not bash's/coreutils' `printf`.** In zsh,
  `printf "%d" some_bareword` evaluates `some_bareword` as an arithmetic
  expression (so a variable name resolves to its value with no `$`
  needed). This is why `zsh_timer()` in `files/zshrc.j2` can do
  `printf "%02d" zsh_timer_counter` without a `$`. When checking shell
  semantics for `.zshrc`/zsh scripts in this repo, verify against a real
  `zsh -c '...'` invocation — the sandbox's default shell for testing
  commands is bash, and bash/coreutils `printf` behaves differently here.

- **Jinja `and`/`or` in a `when:` don't lazily skip a raising operand.**
  `A or B` evaluates `A` first regardless of whether `B` alone would make
  the condition true; if `A` itself raises (e.g. `x is version(y, '<')`
  when `x` is `""`, which errors with "Input version value cannot be
  empty" rather than just returning false), the whole expression blows
  up before `B` is ever considered. Order the operand that's safe on
  empty/missing input first (`x == "" or x is version(y, '<')`), not
  last, so it actually short-circuits.

## Response style

- Keep answers concise by default — state the change/result directly,
  skip preamble and restating the request. Expand into a fuller
  explanation only when the user asks for one (e.g. "explain", "why",
  "walk me through") or when a decision genuinely needs the user's input
  (e.g. a destructive action, an ambiguous playbook change, secrets
  handling) — those still warrant a full question, not a clipped one.

## Commit/PR style

- One commit per logical fix, not squashed — makes review and future
  `git blame` easier on a repo this size.
- Branches follow `pb/YYYYMMDD_description`.
- PRs are opened against `main` with `gh pr create`.
