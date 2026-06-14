# NowPlayingDisplay — Dev Journal

## Version: 0.37.13.0

> Canonical source of truth across forked Claude sessions. Reconcile to this at the
> start of every session. Update on request; Simon re-uploads it at session start.
> Plugin creator must ALWAYS be `CrystalGipsy` in install.xml. Active focus is
> **server mode only**; browser-audio mode is parked and locked.

### Recent version history
- **0.37.13.0** — **settings: clickable display links.** Each display URL on the settings page now has an **Open ↗** anchor (`class="npd-open"`, `target="_blank"`) next to its read-only copy box — general URL plus one per player. The page JS that fills `data-npd-url` was generalised to set anchor `href`s (from `window.location.origin`) as well as input values. Copy boxes retained for bookmarking on other devices. (Links open in the same browser the settings page runs in — can't force the OS-default browser.)
- **0.37.12.0** — **bridge-URL auto-derive (iOS fix).** When `vizServerMode` is on but `vizBridgeUrl` is blank, the page now derives `ws://<page-host>:8770/` (matches `_helperPort()`'s 8770 default) instead of failing. Root cause of "visualizer works on desktop but not iOS": with a blank bridge URL, `vizIsServerMode()` returned false, so desktop silently fell back to browser Web Audio (works) while iOS — which has no Web Audio path — showed nothing. Three JS edits: `VIZ_SERVER_AVAILABLE` and `vizIsServerMode()` now require only `serverMode` (not `bridgeUrl`); `vizBridgeUrl()` derives the host:port when the field is empty. The Bridge URL field is now an optional override. Side effect: desktops with server mode on now use the server path too (consistent across clients).
- **0.37.3.0** — helper rate-robustness (`npd-vizfft.py`): deterministic sample-rate read from the fixed vis_t offset (no loose scan / 44.1k stuck-default), plausible rates 8k–384k, ring sized for highest rate, rate-change logging.
- **0.37.4.0** — manual-player-follow: the Visualizer follows the room manually selected on the display, not just the most-active one (`$_vizDesiredSource` set from the page's state.json poll; reconcile honours the pin).
- **0.37.5.0** — **`vizAutoFollow` toggle** (settings checkbox "Auto-follow the room (mirror)", default on). Off = mirror issues no commands to the Visualizer, so it can sit in a native sync group for experiments while the player + helper keep running. Reconcile early-returns when off.
- **0.37.6.0** — **bidirectional baseline buffer** (helper). A built-in delay lead (default **2000 ms**) makes the offset a two-way trim: `read_back = baseline + offset`. Negative offset pulls visuals EARLIER (toward live edge), positive pushes them LATER. Forward limit is the baseline; offset clamps to `[-baseline, max_offset-baseline]`.
- **0.37.7.0** — calibration WAVs regenerated to **60 s, one beep per second** (120 ms bursts, 5 ms raised-cosine edges, -6 dBFS, mono 44.1k). Offset read-back logging: each change logs `reading Nms behind live edge`.
- **0.37.8.0 / 0.37.8.1** — **bouncing-ball calibration view** (Fire-TV-style A/V sync tool). Beep-onset-driven from the captured (offset-delayed) audio. Ball bounces continuously (floor→apex→floor, eased), block slides L→R through centre at impact, ball/block colour-swap + big flash lower-left + brief full-screen wash on the detected beep. 8.1 fixed the ball to bounce rather than teleport to top.
- **0.37.9.0** — **ring-reset bug fix (KEY FIX).** Helper no longer wipes its 4.5 s history on a shmem overrun; it keeps history + offset stable and just resyncs the index. This was the root cause of glitching, non-deterministic drift, and "same offset gives different sync."
- **0.37.10.0** — calibration rework: **save/restore room queue** (snapshot playlist+index+time+mode, restore+resume on stop), play tone on room + Visualizer, mirror suppression during calibration.
- **0.37.11.0** — calibration **single-clock mirror path.** Tone plays once on the room; the **mirror** carries it to the Visualizer via the same play+seek path used in normal playback (no separate viz play). Calibration pins `$_vizDesiredSource` to its room and forces the mirror on even if auto-follow is off; restores the pin on stop. Removes the per-session start jitter of the old dual-play.

## Server & install
- **LMS:** Lyrion Music Server 9.1.1, DietPi x86_64, hostname `plex`, IP `192.168.1.234:9000`
- **Plugin install path:** `/usr/share/squeezeboxserver/Plugins/NowPlayingDisplay/` (manual, NOT cache/InstalledPlugins)
- **SSH:** `ssh dietpi@plex`
- **Restart LMS:** `sudo systemctl restart squeezeboxserver`
- **Logs:** `/var/log/squeezeboxserver/server.log`; helper: `/tmp/nowplayingdisplay-helper.log`
- **Plugin creator:** must always be `CrystalGipsy` in install.xml
- **No telnet/nc on the box.** Query LMS via curl JSON-RPC:
  ```
  curl -s http://localhost:9000/jsonrpc.js -d '{"id":1,"method":"slim.request","params":["<MAC>",["cmd","args"]]}'
  ```
- **Install from zip:**
  ```
  scp NowPlayingDisplay.zip dietpi@plex:/tmp/
  ssh dietpi@plex 'sudo unzip -oq /tmp/NowPlayingDisplay.zip -d /usr/share/squeezeboxserver/Plugins/ && sudo systemctl restart squeezeboxserver'
  ```

## Key files
```
/usr/share/squeezeboxserver/Plugins/NowPlayingDisplay/
  Plugin.pm          — main plugin (~6450 lines)
  Settings.pm        — settings prefs list
  strings.txt
  install.xml        — version + <creator>CrystalGipsy</creator>
  Bin/npd-vizfft.py  — FFT helper (reads squeezelite shmem, serves frames over WS:8770)
  Bin/calibration-1khz.wav, calibration-200hz.wav  — 60 s, 1 beep/sec
  HTML/EN/plugins/NowPlayingDisplay/settings/basic.html  — settings template
```

## Runtime files (tmp)
- `/tmp/nowplayingdisplay-helper.log` — helper log (frames, rate changes, offset read-back, resync events)
- `/tmp/nowplayingdisplay-offset.txt` — offset in ms; helper polls every 100 ms. Written by plugin at: helper startup, `/setoffset` save, `/setlivenoffset` nudge, auto-follow source change.

## Players (confirmed via JSON-RPC this session)
**Every room is a bridge / network endpoint — there is NO native Slimproto room.** The only real SqueezeLite player is the Visualizer.
- **Visualizer SqueezeLite** `38:f7:cd:c5:1a:2c` — capture infrastructure; shmem `/squeezelite-38:f7:cd:c5:1a:2c`; excluded from all user-facing player lists. Args `-b 256:8192 -a 20:2::: -v`, output `plughw:CARD=Dummy`.
- **Lounge** `bb:bb:93:32:0d:53` — UPnPBridge (WISA), highest latency
- **Sonos** `aa:aa:b8:05:b6:35` — RaopBridge
- **Sonos 2** `aa:aa:60:90:9c:b0` — RaopBridge
- **Kitchen** `cc:cc:60:4f:9a:55` — CastBridge
- **Living Room TV** `cc:cc:8b:4b:78:88` — CastBridge
- **Dining Room** `50:41:1c:72:4a:c8` — WiiM
- **DMP-A8** `80:0a:80:5e:2b:7b` — Eversolo, model "Squeeze connect"

> **ALWAYS ASK Simon which player he's testing. Never assume from this list.**

## Architecture

### Sync offset — bidirectional baseline buffer (v0.37.6+)
- Offset is applied in the **FFT helper** (`npd-vizfft.py`), not the browser.
- Helper keeps a ~4.5 s Python ring accumulated from squeezelite shmem via `buf_index` delta tracking.
- **Baseline lead** (default 2000 ms): the helper reads audio `baseline` ms back from the live edge by default, so the offset trims both ways:
  - `read_back_ms = baseline_ms + offset_ms` (clamped `[0, max_offset_ms]`)
  - offset `0` → read `baseline` back (neutral)
  - offset **negative** → read nearer live edge → visuals **earlier/forward**
  - offset **positive** → read further back → visuals **later/delayed**
- CLI: `--baseline-ms` (default 2000), `--max-offset-ms` (default 4500). Ring sized for 192 kHz so the full window holds on hi-res.
- **Cost (inherent, NOT a bug):** at neutral the visuals are `baseline` ms behind live capture, so they trail the room and keep rendering ~baseline ms after music stops (plus up to ~1 s mirror lag before the Visualizer itself stops). Startup pays a one-time ~baseline-ms fill before visuals appear. Shrink the baseline once real per-room offsets are known.
- Offset is stored in ms and converted with the live rate, so ONE offset works across all sample rates.

### Offset sign convention
- **Positive = later (delay the visuals).** Negative = earlier (pull toward live edge). Per-player value is ABSOLUTE (replaces default, not additive).

### Per-player offsets (v0.37.2 — named-preset model retired)
- Flat map `vizPlayerOffsets = {playerId: ms}` with `vizDelayMs` as global fallback. `_resolveOffsetForPlayer($pid)` reads the flat map, else the default. `_migratePlayerOffsets` migrated the old presets.
- Save: `/setoffset?ms&player` → writes the active room's entry. Nudge: `/setlivenoffset` → transient (live file write, NOT persisted). Tuner clamps ±2000.

### Auto-follow (mirror) — the ONLY viable architecture (see Sync investigation)
- Server-side 1 Hz `_vizReconcile`. `_vizPickActiveSource` picks most-active OR the pinned `$_vizDesiredSource`. Mirrors the room's track onto the Visualizer via `playlist play` + ~0.6 s-delayed `time` seek.
- **Manual-follow (0.37.4):** the display's state.json poll sets `$_vizDesiredSource` so the Visualizer follows the selected room.
- **`vizAutoFollow` toggle (0.37.5):** off = no mirror commands (for sync experiments); player + helper still run. Calibration OVERRIDES this (forces mirror on).

### Calibration (single-clock mirror path, v0.37.11)
- Tuner overlay has **♪ 1k** / **♪ 200** buttons → `/calibrate?action=start|stop&tone=&player=`.
- **Tones:** `calibration-1khz.wav` / `calibration-200hz.wav`, 60 s, one beep/sec, played via `file://` URL (`fileURLFromPath`); HTTP self-loops trip a socket-bind quirk in `Slim::Player::Protocols::HTTP`.
- **Start:** snapshot the room's queue (`_calSnapshotPlaylist`: status tags:u → urls/index/time/mode); record prev repeat + prev `$_vizDesiredSource`; set `$CALIBRATION_ACTIVE{$playerId}`; **pin `$_vizDesiredSource` to the room**; play tone on the **room only** (repeat 1). The mirror (forced on during calibration) carries the tone to the Visualizer through the real play+seek path — one source, one stream path. NO separate viz play (removed in 0.37.11 to kill per-session start jitter).
- **Stop (`_calibrationStop`, single-arg):** restore prev pin; stop+clear viz; on the room `stop → playlist clear → power 0 → power 1` (power-cycle releases the file:// device handle — proven necessary), restore repeat, `_calRestorePlaylist` (re-add urls, index, time seek, match play/pause/stop). 10-min safety auto-stop backstop.
- **Bouncing-ball view (`vizDrawCalibration`):** active whenever `calActiveTone` set; takes over the canvas (no bars). Detects beep onsets from `vizServerWave` RMS (hysteresis ON 0.06 / OFF 0.03, 450 ms refractory), EMA-locks the ~1 Hz period. Ball bounces floor↔apex (eased), block slides through centre at impact, colour-swap + flash on the detected beep. Tune offset until the strike/flash lands on the beep heard from the room.
- **True sample-sync is impossible** here (bridges — see below), so the mirror path is the closest correct equivalent; residual is the same skew normal playback has, which the offset absorbs. ~1 s ambiguity if real offset > ~500 ms (1 Hz spacing); the continuous bounce helps disambiguate.

### Visualizer SqueezeLite args
`-b 256:8192 -a 20:2::: -v` — tuned to run ahead of any room so the offset stays usable. No `-r` (not rate-locked).

## HTTP / control endpoints
- `/setoffset?ms&player` — persist per-player offset (Save)
- `/setlivenoffset?ms` — transient nudge (writes offset file, not persisted)
- `/calibrate?action=start|stop|status&tone&player`
- `/helper?action=start|stop|restart|status|log`
- Frames: WebSocket `ws://<host>:8770/` from the helper; browser keeps only the latest frame.

## Build & lint
```bash
# Perl:
PERL5LIB=/tmp/stubs perl -c Plugin.pm            # needs Slim::*/JSON::XS stubs
PERL5LIB=/tmp/stubs perl -c Settings.pm
# JS (extract largest <script>, stub TT vars, node --check):
#   replace __NPD_VIZ_CFG__ etc, then: node --check /tmp/page.js
# Python:
python3 -c "import py_compile; py_compile.compile('Bin/npd-vizfft.py', doraise=True)"
# Bump version (install.xml) + keep <creator>CrystalGipsy</creator>:
sed -i -E "s|<version>[0-9.]+</version>|<version>X.Y.Z</version>|" install.xml
# Package:
rm -rf NowPlayingDisplay/Bin/__pycache__ && zip -qr NowPlayingDisplay.zip NowPlayingDisplay
```

## SYNC GROUPING — RULED OUT (do not re-investigate)
Tested this session via curl JSON-RPC (`sync`, `syncgroups ?`, `mode ?`) on Sonos, WiiM, and DMP-A8 with the Visualizer as follower:
- Players **do** join a sync group (`syncgroups ?` lists both members), BUT no audio reaches the Visualizer follower. Sonos → `mode:play` but **blank** (silent capture). DMP-A8 → `mode:play` but **blank**. WiiM → `mode:stop` (didn't take).
- Root cause: every room is a bridge (UPnP/RAOP/Cast/WiiM) or "Squeeze connect" (DMP-A8) that owns its own playback path; LMS does not relay a synchronized stream to a SqueezeLite follower behind a bridge. There is no native Slimproto streamer to act as a feeding master.
- Mirror mode was verified WORKING during the same session (capture chain healthy; player-switch change exonerated).
- **Conclusion: the mirror model is the only viable architecture. Native sync is a dead end on this hardware. Calibration's "one clock" therefore uses the mirror path, not real sync.**

## Known issues / deferred
1. **Track-boundary drift (OPEN, priority).** At a track change the mirror does `playlist play` + ~0.6 s delayed `time` seek → two stream reloads → blank → buf_index jump. With the baseline buffer the post-boundary re-settle is now LONGER (read point must climb back to baseline). Candidate fix: **skip the redundant `time` seek** on ordinary sequential same-rate track changes; reserve it for genuine jumps (scrub, large gap, source switch). NEXT STEP: tail helper.log + server.log across ONE real boundary before coding.
2. **Validate real offset magnitude per room → shrink baseline.** 2000 ms baseline is for exploration; once Simon reports a room's tuned offset, shrink the baseline to the minimum that still covers the needed forward pull (reduces resting latency + post-stop tail).
3. **"Renders after music stops"** ≈ baseline + mirror lag. Inherent to the baseline, not a bug. Shrinks with the baseline.
4. **Calibration accuracy:** mirror-path is closest-correct; 1 Hz spacing gives ~1 s ambiguity above ~500 ms offsets. Confirm re-runs give a consistent number.
5. **Unexplained helper restart** seen mid-capture earlier (two `helper start` lines) — possible crash; investigate if it recurs.
6. **Streaming drift:** deferred.
7. **Server mode as default / deprecate browser-audio:** longer-term.

## Key learnings
- **Solve the right problem.** The original browser-buffer approach delayed already-seen frames, not the audio reaching the FFT analysis. Correct fix = delay the captured audio in the helper.
- **Ring-reset was the silent killer (0.37.9.0).** Wiping 4.5 s of history on any ~93 ms shmem overrun forced the offset to ramp from zero on every hiccup → glitch, non-deterministic drift, "same offset ≠ same sync." Fix: keep history, resync index only. Producer and per-client WS senders are decoupled (`_latest` under lock), so a slow client can't stall the producer — overruns are GC/CPU hiccups, now ridden through.
- **Sync is impossible on bridges** (above). Don't reopen it.
- **Use what LMS provides** (e.g. `Slim::Utils::Network::serverURL()`, `fileURLFromPath()`, existing per-player offset storage, `$_vizDesiredSource` pin).
- **Don't overcomplicate; diagnose before coding.** Gather logs/JSON-RPC across one real event before changing code. Strip to minimum viable.
- **Calibration/playback path is sensitive** — it must never destroy the room queue (snapshot/restore) and must release the device cleanly (power-cycle). Confirm approach before touching it.
- Filesystem artifacts don't persist across Claude container sessions; if source is needed, request it via SSH paste rather than guessing.
