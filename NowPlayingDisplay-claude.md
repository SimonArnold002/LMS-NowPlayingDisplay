# NowPlayingDisplay — Dev Journal

## Version: 0.38.8.0

> Canonical source of truth across forked Claude sessions. Reconcile to this at the
> start of every session. Update on request; Simon re-uploads it at session start.
> Plugin creator must ALWAYS be `CrystalGipsy` in install.xml. The visualizer is
> **server mode only** — the browser-audio (Web Audio) path was REMOVED in 0.38.0.0.
> **ALWAYS bump the version (install.xml + repo.xml) on every rebuild** — LMS won't
> reinstall on an unchanged version, so same-version rebuilds never reach the box.

### Recent version history
- **0.38.8.0** — **ROOT CAUSE of "tracks wiped for no reason during playback".**
  The calibration 10-min safety auto-stop timer was registered with
  `setTimer($client, …, $stopRef)` but cancelled with `killTimers(undef, $stopRef)`
  (in `_calibrationStop` and the re-start path). LMS matches timers on the
  **(object, coderef) pair**, so an undef-object kill NEVER cancels a $client-object
  timer → every calibration lit a 10-minute fuse that normal Stop didn't put out.
  ~10 min later, mid-normal-playback, it fired `_calibrationStop`, which ran the
  destructive teardown — `stop` → **`playlist clear`** → `power 0/1` on the ROOM —
  and since the calibration entry was already gone, the snapshot was undef so
  nothing was restored → queue wiped "for no reason". This is the real culprit
  (NOT the lead/seek, NOT the mirror — both only ever touch the Visualizer). FIX:
  (1) register the auto-stop timer with `undef` so the existing kills match;
  (2) `_calibrationStop` now `return`s immediately unless an active calibration
  entry exists for that player — so a stray/duplicate stop can never run the
  destructive teardown on a live queue. Belt + braces. Lint OK.
- **0.38.7.0** — **calibration ball: fixed the "blip tied to the flash / not movable"
  problem** (the long-open self-referential-view issue). OLD: the ball, block AND
  flash were all hard-locked to `calLastOnset` (the detected beep), re-set every
  cycle — so the whole animation re-centred on itself and nudging the offset just
  made it jerk and re-lock, never showing a movable relationship. NEW (per Simon's
  steer — keep ball+bounce, do NOT track the room clock, your ears are the
  reference like judging bars against music): the ball now bounces on a CONTINUOUS
  beat phase (`calPhase`, advances at 1/`calPeriod`) that's gently PLL-pulled
  toward each detected beep (50%/beat) — smooth anticipation, never teleports; the
  flash fires on the RAW detected beep so an offset nudge moves the strike/flash
  IMMEDIATELY relative to the audible beep. Dropped the sliding block + colour
  swap; added a faint fixed strike-pad at centre-floor as a watch spot. Tune until
  the ball strikes / flashes exactly when you HEAR the beep. (Lint: perl -c, JS
  parse via JavaScriptCore — both OK.) NOTE STILL OPEN: calibration's _calibrationStop
  teardown is still destructive (`playlist clear` + `power 0/1` on the ROOM, line
  ~1329/1330) — that's the queue-reset/skip-all-tracks culprit confirmed live this
  session (log showed `_calibrationStop … tracks=0`). The ball fix does NOT touch
  that; using calibration still risks the queue until the teardown is made safe.
- **0.38.6.0** — **AV-sync: start-time seek-align (lead) + system-delay self-test.**
  Real-world finding (Simon): in steady state the ROOM audio runs AHEAD of the
  visualiser (visuals late) — the delay-only buffer can't fix that (it can delay
  visuals but never advance them). Only a bridged device's slow start makes the
  visualiser late→behind transiently. **Two changes:**
  (1) **Start lead (`vizLeadMs`, global pref, default 0).** The mirror seek
  (`_vizMirrorAction`) now, after the stream loads (0.6 s), RE-MEASURES the room's
  CURRENT `songElapsedSeconds` (the room has truly "registered" playback by then,
  instead of reusing the stale position captured at play-issue) and seeks the
  Visualizer to `room-now + lead`, so its capture sits `lead` ms AHEAD of the room
  → the delay buffer can always pull it to exact sync. Lead doesn't persist across
  tracks (each track is a fresh independent stream on both players), so when
  `vizLeadMs>0` we re-seek on EVERY new track incl. same-room advances (accepting
  one extra reload/track); when `vizLeadMs==0` behaviour is byte-identical to
  before (seek only on source-switch/mid-track join, no per-track reseek — no
  regression). New endpoint `/setlead?ms=` (clamp 0..4000); `leadMs` added to both
  page-config blocks; tuner has a −50/+50 Lead stepper (in the self-test panel)
  that persists debounced.
  (2) **System-delay self-test** (⏱ Test button → centered results card). Measures
  the SOFTWARE pipeline budget so the manual ball calibration only has to absorb
  the one stage software can't see (TV/panel latency). Helper: per-frame `proc_ms`
  EMA (shmem-read→FFT→serialise) stored in `_latest`; WS now also READS client
  frames (was send-only) via `select`+a minimal masked-frame decoder and answers
  `{"ping":t}` with `{"pong":t,"proc_ms":x}` (also replies to protocol pings/close).
  Browser: control msgs disambiguated by leading `{`; self-test sends 30 pings over
  ~3 s, times RTT/2 (transport) + reads proc_ms, and samples receive→draw latency
  in `vizDraw`; reports proc + transport + draw + current offset = "known total".
  Lint: perl -c OK, py_compile OK, JS parse OK (via JavaScriptCore `new Function`
  — no node on this Mac; `osascript -l JavaScript` harness in scratchpad/check.js).
  NOTE: still OPEN — the self-referential calibration ball view (carried from
  0.38.5.0).
- **0.38.5.0** — **calibration: queue-safety + "waiting for tone" race fixes** (diagnosed
  live via `http://plex:9000` log.txt + a WS sampler — offset proven working: a 500 ms
  change shifted the beep output by 496 ms, so the engine is fine; the faults were the
  calibration tool). (1) QUEUE LOSS: re-triggering calibration deleted the good snapshot
  and re-snapshotted the *tone* (or an empty/streaming queue) → user's music gone. Fix:
  on re-start REUSE the existing snapshot (don't re-snapshot); on a FRESH start, if the
  room is play/pause but the snapshot has 0 tracks, ABORT with an error instead of
  replacing the live queue with the tone; `_calSnapshotPlaylist` now filters out any
  calibration-tone URL; `_calRestorePlaylist` no longer `playlist clear`s on an empty
  snapshot. (2) "Waiting for calibration tone": `_calibrationStop` cleared the Visualizer
  but did NOT reset `$_vizLastSource`/`$_vizLastTrackUrl`, so a re-start with the SAME
  tone saw "same track already mirrored" and never re-played → Visualizer sat empty. Fix:
  reset both trackers in `_calibrationStop` (moved their `my` decls up next to
  `$_vizDesiredSource` so the earlier sub can see them). STILL OPEN: the self-referential
  calibration BALL view (free-runs on EMA period; ball+flash+block all derive from the
  same detected beep so they always coincide → the offset shift isn't visible on-screen
  even though it IS happening). Next: make the view show the offset against an
  independent reference, or replace the ball.
- **0.38.4.0** — **stability: REMOVED the live shmem-reconnect (it could freeze the
  whole visualiser).** The 0.38.1 inode-based "shmem changed → reconnect" check called
  `open_reader_with_retry` mid-loop, which BLOCKS until the segment reappears → frozen
  producer = black visualiser (Simon's "completely crashed using calibration"). Removed
  entirely; only the safe STARTUP wait remains (if SqueezeLite is restarted mid-run,
  restart the helper from the settings button). Also made the helper log **line-buffered**
  (`sys.stdout.reconfigure(line_buffering=True)`) so `helper?action=log` is readable live —
  essential for diagnosing without SSH (Simon does NOT allow SSH; the local
  `~/Documents/logs` is a manual debug copy, not a live sync — don't rely on it). 0.38.3.0
  (debounced reconnect) was superseded by this full removal before deploy.
- **0.38.2.0** — **calibration glitch/stuck + track-change dropout fixes** (mirror path).
  (1) Calibration set `repeat 1` on the *room* only, so the Visualizer played the 60 s
  tone once, ended, and the reconcile resume path (`pause 0`+`time`) fired on an ended
  playlist every loop → glitch/stuck. Fix: `_vizMirrorAction` now also sets `repeat 1`
  on the Visualizer while `$CALIBRATION_ACTIVE{$srcId}` (cleared in `_calibrationStop`),
  so the tone loops seamlessly. (2) Every track change did `playlist play` + a 0.6 s
  delayed `time` seek = two stream reloads → blank at each boundary. Fix: skip the
  redundant seek on a *sequential same-room* advance (`$sourceChanged` is false); only
  seek when joining a possibly-mid-track source (first mirror / room switch). Addresses
  known-issue #1. STILL OPEN: room↔Visualizer loop-PHASE drift (they loop on independent
  clocks) — needs the position-lock work, not just the seek change.
- **0.38.1.0** — **helper self-heal + restored server-mode toggle.** Helper waits/retries
  for the shmem (`open_reader_with_retry`) instead of crashing the producer thread when
  SqueezeLite isn't up yet, and reconnects (inode check) if SqueezeLite restarts — fixes
  the permanent-blank after a startup race. Reverted the 0.38.0.0 "force `vizServerMode`
  on / remove toggle": it's a default-off master switch again (the supervisor reads it,
  so forcing it on meant the Stop buttons never stuck). Tilt steepened 3.0→4.0 dB/oct.
- **0.38.0.0** — **offset re-spec (delay-only) + browser-audio removal.** (1) Offset
  model rewritten: `0` = live-edge passthrough (zero added latency, no startup
  drift-into-sync), positive = **delay the visuals** (helper reads back into a 2 s
  buffer) to match the room. Range `0..2000` ms everywhere (helper, `_writeOffsetFile`,
  Settings `$clampMs`, on-screen tuner). The old bidirectional 2000 ms baseline + the
  inverted sign convention are GONE, as is the `_writeOffsetFile` negative→0 clamp that
  silently killed the only useful tuning direction. Helper spawned with
  `--baseline-ms 0 --max-offset-ms 2000`; emits silent frames until the ring is primed
  to the requested read-back (no visible ramp). (2) **Browser-audio path removed:**
  deleted the Web Audio graph (`vizBuildGraph`/AudioContext/analyser), `vizSync`/
  `vizResume`/`vizCorrect`/`vizSeekTo`/`vizEstimatedRoomPos`, the hidden `<audio>`
  element, the `/streamurl` + `/streamproxy` endpoints (and `_proxySecret`/
  `_signProxyUrl`/`_constantTimeEq`), and the iOS gating. Server mode is now
  unconditional (`vizServerMode` forced on at init, toggle removed from settings;
  `vizBridgeUrl` kept as an optional override).
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
  Plugin.pm          — main plugin (~5820 lines)
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

### Sync offset — delay-only (v0.38.0.0)
- Offset is applied in the **FFT helper** (`npd-vizfft.py`), not the browser.
- Helper keeps a ~2 s Python ring accumulated from squeezelite shmem via `buf_index` delta tracking (ring sized for 192 kHz so the full window holds on hi-res).
- **Delay-only model:** `read_back_ms = baseline_ms + offset_ms`, clamped `[0, max_offset_ms]`, with **baseline 0**, so:
  - offset `0` → read at the **live capture edge** = zero added latency = passthrough start point. (The Visualizer SqueezeLite is tuned to capture *ahead* of the room, so at 0 the visuals naturally lead the sound.)
  - offset **positive** → read further back → visuals **delayed** to match (and past) the room.
  - There is **no negative side** — we can't analyse audio the room's stream hasn't produced yet. The slider floors at 0.
- **No startup drift-into-sync:** the helper emits silent frames until the ring holds `read_back + FFT_SIZE` samples, instead of rendering a clamped-nearer-live window that visibly ramped. At offset 0 the wait is ~one FFT window; for a non-zero per-room offset it's a one-time prime of that delay.
- CLI: `--baseline-ms` (default 0), `--max-offset-ms` (default 2000). Plugin spawns the helper with both explicit.
- Offset is stored in ms and converted with the live rate, so ONE offset works across all sample rates. Per-player value is ABSOLUTE (replaces default, not additive).
- **Why "delay audio / delay video" maps onto one knob:** Simon's mental model is up=delay-audio / down=delay-video, but there's only one lever (where the visuals are read relative to captured audio). Since the room audio is untouched and the capture runs ahead, syncing always means *delaying the visuals* — so the implementation is a single 0..2000 ms visual delay; the sync point lands somewhere positive.

### Per-player offsets (v0.37.2 — named-preset model retired)
- Flat map `vizPlayerOffsets = {playerId: ms}` with `vizDelayMs` as global fallback. `_resolveOffsetForPlayer($pid)` reads the flat map, else the default. `_migratePlayerOffsets` migrated the old presets.
- Save: `/setoffset?ms&player` → writes the active room's entry. Nudge: `/setlivenoffset` → transient (live file write, NOT persisted). Tuner/Settings/helper all clamp `0..2000`.

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
# JS (extract largest <script>, stub TT vars, syntax check):
#   replace __NPD_VIZ_CFG__ etc. NO node on this Mac — parse via JavaScriptCore:
#   osascript -l JavaScript with `new Function(src)` (parse-only, no execution).
#   See scratchpad/check.js (reads the file via NSString, catches SyntaxError).
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
1. **Track-boundary dropout — PARTLY FIXED in 0.38.2.0.** The redundant `time` seek is now skipped on sequential same-room advances (only seek when joining a possibly-mid-track source), killing the double-reload blank at each track change. REMAINING: on a sequential advance the Visualizer starts the new track from 0 while the room may be up to ~1 s in (1 Hz poll latency), so the viz can sit up to ~1 s behind right after a boundary until the next natural re-settle. The real cure is position-locking (below), not the seek tweak. Watch whether the post-boundary lag is acceptable in practice.
1b. **Room↔Visualizer position drift / loop-phase jump (OPEN, the big one).** The Visualizer is a SEPARATE player mirroring the room; after the initial seek both free-run on independent clocks/buffers, so the audio↔visual skew wanders and jumps at every tone loop / track boundary. A single fixed offset can't track a moving skew — this is why calibration is "in sync one loop, out the next" and why a tone-derived offset doesn't transfer to music. Proper fix: keep the Visualizer position-LOCKED to the room (track the steady-state skew, re-seek only on real deviation — NOT every tick, which caused the old 1 Hz glitch). Then the skew is constant and one offset works everywhere. Also note a hard floor: for a LOW-latency room the visual pipeline (squeezelite→shmem→FFT→WS→render) can lag the room audio, and delay-only can't pull the visual earlier than live capture — unfixable without delaying room audio (ruled out).
2. **Confirm real per-room offset magnitudes.** With 0 = passthrough, each room's synced value is some positive ms; once Simon dials rooms in, sanity-check they sit well within the 2000 ms buffer (raise `--max-offset-ms` only if a room needs more).
3. **"Renders after music stops"** ≈ the room's offset + mirror lag. Now scales with the *tuned* offset (0 at passthrough), not a fixed 2 s baseline.
4. **Calibration accuracy:** mirror-path is closest-correct; 1 Hz spacing gives ~1 s ambiguity above ~500 ms offsets. Confirm re-runs give a consistent number.
5. **Unexplained helper restart** seen mid-capture earlier (two `helper start` lines) — possible crash; investigate if it recurs.
6. **Streaming drift:** deferred.

## Key learnings
- **Solve the right problem.** The original browser-buffer approach delayed already-seen frames, not the audio reaching the FFT analysis. Correct fix = delay the captured audio in the helper.
- **Ring-reset was the silent killer (0.37.9.0).** Wiping 4.5 s of history on any ~93 ms shmem overrun forced the offset to ramp from zero on every hiccup → glitch, non-deterministic drift, "same offset ≠ same sync." Fix: keep history, resync index only. Producer and per-client WS senders are decoupled (`_latest` under lock), so a slow client can't stall the producer — overruns are GC/CPU hiccups, now ridden through.
- **Sync is impossible on bridges** (above). Don't reopen it.
- **Use what LMS provides** (e.g. `Slim::Utils::Network::serverURL()`, `fileURLFromPath()`, existing per-player offset storage, `$_vizDesiredSource` pin).
- **Don't overcomplicate; diagnose before coding.** Gather logs/JSON-RPC across one real event before changing code. Strip to minimum viable.
- **Calibration/playback path is sensitive** — it must never destroy the room queue (snapshot/restore) and must release the device cleanly (power-cycle). Confirm approach before touching it.
- Filesystem artifacts don't persist across Claude container sessions; if source is needed, request it via SSH paste rather than guessing.
