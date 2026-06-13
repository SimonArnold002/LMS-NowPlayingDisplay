# Server-side Visualizer — one-time system setup

The NowPlayingDisplay plugin manages everything itself except two small
system-level steps that need root:

1. Make `snd-dummy` (the virtual sound card kernel module) load at boot
2. Allow non-audio-group users to access the Dummy ALSA card it creates

After that, the plugin spawns and supervises both SqueezeLite and the FFT
helper itself — start/stop them from the settings page, automatic restart
on crash, automatic shutdown on plugin disable.

**Why the audio-card permission step?** Our embedded SqueezeLite captures
audio into shared memory via `-v`, and it needs an ALSA output as a clocking
source (the virtual Dummy card). ALSA devices are normally protected by the
`audio` group. Rather than adding the LMS user to that group (which gives it
access to *all* sound hardware), we ship a focused udev rule that only opens
up the Dummy card — a virtual device with no real-world security implications.

---

## One-time setup (any Linux distro)

```bash
PLUGIN=/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/NowPlayingDisplay
# The settings page shows your install's actual path — use whichever it shows.

# 1. snd-dummy at boot. The module ships in every distro's stock kernel; this
#    just tells the system to load it at boot.
sudo cp $PLUGIN/Service/snd-dummy.conf /etc/modules-load.d/snd-dummy.conf
sudo modprobe snd-dummy

# 2. Open Dummy card permissions via udev rule. Affects only the virtual
#    Dummy ALSA card — no other audio hardware permissions are touched.
sudo cp $PLUGIN/Service/99-snd-dummy-permissions.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger

# 3. Install apt deps if you don't have them.
#    Debian / Ubuntu / Raspbian / DietPi:
sudo apt install -y squeezelite python3 python3-numpy
#    Alpine:
# sudo apk add squeezelite python3 py3-numpy
#    Arch / Manjaro:
# sudo pacman -S squeezelite python python-numpy
#    Fedora / RHEL:
# sudo dnf install squeezelite python3 python3-numpy
```

Then in the plugin's settings page:

- **Visualizer SqueezeLite** should say "running (PID …)" with binary
  at `/usr/bin/squeezelite` and Dummy ALSA card "loaded"
- **FFT helper** should say "running (PID …)" with dependencies "OK"

If anything's red, the status line tells you what's missing.

---

## OpenRC variant (Alpine before 3.16, Gentoo, Devuan)

Use `/etc/modules` instead of `/etc/modules-load.d/`; udev step is unchanged:

```sh
echo snd-dummy | sudo tee -a /etc/modules
sudo modprobe snd-dummy

sudo cp $PLUGIN/Service/99-snd-dummy-permissions.rules /etc/udev/rules.d/
sudo udevadm control --reload
sudo udevadm trigger
```

LMS-package-equivalent and Python deps are unchanged from above (substitute
your distro's package manager).

---

## Why not just use UPnPBridge's approach?

A reasonable question — UPnPBridge ships a `squeeze2upnp` binary that just
works without any audio-group setup. The difference: that binary isn't a real
squeezelite. It uses the squeezelite *protocol* to receive audio from LMS,
then forwards it over the network to UPnP/DLNA renderers. It never opens an
ALSA device, so it never needs audio permissions.

We need a *real* squeezelite because the `-v` shared-memory buffer (which our
FFT helper reads) is populated by squeezelite's output thread, which needs an
ALSA output as its clocking source. The Dummy card gives us that timing
without any actual sound playback.

---

## Troubleshooting

**SqueezeLite section says "stopped" and won't start.** Check the log link in
the settings page.
- "ALSA cannot open device" → the udev rule isn't in effect. Confirm with
  `ls -l /dev/snd/` — the `controlC*` and `pcmC*` nodes for the Dummy card
  should show `0666` (rw for all). If not, re-run the udev step. Alternatively,
  `sudo modprobe -r snd-dummy && sudo modprobe snd-dummy` triggers a fresh
  device creation that picks up the rule.
- "Dummy ALSA card: not loaded" in settings → run `sudo modprobe snd-dummy`
  to load it for this session; the `/etc/modules-load.d/snd-dummy.conf`
  step above makes it persist across reboots.

**FFT helper says "python3 found, but numpy module is missing".** Install the
distro's `numpy` package and click **Re-check dependencies**.

**"squeezelite not found in PATH".** Install it (`sudo apt install
squeezelite` etc.). The plugin looks in `/usr/bin/squeezelite`,
`/usr/local/bin/squeezelite`, `/opt/squeezelite/squeezelite`, and via
`which squeezelite`.

**Visualizer player isn't appearing in LMS.** Both SqueezeLite and LMS need
to be running on the same machine for the default `-s 127.0.0.1` to work.
Check the SqueezeLite log shows "connected to" the LMS host.

**I'd rather run SqueezeLite or the helper as my own systemd unit.** Turn
off the relevant Auto-start checkbox in settings. The plugin will leave that
process alone. The bundled `snd-dummy.conf` is still useful for the
modprobe-at-boot piece either way.
