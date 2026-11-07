# orbvm — OrbStack VMs on Tailscale

Spin up Linux VMs in OrbStack that are reachable from anywhere on your Tailscale
tailnet. Each VM joins the tailnet as its own node (with **Tailscale SSH**, so no
SSH keys to manage), comes with **Node (via nvm) + git + Claude Code + zsh/Oh My
Zsh + tmux** preinstalled, and can serve test sites privately over HTTPS.

## One-time setup

1. **Tailscale auth key.** Generate a **reusable + ephemeral** key at
   <https://login.tailscale.com/admin/settings/keys>. Ephemeral means a
   deleted/stopped VM drops off your tailnet automatically. Store it:

   ```bash
   mkdir -p ~/.config/orbvm
   printf '%s' 'tskey-auth-xxxxxxxxxxxx' > ~/.config/orbvm/authkey
   chmod 600 ~/.config/orbvm/authkey
   ```

   (Or export `TS_AUTHKEY` in your shell instead of using the file.)

2. **Enable HTTPS certificates** for your tailnet: admin console → **DNS** →
   *Enable HTTPS*. Required so `tsweb` can serve preview URLs over HTTPS.
   MagicDNS is already on.

## Usage

```bash
./create-vm.sh devbox            # create a VM named "devbox" (ubuntu:noble)
./create-vm.sh devbox ubuntu:noble   # or pick a distro (see `orb create --help`)
```

When it finishes it prints how to connect. From **any** device on your tailnet:

```bash
ssh <you>@devbox.<your-tailnet>.ts.net   # Tailscale SSH, no keys needed
claude                                    # log in once on first run
```

Locally on the Mac you can also just `orb -m devbox` to drop into a shell.

### Serving a test site

Inside the VM, start whatever dev server you're testing, then expose its port:

```bash
# in the VM
python3 -m http.server 3000      # or: npm run dev, etc.
tsweb 3000                       # -> https://devbox.<your-tailnet>.ts.net/
```

The URL is reachable only by devices on your tailnet. Stop serving with:

```bash
tailscale serve --https=443 off
```

### Tear down

```bash
./delete-vm.sh devbox            # logs out of Tailscale, deletes the VM
```

## Baked-in Claude configuration

Every machine created with `create-vm.sh` is provisioned with a shared Claude
Code setup from `claude-config/`:

- `settings.json` — permissions (allow/deny lists), `opus` model, the guard hook,
  the status line, enabled plugins, and lifecycle hooks that publish Claude's
  state (busy/waiting/idle) to its tmux pane via `@claude_state`, which the
  bundled `tmux.conf` renders in the window name. The hardcoded home path in the
  status line is rewritten to the VM's real `$HOME` on install.
- `statusline-command.sh` — cwd · git branch · model · context % · rate limits.
- `hooks/guard.sh` — a PreToolUse guard that blocks `rm -rf`, non-lease force
  pushes, and reads of `.env` secrets. (`jq` is installed to support it.)
- `CLAUDE.md` — global user instructions.
- Plugins — `typescript-lsp@claude-plugins-official` and `svelte@svelte` (from
  the `sveltejs/ai-tools` marketplace) are installed and enabled.

Edit anything under `claude-config/` to change what new machines get. To push the
current config to an **existing** machine (e.g. after editing it), run:

```bash
./apply-claude-config.sh <machine>      # idempotent; safe to re-run
```

You still log in to Claude once per VM on the first `claude` run; the config and
plugins above are applied regardless of login.

## Shell (zsh + Oh My Zsh)

Each machine gets `zsh` with [Oh My Zsh](https://ohmyz.sh/) installed (default
`robbyrussell` theme) and set as the default login shell, so SSH sessions land in
zsh. `~/.local/bin` is added to `.zshrc` so the `claude` CLI stays on PATH (zsh
doesn't read the base image's `~/.profile`). To add it to an existing machine:

```bash
./setup-shell.sh <machine>      # idempotent; safe to re-run
```

## Node (nvm)

Node is installed per-user with [nvm](https://github.com/nvm-sh/nvm) (the latest
LTS, set as the default), so you can switch versions per project with
`nvm install <version>` / `nvm use <version>`. The nvm loader is added to both
the bash profile and `~/.zshrc`, so `node`/`npm` are on PATH in interactive SSH
sessions. (Provisioning steps source nvm explicitly, since Ubuntu's `~/.bashrc`
returns early for the non-interactive shells those steps run in.)

## tmux

Each machine gets `tmux`, configured from `tmux.conf` in this repo. tmux keeps
your shell, Claude, and dev servers running on the VM even when the SSH/Tailscale
connection drops — so a flaky link or a closed laptop doesn't kill your work.
Typical use:

```bash
ssh <you>@devbox.<your-tailnet>.ts.net
tmux new -s work        # start (or: tmux attach -t work  to reattach after a drop)
claude                  # keeps running inside tmux even if SSH dies
# detach any time with:  Ctrl-b d
```

The bundled `tmux.conf` adds: mouse on, 50k scrollback, 1-based window numbering,
vi copy-mode keys, copy to the **Mac clipboard** (via OrbStack's `mac pbcopy`,
plus OSC 52), and window names that track Claude Code's state — `●` busy,
`?` waiting on you, `✳` idle (driven by the hooks in `claude-config/settings.json`).

`tmux.conf` is the source of truth: edit it here, then re-run `setup-tmux.sh` to
push it to a machine (it rewrites the VM's `~/.tmux.conf` and reloads a running
server):

```bash
./setup-tmux.sh <machine>       # idempotent; (re)applies the repo config
```

## Git identity

Each machine's global git identity is set from the values at the top of
`setup-git.sh` (currently `Nate Gittlen <nathaniel.gittlen@gmail.com>`). Edit
those two variables to change it, then apply to an existing machine with:

```bash
./setup-git.sh <machine>        # idempotent
```

## Web dashboard

A small web UI to list machines (name, tailnet address, status, live CPU/memory),
start/stop (shut down) them, tear them down, and create new ones — reachable from
any device on your tailnet.

```bash
./start-dashboard.sh
```

This starts a localhost-only Node server (`dashboard/server.js`) and puts it
behind `tailscale serve`, printing a URL like
`https://nathaniels-macbook-pro-2.tail8e6d2.ts.net/`. Open it from any tailnet
device. Ctrl-C stops the server and removes the serve. Run it on a different
port with `PORT=9000 ./start-dashboard.sh`.

What it shows per machine:

- **Status** — `running`, `provisioning` (while `create-vm.sh` is still
  installing), `stopped`, or `error`.
- **Tailscale address** and a copy-the-`ssh`-command chip.
- **CPU %** and **memory** — measured *per VM* by summing that VM's own
  processes (OrbStack VMs share the host kernel, so `/proc` totals are host-wide;
  the dashboard uses the VM's PID namespace instead). CPU is normalized so 100% =
  one core and can exceed 100% across cores; memory is the VM's footprint against
  the shared host RAM.

Each running machine has a **Stop** button (shut down, reversible — `orb stop`);
a stopped machine shows **Start** (`orb start`). These keep the VM and its data,
unlike **Delete**. Create and delete go through the same `create-vm.sh` /
`delete-vm.sh` scripts. Machine names are validated and passed as arguments
(never through a shell).

Because it can create and delete VMs, keep the dashboard tailnet-only (that's
what `tailscale serve`, as opposed to `funnel`, gives you) — don't expose it
publicly.

## Notes & troubleshooting

- **Tailscale SSH / ACLs.** With the default tailnet policy you can SSH to your
  own devices. If the SSH connection is refused, add an `ssh` rule to your ACLs
  in the admin console allowing your user to its own devices.
- **Userspace networking fallback.** If a VM has no `/dev/net/tun`, `create-vm.sh`
  brings Tailscale up in userspace mode automatically. SSH and `serve` still work.
- **Claude login.** Each VM is a separate machine, so you log in to Claude once
  per VM on the first `claude` run.
- **Multiple VMs.** Just run `create-vm.sh` again with a different name; each gets
  its own tailnet node and `https://<name>.<your-tailnet>.ts.net/` URL.
- **A create that failed partway.** After the VM and Tailscale are up, each
  provisioning step is resilient: a failure is recorded and the run keeps going,
  then exits non-zero with a summary naming the failed step(s). In the dashboard,
  a `provisioning`/`error` card has a **View provisioning log** toggle showing the
  full captured output. To finish a partial machine, re-run the matching
  idempotent script against it — any of:
  `apply-claude-config.sh`, `setup-shell.sh`, `setup-tmux.sh`, `setup-git.sh`,
  `setup-github.sh`, `setup-tsweb.sh` (e.g. `./setup-git.sh <machine>`).
