package Plugins::NowPlayingDisplay::Plugin;

# NowPlaying — a standalone now-playing display page for LMS.
#
# Read-only with respect to the user's rooms. The server-side visualizer
# feature adds:
#   - An auto-follow loop that mirrors the active room onto a dedicated
#     headless SqueezeLite instance (the "Visualizer" player) so the
#     server can analyse the audio. All commands gated by _isVizPlayer
#     so it can only ever touch that specific MAC — _vizFindVisualizer
#     is the chokepoint.
#   - A bundled Python FFT helper (Bin/npd-vizfft.py) supervised by the
#     plugin: spawned when the visualizer is enabled, restarted on death,
#     stopped cleanly on plugin shutdown. The helper streams band data to
#     the page over WebSocket — the page never uses Web Audio.
#
# HTTP endpoints, all idempotent except the ones marked (*):
#   /plugins/NowPlayingDisplay/page             -> display HTML
#   /plugins/NowPlayingDisplay/state.json       -> per-player snapshot
#   /plugins/NowPlayingDisplay/players.json     -> list of players for the dropdown
#   /plugins/NowPlayingDisplay/biography.json   -> artist biography via MAI
#   /plugins/NowPlayingDisplay/lyrics.json      -> synced lyrics via MAI
#   /plugins/NowPlayingDisplay/setoffset    (*) -> save visualizer sync offset
#   /plugins/NowPlayingDisplay/setstyle     (*) -> save visualizer style
#   /plugins/NowPlayingDisplay/helper       (*) -> start/stop/restart/status/log
#                                                  for the bundled FFT helper

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use JSON::XS;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::OSDetect;
use Slim::Utils::Network;
use Slim::Utils::Misc;
use Slim::Web::Pages;
use Slim::Web::HTTP;
use Slim::Control::Request;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Timers;
use Time::HiRes ();
use File::Spec::Functions qw(catdir catfile);
use POSIX qw(setsid _exit);

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.nowplayingdisplay',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_NOWPLAYINGDISPLAY',
});

# Plugin preferences. LMS persists these across restarts in a prefs file.
# The settings page module (Settings.pm) reads and writes these.
my $prefs = preferences('plugin.nowplayingdisplay');
$prefs->init({
    defaultMode      => 'now-playing',
    scrollSpeed      => 'medium',              # low | medium | high
    enableVisualizer => 1,                     # on by default; settings can turn it off
    vizDelayMs       => 0,                     # global default sync offset (ms). Delay-only:
                                               #   0 = passthrough (visuals at live edge),
                                               #   positive = delay visuals to match the room
    vizLeadMs        => 0,                      # start-time lead (ms): when we mirror a room's
                                               #   track onto the Visualizer we seek it to the
                                               #   room's MEASURED current position PLUS this
                                               #   lead, so the Visualizer captures slightly
                                               #   AHEAD of the room. That guarantees the
                                               #   delay-only buffer (vizDelayMs) can always
                                               #   pull the visuals back to exact sync — the
                                               #   buffer can delay but never advance, so the
                                               #   capture must lead. 0 = legacy behaviour
                                               #   (seek only on source-switch/mid-track join,
                                               #   to the room position, no per-track reseek).
    vizSmoothing     => 'medium',              # meter responsiveness: lively|medium|smooth|verysmooth
    vizStyle         => 'segmented',           # validated set: segmented, scope, ring,
                                               #   ringVivid, ringZoom, ringClassic,
                                               #   starburst, bokeh (see _handleSetStyle)
    vizServerMode    => 0,                     # master switch for the server-side visualizer
                                               #   backend (SqueezeLite capture + FFT helper +
                                               #   mirror). Off = the supervisor stops both
                                               #   processes and the Stop buttons stick. The
                                               #   page is always server-rendered (browser
                                               #   Web Audio was removed); with this off the
                                               #   visualizer simply has no data source.
    vizBridgeUrl     => '',                    # ws://host:port/ override for the helper URL;
                                               #   blank = derive ws://<page-host>:8770/
    vizPlayerOffsets => {},                    # { playerId => ms } — per-player sync offset,
                                               #   set directly from the on-screen Save button
    vizPresets       => [],                    # DEPRECATED (named presets) — kept only so the
    vizPlayerMap     => {},                    #   one-time migration in _migratePlayerOffsets
                                               #   can fold old assignments into vizPlayerOffsets
    vizPlayerMac     => '38:f7:cd:c5:1a:2c',   # dedicated Visualizer SqueezeLite — the
                                               #   safety chokepoint for server-mode commands
    vizHelperEnabled => 1,                     # auto-start bundled FFT helper when server
                                               #   mode is on. Off only if user runs it
                                               #   externally as a service themselves.
    vizSqueezeliteEnabled => 1,                # auto-start dedicated Visualizer SqueezeLite
                                               #   alongside the helper. Off if user runs it
                                               #   externally (e.g. a separate systemd unit).
    vizAutoFollow    => 1,                      # mirror the active/selected room onto the
                                               #   Visualizer player (the current model). Turn
                                               #   OFF to test native LMS sync grouping — when
                                               #   off the plugin issues no playlist/seek
                                               #   commands to the Visualizer, so you can sync
                                               #   it into a room's group without the mirror
                                               #   clobbering the shared queue. Player+helper
                                               #   keep running (capture still works).
});

# ----------------------------------------------------------------------------
# Bundled FFT helper supervisor
# ----------------------------------------------------------------------------
#
# The plugin can spawn and supervise the Python FFT helper that backs the
# server-side visualizer. Lifecycle is:
#   * initPlugin             -> start a 5s supervisor timer if server mode is on
#   * supervisor tick (5s)   -> if helper not running and should be, restart it
#   * pref change            -> the timer's check on next tick reconciles
#   * shutdownPlugin         -> SIGTERM the helper, wait briefly, SIGKILL
#
# A pidfile under /tmp/ tracks the running PID across plugin reloads (LMS can
# reload plugins without a server restart). On startup we read the pidfile and
# check if a previous instance is still alive; if so we adopt it; if not, we
# spawn fresh. Avoids double-starts and orphaned helpers.

my $HELPER_PID_FILE = '/tmp/nowplayingdisplay-helper.pid';
my $HELPER_LOG_FILE = '/tmp/nowplayingdisplay-helper.log';
# File the plugin writes the active offset (ms) to. Helper polls this file
# every 100ms and uses it to position the FFT read window in its Python-side
# ring buffer. Writing the file is the ONLY way to change the visualiser's
# sync offset in server mode — JS-side buffering has been removed.
my $HELPER_OFFSET_FILE = '/tmp/nowplayingdisplay-offset.txt';
my $HELPER_LOG_MAX_BYTES = 1024 * 1024;        # rotate at 1MB
# Cheap pidfile-check supervisor cadence. 15 s is plenty for "respawn if my
# child died unexpectedly" semantics — we're not chasing real-time correctness.
# Keeping this longer reduces our event-loop footprint, which matters because
# LMS is single-threaded and other plugins' supervisors share the same loop.
my $HELPER_SUPERVISE_SECS = 15;

# Capture the LMS process PID at module load. Any later call to our subs that
# comes from a process with a DIFFERENT PID is a forked-but-not-exec'd child
# that's somehow still running our Perl code. That should never happen with
# the hardened spawn paths in _helperStart/_sqzStart, but it's the bug that
# caused multiple "squeezeboxserver" processes to appear and we want it to be
# self-defending against any future regression. _checkNotClone() short-circuits
# everything in a clone child so it can't multiply LMS resources further.
my $LMS_OWNER_PID = $$;
sub _isClone { return $$ != $LMS_OWNER_PID; }
sub _checkNotClone {
    return 0 unless _isClone();
    # We're in a clone child that escaped exec(). Get out NOW. No log call —
    # the log handle may be shared with the parent and writes could confuse
    # the parent's log state.
    POSIX::_exit(99);
}

# Check whether a single PID's cmdline matches a regex. ONE file open, no
# /proc directory walk — different from the orphan-hunting _findProcsByCmdline
# which is expensive. This is cheap enough to call from every pidfile read.
sub _pidCmdlineMatches {
    my ($pid, $re) = @_;
    return 0 unless $pid && $pid =~ /^\d+$/;
    my $cmdline = '';
    if (open my $fh, '<', "/proc/$pid/cmdline") {
        local $/ = undef;
        $cmdline = <$fh>;
        close $fh;
    }
    return 0 unless $cmdline;
    $cmdline =~ tr/\0/ /;
    return $cmdline =~ /$re/ ? 1 : 0;
}

# Path to our bundled Python helper. Uses the canonical LMS pattern (same as
# UPnPBridge etc): resolve via Slim::Utils::PluginManager + decodeExternalHelperPath
# so cross-platform paths work and the user never has to configure this.
sub _helperScriptPath {
    my $basedir = eval {
        Slim::Utils::PluginManager->allPlugins->{'NowPlayingDisplay'}->{'basedir'}
    };
    return undef unless $basedir;
    my $script = catfile($basedir, 'Bin', 'npd-vizfft.py');
    return Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($script);
}

# Derive listen port from vizBridgeUrl (ws://host:port/). If unparseable,
# default to 8770 — matches the documented default in CLAUDE.md and the
# settings-page placeholder.
sub _helperPort {
    my $url = $prefs->get('vizBridgeUrl') // '';
    return $1 if $url =~ m{://[^:/]+:(\d+)};
    return 8770;
}

# Read PID from pidfile if present and the process is still alive. Returns
# the PID or undef. "Alive" check is kill(0, $pid) — works for any user since
# we only ever spawn as ourselves.
sub _helperReadPid {
    return undef unless -r $HELPER_PID_FILE;
    open my $fh, '<', $HELPER_PID_FILE or return undef;
    my $pid = <$fh>;
    close $fh;
    return undef unless defined $pid;
    chomp $pid;
    return undef unless $pid =~ /^\d+$/;
    # kill(0) alone returns true for ANY process with that PID, so if our
    # original child died and the OS recycled the PID to something else,
    # we'd incorrectly think the helper is running. Verify the cmdline
    # actually looks like our helper.
    return undef unless kill(0, $pid);
    return _pidCmdlineMatches($pid, qr/npd-vizfft\.py/) ? $pid : undef;
}

sub _helperWritePid {
    my ($pid) = @_;
    open my $fh, '>', $HELPER_PID_FILE or return;
    print $fh "$pid\n";
    close $fh;
}

sub _helperClearPid {
    unlink $HELPER_PID_FILE if -e $HELPER_PID_FILE;
}

# Rotate the log if it's grown past the cap. Cheap stat check on every spawn
# (we don't care about within-run growth — just keep size bounded).
sub _helperMaybeRotateLog {
    return unless -e $HELPER_LOG_FILE;
    my $sz = -s $HELPER_LOG_FILE // 0;
    return if $sz < $HELPER_LOG_MAX_BYTES;
    rename $HELPER_LOG_FILE, "$HELPER_LOG_FILE.old";
}

# Write the current effective offset (ms) to the file the FFT helper polls.
# The plugin calls this whenever the offset changes:
#   - user nudges via the tuner buttons (transient)
#   - user saves a preset (persistent)
#   - auto-follow picks a different active room (per-room preset applies)
#   - plugin first starts the helper (initial value)
# Returns the value that was written, or undef on I/O failure.
sub _writeOffsetFile {
    my ($ms) = @_;
    return undef unless defined $ms;
    $ms = int($ms);
    # Delay-only offset model: 0 = live capture edge (passthrough), positive =
    # delay the visuals to match the room. There is no negative side (we can't
    # show audio the room's stream hasn't produced yet), and the 2s buffer caps
    # the delay at 2000ms — both matching the helper's clamp.
    $ms = 0    if $ms < 0;
    $ms = 2000 if $ms > 2000;
    open my $fh, '>', $HELPER_OFFSET_FILE or do {
        $log->warn("[helper] could not write offset file $HELPER_OFFSET_FILE: $!");
        return undef;
    };
    print $fh "$ms\n";
    close $fh;
    return $ms;
}

# Compute the offset that applies to a given player ID:
#   1. If the player has its own saved offset in vizPlayerOffsets, use it.
#   2. Otherwise fall back to vizDelayMs (the global default).
# Returns the ms value (or 0 if nothing resolves).
sub _resolveOffsetForPlayer {
    my ($playerId) = @_;
    my $offs = $prefs->get('vizPlayerOffsets') || {};
    if (ref($offs) eq 'HASH' && $playerId && defined $offs->{$playerId}
            && $offs->{$playerId} =~ /^-?\d+$/) {
        return int($offs->{$playerId});
    }
    return int($prefs->get('vizDelayMs') // 0);
}

# One-time migration from the deprecated named-preset model
# (vizPresets + vizPlayerMap) to the flat per-player map (vizPlayerOffsets).
# Idempotent: runs only while vizPlayerOffsets is empty and there's old data
# to fold in. Each previously-assigned player gets its resolved preset ms
# copied straight into vizPlayerOffsets, then the legacy prefs are cleared so
# the settings page no longer shows the old editor.
sub _migratePlayerOffsets {
    my $offs = $prefs->get('vizPlayerOffsets');
    return if ref($offs) eq 'HASH' && keys %$offs;   # already populated

    my $presets = $prefs->get('vizPresets')   || [];
    my $pmap    = $prefs->get('vizPlayerMap') || {};
    return unless ref($pmap) eq 'HASH' && keys %$pmap;

    my %byName;
    if (ref($presets) eq 'ARRAY') {
        for my $p (@$presets) {
            next unless ref($p) eq 'HASH' && defined $p->{name};
            $byName{$p->{name}} = int($p->{ms} // 0);
        }
    }
    my %new;
    for my $pid (keys %$pmap) {
        my $name = $pmap->{$pid};
        next unless defined $name && exists $byName{$name};
        $new{$pid} = $byName{$name};
    }
    return unless keys %new;

    $prefs->set('vizPlayerOffsets', \%new);
    $prefs->set('vizPresets',   []);
    $prefs->set('vizPlayerMap', {});
    $log->info('[viz] migrated ' . scalar(keys %new)
        . ' per-player offsets from deprecated presets');
}

# Check whether the system has python3 + numpy available. Cached so we don't
# fork python every supervise tick — invalidate after explicit refresh.
my $_helperDepsOk;
my $_helperDepsErr;
sub _helperDepsCheck {
    my ($force) = @_;
    return ($_helperDepsOk, $_helperDepsErr) if defined $_helperDepsOk && !$force;

    my $py = _helperPythonBin();
    if (!$py) {
        $_helperDepsOk  = 0;
        $_helperDepsErr = 'python3 not found in PATH';
        return ($_helperDepsOk, $_helperDepsErr);
    }
    # Try importing numpy. Suppress all output, just look at exit code.
    my $rc = system("$py -c 'import numpy' >/dev/null 2>&1");
    if ($rc != 0) {
        $_helperDepsOk  = 0;
        $_helperDepsErr = 'python3 found, but numpy module is missing (install python3-numpy)';
        return ($_helperDepsOk, $_helperDepsErr);
    }
    $_helperDepsOk  = 1;
    $_helperDepsErr = '';
    return ($_helperDepsOk, $_helperDepsErr);
}

# Find python3. Prefer python3, fall back to python (which on most modern
# distros is also Python 3 anyway).
sub _helperPythonBin {
    for my $cand (qw(python3 python)) {
        my $rc = system("which $cand >/dev/null 2>&1");
        return $cand if $rc == 0;
    }
    return undef;
}

# Spawn the helper. Returns the PID on success, undef on failure. The child
# is detached (setsid + new file descriptors) so it survives a plugin reload
# of the parent.
sub _helperStart {
    my $existing = _helperReadPid();
    if ($existing) {
        $log->info("[helper] already running (PID $existing); not starting another");
        return $existing;
    }

    my ($depsOk, $depsErr) = _helperDepsCheck();
    if (!$depsOk) {
        $log->warn("[helper] dependency check failed: $depsErr — not starting");
        return undef;
    }

    my $script = _helperScriptPath();
    if (!$script || !-r $script) {
        $log->error("[helper] script not found at expected path: " . ($script // '(undef)'));
        return undef;
    }

    my $py = _helperPythonBin();
    my $mac = $prefs->get('vizPlayerMac') // '';
    if (!$mac) {
        $log->warn("[helper] vizPlayerMac is empty — cannot determine shmem path");
        return undef;
    }
    my $port = _helperPort();

    # Shmem path the helper reads from. SqueezeLite writes here when started
    # with -v and -m <mac>.
    my $shmem = "/squeezelite-$mac";

    # Like _sqzStart: NO /proc scan here. Cleanup is via the explicit endpoint.

    _helperMaybeRotateLog();

    # Make sure the offset file exists with the default-offset value before we
    # spawn the helper, so its very first FFT frame uses the right shift
    # rather than 0. The helper's _refresh_offset() will read this in its
    # first iteration of the producer loop.
    my $initialOffset = int($prefs->get('vizDelayMs') // 0);
    _writeOffsetFile($initialOffset);

    my $pid = fork();
    if (!defined $pid) {
        $log->error("[helper] fork failed: $!");
        return undef;
    }
    if ($pid == 0) {
        # ====== CHILD PROCESS ======
        # CRITICAL: the child has inherited every open file descriptor from
        # LMS, including the listening sockets on ports 3483/9090/9000. If
        # exec() fails OR returns OR is somehow bypassed, the child must die
        # IMMEDIATELY — it must NEVER fall back through into Perl/LMS code,
        # because then we'd have two "squeezeboxserver" processes running on
        # the same listening sockets, both running every plugin's init, and
        # the bridge plugins each see they're being shadowed and spawn
        # replacements. Down that path is the "3x squeezeboxserver + 3x of
        # every plugin's helper" mess.
        #
        # Defence layers (any one will save us):
        #  1. POSIX::close every fd above stdio before exec
        #  2. Use POSIX::_exit (the raw _exit(2) syscall) on failure paths,
        #     not Perl's exit — Perl's exit runs END blocks and DESTROYs that
        #     can hang the child against LMS-owned resources
        #  3. Wrap exec in eval AND check return AND have a guaranteed _exit
        #     after the eval block
        eval { setsid(); };

        # Close every inherited FD above stderr. This kicks the child off the
        # LMS listening sockets so even if it somehow keeps running, it's not
        # accepting LMS traffic. /proc/self/fd is more reliable than guessing
        # a max FD number.
        if (opendir(my $fdh, '/proc/self/fd')) {
            while (my $f = readdir $fdh) {
                next unless $f =~ /^\d+$/;
                next if $f < 3;     # keep stdin/stdout/stderr for now; we re-open below
                POSIX::close($f + 0);
            }
            closedir $fdh;
        }

        # Now safely re-open stdio to our log file (the old FDs were closed by
        # the loop above if they pointed anywhere meaningful).
        # CRITICAL: untie STDIN/STDOUT/STDERR before redirecting them. LMS
        # ties these to Slim::Utils::Log::Trapper so plugin output flows into
        # LMS's log files. The Trapper class doesn't implement the OPEN tie
        # method, so `open STDOUT, '>>', $logfile` dies with "Can't locate
        # object method OPEN via package Slim::Utils::Log::Trapper". That
        # kills the child BEFORE we reach exec — squeezelite/python never
        # start, the pidfile we wrote in the parent retains a dead PID, and
        # the status endpoint lies about "running" because kill(0,$pid)
        # eventually matches recycled OS PIDs. Untie removes the tie object
        # so plain open works again.
        untie *STDIN  if tied *STDIN;
        untie *STDOUT if tied *STDOUT;
        untie *STDERR if tied *STDERR;

        open STDIN,  '<',  '/dev/null';
        open STDOUT, '>>', $HELPER_LOG_FILE;
        open STDERR, '>&', \*STDOUT;
        select STDERR; $| = 1;
        select STDOUT; $| = 1;
        print STDOUT "\n=== helper start " . scalar(localtime()) . " (pid $$) ===\n";

        # Exec. On success, control never returns. On failure, fall through to
        # the guaranteed _exit below.
        { exec { $py } $py, $script, '--shmem', $shmem, '--port', $port,
                                     '--offset-file', $HELPER_OFFSET_FILE,
                                     '--baseline-ms', 0, '--max-offset-ms', 2000; }
        print STDERR "[helper] exec($py $script ...) failed: $!\n";
        POSIX::_exit(127);
        # Belt and braces — should be unreachable.
        CORE::exit(127);
    }

    _helperWritePid($pid);
    $log->info("[helper] spawned PID $pid ($py $script --shmem $shmem --port $port --offset-file $HELPER_OFFSET_FILE --baseline-ms 0 --max-offset-ms 2000)");

    # Reap on death so we don't leave a zombie when supervisor checks fire.
    # SIGCHLD handler would be cleaner but interacts badly with LMS's event
    # loop in some versions — explicit waitpid in the supervise tick is safer.
    return $pid;
}

# Stop the running helper. SIGTERM, brief wait, SIGKILL if still alive.
sub _helperStop {
    my $pid = _helperReadPid();
    if (!$pid) {
        _helperClearPid();
        return 1;
    }
    kill('TERM', $pid);
    for (1..10) {                    # up to ~1s
        last unless kill(0, $pid);
        Time::HiRes::usleep(100_000);
    }
    if (kill(0, $pid)) {
        $log->warn("[helper] PID $pid didn't exit after SIGTERM; sending SIGKILL");
        kill('KILL', $pid);
        Time::HiRes::usleep(100_000);
    }
    # Reap so we don't leave a zombie. WNOHANG in case it's already cleaned up.
    eval { waitpid($pid, 1); };      # POSIX::WNOHANG = 1
    _helperClearPid();
    $log->info("[helper] stopped PID $pid");
    return 1;
}

sub _helperRestart {
    _helperStop();
    return _helperStart();
}

# Status snapshot for the settings UI / JSON endpoint.
sub _helperStatus {
    my $pid = _helperReadPid();
    my ($depsOk, $depsErr) = _helperDepsCheck();
    return {
        running         => $pid ? 1 : 0,
        pid             => $pid // 0,
        port            => _helperPort(),
        scriptPath      => _helperScriptPath() // '(unknown)',
        logPath         => $HELPER_LOG_FILE,
        depsOk          => $depsOk ? 1 : 0,
        depsErr         => $depsErr // '',
        pythonBin       => _helperPythonBin() // '',
        serverModeEnabled => $prefs->get('vizServerMode') ? 1 : 0,
        autoStartEnabled  => $prefs->get('vizHelperEnabled') ? 1 : 0,
    };
}

# Supervisor tick. Runs every $HELPER_SUPERVISE_SECS seconds whenever the
# plugin is loaded. Reconciles desired-vs-actual state: helper should be
# running iff (vizServerMode AND vizHelperEnabled AND deps ok). If desired
# but not running, spawn. If not desired but running, stop.
sub _helperSupervise {
    # Self-defence: if we're somehow running in a forked child of LMS (not
    # the original parent), bail out IMMEDIATELY. See the comment on
    # $LMS_OWNER_PID for context. This shouldn't fire — exec() should always
    # replace the child — but a guard here means even if some future bug
    # causes the child to keep running our Perl code, it can't multiply
    # supervisor activity in the LMS clone.
    _checkNotClone();

    # KEEP THIS CHEAP. LMS runs a single-threaded event loop; this tick must
    # complete in microseconds, not anything you can feel. Earlier versions
    # walked /proc looking for orphans every 5 s — that stole enough event-loop
    # time on busy systems to delay OTHER plugins' supervisors (UPnPBridge,
    # CastBridge, etc.), which then thought their own child processes were
    # dead and spawned replacements. Net effect: my plugin enabled = bridge
    # plugins multiplying their squeezelite-like workers.
    #
    # Rule: pidfile reads only here. No /proc. No orphan hunting. If the user
    # wants to clean up orphans they can use the /squeezelite?action=cleanup
    # and /helper?action=cleanup endpoints (or just restart LMS).
    my $serverOn = $prefs->get('vizServerMode') ? 1 : 0;

    # --- Helper (Python FFT) ---
    {
        my $wantOn = $serverOn && $prefs->get('vizHelperEnabled');
        my $pid    = _helperReadPid();
        if ($wantOn && !$pid) {
            my ($depsOk, undef) = _helperDepsCheck();
            if ($depsOk) {
                $log->info("[helper] supervisor: not running but should be; starting");
                _helperStart();
            }
        } elsif (!$wantOn && $pid) {
            $log->info("[helper] supervisor: running but should not be; stopping");
            _helperStop();
        }
    }

    # --- SqueezeLite (dedicated Visualizer instance) ---
    {
        my $wantOn = $serverOn && $prefs->get('vizSqueezeliteEnabled');
        my $pid    = _sqzReadPid();
        if ($wantOn && !$pid) {
            $log->info("[sqz] supervisor: not running but should be; starting");
            _sqzStart();
        } elsif (!$wantOn && $pid) {
            $log->info("[sqz] supervisor: running but should not be; stopping");
            _sqzStop();
        }
    }

    Slim::Utils::Timers::setTimer(undef,
        Time::HiRes::time() + $HELPER_SUPERVISE_SECS,
        \&_helperSupervise);
}

# ----------------------------------------------------------------------------
# /helper endpoint — start/stop/restart/status/log over HTTP for the settings UI
# ----------------------------------------------------------------------------
# Find processes whose /proc/<pid>/cmdline matches a regex. Returns a list of
# PIDs. Used to detect existing squeezelite/helper instances that aren't
# tracked by our pidfile — orphans from prior plugin sessions, manually
# started instances, or runaways from a crashed plugin. Without this, our
# pidfile-only check happily spawns duplicates on top.
#
# Only matches OUR processes (running as the LMS user); we never look at or
# touch other users' processes. /proc/<pid>/cmdline of a process not owned
# by us reads as empty / EACCES, so the regex won't match.
sub _findProcsByCmdline {
    my ($re) = @_;
    my @pids;
    opendir(my $dh, '/proc') or return @pids;
    while (my $entry = readdir $dh) {
        next unless $entry =~ /^\d+$/;
        my $pid = $entry;
        my $cmdline = '';
        if (open my $fh, '<', "/proc/$pid/cmdline") {
            local $/ = undef;
            $cmdline = <$fh>;
            close $fh;
        }
        next unless $cmdline;
        # /proc cmdline uses NUL separators between args
        $cmdline =~ tr/\0/ /;
        push @pids, $pid if $cmdline =~ /$re/;
    }
    closedir $dh;
    return @pids;
}

# Kill any process matching the regex that ISN'T our tracked PID. Used at
# spawn-time to clean up orphans before starting fresh — prevents two
# squeezelites fighting for the same MAC or two helpers fighting for the
# same WebSocket port.
sub _killOrphans {
    my ($re, $keepPid, $label) = @_;
    my @found = _findProcsByCmdline($re);
    my @orphans = grep { !defined($keepPid) || $_ != $keepPid } @found;
    return 0 unless @orphans;
    $log->info("[$label] found " . scalar(@orphans) . " orphan process(es): @orphans — killing");
    for my $pid (@orphans) {
        kill('TERM', $pid);
    }
    # Brief grace, then SIGKILL stragglers.
    Time::HiRes::usleep(200_000);
    for my $pid (@orphans) {
        if (kill(0, $pid)) {
            kill('KILL', $pid);
        }
    }
    # Reap zombies (our children).
    for my $pid (@orphans) {
        eval { waitpid($pid, 1); };               # POSIX::WNOHANG = 1
    }
    return scalar(@orphans);
}

# ----------------------------------------------------------------------------
# Bundled SqueezeLite supervisor — same pattern as the FFT helper
# ----------------------------------------------------------------------------
#
# The dedicated headless Visualizer SqueezeLite instance. We fork+exec a system
# squeezelite binary (located via PATH) with an argv list (no shell quoting
# issues — the systemd unit had a MAC-with-colons problem that this avoids).
# Snd-dummy must be loaded at boot so the Dummy ALSA card exists; that's the
# ONE thing the user must still do at the system level (it requires root).
#
# Privilege note: the LMS plugin runs as 'squeezeboxserver'. For the spawned
# SqueezeLite to open the Dummy ALSA device the squeezeboxserver user must be
# in the 'audio' group. Setup README covers the one-time
#   sudo usermod -aG audio squeezeboxserver
# step. If group access fails, the squeezelite log file shows the ALSA error.

my $SQZ_PID_FILE = '/tmp/nowplayingdisplay-squeezelite.pid';
my $SQZ_LOG_FILE = '/tmp/nowplayingdisplay-squeezelite.log';

# Locate the system squeezelite binary via PATH. Cached for the life of the
# plugin — the binary doesn't move at runtime. Returns undef if not installed.
my $_sqzBin;
sub _sqzBin {
    return $_sqzBin if defined $_sqzBin;
    for my $cand ('/usr/bin/squeezelite', '/usr/local/bin/squeezelite', '/opt/squeezelite/squeezelite') {
        if (-x $cand) { $_sqzBin = $cand; return $_sqzBin; }
    }
    chomp(my $found = `which squeezelite 2>/dev/null`);
    $_sqzBin = ($found && -x $found) ? $found : '';
    return $_sqzBin;
}

# Build the squeezelite argv list from prefs. Returned as a list (NOT a shell
# string) so exec() takes it directly with no quoting/parsing in the middle.
# This is exactly the bug the systemd unit hit: "-n Visualizer -m aa:bb:cc..."
# under shell parsing turned the MAC's colons into argument separators.
sub _sqzArgs {
    my $mac = $prefs->get('vizPlayerMac') // '';
    $mac =~ s/^\s+|\s+$//g;
    my $name = 'Visualizer';
    my $device = 'plughw:CARD=Dummy,DEV=0';   # snd-dummy ALSA card
    my $lms  = '127.0.0.1';                   # local LMS
    # Buffer tuning for the Visualizer SqueezeLite. Two goals:
    #
    # 1) Keep this player's effective latency LOW so it's always ahead of any
    #    real room player (which buffers more for safety). That way the only
    #    offsetting we ever need is "delay the visualizer to wait for the
    #    room" — never "speed up the visualizer to catch up", which is
    #    impossible (you can't see the future).
    # 2) Make the SHMEM RING DEEP so the FFT helper can read back many
    #    hundreds of milliseconds of audio history. Some rooms (WISA
    #    systems, certain bridge endpoints) lag 500+ ms behind LMS; the
    #    helper needs that much history in the ring to time-shift its FFT
    #    read position to match.
    #
    # -b stream:output sizes the stream and output buffers in KILOBYTES.
    #   stream=256 keeps ingest tight (low decode latency).
    #   output=8192 gives ~1.5-2s of audio history in the visualizer shmem
    #   ring at 16-bit stereo 44.1kHz (8192 KB / 4 bytes per frame =
    #   2,097,152 frames; / 44100 Hz = 47s of mono-frame storage, halved
    #   for stereo, halved again because shmem usually mirrors a fraction
    #   of the output buffer — net ~1.5-2s of effective history).
    # -a 20:2 sets the ALSA buffer time to 20 ms (default 40), keeping the
    #   snd-dummy consumption point tight to where squeezelite is writing.
    #
    # Note: glitches on network hiccups don't matter — nothing actually
    # *listens* to snd-dummy's output. The visualizer just analyzes the
    # samples that pass through.
    return (
        '-n', $name,
        '-m', $mac,
        '-o', $device,
        '-v',                                 # CRITICAL: enables shmem buffer
        '-s', $lms,
        '-b', '256:8192',                     # small ingest, deep output ring
        '-a', '20:2:::',                      # 20 ms ALSA buffer, 2 periods
    );
}

# PID/log helpers — same pattern as _helper*. The duplication is small enough
# that abstracting it (a Process class etc.) would be more code than it saves.

sub _sqzReadPid {
    return undef unless -r $SQZ_PID_FILE;
    open my $fh, '<', $SQZ_PID_FILE or return undef;
    my $pid = <$fh>;
    close $fh;
    return undef unless defined $pid;
    chomp $pid;
    return undef unless $pid =~ /^\d+$/;
    return undef unless kill(0, $pid);
    # Verify the PID is actually squeezelite, not a recycled OS PID. See the
    # comment in _helperReadPid.
    return _pidCmdlineMatches($pid, qr/squeezelite/) ? $pid : undef;
}

sub _sqzWritePid {
    my ($pid) = @_;
    open my $fh, '>', $SQZ_PID_FILE or return;
    print $fh "$pid\n";
    close $fh;
}

sub _sqzClearPid { unlink $SQZ_PID_FILE if -e $SQZ_PID_FILE; }

sub _sqzMaybeRotateLog {
    return unless -e $SQZ_LOG_FILE;
    my $sz = -s $SQZ_LOG_FILE // 0;
    return if $sz < $HELPER_LOG_MAX_BYTES;
    rename $SQZ_LOG_FILE, "$SQZ_LOG_FILE.old";
}

# Check that the Dummy ALSA card is present — that's the proxy for "is
# snd-dummy loaded". Without it the spawn will start but immediately fail with
# an ALSA error. Reading /proc/asound/cards is cheap.
sub _sqzDummyCardLoaded {
    return 0 unless -r '/proc/asound/cards';
    open my $fh, '<', '/proc/asound/cards' or return 0;
    my $present = 0;
    while (my $line = <$fh>) {
        if ($line =~ /\bDummy\b/) { $present = 1; last; }
    }
    close $fh;
    return $present;
}

sub _sqzStart {
    my $existing = _sqzReadPid();
    if ($existing) {
        $log->info("[sqz] already running (PID $existing); not starting another");
        return $existing;
    }

    my $bin = _sqzBin();
    if (!$bin) {
        $log->error("[sqz] squeezelite binary not found in /usr/bin or PATH");
        return undef;
    }

    if (!_sqzDummyCardLoaded()) {
        $log->warn("[sqz] Dummy ALSA card not present — load snd-dummy first " .
                   "(sudo modprobe snd-dummy, or put 'snd-dummy' in /etc/modules-load.d/)");
        return undef;
    }

    my $mac = $prefs->get('vizPlayerMac') // '';
    $mac =~ s/^\s+|\s+$//g;
    if (!$mac) {
        $log->error("[sqz] vizPlayerMac is empty — cannot start without a MAC");
        return undef;
    }

    # NOTE: we do NOT scan /proc to clean up other squeezelites here. Walking
    # /proc takes enough event-loop time that other plugins' supervisors miss
    # heartbeats and respawn their own children. If you need to clean up
    # orphans, use /plugins/NowPlayingDisplay/squeezelite?action=cleanup which
    # does the scan deliberately on user request, not on every spawn.

    _sqzMaybeRotateLog();

    my @args = _sqzArgs();
    my $pid = fork();
    if (!defined $pid) {
        $log->error("[sqz] fork failed: $!");
        return undef;
    }
    if ($pid == 0) {
        # See the long comment in _helperStart for the rationale. The child
        # MUST exit (via exec replacement or _exit), never fall through into
        # LMS event-loop code, because it inherited LMS's listening sockets
        # and would create a phantom "squeezeboxserver" running on the same
        # ports — which is the root cause of the multi-process cascade.
        eval { setsid(); };

        if (opendir(my $fdh, '/proc/self/fd')) {
            while (my $f = readdir $fdh) {
                next unless $f =~ /^\d+$/;
                next if $f < 3;
                POSIX::close($f + 0);
            }
            closedir $fdh;
        }

        # See the long comment in _helperStart re: untie. Same issue here.
        untie *STDIN  if tied *STDIN;
        untie *STDOUT if tied *STDOUT;
        untie *STDERR if tied *STDERR;

        open STDIN,  '<',  '/dev/null';
        open STDOUT, '>>', $SQZ_LOG_FILE;
        open STDERR, '>&', \*STDOUT;
        select STDERR; $| = 1;
        select STDOUT; $| = 1;
        print STDOUT "\n=== squeezelite start " . scalar(localtime()) . " (pid $$) ===\n";

        # exec() with an argv LIST — no shell, no quoting concerns. The
        # `exec { $bin } $bin, @args` form is the explicit-filename form,
        # safest against any indirect-object misparsing.
        { exec { $bin } $bin, @args; }
        print STDERR "[sqz] exec($bin ...) failed: $!\n";
        POSIX::_exit(127);
        CORE::exit(127);
    }

    _sqzWritePid($pid);
    $log->info("[sqz] spawned PID $pid ($bin " . join(' ', @args) . ")");
    return $pid;
}

sub _sqzStop {
    my $pid = _sqzReadPid();
    if (!$pid) {
        _sqzClearPid();
        return 1;
    }
    kill('TERM', $pid);
    for (1..10) {
        last unless kill(0, $pid);
        Time::HiRes::usleep(100_000);
    }
    if (kill(0, $pid)) {
        $log->warn("[sqz] PID $pid didn't exit after SIGTERM; sending SIGKILL");
        kill('KILL', $pid);
        Time::HiRes::usleep(100_000);
    }
    eval { waitpid($pid, 1); };
    _sqzClearPid();
    $log->info("[sqz] stopped PID $pid");
    return 1;
}

sub _sqzRestart {
    _sqzStop();
    return _sqzStart();
}

sub _sqzStatus {
    my $pid = _sqzReadPid();
    return {
        running           => $pid ? 1 : 0,
        pid               => $pid // 0,
        binary            => _sqzBin() // '',
        dummyLoaded       => _sqzDummyCardLoaded() ? 1 : 0,
        logPath           => $SQZ_LOG_FILE,
        autoStartEnabled  => $prefs->get('vizSqueezeliteEnabled') ? 1 : 0,
        serverModeEnabled => $prefs->get('vizServerMode') ? 1 : 0,
    };
}

sub _handleSqueezelite {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $action = $q{action} // 'status';

    my $out;
    if ($action eq 'start')        { my $pid = _sqzStart(); $out = _sqzStatus(); $out->{action} = 'start';   $out->{ok} = $pid ? \1 : \0; }
    elsif ($action eq 'stop')      { _sqzStop();            $out = _sqzStatus(); $out->{action} = 'stop';    $out->{ok} = \1; }
    elsif ($action eq 'restart')   { _sqzRestart();         $out = _sqzStatus(); $out->{action} = 'restart'; $out->{ok} = $out->{running} ? \1 : \0; }
    elsif ($action eq 'cleanup') {
        # User-triggered orphan cleanup. Scans /proc for squeezelite processes
        # using OUR configured MAC and kills any that aren't tracked in our
        # pidfile. Deliberately opt-in (not in the supervisor) because the
        # scan is expensive enough to disturb LMS's event loop.
        my $tracked = _sqzReadPid();
        my $mac = $prefs->get('vizPlayerMac') // '';
        $mac =~ s/^\s+|\s+$//g;
        my $killed = 0;
        if ($mac) {
            my $macRe = quotemeta(lc($mac));
            $killed = _killOrphans('squeezelite.*-m\s+' . $macRe, $tracked, 'sqz-cleanup');
        }
        $out = _sqzStatus();
        $out->{action}    = 'cleanup';
        $out->{ok}        = \1;
        $out->{killed}    = $killed;
    }
    elsif ($action eq 'log') {
        my $tail = '';
        if (-r $SQZ_LOG_FILE) {
            my $size = -s $SQZ_LOG_FILE;
            my $offset = $size > 16384 ? $size - 16384 : 0;
            if (open my $fh, '<', $SQZ_LOG_FILE) {
                seek $fh, $offset, 0;
                local $/ = undef;
                $tail = <$fh>;
                close $fh;
            }
        } else {
            $tail = "(no log file yet at $SQZ_LOG_FILE)\n";
        }
        _send($httpClient, $response, 'text/plain; charset=utf-8', $tail, no_cache => 1);
        return;
    }
    else { $out = _sqzStatus(); $out->{action} = 'status'; }

    _send($httpClient, $response, 'application/json', encode_json($out), no_cache => 1);
}

# ----------------------------------------------------------------------------
# Sync calibration
# ----------------------------------------------------------------------------
#
# Two pieces:
#   /plugins/NowPlayingDisplay/calibration/<tone>.wav
#       Static file server for the calibration tones from Bin/. LMS fetches
#       these via HTTP when commanded to "playlist play <url>".
#   /plugins/NowPlayingDisplay/calibrate?action=start|stop&tone=<>&player=<>
#       Orchestrates calibration on a named player. Sends the LMS playlist
#       command to play the tone WAV, schedules an auto-stop in case the
#       browser disappears mid-calibration.
#
# Calibration plays a known 1 Hz beep train through the room (and, via the
# mirror, onto the Visualizer). The browser-side JS detects each beep onset in
# the server-streamed audio and drives the bouncing-ball A/V-sync view, so the
# user raises the offset until the on-screen strike/flash lands on the beep
# they hear. The tuned value is saved to the per-player offset map
# (vizPlayerOffsets) so it Just Works on the next page load for that player.

# Tones we know about. Adding a new one is: drop the WAV in Bin/, add an
# entry here with its center frequency for the eyeball-mode visualizer band.
my %CALIBRATION_TONES = (
    '1khz'  => { file => 'calibration-1khz.wav',  freq => 1000, label => '1 kHz' },
    '200hz' => { file => 'calibration-200hz.wav', freq =>  200, label => '200 Hz' },
);

# Track which calibrations are running so we can auto-stop them. Keyed by
# player ID. Value is a Slim timer handle we can kill if the browser sends
# an explicit stop before the auto-stop fires.
my %CALIBRATION_ACTIVE;

# Player the visualizer mirror should follow, as chosen by the display page (or
# pinned by calibration). Empty = auto (most-active room). Declared here because
# the calibration handler below reads/writes it; the auto-follow code further
# down uses the same variable.
my $_vizDesiredSource = '';

# Mirror trackers — declared here (not further down) so _calibrationStop above
# the auto-follow code can reset them. _vizMirrorAction sets them; resetting them
# forces the next reconcile to re-issue a fresh mirror.
my $_vizLastSource     = '';   # client id of source we're currently mirroring
my $_vizLastTrackUrl   = '';   # last track url commanded to Visualizer

# Calibration WAV duration in seconds — keep in sync with the WAV files.
# Plus a small grace period for the player to actually stop.
# Calibration tone is now looped (repeat-track on) until the user explicitly
# stops it. The safety auto-stop is just a backstop in case the browser tab
# is closed without sending a stop — 10 minutes is plenty for any tuning
# session while ensuring the room doesn't beep forever if forgotten.
my $CALIBRATION_PLAY_SECONDS  = 16;     # length of one play-through of the WAV
my $CALIBRATION_AUTOSTOP_SECS = 600;    # 10 min — safety net only

sub _handleCalibrationWav {
    my ($httpClient, $response) = @_;
    # Extract the requested filename from the URI. Locked down to
    # known-good tones so this can't serve anything else in Bin/.
    my $path = $response->request->uri->path;
    my ($name) = $path =~ m{/calibration/([\w-]+\.wav)\z};
    if (!$name) {
        $response->code(404);
        Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'');
        return;
    }
    my $allowed = 0;
    for my $tone (values %CALIBRATION_TONES) {
        if ($tone->{file} eq $name) { $allowed = 1; last; }
    }
    if (!$allowed) {
        $response->code(404);
        Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'');
        return;
    }

    my $basedir = eval {
        Slim::Utils::PluginManager->allPlugins->{'NowPlayingDisplay'}->{'basedir'}
    };
    my $file = $basedir ? catfile($basedir, 'Bin', $name) : undef;
    $file = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($file) if $file;

    if (!$file || !-r $file) {
        $log->error("[calib] WAV file not found: " . ($file // '(undef)'));
        $response->code(404);
        Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \'');
        return;
    }

    # Read and serve. WAVs are ~1.4MB each; reading whole into memory is
    # fine. Not using streaming because Slim::Web::HTTP's response model is
    # whole-body anyway.
    my $body = '';
    if (open my $fh, '<', $file) {
        binmode $fh;
        local $/ = undef;
        $body = <$fh>;
        close $fh;
    }
    $response->code(200);
    $response->header('Content-Type'   => 'audio/wav');
    $response->header('Content-Length' => length($body));
    # No-cache so a re-generated tone (different volume, different burst
    # pattern in a future version) gets picked up immediately. Tiny cost
    # for an operation only run during calibration.
    $response->header('Cache-Control' => 'no-store');
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body);
}

# Snapshot a player's current queue + position + transport state so calibration
# can restore the user's music afterwards (option a). Uses the status query so
# it's robust across LMS versions and needs no extra imports. Returns a hashref;
# an empty urls list means the room was idle (nothing to restore).
sub _calSnapshotPlaylist {
    my ($client) = @_;
    my %snap = (urls => [], index => 0, time => 0, mode => 'stop');
    eval {
        my $req = Slim::Control::Request->new($client->id, ['status', 0, 99999, 'tags:u']);
        $req->execute();
        my $loop = $req->getResult('playlist_loop') || [];
        # Capture real track URLs only — NEVER the calibration tone itself (a
        # defensive guard against snapshotting a tone that's already playing).
        $snap{urls}  = [ grep { $_ !~ m{/calibration-[\w-]+\.wav(?:\?|\z)} }
                         map  { $_->{url} }
                         grep { defined $_->{url} } @$loop ];
        my $idx = $req->getResult('playlist_cur_index');
        my $t   = $req->getResult('time');
        $snap{index} = (defined $idx && $idx =~ /^\d+$/)      ? $idx : 0;
        $snap{time}  = (defined $t   && $t   =~ /^[\d.]+$/)   ? $t   : 0;
        $snap{mode}  = $req->getResult('mode') // 'stop';
    };
    return \%snap;
}

# Restore a snapshot taken by _calSnapshotPlaylist: rebuild the queue, jump to
# the track + position, and match the prior play/pause/stop state. Safe to call
# with an empty/idle snapshot (just clears).
sub _calRestorePlaylist {
    my ($client, $snap) = @_;
    return unless $client && $snap && ref($snap->{urls}) eq 'ARRAY';
    my @urls = @{ $snap->{urls} };
    # Nothing to restore → do NOT clear. _calibrationStop has already stopped +
    # cleared the tone by the time we get here, so an empty snapshot means "leave
    # the room empty", not "wipe whatever's there". (Clearing here on an empty
    # snapshot is how a bad/streaming snapshot used to nuke the user's queue.)
    return unless @urls;
    eval { $client->execute(['playlist', 'clear']); };
    for my $u (@urls) {
        eval { $client->execute(['playlist', 'add', $u]); };
    }
    eval { $client->execute(['playlist', 'index', ($snap->{index} || 0)]); };
    if ($snap->{time} && $snap->{time} > 0) {
        eval { $client->execute(['time', $snap->{time}]); };
    }
    my $mode = $snap->{mode} // 'play';
    if    ($mode eq 'pause') { eval { $client->execute(['pause', 1]); }; }
    elsif ($mode eq 'stop')  { eval { $client->execute(['stop']);     }; }
    # 'play' — the 'playlist index' above already resumed playback.
}

sub _handleCalibrate {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $action = $q{action} // 'status';
    my $tone   = $q{tone}   // '1khz';
    my $playerId = $q{player} // '';

    my $tcfg = $CALIBRATION_TONES{$tone};
    if (!$tcfg) {
        _send($httpClient, $response, 'application/json',
              encode_json({ ok => \0, error => "unknown tone: $tone" }),
              no_cache => 1);
        return;
    }

    # Resolve the player. forClient() returns the Slim::Player::Client object,
    # or undef if the MAC isn't registered. Safety: refuse to calibrate against
    # the Visualizer player itself — that'd be measuring the system against
    # itself (always zero) and would interrupt the visualizer's audio capture.
    $playerId =~ s/^\s+|\s+$//g;
    my $vizMac = $prefs->get('vizPlayerMac') // '';
    if (lc($playerId) eq lc($vizMac)) {
        _send($httpClient, $response, 'application/json',
              encode_json({ ok => \0, error => 'cannot calibrate the Visualizer player itself' }),
              no_cache => 1);
        return;
    }
    my $client = $playerId ? Slim::Player::Client::getClient($playerId) : undef;
    if (!$client) {
        _send($httpClient, $response, 'application/json',
              encode_json({ ok => \0, error => "unknown player: $playerId" }),
              no_cache => 1);
        return;
    }

    if ($action eq 'start') {
        # Resolve the calibration WAV's path on disk. The plugin runs on the
        # LMS box; LMS can play local files natively via file:// URLs — same
        # as your music library — bypassing HTTP entirely. This avoids the
        # self-referential loop where LMS would otherwise try to open an
        # HTTP URL that points back at itself (which trips a socket-bind
        # quirk in Slim::Player::Protocols::HTTP and never connects).
        my $basedir = eval {
            Slim::Utils::PluginManager->allPlugins->{'NowPlayingDisplay'}->{'basedir'}
        };
        my $wavPath = $basedir ? catfile($basedir, 'Bin', $tcfg->{file}) : undef;
        $wavPath = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($wavPath) if $wavPath;
        if (!$wavPath || !-r $wavPath) {
            $log->error("[calib] WAV not found at expected path: " . ($wavPath // '(undef)'));
            _send($httpClient, $response, 'application/json',
                  encode_json({ ok => \0, error => 'calibration WAV missing on disk' }),
                  no_cache => 1);
            return;
        }
        my $url = Slim::Utils::Misc::fileURLFromPath($wavPath);
        $log->info("[calib] start tone=$tone player=$playerId url=$url");

        my $stopRef = sub { _calibrationStop($playerId); };

        # If calibration is ALREADY running on this room, the live queue is the
        # TONE now. Re-snapshotting here would capture the tone (or an empty,
        # mid-transition queue) and PERMANENTLY lose the user's music — the
        # snapshot is the only copy once the tone is playing. So on a re-start
        # REUSE the original snapshot + original pre-calibration mirror pin.
        my $existing = delete $CALIBRATION_ACTIVE{$playerId};
        eval { Slim::Utils::Timers::killTimers(undef, $existing->{stop_ref}); } if $existing;

        my ($snap, $prevRepeat, $prevDesired);
        if ($existing) {
            $snap        = $existing->{snapshot};
            $prevRepeat  = $existing->{prev_repeat};
            $prevDesired = $existing->{prev_desired};
            $log->info("[calib] re-start on active player $playerId; reusing saved snapshot ("
                       . scalar(@{ $snap->{urls} || [] }) . " tracks) — NOT re-snapshotting the tone");
        } else {
            # Fresh start. Capture repeat + queue BEFORE we replace it with the tone.
            $prevRepeat = eval {
                my $req = Slim::Control::Request->new($client->id, ['playlist', 'repeat', '?']);
                $req->execute();
                $req->getResult('_repeat');
            };
            $prevRepeat  = 0 unless defined $prevRepeat && $prevRepeat =~ /^\d+$/;
            $prevDesired = $_vizDesiredSource;
            $snap = _calSnapshotPlaylist($client);

            # QUEUE SAFETY: if the room is actively playing/paused but the
            # snapshot captured ZERO tracks, the snapshot is unreliable (a
            # streaming track, or a mid-track transition 'status' didn't return).
            # Replacing the live queue with the tone now would lose the user's
            # music for good. Refuse rather than risk it.
            my $busy    = defined $snap->{mode} && $snap->{mode} ne 'stop';
            my $ntracks = scalar(@{ $snap->{urls} || [] });
            if ($busy && $ntracks == 0) {
                $log->warn("[calib] ABORT start: room mode=$snap->{mode} but snapshot has 0 tracks; "
                           . "refusing so we don't clear the queue");
                _send($httpClient, $response, 'application/json',
                      encode_json({ ok => \0,
                          error => "Couldn't safely save this room's play queue (streaming track?). "
                                 . "Calibration aborted to protect your music — pause the room, or use a local track." }),
                      no_cache => 1);
                return;
            }
        }

        # Mark calibration active BEFORE playing anything. This makes the
        # mirror (which we override-on below) carry the tone to the Visualizer.
        $CALIBRATION_ACTIVE{$playerId} = {
            stop_ref     => $stopRef,
            prev_repeat  => $prevRepeat,
            snapshot     => $snap,
            viz_mac      => $vizMac,
            prev_desired => $prevDesired,   # restore the mirror pin on stop
        };

        # Pin the auto-follow mirror to THIS room for the duration. The mirror
        # then delivers the room's tone to the Visualizer through the same
        # play+seek path as normal playback — one source, one stream path — so
        # the offset you tune is the one that's actually correct in real use.
        # (True sample-sync isn't possible here: every room is a bridge that
        # won't feed a synced SqueezeLite follower — proven earlier — so the
        # mirror path is the closest correct equivalent.)
        $_vizDesiredSource = $playerId;

        # Play the looping tone on the ROOM, so you HEAR it. Its queue is saved
        # above and restored on stop. The Visualizer gets the tone via the
        # mirror (see above), NOT a separate play — that's what keeps the heard
        # beep and the seen beep on the same clock.
        $client->execute(['playlist', 'play', $url]);
        $client->execute(['playlist', 'repeat', 1]);

        my $vizClient = $vizMac ? Slim::Player::Client::getClient($vizMac) : undef;
        if (!$vizClient) {
            $log->warn("[calib] no Visualizer player ($vizMac) — ball won't animate");
        }

        # Safety net: stop after a generous timeout so the room doesn't beep
        # forever if the browser tab is closed without a stop.
        # CRITICAL: register the timer against undef (NOT $client) so it matches
        # the killTimers(undef, $stopRef) calls in _calibrationStop / re-start.
        # LMS matches timers on the (object, coderef) PAIR — a timer set on
        # $client could never be cancelled with undef, so the 10-min fuse
        # survived every normal Stop and later fired during ordinary playback,
        # running the destructive teardown (playlist clear + power-cycle) and
        # WIPING the user's queue "for no reason".
        Slim::Utils::Timers::setTimer(undef,
            Time::HiRes::time() + $CALIBRATION_AUTOSTOP_SECS,
            $stopRef);

        _send($httpClient, $response, 'application/json',
              encode_json({
                  ok => \1, action => 'start', tone => $tone,
                  freq => $tcfg->{freq}, duration => $CALIBRATION_PLAY_SECONDS,
                  player => $playerId, url => $url,
              }),
              no_cache => 1);
        return;
    }
    elsif ($action eq 'stop') {
        _calibrationStop($playerId);
        _send($httpClient, $response, 'application/json',
              encode_json({ ok => \1, action => 'stop', player => $playerId }),
              no_cache => 1);
        return;
    }

    # status (default)
    _send($httpClient, $response, 'application/json',
          encode_json({
              ok => \1, action => 'status',
              active => $CALIBRATION_ACTIVE{$playerId} ? \1 : \0,
              tones => [ map {
                  { id => $_, label => $CALIBRATION_TONES{$_}{label},
                    freq => $CALIBRATION_TONES{$_}{freq} }
              } sort keys %CALIBRATION_TONES ],
          }),
          no_cache => 1);
}

# Stop calibration on a player: fully tear down the playback so the device
# audio output is released. Just calling 'stop' / 'playlist clear' leaves
# the stream half-open on some players (especially with local file:// URLs
# that go through LMS's streaming pipeline) — the device handle stays held
# and subsequent track plays get blocked or skip. The reliable way to
# release everything is a power-cycle: power 0 tears down all streams and
# closes the device, power 1 reopens it clean.
#
# Idempotent — safe to call when no calibration is running.
# Stop calibration on a player: release the tone on the Visualizer, put the
# user's music back on the room, and un-suppress the mirror. Single-arg now —
# everything else (repeat, snapshot, viz mac) comes from the active entry.
# Idempotent — safe to call when no calibration is running.
sub _calibrationStop {
    my ($playerId) = @_;
    return unless $playerId;

    my $entry      = $CALIBRATION_ACTIVE{$playerId};

    # STALE-TIMER / DOUBLE-STOP SAFETY: only ever run the destructive teardown
    # below (stop + playlist clear + power-cycle on the ROOM) when calibration is
    # ACTUALLY active for this player. If there's no active entry, calibration is
    # already stopped — there's no tone to clear and no snapshot to restore, so
    # touching the room here would just wipe whatever the user is now playing.
    # This is the belt-and-braces guard behind the timer-cancel fix: even if a
    # stray stop fires, it can never clear a live queue.
    return unless $entry;

    my $prevRepeat = $entry ? $entry->{prev_repeat} : 0;
    my $snap       = $entry ? $entry->{snapshot}    : undef;
    my $vizMac     = $entry ? $entry->{viz_mac}     : ($prefs->get('vizPlayerMac') // '');

    # Restore the mirror pin to whatever it was before calibration (so we don't
    # leave the Visualizer locked to the calibration room).
    if ($entry && exists $entry->{prev_desired}) {
        $_vizDesiredSource = $entry->{prev_desired};
    }

    # Reset the mirror trackers. We're about to clear the Visualizer, so the
    # next reconcile MUST re-issue a fresh mirror — even if the same room
    # re-starts the SAME tone. Without this, $_vizLastTrackUrl still equals the
    # tone URL, the reconcile sees "same track already mirrored", skips the
    # play, and the Visualizer sits empty → the browser shows "Waiting for
    # calibration tone" forever (the start/stop race you hit).
    $_vizLastSource   = '';
    $_vizLastTrackUrl = '';

    # 1. Stop + clear the tone on the Visualizer. Once the mirror is
    #    un-suppressed (below) its next reconcile re-takes the Visualizer.
    if ($vizMac) {
        my $viz = Slim::Player::Client::getClient($vizMac);
        if ($viz) {
            eval { $viz->execute(['stop']); };
            eval { $viz->execute(['playlist', 'clear']); };
            # Clear the calibration loop's repeat (set on the Visualizer while the
            # tone played) so normal mirrored playback — which re-plays each track
            # itself — doesn't loop a single track.
            eval { $viz->execute(['playlist', 'repeat', 0]); };
        }
    }

    # 2. Restore the ROOM. Stop the tone, power-cycle to release the file://
    #    device handle cleanly (proven necessary on these players), restore the
    #    repeat mode, then put the user's queue + position + transport back.
    my $client = Slim::Player::Client::getClient($playerId);
    if ($client) {
        $log->info("[calib] stop player=$playerId restore-repeat=" . ($prevRepeat // '?')
                   . " tracks=" . ($snap ? scalar(@{$snap->{urls} || []}) : 0));
        eval { $client->execute(['stop']); };
        eval { $client->execute(['playlist', 'clear']); };
        eval { $client->execute(['power', 0]); };
        eval { $client->execute(['power', 1]); };
        if (defined $prevRepeat && $prevRepeat =~ /^\d+$/) {
            eval { $client->execute(['playlist', 'repeat', $prevRepeat]); };
        }
        _calRestorePlaylist($client, $snap) if $snap;
    }

    # 3. Removing the entry un-suppresses the mirror.
    if (my $e = delete $CALIBRATION_ACTIVE{$playerId}) {
        eval { Slim::Utils::Timers::killTimers(undef, $e->{stop_ref}); };
    }
}

sub _handleHelper {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $action = $q{action} // 'status';

    my $out;
    if ($action eq 'start') {
        my $pid = _helperStart();
        $out = _helperStatus();
        $out->{action} = 'start';
        $out->{ok}     = $pid ? \1 : \0;
    } elsif ($action eq 'stop') {
        _helperStop();
        $out = _helperStatus();
        $out->{action} = 'stop';
        $out->{ok}     = \1;
    } elsif ($action eq 'restart') {
        _helperRestart();
        $out = _helperStatus();
        $out->{action} = 'restart';
        $out->{ok}     = ($out->{running} ? \1 : \0);
    } elsif ($action eq 'log') {
        # Return last ~50 lines of the helper log as plain text.
        my $tail = '';
        if (-r $HELPER_LOG_FILE) {
            # Read last ~16KB so we're not pulling a huge file.
            my $size = -s $HELPER_LOG_FILE;
            my $offset = $size > 16384 ? $size - 16384 : 0;
            if (open my $fh, '<', $HELPER_LOG_FILE) {
                seek $fh, $offset, 0;
                local $/ = undef;
                $tail = <$fh>;
                close $fh;
            }
        } else {
            $tail = "(no log file yet at $HELPER_LOG_FILE)\n";
        }
        _send($httpClient, $response, 'text/plain; charset=utf-8', $tail, no_cache => 1);
        return;
    } elsif ($action eq 'cleanup') {
        # User-triggered orphan cleanup. Scans /proc for helper processes
        # not tracked in our pidfile. Same reasoning as the squeezelite
        # cleanup action.
        my $tracked = _helperReadPid();
        my $killed = _killOrphans('npd-vizfft\.py', $tracked, 'helper-cleanup');
        $out = _helperStatus();
        $out->{action} = 'cleanup';
        $out->{ok}     = \1;
        $out->{killed} = $killed;
    } elsif ($action eq 'recheck-deps') {
        _helperDepsCheck(1);              # force
        $out = _helperStatus();
        $out->{action} = 'recheck-deps';
        $out->{ok}     = \1;
    } else {
        $out = _helperStatus();
        $out->{action} = 'status';
    }

    _send($httpClient, $response, 'application/json',
          encode_json($out), no_cache => 1);
}

# Plugin shutdown hook — LMS calls this when the plugin is disabled or the
# server is shutting down. Stop the helper cleanly so we don't orphan it.
sub shutdownPlugin {
    my $class = shift;
    _helperStop();
    _sqzStop();
}

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

    # Fold any deprecated named-preset assignments into the flat per-player
    # offset map before anything reads offsets. Idempotent / no-op once done.
    eval { _migratePlayerOffsets(); };
    $log->error("[viz] offset migration failed: $@") if $@;

    # Settings page registration. The Settings.pm module subclasses
    # Slim::Web::Settings and shows up under Settings → Advanced. Skip
    # registration when LMS is running its scanner (no web UI in that mode).
    if (!$main::SCANNER) {
        eval {
            require Plugins::NowPlayingDisplay::Settings;
            Plugins::NowPlayingDisplay::Settings->new;
            $log->info("Settings page registered.");
        };
        if ($@) {
            $log->error("Failed to register Settings page: $@");
        }
    }

    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/state\.json\b},   \&_handleStateJson,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/players\.json\b}, \&_handlePlayersJson,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/biography\.json\b}, \&_handleBiographyJson,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/lyrics\.json\b},    \&_handleLyricsJson,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/manifest\.json\b}, \&_handleManifest,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/setoffset\b},     \&_handleSetOffset,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/setlivenoffset\b}, \&_handleSetLiveOffset,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/setlead\b},       \&_handleSetLead,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/setstyle\b},      \&_handleSetStyle,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/helper\b},        \&_handleHelper,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/squeezelite\b},   \&_handleSqueezelite,
    );
    # Calibration tone WAV files served straight from the plugin's Bin/.
    # LMS itself fetches these via HTTP when we send it a "playlist play
    # <url>" command — same loopback pattern any plugin uses to feed audio.
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/calibration/[\w-]+\.wav\b},
        \&_handleCalibrationWav,
    );
    # Calibration orchestration: starts/stops calibration playback on a
    # named player, with cleanup so playback doesn't run forever if the
    # browser tab is closed mid-calibration.
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/calibrate\b},     \&_handleCalibrate,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/page\b},          \&_handlePage,
    );

    # Register a link in the Extras menu (and an icon for Material Skin). The
    # link opens the plugin's SETTINGS page, where the per-player display URLs
    # and visualizer options live. Matches the working NowPlayingShare pattern:
    # addPageLinks (plural) + paired 'icons' entry, plus a webPages() hook below
    # that re-registers on enable/disable.
    Slim::Web::Pages->addPageLinks(
        'plugins', { 'PLUGIN_NOWPLAYINGDISPLAY' => 'plugins/NowPlayingDisplay/settings/basic.html' }
    );
    Slim::Web::Pages->addPageLinks(
        'icons', { 'PLUGIN_NOWPLAYINGDISPLAY' => 'plugins/NowPlayingDisplay/html/images/NowPlayingDisplayIcon_svg.png' }
    );

    $log->info("NowPlayingDisplay initialised — open http://<lms>:9000/plugins/NowPlayingDisplay/page");

    # Kick off the helper supervisor. It self-reschedules every 5s and
    # reconciles desired-vs-actual helper state. Spawning the helper is gated
    # on server mode + autorun pref + deps present, so this is safe to start
    # unconditionally — it just no-ops when the helper shouldn't be running.
    # CRITICAL: kill any previously-scheduled supervisor first. LMS can call
    # initPlugin multiple times (plugin enable/disable cycles, reload after a
    # version bump). Without killTimers, each call would stack another
    # supervisor chain — they'd all fire every 5s in parallel, each spawning
    # its own helper/squeezelite, multiplying processes.
    Slim::Utils::Timers::killTimers(undef, \&_helperSupervise);
    Slim::Utils::Timers::setTimer(undef,
        Time::HiRes::time() + 2,                   # first tick 2s after boot
        \&_helperSupervise);

    # Stage 2 auto-follow: subscribe to player events so we re-mirror the
    # active room onto the Visualizer player automatically. Only registers
    # when server mode is on; safe to call repeatedly (idempotent).
    _vizAutoEnsureSubscribed();
}

# LMS calls webPages() to (re)register menu links, including after the plugin
# is enabled/disabled. Mirrors NowPlayingShare: register the Extras link (to the
# settings page) + icon when enabled, clear them when disabled.
sub webPages {
    my $class = shift;
    if (Slim::Utils::PluginManager->isEnabled('Plugins::NowPlayingDisplay::Plugin')) {
        Slim::Web::Pages->addPageLinks(
            'plugins', { 'PLUGIN_NOWPLAYINGDISPLAY' => 'plugins/NowPlayingDisplay/settings/basic.html' }
        );
        Slim::Web::Pages->addPageLinks(
            'icons', { 'PLUGIN_NOWPLAYINGDISPLAY' => 'plugins/NowPlayingDisplay/html/images/NowPlayingDisplayIcon_svg.png' }
        );
    } else {
        Slim::Web::Pages->addPageLinks('plugins', { 'PLUGIN_NOWPLAYINGDISPLAY' => undef });
        Slim::Web::Pages->addPageLinks('icons',   { 'PLUGIN_NOWPLAYINGDISPLAY' => undef });
    }
}

# ----- snapshot builders -----------------------------------------------------

# Build a snapshot for a given player using the LMS request/status API.
#
# This is the same query Material Skin uses, so we get exactly the same
# field set Material gets — including isClassical, composer, work, lyrics,
# album year, multiple artist fields, and resolved artwork URLs.
#
# Going through the request layer (rather than poking Track objects directly)
# also insulates us from accessor-name changes between LMS versions.
sub _snapshotFor {
    my $client = shift;
    my $snap = {
        player        => { id => $client->id, name => $client->name },
        state         => 'stopped',
        title         => '',
        artist        => '',
        album_artist  => '',
        composer      => '',
        album         => '',
        year          => 0,
        artwork       => '',
        lyrics        => '',
        is_classical  => 0,
        work          => '',
        grouping      => '',
        duration      => 0,
        position      => 0,
        bitrate       => '',
        ts            => time(),
    };

    # Mode: play/pause/stop comes from the status response.
    eval {
        $snap->{position} = Slim::Player::Source::songTime($client) || 0;
    };

    # The big tag string is the union of what Material requests, which
    # gives us the richest payload LMS exposes for a track.
    my $tags = 'cdegilopqrstuyAABEGIKNPSTVbhz124';

    # Request the current track plus the next one (count 2 from the current
    # index). The current track is playlist_loop[0]; the next, when present,
    # is playlist_loop[1]. We expose the next track's url/id in the snapshot
    # so the page can pre-fetch its lyrics before it starts playing.
    my $req = Slim::Control::Request::executeRequest(
        $client, ['status', '-', 2, "tags:$tags"]
    );
    return $snap unless $req && !$req->isStatusError;

    my $results = $req->getResults || {};

    # Top-level mode (play/pause/stop) is on the status result, not in the loop.
    if (my $mode = $results->{mode}) {
        $snap->{state} = $mode eq 'play'  ? 'playing'
                       : $mode eq 'pause' ? 'paused'  : 'stopped';
    }

    # Current track lives in playlist_loop[0] when we asked from "-" (current).
    my $loop = $results->{playlist_loop};
    return $snap unless $loop && ref $loop eq 'ARRAY' && @$loop;
    my $t = $loop->[0];

    # Artist: try the fields Material falls back through, in order.
    $snap->{title}        = $t->{title}              // '';
    $snap->{artist}       = $t->{artist}
                         // $t->{trackartist}
                         // $t->{albumartist}
                         // '';
    $snap->{artist_id}    = $t->{artist_id}           // '';
    $snap->{album_artist} = $t->{albumartist}        // '';
    $snap->{composer}     = $t->{composer}           // '';
    $snap->{album}        = $t->{album}              // '';
    $snap->{year}         = ($t->{year} && $t->{year} > 0) ? $t->{year} + 0 : 0;
    $snap->{duration}     = ($t->{duration} // 0) + 0;
    $snap->{lyrics}       = $t->{lyrics}             // '';
    $snap->{is_classical} = $t->{isClassical} ? 1 : 0;
    $snap->{work}         = $t->{work}               // '';
    $snap->{grouping}     = $t->{grouping}           // '';
    $snap->{bitrate}      = $t->{bitrate}            // '';
    # Track URL is needed by the lyrics endpoint (MAI's lyrics command takes
    # a url:<...> param). Works for both local files ('file:///...') and
    # streaming ('qobuz://...', 'bandcamp://...', etc.).
    $snap->{track_url}    = $t->{url}                // '';

    # Track id is how Material identifies local tracks to MAI. Material's
    # lyrics logic: if track_id is missing or negative (remote/streaming),
    # query MAI by url; otherwise query by track_id. Local files have a
    # positive integer id; remote tracks get synthetic negative ids. We
    # expose it so the lyrics endpoint can mirror Material's behaviour.
    $snap->{track_id}     = (defined $t->{id} && $t->{id} ne '') ? $t->{id} : '';

    # Next track in the queue (playlist_loop[1] when present). We expose just
    # its url and id so the page can pre-fetch its lyrics ahead of time — by
    # the time it actually starts playing they're already cached and render
    # with no lag. Empty when the current track is the last in the queue.
    my $next = (ref $loop eq 'ARRAY' && @$loop > 1) ? $loop->[1] : undef;
    $snap->{next_track_url} = $next ? ($next->{url} // '') : '';
    $snap->{next_track_id}  = ($next && defined $next->{id} && $next->{id} ne '')
                            ? $next->{id} : '';

    # For remote tracks (Qobuz, Bandcamp, BBC Sounds, Radio Paradise, etc.)
    # the most useful metadata often lives at the top level of the status
    # response under remoteMeta, not in playlist_loop. Merge it in as a
    # fallback when the loop value is blank.
    my $remote = $results->{remoteMeta} || {};
    $snap->{title}    ||= $remote->{title}    // '';
    $snap->{artist}   ||= $remote->{artist}   // '';
    $snap->{album}    ||= $remote->{album}    // '';
    $snap->{duration} ||= ($remote->{duration} // 0) + 0;
    $snap->{track_url} ||= $remote->{url}     // '';

    # Artwork resolution — order matters:
    #   1. artwork_url: streaming services and remote tracks all set this to
    #      an LMS imageproxy path like '/imageproxy/<encoded URL>/image.jpg'.
    #      It's already a server-relative URL we can hand to the browser.
    #   2. /music/<coverid>/cover.jpg: standard endpoint for local tracks.
    #      Skip this when coverid is negative — those are synthetic IDs LMS
    #      assigns to remote tracks and the /music/ endpoint 404s on them.
    my $art = $t->{artwork_url} || $remote->{artwork_url};
    if ($art) {
        $snap->{artwork} = $art;
    } else {
        my $cover = $t->{coverid} // $t->{artwork_track_id} // $t->{id}
                 // $remote->{coverid} // $remote->{id};
        # Local coverids are hex strings (e.g. '6d07af45'); remote tracks
        # get synthetic negative IDs ('-94350071504528') which 404 on the
        # /music/ endpoint. Accept anything that doesn't start with '-'.
        if ($cover && $cover !~ /^-/) {
            $snap->{artwork} = "/music/$cover/cover.jpg";
        }
    }

    return $snap;
}

# Helper: is this client the dedicated server-side Visualizer SqueezeLite?
# When server-mode auto-follow is on, that player is constantly playing a
# mirror of the active room. We must exclude it from any "which player to
# show / which is active" lookup, or the UI/page ends up following the
# mirror instead of the real listening room (the page would see the
# Visualizer's stream URL, which may be local-only resolved or empty,
# producing the "only available for local library tracks" hint).
sub _isVizPlayer {
    my ($client) = @_;
    return 0 unless $client;
    # No filtering if server mode is off — the Visualizer SqueezeLite isn't
    # running, so there's nothing to exclude.
    return 0 unless $prefs->get('vizServerMode');
    my $vizMac = $prefs->get('vizPlayerMac') // '';
    $vizMac =~ s/^\s+|\s+$//g;
    return 0 unless $vizMac;
    return lc($client->id // '') eq lc($vizMac) ? 1 : 0;
}

sub _playerList {
    my @out;
    for my $c (Slim::Player::Client::clients()) {
        next if _isVizPlayer($c);   # hide the dedicated Visualizer from the dropdown
        # Determine state cheaply — no full status query needed for the list.
        my $state = $c->isPlaying ? 'playing'
                  : $c->isPaused  ? 'paused' : 'stopped';

        # last_play_time lets us pick "most recently active" without a
        # separate event subscription. It's set by LMS each time playback
        # actually transitions.
        my $lastPlay = 0;
        $lastPlay = $c->lastActivityTime if $c->can('lastActivityTime');

        push @out, {
            id        => $c->id,
            name      => $c->name,
            connected => $c->connected ? 1 : 0,
            state     => $state,
            last_seen => $lastPlay,
        };
    }
    return \@out;
}

# ----- HTTP handlers ---------------------------------------------------------

# Persist the visualizer sync offset from the on-screen tuner Save button.
# Accepts ?ms=<signed int> and ?player=<id>. Saves straight to that player's
# entry in vizPlayerOffsets (the per-player sync map), so each room keeps its
# own offset. Falls back to the global default (vizDelayMs) only when no player
# is resolvable (ambient / no-player pages). Returns the saved value as JSON.
#
# Also writes the helper offset file so the server-mode FFT-read window updates
# immediately (the helper polls it at ~100ms).
sub _handleSetOffset {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $ms = $q{ms};
    $ms = '' unless defined $ms;
    $ms =~ s/[^\-\d]//g;
    $ms = 0 unless $ms =~ /^-?\d+$/;
    $ms = -2000 if $ms < -2000;
    $ms =  2000 if $ms >  2000;
    $ms = int($ms);

    # The on-screen tuner is always tuning the room currently displayed/followed.
    # The page sends ?player=<id>; we save directly to that player so the offset
    # never bleeds onto other rooms. (Guard against the Visualizer's own MAC.)
    my $playerId = $q{player} // '';
    $playerId =~ s/^\s+|\s+$//g;
    my $vizMac = lc($prefs->get('vizPlayerMac') // '');
    my $client = ($playerId && lc($playerId) ne $vizMac)
        ? Slim::Player::Client::getClient($playerId) : undef;

    my $scope;
    if ($client) {
        my $pid  = $client->id;
        my $offs = $prefs->get('vizPlayerOffsets') || {};
        $offs    = {} unless ref($offs) eq 'HASH';
        $offs->{$pid} = $ms;
        $prefs->set('vizPlayerOffsets', $offs);
        $scope = 'player';
        $log->info("[viz] saved offset ${ms}ms for player $pid (" . $client->name . ")");
    } else {
        # No resolvable player — fall back to the global default.
        $prefs->set('vizDelayMs', $ms);
        $scope = 'global';
        $log->info("[viz] saved global default offset ${ms}ms");
    }

    # Apply live. The tuned player is the one currently being followed, so
    # writing $ms here takes effect on the helper's next poll (~100ms).
    # _writeOffsetFile clamps to [0, 2000] (delay-only: 0 = passthrough).
    _writeOffsetFile($ms);
    _send($httpClient, $response, 'application/json',
          encode_json({ ok => \1, ms => $ms, scope => $scope,
                        playerId => ($client ? $client->id : undef) }),
          no_cache => 1);
}

# Transient offset update — for the ±10/±50 nudge buttons. Updates the helper
# offset file so the user sees the change immediately, but does NOT persist
# the value to the preset. The Save button hits /setoffset for that.
sub _handleSetLiveOffset {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $ms = $q{ms};
    $ms = '' unless defined $ms;
    $ms =~ s/[^\-\d]//g;
    $ms = 0 unless $ms =~ /^-?\d+$/;
    $ms = -2000 if $ms < -2000;
    $ms =  2000 if $ms >  2000;
    $ms = int($ms);
    my $written = _writeOffsetFile($ms);
    _send($httpClient, $response, 'application/json',
          encode_json({ ok => \1, ms => $ms, applied => $written }), no_cache => 1);
}

# Persist the start-time lead (ms) used by the mirror seek (vizLeadMs). The
# self-test recommends a value; this endpoint lets the page apply it. Global
# (not per-player) — it's a property of the Visualizer's start latency, not of
# any one room. Takes effect on the NEXT track load (the seek path reads the
# pref fresh each mirror). Range [0, 4000].
sub _handleSetLead {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $ms = $q{ms};
    $ms = '' unless defined $ms;
    $ms =~ s/[^\d]//g;
    $ms = 0 unless $ms =~ /^\d+$/;
    $ms = int($ms);
    $ms = 0    if $ms < 0;
    $ms = 4000 if $ms > 4000;
    $prefs->set('vizLeadMs', $ms);
    $log->info("[viz] saved start lead ${ms}ms");
    _send($httpClient, $response, 'application/json',
          encode_json({ ok => \1, ms => $ms }), no_cache => 1);
}

# Persist the visualizer style from the on-screen Style button.
sub _handleSetStyle {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $style = $q{style} // '';
    my %valid = map { $_ => 1 } qw(segmented scope ring ringVivid ringZoom ringClassic starburst bokeh);
    $style = 'segmented' unless $valid{$style};
    $prefs->set('vizStyle', $style);
    _send($httpClient, $response, 'application/json',
          encode_json({ ok => \1, style => $style }), no_cache => 1);
}

# ---------------------------------------------------------------------------
# Server-side visualizer: mirror the active room onto the dedicated headless
# Visualizer player. Stage 1 (manual button) + Stage 2 (auto-follow on player
# events).
#
# *** SAFETY DESIGN ***
# Every command issued through this code path goes to ONE specific player —
# the one whose id (MAC) matches the configured `vizPlayerMac` pref. The
# lookup helper (_vizFindVisualizer) is the choke point; it returns the client
# only if the id matches exactly. All mirror/seek/stop actions take that
# vetted client as input. There is no code path where a real listening player
# could receive a command, because the lookup always returns either the
# Visualizer player or undef.
# ---------------------------------------------------------------------------

# Module-level state for stage 2 (auto-follow).
my $_vizAutoSubscribed = 0;
# $_vizLastSource / $_vizLastTrackUrl declared earlier (next to $_vizDesiredSource)
# so _calibrationStop can reset them.
my $_vizNoVizLogged    = 0;    # throttle for "no Visualizer player" log
my $_vizAutoOffLogged  = 0;    # throttle for "auto-follow disabled" log
# $_vizDesiredSource is declared earlier (above the calibration handler, which
# also reads/writes it). Empty = auto (follow the most-active room). Set from
# the page's state.json poll, which carries its ?player= selection every tick.
# NOTE: single shared Visualizer SqueezeLite, so this is global — if two
# displays pin different rooms, the most recent poll wins.

# Locate the Visualizer player by configured MAC. Returns the Slim::Player
# client object only on exact (case-insensitive) match, or undef if not found
# or no MAC is configured. THIS IS THE SAFETY CHOKEPOINT — every command path
# starts from here.
sub _vizFindVisualizer {
    my $vizMac = $prefs->get('vizPlayerMac') // '';
    $vizMac =~ s/^\s+|\s+$//g;
    return (undef, '') unless $vizMac;
    for my $c (Slim::Player::Client::clients()) {
        my $id = lc($c->id // '');
        if ($id eq lc($vizMac)) {
            return ($c, $vizMac);
        }
    }
    return (undef, $vizMac);
}

# Pick the "active" source room to mirror. Strategy: the most recently-started
# playing client, excluding the Visualizer player itself. **Paused players are
# still considered active** — pause is just "play state == pause", not "no
# longer the room we care about". Returns undef only when no real player has
# anything queued/playing.
sub _vizPickActiveSource {
    my ($vizClient) = @_;
    my $vizId = $vizClient ? lc($vizClient->id // '') : '';
    my $best;
    my $bestStart = -1;
    my $bestPlaying = 0;
    for my $c (Slim::Player::Client::clients()) {
        next unless $c;
        next if $vizId && lc($c->id // '') eq $vizId;   # never mirror ourselves
        my $song = $c->playingSong;
        next unless $song;                              # nothing queued at all
        my $playing = $c->isPlaying ? 1 : 0;
        my $start   = eval { $song->startOffset } // 0;
        # Prefer playing over paused; among playing, prefer most recently
        # started.
        if (!$best
            || ($playing && !$bestPlaying)
            || ($playing == $bestPlaying && $start > $bestStart)) {
            $best        = $c;
            $bestStart   = $start;
            $bestPlaying = $playing;
        }
    }
    return $best;
}

# Issue the mirror commands: clear + play <url> + (delayed) seek to position.
# The delayed seek is essential — calling `time` immediately after `playlist
# play` ran into the player having not yet loaded the stream, so the seek
# would be ignored and playback would start from 0 (the "out of sync by a long
# way" bug from stage 1).
#
# Returns 1 on success, 0 on failure, with optional info hash via $info ref.
sub _vizMirrorAction {
    my ($vizClient, $sourceClient, $info) = @_;
    return 0 unless $vizClient && $sourceClient;

    my $song = $sourceClient->playingSong;
    if (!$song) {
        _vizStop($vizClient);
        $info->{stopped} = 1 if $info;
        return 1;
    }
    my $trackUrl;
    eval { $trackUrl = $song->track ? $song->track->url : '' };
    $trackUrl //= '';
    return 0 unless $trackUrl;

    my $pos = 0;
    eval { $pos = $sourceClient->songElapsedSeconds || 0 };
    $pos = 0 if !defined $pos || $pos < 0;

    # If we're already mirroring this exact track on the same source, do NOT
    # re-issue 'time' every tick. A per-tick seek (this runs ~1/sec) caused a
    # visible 1 Hz glitch — each seek re-opens/re-buffers the stream, which
    # hitches the analysed audio. Only correct genuine drift, handled by the
    # reconcile loop comparing positions.
    my $srcId = $sourceClient->id // '';
    # Did we switch to a DIFFERENT room since the last mirror, vs. the same room
    # just rolling on to its next track? Captured before we update the tracker.
    my $sourceChanged = ($_vizLastSource ne $srcId);
    if ($_vizLastSource eq $srcId && $_vizLastTrackUrl eq $trackUrl) {
        $info->{seekedOnly} = 1 if $info;
        $info->{alreadyMirroring} = 1 if $info;
    } else {
        my $playReq = Slim::Control::Request::executeRequest(
            $vizClient, ['playlist', 'play', $trackUrl]
        );
        my $playOk = $playReq && !$playReq->isStatusError;
        return 0 unless $playOk;
        $_vizLastSource   = $srcId;
        $_vizLastTrackUrl = $trackUrl;

        # Calibration: the room loops the tone (repeat 1). Mirror that onto the
        # Visualizer so it loops too — otherwise it plays the tone once, ends,
        # and the reconcile resume path (pause 0 + time) fires on an ended
        # playlist every ~60s, which glitches / sticks the calibration view.
        if ($CALIBRATION_ACTIVE{$srcId}) {
            eval { Slim::Control::Request::executeRequest($vizClient, ['playlist', 'repeat', 1]); };
            $info->{calRepeat} = 1 if $info;
        }

        # Decide whether to seek the Visualizer after the stream loads.
        #
        # vizLeadMs == 0 (legacy/default): seek ONLY when joining a source that
        # might be mid-track — the first mirror or a room switch. For an ordinary
        # sequential track advance on the SAME room, the room and the Visualizer
        # both roll into the new track from ~0 at about the same moment, so a seek
        # is redundant AND forces a SECOND stream reload → the blank/glitch at
        # every track change. Skip it there.
        #
        # vizLeadMs > 0: the user wants the Visualizer to capture AHEAD of the
        # room so the delay buffer can pull it to exact sync. A lead does not
        # persist across tracks (each track is a fresh stream that starts at 0 on
        # both players, and per-device start latency recurs), so we must re-apply
        # it on EVERY new track — including same-room advances. We accept the one
        # extra reload per track as the cost of reliable sync; without it the
        # Visualizer drifts behind on slow-to-start (e.g. bridged) rooms and the
        # delay-only buffer can't recover it.
        my $leadMs = int($prefs->get('vizLeadMs') // 0);
        my $lead   = $leadMs / 1000.0;
        # Seek on a mid-track join (any time), or — when a lead is configured —
        # on every fresh load so the Visualizer always starts ahead.
        my $doSeek = ($sourceChanged && $pos > 0.5) || ($leadMs > 0);
        if ($doSeek) {
            my $srcRef = $sourceClient;
            Slim::Utils::Timers::setTimer(
                undef, Time::HiRes::time() + 0.6,
                sub {
                    my $vc = $vizClient;
                    # Re-vet the target before commanding: the client may have
                    # gone; refuse if its id no longer matches the configured MAC.
                    my ($recheck, $mac) = _vizFindVisualizer();
                    return unless $recheck && lc($recheck->id // '') eq lc($vc->id // '');
                    # Re-measure the ROOM's CURRENT position now (the stream has
                    # had 0.6s to load and the room has truly "registered"
                    # playback), rather than reusing the stale position captured
                    # when we issued play. Seek the Visualizer to room-now + lead
                    # so its capture sits `lead` ms ahead of the room.
                    my $newPos;
                    eval { $newPos = $srcRef->songElapsedSeconds };
                    $newPos = $pos unless defined $newPos && $newPos >= 0;
                    $newPos += $lead;
                    $newPos = 0 if $newPos < 0;
                    eval {
                        Slim::Control::Request::executeRequest($vc, ['time', $newPos]);
                    };
                }
            );
        }
        $info->{seeked}  = $doSeek ? 1 : 0 if $info;
        $info->{leadMs}  = $leadMs if $info;
    }

    if ($info) {
        $info->{sourceId} = $srcId;
        $info->{trackUrl} = $trackUrl;
        $info->{position} = $pos + 0;
    }
    return 1;
}

# Helper: stop the Visualizer player cleanly (used when the source isn't
# playing). Safe to call even if the Visualizer is already idle.
sub _vizStop {
    my ($vizClient) = @_;
    return unless $vizClient;
    eval {
        Slim::Control::Request::executeRequest($vizClient, ['playlist', 'clear']);
    };
    # Forget our "last mirrored" state so the next mirror is a fresh load.
    $_vizLastSource   = '';
    $_vizLastTrackUrl = '';
}

# ---------------------------------------------------------------------------
# Stage 2: auto-follow. Subscribe to LMS player events so any play/pause/stop/
# newsong on a real room triggers a re-mirror onto the Visualizer player.
# Subscription is enabled iff vizServerMode is on, and registered exactly
# once (idempotent).
# ---------------------------------------------------------------------------

sub _vizAutoEnsureSubscribed {
    # Despite the name (kept for call-site compatibility), this now starts a
    # POLLING timer rather than event subscriptions. Polling proved far more
    # robust than LMS's event API for this purpose: it's self-correcting (every
    # tick reconciles the Visualizer with the active room), doesn't depend on
    # getting event-matcher syntax exactly right, and ~1s lag on a track change
    # is invisible for a visualizer.
    return if $_vizAutoSubscribed;
    if (!$prefs->get('vizServerMode')) {
        $log->debug('[vizauto] not starting — server mode is off');
        return;
    }
    $_vizAutoSubscribed = 1;
    $log->info('[vizauto] starting auto-follow poll timer (1s)');
    _vizAutoPoll();   # kick off immediately, then it re-schedules itself
}

# The poll: reconcile the Visualizer with whatever the active room is doing.
# Re-schedules itself every second while server mode is on.
sub _vizAutoPoll {
    # Stop the loop cleanly if server mode gets turned off.
    if (!$prefs->get('vizServerMode')) {
        $_vizAutoSubscribed = 0;
        $log->info('[vizauto] server mode off — stopping poll timer');
        return;
    }

    eval { _vizReconcile(); };
    if ($@) { $log->error("[vizauto] reconcile error: $@"); }

    # Re-arm.
    Slim::Utils::Timers::setTimer(
        undef, Time::HiRes::time() + 1.0, \&_vizAutoPoll
    );
}

# Core reconciliation: look at the active room, make the Visualizer match.
sub _vizReconcile {
    my ($vizClient, $vizMac) = _vizFindVisualizer();
    if (!$vizClient) {
        # Log occasionally (not every tick) so we can see the MAC mismatch /
        # missing-player case without flooding the log.
        $_vizNoVizLogged //= 0;
        if (time() - $_vizNoVizLogged > 30) {
            $_vizNoVizLogged = time();
            $log->info("[vizauto] no connected Visualizer player matching MAC '" . ($vizMac // '') . "' — auto-follow idle");
        }
        return;
    }

    my $calActive = scalar keys %CALIBRATION_ACTIVE;

    # Auto-follow (mirror) can be disabled to test native LMS sync grouping.
    # When off we issue NO commands to the Visualizer. EXCEPTION: while a
    # calibration tone is running we must mirror regardless, because that's how
    # the tone reaches the Visualizer — through the exact same playback path
    # (play + position-seek) used in normal use, so the offset we measure is the
    # one that's actually correct for real playback. Calibration pins
    # $_vizDesiredSource to its room (below) so the mirror follows the tone.
    if (!$calActive && !$prefs->get('vizAutoFollow')) {
        $_vizAutoOffLogged //= 0;
        if (time() - $_vizAutoOffLogged > 60) {
            $_vizAutoOffLogged = time();
            $log->info('[vizauto] auto-follow disabled (vizAutoFollow=0) — not mirroring; sync-test mode');
        }
        return;
    }

    # Choose the source the visualizer should mirror. If the display pinned a
    # specific room, follow exactly that one (and show nothing when it isn't
    # playing — handled by the isPlaying branch below). Only fall back to the
    # most-active room when no room is pinned (auto), or when the pinned room
    # has disconnected entirely.
    my $source;
    if ($_vizDesiredSource ne '') {
        $source = Slim::Player::Client::getClient($_vizDesiredSource);
        if (!$source) {
            # Pinned player is gone — clear the pin and fall back to auto so we
            # don't get stuck following a vanished player.
            $log->info("[vizauto] pinned source $_vizDesiredSource not connected; reverting to auto");
            $_vizDesiredSource = '';
            $source = _vizPickActiveSource($vizClient);
        }
    } else {
        $source = _vizPickActiveSource($vizClient);
    }
    if (!$source) {
        # Nothing queued anywhere. Clear the Visualizer if it's still busy.
        if ($_vizLastTrackUrl ne '') {
            _vizStop($vizClient);
            $log->info('[vizauto] no active source; stopped Visualizer');
        }
        return;
    }

    # Paused source -> pause Visualizer, keep state for a clean resume.
    if (!$source->isPlaying) {
        if ($vizClient->isPlaying) {
            eval { Slim::Control::Request::executeRequest($vizClient, ['pause', 1]); };
            $log->debug('[vizauto] source paused; paused Visualizer');
        }
        return;
    }

    # Source is playing. Figure out the source's current track + position.
    my $song = $source->playingSong;
    return unless $song;
    my $trackUrl;
    eval { $trackUrl = $song->track ? $song->track->url : '' };
    $trackUrl //= '';
    return unless $trackUrl;
    my $srcId = $source->id // '';
    my $pos = 0;
    eval { $pos = $source->songElapsedSeconds || 0 };
    $pos = 0 if !defined $pos || $pos < 0;

    my $needNewTrack = ($_vizLastSource ne $srcId) || ($_vizLastTrackUrl ne $trackUrl);

    if ($needNewTrack) {
        # If we're switching SOURCE (not just track within the same source),
        # the visualizer's offset should match the new room's per-player
        # preset. Write the resolved offset to the helper file so its
        # next FFT frame uses it. Doing this only on source-change avoids
        # spurious file writes when the same room moves between tracks.
        if ($_vizLastSource ne $srcId) {
            my $newOffset = _resolveOffsetForPlayer($srcId);
            _writeOffsetFile($newOffset);
            $log->info("[vizauto] source -> $srcId; offset=${newOffset}ms");
        }
        # New track (or switched rooms) — load it onto the Visualizer.
        my %info;
        _vizMirrorAction($vizClient, $source, \%info);
        $log->info("[vizauto] new track -> mirroring: " . encode_json(\%info));
        return;
    }

    # Same track already loaded. Handle resume-after-pause and drift.
    my $wasResumed = 0;
    if (!$vizClient->isPlaying) {
        # Resume transition: unpause AND force a re-seek to the source's current
        # position. We can't rely on the drift check here — right after a pause
        # the positions look aligned, but the ~1s poll latency + resume-command
        # latency leaves the Visualizer lagging by a noticeable, sub-threshold
        # amount that would never get corrected. Seeking on resume guarantees
        # alignment at the moment playback restarts.
        eval { Slim::Control::Request::executeRequest($vizClient, ['pause', 0]); };
        eval { Slim::Control::Request::executeRequest($vizClient, ['time', $pos]); };
        $wasResumed = 1;
        $log->debug("[vizauto] resumed Visualizer + re-seek to ${pos}s");
    }
    return if $wasResumed;

    # NO periodic drift re-seek. Once the right track is loaded and playing, we
    # let it play through untouched. A drift re-seek here fired every tick —
    # streaming has inherent buffer latency, so the Visualizer legitimately runs
    # a few seconds behind the source, the drift threshold tripped constantly,
    # and the resulting once-per-second seek re-buffered the stream and caused
    # the 1 Hz glitch. The visualizer doesn't need tight position sync — it only
    # needs smoothly-flowing audio to analyse; absolute position is irrelevant
    # (and any audio-to-visual offset is handled by the sync-offset tuner). So
    # we deliberately do nothing here.
}

sub _handleStateJson {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $playerId = $q{player} // '';

    # Idempotent: ensures server-mode auto-follow is wired up. Picks up users
    # who enable server mode in settings without an LMS restart.
    _vizAutoEnsureSubscribed();

    # Record which player this display wants the visualizer to follow. A manual
    # selection pins the visualizer to THAT room; "auto"/empty lets it follow
    # the most-active room (the original behaviour). The Visualizer's own MAC is
    # never a valid source. This steers _vizReconcile / _vizPickActiveSource.
    {
        my $vizMac = lc($prefs->get('vizPlayerMac') // '');
        if ($playerId eq '' || lc($playerId) eq 'auto') {
            $_vizDesiredSource = '';
        } elsif ($vizMac && lc($playerId) eq $vizMac) {
            # ignore — never follow ourselves
        } else {
            $_vizDesiredSource = $playerId;
        }
    }

    # Resolve "auto" / empty to the most-recently-active player. Preference
    # order: currently playing > recently paused > anything connected.
    my $client;
    if ($playerId eq '' || lc($playerId) eq 'auto') {
        $client = _autoActivePlayer();
    } else {
        $client = Slim::Player::Client::getClient($playerId);
    }

    my $body;
    if ($client) {
        my $snap = _snapshotFor($client);
        $snap->{resolved_from} = ($playerId eq '' || lc($playerId) eq 'auto') ? 'auto' : 'explicit';
        $snap->{cfg} = _liveConfig();
        $body = encode_json($snap);
    } else {
        $body = encode_json({ state => 'no_player', cfg => _liveConfig() });
    }

    _send($httpClient, $response, 'application/json', $body, no_cache => 1);
}

# Live-updatable settings, included in every state.json poll so an open display
# picks up changes (scroll speed, visualizer offset/presets) without a reload.
# defaultMode and the enableVisualizer toggle are deliberately NOT live (they
# only matter at load / would disrupt a running session).
sub _liveConfig {
    my %speedMap = (low => 30, medium => 50, high => 80);
    my $scrollSpeed = $prefs->get('scrollSpeed') // 'medium';
    my $offs = $prefs->get('vizPlayerOffsets') || {};
    $offs = {} unless ref($offs) eq 'HASH';
    my $vizDefault = $prefs->get('vizDelayMs');
    $vizDefault = 0 unless defined $vizDefault && $vizDefault =~ /^-?\d+$/;
    return {
        scrollPx  => ($speedMap{$scrollSpeed} // 50),
        viz       => {
            playerOffsets => $offs,
            default    => $vizDefault + 0,
            leadMs     => int($prefs->get('vizLeadMs') // 0),
            smoothing  => ($prefs->get('vizSmoothing') // 'medium'),
            style      => ($prefs->get('vizStyle') // 'segmented'),
            # Server-side analysis mode (opt-in, default OFF): when on AND a
            # bridgeUrl is configured, the page connects to the WebSocket and
            # renders from server-computed band data, bypassing Web Audio. This
            # is what enables Safari/iOS/TV-browser support.
            serverMode => ($prefs->get('vizServerMode') ? \1 : \0),
            bridgeUrl  => ($prefs->get('vizBridgeUrl') // ''),
        },
    };
}

# Pick whichever player is "most active" right now. Used when the page
# requests player=auto (or omits the param) — common for TVs and ambient
# displays where there's no human to choose.
sub _autoActivePlayer {
    my @clients = Slim::Player::Client::clients();
    # Exclude the dedicated Visualizer SqueezeLite — it's a mirror, not a
    # listening room. Picking it here would make the page follow itself.
    @clients = grep { !_isVizPlayer($_) } @clients;
    return unless @clients;

    # First preference: anything currently playing.
    for my $c (@clients) {
        return $c if $c->isPlaying;
    }
    # Second preference: anything paused (i.e. recently active).
    for my $c (@clients) {
        return $c if $c->isPaused;
    }
    # Fallback: first connected client; failing that, first client at all.
    for my $c (@clients) {
        return $c if $c->connected;
    }
    return $clients[0];
}

sub _handlePlayersJson {
    my ($httpClient, $response) = @_;
    my $body = encode_json({ players => _playerList() });
    _send($httpClient, $response, 'application/json', $body, no_cache => 1);
}

# ----- Lyrics (via Music Artist Info plugin) ---------------------------------
#
# Same architecture as biography: the page polls this endpoint when the
# Lyrics mode is active. We dispatch to MAI ourselves so:
#   - The browser doesn't need to know MAI's command shape
#   - We can cache per-track (MAI hits external lyric services on cold
#     fetch, which is slow)
#   - We translate MAI's response into a normalised payload the page
#     understands without parsing logic.
#
# MAI's lyrics command with timestamps:1 returns LRC-style timestamped
# lyrics when the source has them, plain HTML otherwise. We detect which
# by looking at the response shape:
#   - Timestamped: result.lyrics_array = [ [time_in_seconds, "line"], ... ]
#   - Plain: result.lyrics = "<p>...</p>" or similar HTML/text
# (The exact field names vary by MAI version; we look for both.)

my %LYR_CACHE;          # key (track URL) => { ts => time, body => {...} }
my $LYR_TTL = 86400;    # 24h — lyrics don't change
my $LYR_CACHE_MAX = 200;

# Insert/refresh a cache entry, evicting the oldest entries by ts when over
# the cap. Earlier versions only checked TTL on read, so stale-but-not-yet-
# requested-again entries accumulated forever — slow leak on a long-running
# LMS box. Cap+evict keeps the hash bounded with no extra timer needed.
sub _cacheStore {
    my ($cache, $cap, $key, $entry) = @_;
    $cache->{$key} = $entry;
    return unless scalar(keys %$cache) > $cap;
    # Drop the 10% oldest in one pass so we don't do this work on every insert.
    my $drop = int($cap * 0.10) || 1;
    my @sorted = sort { $cache->{$a}{ts} <=> $cache->{$b}{ts} } keys %$cache;
    for my $k (@sorted[0 .. $drop - 1]) { delete $cache->{$k}; }
}

sub _handleLyricsJson {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $url      = $q{url}      // '';
    my $track_id = $q{track_id} // '';

    # Decide how to identify the track to MAI, exactly as Material does:
    #   - local track (positive integer id) -> track_id:<id>
    #   - remote/streaming (missing or negative id) -> url:<url>
    # This matters because MAI returns lyrics for local tracks keyed by
    # track_id but often returns nothing when the same track is queried by
    # file:// url. (This was the cause of "lyrics work in Material but not
    # here" — we were always sending url:.)
    my $use_track_id = ($track_id ne '' && $track_id !~ /^-/ && $track_id =~ /^\d+$/);

    # Cache key: prefer track_id (stable) for local, url for remote.
    my $cache_key = $use_track_id ? "tid:$track_id" : "url:$url";

    if (!$url && !$use_track_id) {
        _send($httpClient, $response, 'application/json',
              encode_json({ synced => \0, lines => [], html => '' }), no_cache => 1);
        return;
    }

    if (my $hit = $LYR_CACHE{$cache_key}) {
        if (time() - $hit->{ts} < $LYR_TTL) {
            _send($httpClient, $response, 'application/json',
                  encode_json($hit->{body}), no_cache => 1);
            return;
        }
    }

    # MAI call shape (matching Material Skin's source exactly):
    #   ['musicartistinfo','lyrics','html:1','timestamps:1', <id arg>]
    # where <id arg> is 'track_id:<id>' for local tracks or 'url:<url>' for
    # remote. Pass a real connected client — MAI silently returns empty when
    # called with undef from a plugin handler context.
    my @args = ('musicartistinfo', 'lyrics', 'html:1', 'timestamps:1');
    if ($use_track_id) {
        push @args, "track_id:$track_id";
    } else {
        push @args, "url:$url";
    }
    my $client = _anyConnectedClient();

    my $payload = { synced => \0, lines => [], html => '' };
    my $req = Slim::Control::Request::executeRequest($client, \@args);
    if ($req && !$req->isStatusError) {
        my $r = $req->getResults || {};

        # MAI synced-lyrics shapes, in priority order:
        #   1. result.data with result.timed truthy — Material's shape:
        #      data = [ { time => 12.3, text => "..." }, ... ]
        #   2. result.lyrics_array / syncedLyrics — [[time, text], ...]
        #   3. Inline LRC tags in result.lyrics — "[mm:ss.xx] line"
        my $synced_lines;
        if ($r->{timed} && ref($r->{data}) eq 'ARRAY') {
            $synced_lines = _normaliseSyncedHashes($r->{data});
        }
        $synced_lines ||= _normaliseSyncedArray($r->{lyrics_array})
                       || _normaliseSyncedArray($r->{syncedLyrics});
        if (!$synced_lines) {
            $synced_lines = _parseLrcInline($r->{lyrics} || '');
        }

        if ($synced_lines && @$synced_lines) {
            $payload->{synced} = \1;
            $payload->{lines}  = $synced_lines;
        } else {
            # Plain text fallback: strip MAI's stylesheet link, leave HTML alone.
            my $html = $r->{lyrics} || '';
            $html =~ s{<link\b[^>]*>}{}gi;
            $payload->{html} = $html;
        }
    }

    # Only cache positive results (synced lines or non-empty plain html).
    # Empty results shouldn't poison future queries — see _handleBiographyJson.
    if ((ref($payload->{lines}) eq 'ARRAY' && @{$payload->{lines}})
            || (defined $payload->{html} && length $payload->{html})) {
        _cacheStore(\%LYR_CACHE, $LYR_CACHE_MAX, $cache_key,
                    { ts => time(), body => $payload });
    }
    _send($httpClient, $response, 'application/json',
          encode_json($payload), no_cache => 1);
}

# Turn [[time, text], ...] into [{ t, text }, ...] if it's well-formed.
# Returns undef if the structure isn't a usable array.
sub _normaliseSyncedArray {
    my ($arr) = @_;
    return undef unless ref($arr) eq 'ARRAY' && @$arr;
    my @out;
    for my $entry (@$arr) {
        next unless ref($entry) eq 'ARRAY' && @$entry >= 2;
        push @out, { t => $entry->[0] + 0, text => "$entry->[1]" };
    }
    return @out ? \@out : undef;
}

# Turn MAI's [{time=>N, text=>"..."}, ...] (Material's "data" shape, used
# when result.timed is true) into our [{ t, text }, ...]. Returns undef if
# the structure isn't usable. We tolerate either 'time' or 't' on input.
sub _normaliseSyncedHashes {
    my ($arr) = @_;
    return undef unless ref($arr) eq 'ARRAY' && @$arr;
    my @out;
    for my $entry (@$arr) {
        next unless ref($entry) eq 'HASH';
        my $t = $entry->{time} // $entry->{t};
        next unless defined $t;
        push @out, { t => $t + 0, text => defined $entry->{text} ? "$entry->{text}" : '' };
    }
    return @out ? \@out : undef;
}

# Parse LRC-format inline timestamps out of lyrics HTML/text. Looks for
# lines like "[mm:ss.xx] some text" and builds a synced array. Returns
# undef if no timestamps are found (caller should fall through to plain).
#
# Real-world MAI lyrics often interleave timestamped lines with HTML
# (<p>...</p>, <br/>), so we strip tags first and split on newlines.
sub _parseLrcInline {
    my ($html) = @_;
    return undef unless $html && $html =~ /\[\d{1,2}:\d{2}/;

    # Strip HTML tags but preserve line breaks. Common patterns: <br/>,
    # <br>, </p>, newlines. Turn each into a single \n then strip remaining
    # tags.
    my $text = $html;
    $text =~ s{<br\s*/?>}{\n}gi;
    $text =~ s{</p\s*>}{\n}gi;
    $text =~ s{<[^>]+>}{}g;       # strip remaining tags
    $text =~ s{&nbsp;}{ }g;
    $text =~ s{&amp;}{&}g;
    $text =~ s{&lt;}{<}g;
    $text =~ s{&gt;}{>}g;
    $text =~ s{&quot;}{"}g;
    $text =~ s{&#39;}{'}g;

    my @lines;
    for my $raw (split /\r?\n/, $text) {
        # A line may have one or more leading [mm:ss.xx] stamps (some LRC
        # variants stamp the same line at multiple times). Pull them all.
        my @stamps;
        while ($raw =~ s/^\s*\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]//) {
            my $secs = $1 * 60 + $2 + (defined $3 ? ("0.$3" + 0) : 0);
            push @stamps, $secs;
        }
        my $body = $raw;
        $body =~ s/^\s+//; $body =~ s/\s+$//;
        next unless @stamps && length $body;
        for my $t (@stamps) {
            push @lines, { t => $t + 0, text => $body };
        }
    }

    @lines = sort { $a->{t} <=> $b->{t} } @lines;
    return @lines ? \@lines : undef;
}

# ----- Biography (via Music Artist Info plugin) ------------------------------
#
# The page polls this endpoint when the Biography mode is active. We dispatch
# to MAI ourselves rather than letting the browser do it, so:
#   - The browser never has to know MAI's command shape (cleaner contract)
#   - We can cache per-artist (MAI is slow on first hit — 3-5s — and our
#     page polls every 10s; we don't want to re-fetch on every poll)
#   - The cached HTML has MAI's own <link> stylesheet stripped out so the
#     page doesn't end up loading random CSS.
#
# Cache is in-memory only — short and simple. TTL keeps the bio reasonably
# fresh in case a user has updated their MAI provider.

my %BIO_CACHE;          # key => { ts => time, body => {...} }
my $BIO_TTL = 3600;     # one hour is plenty for static biographies
my $BIO_CACHE_MAX = 100;

sub _handleBiographyJson {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $artist       = $q{artist}        // '';
    my $artist_id    = $q{artist_id}     // '';
    my $albumartist  = $q{albumartist}   // '';
    my $album        = $q{album}         // '';

    # Cache key includes the album, since the same artist name can resolve
    # differently depending on the album hint MAI uses for disambiguation.
    my $key = ($artist_id ? "id:$artist_id" : lc $artist) . '|' . lc($album);

    if (my $hit = $BIO_CACHE{$key}) {
        if (time() - $hit->{ts} < $BIO_TTL) {
            _send($httpClient, $response, 'application/json',
                  encode_json($hit->{body}), no_cache => 1);
            return;
        }
    }

    if (!$artist && !$artist_id) {
        _send($httpClient, $response, 'application/json',
              encode_json({ html => '', artist => '' }), no_cache => 1);
        return;
    }

    # Material's biography call always includes the album as a disambiguation
    # hint AND passes a real player ID. We do the same — MAI sometimes
    # returns empty when called with no client context from a plugin handler,
    # so we hand it any connected client to satisfy that path.
    my $client = _anyConnectedClient();
    my $payload = _fetchBiography($client, $artist_id, $artist, $album);

    # Material's fallback (line 444-445 of material-deferred.min.js):
    #   if biography is empty AND we have an albumartist AND artist contains
    #   albumartist (e.g. "Spencer Krug featuring Wolf Parade" contains
    #   "Wolf Parade") -> retry with albumartist, dropping the album param.
    if (!$payload->{html} && $albumartist
            && lc($albumartist) ne lc($artist)
            && index(lc($artist), lc($albumartist)) >= 0) {
        my $retry = _fetchBiography($client, '', $albumartist, '');
        $payload = $retry if $retry->{html};
    }

    # Only cache successful results. Caching empty results poisons future
    # queries for an hour after any transient failure (e.g. an MAI call that
    # failed before we had the player-passing fix). Better to retry on each
    # request for empty bios than to return stale negative results.
    if ($payload->{html}) {
        _cacheStore(\%BIO_CACHE, $BIO_CACHE_MAX, $key,
                    { ts => time(), body => $payload });
    }

    _send($httpClient, $response, 'application/json',
          encode_json($payload), no_cache => 1);
}

# Return any currently-connected player client object, or undef if none.
# MAI's biography handler is registered with needsClient=0 but in practice
# behaves more reliably with a real client, matching what Material does.
sub _anyConnectedClient {
    for my $c (Slim::Player::Client::clients()) {
        return $c if $c->connected;
    }
    return undef;
}

# Dispatch a single MAI biography request and return { html, artist }.
#
# Important: MAI returns empty when executeRequest is passed undef as the
# client from a plugin handler context. Material always passes a real
# player ID via lmsCommand(a.playerId(), ...) — we do the same by handing
# in any connected client (it doesn't matter which; MAI just needs a
# non-undef slot to behave correctly).
sub _fetchBiography {
    my ($client, $artist_id, $artist, $album) = @_;
    my @args = ('musicartistinfo', 'biography', 'html:1');
    push @args, "album:$album"          if $album;
    push @args, "artist_id:$artist_id"  if $artist_id;
    push @args, "artist:$artist"        if $artist && !$artist_id;

    my $req = Slim::Control::Request::executeRequest($client, \@args);
    return { html => '', artist => $artist } unless $req && !$req->isStatusError;

    my $r    = $req->getResults || {};
    my $html = $r->{biography}  || '';
    $html =~ s{<link\b[^>]*>}{}gi;     # strip MAI's stylesheet link

    return {
        html   => $html,
        artist => $r->{artist} || $artist,
    };
}

sub _handleManifest {
    my ($httpClient, $response) = @_;
    # PWA manifest — when the user does "Add to Home Screen" on a tablet,
    # the page launches in standalone (no browser chrome) mode and behaves
    # like a native app. Costs us nothing, helps the wall-mount case a lot.
    my $manifest = {
        name             => 'Now Playing',
        short_name       => 'Now Playing',
        start_url        => '/plugins/NowPlayingDisplay/page',
        scope            => '/plugins/NowPlayingDisplay/',
        display          => 'standalone',
        orientation      => 'any',
        background_color => '#0a0a0a',
        theme_color      => '#0a0a0a',
    };
    _send($httpClient, $response, 'application/manifest+json', encode_json($manifest));
}

sub _handlePage {
    my ($httpClient, $response) = @_;
    my $body = _pageHtml();
    # Inject runtime prefs by replacing markers in the heredoc. We do this
    # at serve time so the user can change settings without restarting LMS
    # to see the new defaults.
    my $defaultMode = $prefs->get('defaultMode') || 'now-playing';
    my $scrollSpeed = $prefs->get('scrollSpeed') || 'medium';
    # scrollSpeed → px/s mapping. Done server-side so the page just gets
    # a number to use.
    my %speedMap = (low => 30, medium => 50, high => 80);
    my $scrollPx = $speedMap{$scrollSpeed} // 50;
    my $vizEnabled = $prefs->get('enableVisualizer') ? 'true' : 'false';

    # Visualizer offset resolution. Each player has its own saved sync offset;
    # the page resolves its offset from this map using its ?player= id, falling
    # back to the global default. Shapes:
    #   vizPlayerOffsets = { '<player_id>' => <ms>, ... }
    #   vizDelayMs       = global default offset (fallback)
    my $offs = $prefs->get('vizPlayerOffsets') || {};
    $offs = {} unless ref($offs) eq 'HASH';
    my $vizDefault = $prefs->get('vizDelayMs');
    $vizDefault = 0 unless defined $vizDefault && $vizDefault =~ /^-?\d+$/;
    my $vizCfg = encode_json({
        playerOffsets => $offs,
        default    => $vizDefault + 0,
        leadMs     => int($prefs->get('vizLeadMs') // 0),
        smoothing  => ($prefs->get('vizSmoothing') // 'medium'),
        style      => ($prefs->get('vizStyle') // 'segmented'),
        serverMode => ($prefs->get('vizServerMode') ? \1 : \0),
        bridgeUrl  => ($prefs->get('vizBridgeUrl') // ''),
    });
    $body =~ s/__NPD_DEFAULT_MODE__/$defaultMode/g;
    $body =~ s/__NPD_SCROLL_PX__/$scrollPx/g;
    $body =~ s/__NPD_VIZ_ENABLED__/$vizEnabled/g;
    $body =~ s/__NPD_VIZ_CFG__/$vizCfg/g;
    # Disable browser cache for the page HTML. The page contains inline JS
    # that we update with each plugin release, and any browser holding a
    # stale copy will silently keep using old code. Setting no_cache pushes
    # Chrome (and others) to revalidate on every visit. Costs basically
    # nothing since the HTML is ~50KB and generated server-side.
    _send($httpClient, $response, 'text/html; charset=utf-8', $body, no_cache => 1);
}

sub _send {
    my ($httpClient, $response, $type, $body, %opts) = @_;
    $response->code(200);
    $response->header('Content-Type'  => $type);
    $response->header('Content-Length' => length($body));
    if ($opts{no_cache}) {
        # Belt-and-braces no-cache. 'no-store' is the strongest directive
        # for HTTP/1.1; the Pragma + Expires are for older browsers and
        # HTTP/1.0 proxies that don't honor Cache-Control.
        $response->header('Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0');
        $response->header('Pragma'        => 'no-cache');
        $response->header('Expires'       => '0');
    }
    $response->header('Access-Control-Allow-Origin' => '*');
    $response->content($body);
    Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body);
}

# ----- The page itself -------------------------------------------------------

sub _pageHtml { return <<'HTML'; }
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Now Playing</title>
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0a0a0a">

<!-- PWA: when added to home screen, launch chrome-less. iOS uses the apple-* tags. -->
<link rel="manifest" href="/plugins/NowPlayingDisplay/manifest.json">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Now Playing">

<style>
  @import url('https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500;700&family=JetBrains+Mono:wght@500&display=swap');

  /* Palette and proportions adapted from NowPlayingShare canvas card,
     scaled to fluid web typography that works from phones to 4K TVs. */
  :root {
    --bg:      #0a0a0a;
    --fg:      #ffffff;                /* Primary text (title, NOW PLAYING) */
    --text2:   rgba(255,255,255,0.85); /* Values: artist, album, composer */
    --text3:   rgba(255,255,255,0.70); /* Tertiary text */
    --label:   rgba(255,255,255,0.45); /* Dim labels: "by" / "from" / "work" */
    --faint:   rgba(255,255,255,0.18); /* Lines, borders */
    --accent:  #c9a84c;                /* Material Skin gold accent */
    /* Legacy aliases so older inline rules keep working. */
    --dim:     rgba(255,255,255,0.70);
  }
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
  html,body { height: 100%; overflow: hidden; }
  body {
    background: var(--bg);
    color: var(--fg);
    font-family: 'Roboto', system-ui, sans-serif;
    user-select: none; -webkit-user-select: none;
  }

  /* ============================================================
     Shared text classes — same visual language across every mode.
     ============================================================ */

  /* "NOW PLAYING" small caps label. Letter-spaced, weight 500. */
  .t-label {
    font-weight: 500;
    color: var(--text3);
    letter-spacing: 0.15em;
    text-transform: uppercase;
    font-size: clamp(0.7rem, 1.1vw, 1.1rem);
  }
  /* Main title — heavy weight. Long titles wrap onto multiple lines, and the
     responsive clamp() font-size scales the text down on smaller viewports so
     it stays readable. No truncation: the full title is always shown. */
  .t-title {
    font-weight: 700;
    color: var(--fg);
    letter-spacing: -0.01em;
    line-height: 1.12;
    font-size: clamp(2rem, 5.8vw, 5.4rem);
    width: 100%;
    max-width: 100%;
    /* Allow wrapping; break very long unbroken words rather than overflowing. */
    overflow-wrap: anywhere;
    word-break: break-word;
  }
  .t-title.small {
    font-size: clamp(1.4rem, 3vw, 2.8rem);
    line-height: 1.2;
  }
  /* Value lines (artist, album, composer). */
  .t-line {
    font-weight: 400;
    color: var(--text2);
    line-height: 1.3;
    font-size: clamp(1.1rem, 2.4vw, 2.2rem);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .t-line.small {
    font-size: clamp(0.95rem, 1.7vw, 1.5rem);
  }
  /* The dim italic "by" / "from" / "performed by" prefix.
     Sits inline before the value at ~0.78em of the value's size. */
  .t-prefix {
    font-weight: 300;
    font-style: italic;
    color: var(--label);
    margin-right: 0.5em;
    font-size: 0.78em;
  }

  /* Blurred-art background shared by every mode. */
  #bg {
    position: fixed; inset: 0; z-index: 0;
    background-size: cover; background-position: center;
    filter: blur(80px) saturate(1.5) brightness(0.4);
    transform: scale(1.3);
    transition: background-image 1.6s ease;
  }
  #bg::after {
    content:''; position: absolute; inset: 0;
    background:
      radial-gradient(ellipse at center, transparent 0%, rgba(10,10,10,0.65) 70%),
      linear-gradient(180deg, rgba(10,10,10,0.4), rgba(10,10,10,0.2) 50%, rgba(10,10,10,0.6));
  }

  /* Each mode is a section that occupies the full viewport when active. */
  .mode {
    position: relative; z-index: 1;
    height: 100%; width: 100%;
    display: none;
  }
  .mode.active { display: grid; }

  /* ===== Mode: now-playing ============================================= */
  .mode.now-playing {
    grid-template-columns: auto 1fr;
    gap: 6vw; align-items: center;
    padding: 6vh 8vw;
  }
  #np-art {
    width: 42vh; height: 42vh; max-width: 50vw;
    border-radius: 6px;
    background: #181818 center/cover no-repeat;
    box-shadow: 0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.04);
    transition: background-image 0.9s ease;
  }
  .np-meta { display: flex; flex-direction: column; gap: 1.4vh; min-width: 0; }
  /* Per-mode tweak only: text spacing inside Now Playing. */
  .np-progress {
    margin-top: 3.5vh;
    display: flex; flex-direction: column; gap: 0.7vh;
    font-family: 'JetBrains Mono', monospace; font-size: clamp(0.75rem, 1vw, 1rem);
    color: var(--text3);
  }
  .np-bar { height: 2px; background: var(--faint); border-radius: 1px; overflow: hidden; }
  .np-bar > span {
    display: block; height: 100%; background: var(--accent);
    width: 0%; transition: width 0.4s linear;
  }
  .np-times { display: flex; justify-content: space-between; }

  /* ===== Mode: artwork (fullscreen art + minimal overlay) ============== */
  .mode.artwork {
    place-items: center;
  }
  #art-full {
    width: 88vh; max-width: 88vw; height: 88vh; max-height: 88vw;
    background: #181818 center/cover no-repeat;
    border-radius: 8px;
    box-shadow: 0 40px 100px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.04);
    transition: background-image 0.9s ease;
  }
  #art-overlay {
    position: fixed; left: 5vw; right: 5vw; bottom: 5vh; z-index: 5;
    pointer-events: none;
    opacity: 0; transition: opacity 0.6s ease;
  }
  body.show-overlay #art-overlay { opacity: 1; }
  #art-overlay > div { text-shadow: 0 2px 12px rgba(0,0,0,0.85); }

  /* ===== Mode: lyrics ================================================= */
  .mode.lyrics {
    grid-template-rows: auto 1fr;
    padding: 4vh 8vw 6vh;
    gap: 3vh;
  }
  .lyrics-header {
    display: flex; align-items: center; gap: 2vw;
    border-bottom: 1px solid var(--faint);
    padding-bottom: 2vh;
  }
  #lyr-art {
    width: 11vh; height: 11vh; flex-shrink: 0;
    background: #181818 center/cover no-repeat;
    border-radius: 4px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  }
  .lyrics-header > div:last-child { min-width: 0; flex: 1; }
  #lyr-body {
    font-weight: 400;
    line-height: 1.7;
    color: var(--fg);
    overflow-y: auto;
    scrollbar-width: thin; scrollbar-color: var(--faint) transparent;
    min-height: 0;
  }
  #lyr-body::-webkit-scrollbar { width: 4px; }
  #lyr-body::-webkit-scrollbar-thumb { background: var(--faint); border-radius: 2px; }
  /* Plain-text variant (no timestamps): center-aligned, pre-wrap. */
  #lyr-body.plain {
    text-align: center;
    white-space: pre-wrap;
    font-size: clamp(1.4rem, 2.6vw, 2.4rem);
  }
  #lyr-body.plain p { margin: 0 0 1em; }
  /* Synced variant: each line is a div we can highlight. Dim by default,
     fully visible when active. */
  #lyr-body.synced {
    text-align: center;
    font-size: clamp(1.5rem, 2.8vw, 2.6rem);
    /* Top padding pushes the first line down so the active-line
       upper-third position has space to scroll to. */
    padding-top: 35vh;
    padding-bottom: 35vh;
  }
  #lyr-body.synced .lyr-line {
    opacity: 0.30;
    transition: opacity 0.4s ease, color 0.4s ease, transform 0.4s ease;
    padding: 0.15em 0;
    color: var(--text2);
    transform: scale(0.98);
    transform-origin: center;
  }
  #lyr-body.synced .lyr-line.active {
    opacity: 1;
    color: var(--fg);
    transform: scale(1.04);
  }
  #lyr-body.synced .lyr-line.past   { opacity: 0.20; }
  #lyr-body.synced .lyr-line.future { opacity: 0.45; }
  #lyr-body.empty {
    display: flex; align-items: center; justify-content: center;
    color: var(--label); font-style: italic;
    font-size: clamp(1.2rem, 2vw, 1.8rem);
  }

  /* ===== Mode: ambient (clock + minimal info) ========================= */
  .mode.ambient {
    place-items: center;
    grid-template-rows: 1fr auto;
    padding: 8vh 6vw;
  }
  #amb-clock {
    align-self: center;
    font-family: 'Roboto', sans-serif;
    font-weight: 300;
    font-size: clamp(6rem, 18vw, 16rem);
    line-height: 1;
    letter-spacing: -0.04em;
    text-align: center;
  }
  #amb-date {
    margin-top: 1.5vh;
    text-align: center;
    font-size: clamp(0.9rem, 1.3vw, 1.2rem);
    color: var(--text3);
    letter-spacing: 0.18em;
    text-transform: uppercase;
    font-weight: 500;
  }
  .amb-strip {
    align-self: end;
    display: flex; align-items: center; gap: 1.5vw;
    width: 100%; max-width: 900px;
    padding: 2vh 2.5vw;
    background: rgba(0,0,0,0.45);
    border: 1px solid var(--faint);
    border-radius: 999px;
    backdrop-filter: blur(8px);
    opacity: 0; transition: opacity 0.6s ease;
  }
  body.has-track .amb-strip { opacity: 1; }
  #amb-art {
    width: 6vh; height: 6vh; flex-shrink: 0;
    background: #181818 center/cover no-repeat;
    border-radius: 4px;
  }
  .amb-strip > div:last-child { flex: 1; min-width: 0; }
  #amb-title-line, #amb-artist-line {
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }

  /* ===== Mode: vinyl ================================================== */
  .mode.vinyl {
    place-items: center;
    grid-template-rows: 1fr auto;
    gap: 4vh;
    padding: 6vh 4vw;
  }
  /* Vinyl uses a softer, less-blurred background than other modes so
     the artwork reads as the visual subject rather than mere ambience. */
  body.vinyl-active #bg {
    filter: blur(40px) saturate(1.4) brightness(0.55);
  }
  .vinyl-stage {
    position: relative;
    width: min(66vh, 66vw);
    height: min(66vh, 66vw);
    align-self: center;
  }
  /* The disc itself — rotating wrapper. */
  .vinyl-disc {
    position: absolute; inset: 0;
    border-radius: 50%;
    background:
      radial-gradient(circle at center, #1a1a1a 0%, #050505 70%, #000 100%);
    box-shadow:
      0 50px 100px rgba(0,0,0,0.75),
      inset 0 0 60px rgba(0,0,0,0.8);
    animation: vinyl-spin 6s linear infinite;
    animation-play-state: paused;
  }
  body.vinyl-playing .vinyl-disc { animation-play-state: running; }
  @keyframes vinyl-spin { to { transform: rotate(360deg); } }

  /* Grooves: concentric rings via repeating gradients. Slightly more
     prominent now that they only show on a thin ring around the label. */
  .vinyl-rings {
    position: absolute; inset: 0;
    border-radius: 50%;
    background:
      repeating-radial-gradient(circle at center,
        rgba(255,255,255,0.03) 0px,
        rgba(255,255,255,0.03) 1px,
        transparent 1px,
        transparent 3px);
    mix-blend-mode: screen;
    opacity: 0.8;
  }
  /* A soft specular highlight that rotates with the disc. */
  .vinyl-shine {
    position: absolute; inset: 0;
    border-radius: 50%;
    background: linear-gradient(115deg,
      transparent 30%,
      rgba(255,255,255,0.06) 45%,
      rgba(255,255,255,0.14) 50%,
      rgba(255,255,255,0.06) 55%,
      transparent 70%);
    pointer-events: none;
  }
  /* Center label = album art, at 60% of the disc so a wider ring of vinyl
     shows around it (more record-like, and a slightly smaller artwork). */
  .vinyl-label {
    position: absolute;
    left: 20%; top: 20%; width: 60%; height: 60%;
    border-radius: 50%;
    background: #181818 center/cover no-repeat;
    box-shadow:
      0 0 0 1px rgba(255,255,255,0.05),
      0 8px 24px rgba(0,0,0,0.6);
    transition: background-image 0.9s ease;
  }
  .vinyl-hole {
    position: absolute;
    left: 49.2%; top: 49.2%; width: 1.6%; height: 1.6%;
    border-radius: 50%;
    background: #000;
    box-shadow: inset 0 0 3px rgba(255,255,255,0.2);
  }
  .vinyl-meta {
    text-align: center; max-width: 80vw;
    text-shadow: 0 2px 12px rgba(0,0,0,0.8);
  }
  .vinyl-meta .t-line { display: block; }
  .vinyl-meta .t-line + .t-line { margin-top: 0.3em; }

  /* ===== Mode: visualizer ===========================================
     Fullscreen black canvas. The hidden <audio> is never shown. */
  .mode.visualizer {
    align-items: center;
    justify-content: center;
    background: #000;
  }
  #viz-canvas {
    width: 100vw;
    height: 100vh;
    display: block;
  }
  .viz-hint {
    position: absolute;
    bottom: 6vh; left: 0; right: 0;
    text-align: center;
    color: var(--label, rgba(255,255,255,0.4));
    font-size: 0.9rem;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    pointer-events: none;
    transition: opacity 0.6s ease;
  }
  #viz-audio { display: none; }

  /* On-screen offset tuner — appears over the visualizer for live sync
     fine-tuning. Auto-hides when idle; tap the screen to reveal. */
  .viz-tuner {
    position: absolute;
    bottom: 6vh; left: 50%; transform: translateX(-50%);
    display: flex; align-items: center; gap: 10px;
    padding: 10px 14px;
    background: rgba(20,22,26,0.82);
    border: 1px solid rgba(255,255,255,0.1);
    border-radius: 14px;
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    transition: opacity 0.4s ease;
    z-index: 5;
  }
  .viz-tuner.fade { opacity: 0; pointer-events: none; }
  .viz-tbtn {
    appearance: none; border: 1px solid rgba(255,255,255,0.18);
    background: rgba(255,255,255,0.06); color: #fff;
    font-size: 1rem; font-weight: 600;
    padding: 8px 12px; border-radius: 10px; cursor: pointer;
    min-width: 48px;
  }
  .viz-tbtn:active { background: rgba(255,255,255,0.18); }
  .viz-tsave { background: rgba(79,176,208,0.25); border-color: rgba(79,176,208,0.5); }
  .viz-tval { min-width: 70px; text-align: center; color: #fff; }
  .viz-tval #viz-tms { font-size: 1.4rem; font-weight: 700; }
  .viz-tunit { font-size: 0.8rem; color: var(--label,#999); margin-left: 3px; }
  .viz-tsaved {
    position: absolute; top: -28px; left: 50%; transform: translateX(-50%);
    background: rgba(79,176,208,0.9); color: #fff;
    padding: 3px 10px; border-radius: 8px; font-size: 0.8rem;
  }
  .viz-tlegend {
    position: absolute; bottom: -22px; left: 50%; transform: translateX(-50%);
    white-space: nowrap; color: var(--label,#999); font-size: 0.72rem; opacity: 0.8;
  }

  /* System-delay self-test results panel — centered card the ⏱ Test button
     reveals. Shows the measured software pipeline budget + a Lead stepper. */
  .viz-selftest {
    position: absolute; top: 50%; left: 50%; transform: translate(-50%,-50%);
    min-width: 320px; max-width: 86vw;
    background: rgba(16,18,22,0.94);
    border: 1px solid rgba(255,255,255,0.12);
    border-radius: 16px;
    padding: 20px 22px 18px;
    backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px);
    box-shadow: 0 18px 50px rgba(0,0,0,0.6);
    color: #fff; z-index: 8;
    font-size: 0.92rem; line-height: 1.5;
  }
  .viz-selftest h3 {
    margin: 0 0 10px; font-size: 1.0rem; font-weight: 700; letter-spacing: 0.02em;
  }
  .viz-stline { display: flex; justify-content: space-between; gap: 18px; }
  .viz-stline .v { font-variant-numeric: tabular-nums; color: #9fd8e8; font-weight: 600; }
  .viz-stline.total { border-top: 1px solid rgba(255,255,255,0.14); margin-top: 6px; padding-top: 6px; }
  .viz-stline.total .v { color: #fff; }
  .viz-stnote { margin-top: 10px; font-size: 0.78rem; color: var(--label,#9a9a9a); line-height: 1.45; }
  .viz-stlead {
    display: flex; align-items: center; justify-content: center; gap: 8px;
    margin-top: 14px; padding-top: 12px; border-top: 1px solid rgba(255,255,255,0.14);
  }
  .viz-stlead .lbl { color: var(--label,#bbb); font-size: 0.82rem; }
  .viz-stlead .lv { min-width: 56px; text-align: center; font-weight: 700; font-variant-numeric: tabular-nums; }
  .viz-stactions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 16px; }

  /* Calibration tone buttons. When a tone is playing, the active button
     glows so it's obvious which tone is on (and that "tap again to stop"
     is the way to silence it). */
  .viz-tcal {
    font-size: 0.9rem;
    background: rgba(255,255,255,0.06);
  }
  .viz-tcal.active {
    background: #ff8040;
    color: #000;
    box-shadow: 0 0 12px #ff8040;
    animation: viz-tcal-pulse 1s ease-in-out infinite;
  }
  @keyframes viz-tcal-pulse {
    0%, 100% { box-shadow: 0 0 8px #ff8040; }
    50%      { box-shadow: 0 0 20px #ff8040; }
  }


  /* ===== Mode: biography ============================================= */
  /* Two-column split: artist image + now-playing meta on the left, the
     biography body scrolls on the right. Layout collapses to a stacked
     vertical view on narrow / portrait screens. */
  .mode.biography {
    grid-template-columns: minmax(280px, 38%) 1fr;
    grid-template-rows: minmax(0, 1fr);     /* row can shrink below content */
    align-items: stretch;
    gap: 5vw;
    /* Bottom padding leaves room for the floating player picker pill so
       the bio doesn't visually run into it. */
    padding: 6vh 6vw 12vh;
    min-height: 0;
  }
  .bio-left {
    display: flex; flex-direction: column;
    gap: 3vh;
    min-width: 0;
    min-height: 0;
    /* The left column doesn't scroll; it just doesn't push the row taller. */
    overflow: hidden;
  }
  #bio-art {
    /* Square art, but capped so it never makes the row taller than the
       viewport. width:100% sets the natural square size from the column
       width; max-height kicks in only when that square would be too tall
       (narrow tall layouts), shrinking it proportionally. */
    width: 100%;
    aspect-ratio: 1 / 1;
    max-height: 45vh;
    background: #181818 center/cover no-repeat;
    border-radius: 8px;
    box-shadow: 0 30px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.04);
    transition: background-image 0.9s ease;
    flex: 0 0 auto;
  }
  .bio-meta { min-width: 0; flex: 0 0 auto; }
  .bio-right {
    display: flex; flex-direction: column;
    gap: 2vh;
    min-width: 0;
    /* The right column owns its own scroll context so a long bio doesn't
       push the layout. */
    overflow: hidden;
  }
  #bio-heading {
    flex-shrink: 0;
    border-bottom: 1px solid var(--faint);
    padding-bottom: 1.5vh;
  }
  #bio-body {
    flex: 1; min-height: 0;
    overflow-y: auto;
    font-size: clamp(0.95rem, 1.4vw, 1.25rem);
    line-height: 1.7;
    color: var(--text2);
    scrollbar-width: thin; scrollbar-color: var(--faint) transparent;
    padding-right: 0.5em;
  }
  #bio-body::-webkit-scrollbar { width: 4px; }
  #bio-body::-webkit-scrollbar-thumb { background: var(--faint); border-radius: 2px; }
  /* MAI's bio HTML uses paragraph, header, and list tags. Tune them to
     match our type scale rather than relying on browser defaults. */
  #bio-body p { margin: 0 0 1em; }
  #bio-body h2, #bio-body h3, #bio-body h4 {
    color: var(--fg);
    font-weight: 500;
    margin: 1.6em 0 0.5em;
    font-size: 1.15em;
    letter-spacing: 0.01em;
  }
  #bio-body i, #bio-body em { color: var(--text2); }
  #bio-body b, #bio-body strong { color: var(--fg); font-weight: 500; }
  #bio-body ul { list-style: none; padding: 0; margin: 1em 0; }
  #bio-body li { padding: 0.2em 0; }
  #bio-body a {
    color: var(--accent); text-decoration: none;
    border-bottom: 1px dotted var(--accent);
  }
  /* "More online sources" list — keep it compact and visually quieter. */
  #bio-body ul.maiExternalLinksList li { display: inline-block; margin-right: 1em; }
  #bio-body.bio-empty {
    display: flex; align-items: center; justify-content: center;
    color: var(--label); font-style: italic;
    font-size: clamp(1rem, 1.5vw, 1.3rem);
  }

  /* Portrait / narrow screens: stack vertically. */
  @media (max-aspect-ratio: 5/6) {
    .mode.biography {
      grid-template-columns: 1fr;
      gap: 3vh;
      padding: 4vh 6vw;
    }
    #bio-art { max-width: 60vw; align-self: center; }
  }

  /* ===== UI chrome (fades after inactivity) =========================== */
  .ui {
    position: fixed; z-index: 20;
    transition: opacity 0.6s ease;
  }
  .ui.hidden { opacity: 0; pointer-events: none; }

  /* ===== Lyrion logo, top-right ====================================== */
  #brand {
    /* On iOS PWAs, the status bar is overlaid on our page (black-translucent).
       max(...) ensures we sit BELOW it on iOS while keeping the same look on
       platforms with no safe-area (Android, desktop) where env() evaluates to 0. */
    position: fixed;
    top: max(3vh, env(safe-area-inset-top));
    right: max(3vw, env(safe-area-inset-right));
    z-index: 11;
    display: flex; align-items: center;
    height: 3.6vh; min-height: 28px; max-height: 48px;
    opacity: 0.7;
    pointer-events: none;
  }
  #brand svg { height: 100%; width: auto; display: block; }

  /* ===== Mode icons, top-left ======================================== */
  #mode-picker {
    /* Same iOS safe-area trick as #brand. */
    top: max(3vh, env(safe-area-inset-top));
    left: max(3vw, env(safe-area-inset-left));
    display: flex; align-items: center; gap: 0.4em;
    padding: 0.3em;
    background: rgba(0,0,0,0.4);
    border: 1px solid var(--faint);
    border-radius: 999px;
    backdrop-filter: blur(8px);
  }
  .mode-btn {
    display: inline-flex; align-items: center; justify-content: center;
    width: 2.6em; height: 2.6em;
    background: transparent;
    border: none; border-radius: 999px;
    color: var(--text3);
    cursor: pointer;
    transition: background 0.2s ease, color 0.2s ease;
    padding: 0;
  }
  .mode-btn:hover { background: rgba(255,255,255,0.08); color: var(--fg); }
  .mode-btn.active {
    background: rgba(201,168,76,0.18);
    color: var(--accent);
  }
  .mode-btn svg {
    width: 1.4em; height: 1.4em;
    fill: none; stroke: currentColor;
    stroke-width: 1.6;
    stroke-linecap: round; stroke-linejoin: round;
  }
  /* Filled variants for icons that read better solid (vinyl disc, note). */
  .mode-btn svg.solid { fill: currentColor; stroke: none; }

  /* ===== Player picker, bottom-centre, reveals upward ================ */
  #picker {
    bottom: max(3vh, env(safe-area-inset-bottom)); left: 50%; transform: translateX(-50%); top: auto; right: auto;
    display: flex; align-items: center; gap: 0.8em;
    padding: 0.6em 1.2em;
    background: rgba(0,0,0,0.5);
    border: 1px solid var(--faint);
    border-radius: 999px;
    backdrop-filter: blur(8px);
    font-family: 'JetBrains Mono', monospace;
    font-size: 0.85rem;
    color: var(--text3);
  }
  #picker .dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: var(--faint);
    flex-shrink: 0;
  }
  #picker .dot.live { background: var(--accent); box-shadow: 0 0 8px var(--accent); }

  /* Trigger button — shows the current player; tap to open the panel above. */
  #player-trigger {
    background: transparent; border: none;
    color: var(--fg);
    font: inherit;
    cursor: pointer;
    padding: 0.2em 0.6em;
    border-radius: 4px;
    display: inline-flex; align-items: center; gap: 0.4em;
    max-width: 60vw;
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }
  #player-trigger:hover { background: rgba(255,255,255,0.08); }
  #player-trigger .caret {
    width: 0; height: 0;
    /* Up-triangle to hint that options open upward. */
    border-left: 4px solid transparent;
    border-right: 4px solid transparent;
    border-bottom: 5px solid var(--text3);
    margin-left: 0.2em;
  }

  /* The panel of player options. Hidden by default; shown via .open. */
  #player-panel {
    position: absolute;
    bottom: calc(100% + 0.6em);
    left: 50%; transform: translateX(-50%);
    min-width: 240px; max-width: 80vw;
    max-height: 60vh; overflow-y: auto;
    padding: 0.4em;
    background: rgba(0,0,0,0.85);
    border: 1px solid var(--faint);
    border-radius: 12px;
    backdrop-filter: blur(12px);
    display: none;
    flex-direction: column;
    gap: 0.2em;
  }
  #picker.open #player-panel { display: flex; }
  .player-option {
    display: flex; align-items: center; gap: 0.6em;
    padding: 0.6em 1em;
    background: transparent; border: none;
    color: var(--fg);
    font: inherit;
    text-align: left;
    cursor: pointer;
    border-radius: 6px;
    white-space: nowrap;
  }
  .player-option:hover { background: rgba(255,255,255,0.08); }
  .player-option.selected { color: var(--accent); }
  .player-option .pdot {
    width: 6px; height: 6px; border-radius: 50%;
    background: var(--faint);
    flex-shrink: 0;
  }
  .player-option .pdot.playing { background: var(--accent); }

  /* Compact / portrait — stack the now-playing layout. */
  @media (max-aspect-ratio: 5/6) {
    .mode.now-playing {
      grid-template-columns: 1fr;
      grid-template-rows: auto auto;
      justify-items: center;
      text-align: center;
      gap: 4vh;
    }
    #np-art { width: 60vw; height: 60vw; }
    .np-meta { align-items: center; }
  }

  .idle .t-title { color: var(--text3); font-style: italic; font-weight: 400; }
  .idle #np-art, .idle #art-full { opacity: 0.3; }
</style>
</head>
<body>
  <div id="bg"></div>

  <!-- Lyrion logo, top-left. Inline SVG so we can recolour via fill="currentColor"
       and avoid an extra HTTP request. Source: Lyrion's own lyrion-logo.svg,
       same as Material Skin ships. We override fill to white. -->
  <div id="brand" aria-hidden="true">
    <svg viewBox="232 508.37 128 26" xmlns="http://www.w3.org/2000/svg">
      <path d="m280.47 528.77v-15.183h2.1882v13.296h8.2933v1.887zm15.092 0v-5.8129l0.50328 1.3448-6.5865-10.715h2.3414l5.5361 9.0447h-1.2692l5.558-9.0447h2.1663l-6.5646 10.715 0.4814-1.3448v5.8129zm10.188 0v-15.183h5.9738q2.0131 0 3.4355 0.629 1.4223 0.62901 2.1882 1.822t0.76587 2.8414-0.76587 2.8414q-0.76587 1.1712-2.1882 1.8002-1.4223 0.62901-3.4355 0.62901h-4.7703l0.98469-0.99773v5.6177zm10.241 0-3.895-5.5092h2.3414l3.9388 5.5092zm-8.0526-5.4008-0.98469-1.0628h4.7046q2.1007 0 3.1729-0.88928 1.0941-0.91097 1.0941-2.5377t-1.0941-2.516q-1.0722-0.88929-3.1729-0.88929h-4.7046l0.98469-1.0845zm13.72 5.4008v-15.183h2.1882v15.183zm13.698 0.17352q-1.7506 0-3.2604-0.58562-1.488-0.58563-2.5821-1.6267-1.0941-1.0628-1.7068-2.4726-0.61269-1.4098-0.61269-3.08t0.61269-3.08q0.6127-1.4098 1.7068-2.451 1.0941-1.0628 2.5821-1.6484 1.488-0.58563 3.2604-0.58563 1.7506 0 3.2166 0.58563 1.488 0.56393 2.5821 1.6267 1.116 1.0411 1.7068 2.451 0.61269 1.4098 0.61269 3.1016t-0.61269 3.1016q-0.59081 1.4098-1.7068 2.4726-1.0941 1.0411-2.5821 1.6267-1.4661 0.56393-3.2166 0.56393zm0-1.9304q1.2692 0 2.3414-0.4338 1.0941-0.4338 1.8818-1.2146 0.80963-0.80252 1.2473-1.8653 0.45952-1.0628 0.45952-2.3208t-0.45952-2.3208q-0.43764-1.0628-1.2473-1.8436-0.78775-0.80252-1.8818-1.2363-1.0722-0.43379-2.3414-0.43379-1.291 0-2.3851 0.43379-1.0722 0.4338-1.8818 1.2363-0.80963 0.78084-1.2692 1.8436-0.43764 1.0628-0.43764 2.3208t0.43764 2.3208q0.45952 1.0628 1.2692 1.8653 0.80963 0.78083 1.8818 1.2146 1.0941 0.4338 2.3851 0.4338zm11.466 1.7569v-15.183h1.7943l10.131 12.472h-0.94092v-12.472h2.1882v15.183h-1.7943l-10.131-12.472h0.94092v12.472zm-79.853-9.5045c0.50976 0 0.923 0.40961 0.923 0.91491v2.3906c0 0.50527-0.41324 0.91492-0.923 0.91492-0.50975 0-0.92299-0.40965-0.92299-0.91492v-2.3906c0-0.5053 0.41324-0.91491 0.92299-0.91491zm-7.5669-2.3324c0.50976 0 0.92299 0.40961 0.92299 0.91492v7.0555c0 0.50528-0.41323 0.91492-0.92299 0.91492-0.50975 0-0.92297-0.40964-0.92297-0.91492v-7.0555c0-0.50531 0.41322-0.91492 0.92297-0.91492zm3.7835-5.2179c0.50975 0 0.92298 0.4096 0.92298 0.91488v17.491c0 0.50527-0.41323 0.91492-0.92298 0.91492-0.50976 0-0.92299-0.40965-0.92299-0.91492v-17.491c0-0.50528 0.41323-0.91488 0.92299-0.91488zm-7.5669 0.53672c0.50976 0 0.92299 0.40959 0.92299 0.91486v16.418c0 0.50529-0.41323 0.91488-0.92299 0.91488-0.50975 0-0.92299-0.40959-0.92299-0.91488v-16.418c0-0.50527 0.41324-0.91486 0.92299-0.91486zm-7.5669 2.4449c0.50975 0 0.92299 0.40959 0.92299 0.91488v11.528c0 0.5053-0.41324 0.91491-0.92299 0.91491s-0.92299-0.40961-0.92299-0.91491v-11.528c0-0.50529 0.41324-0.91488 0.92299-0.91488zm-3.7835 2.4449c0.50975 0 0.923 0.40964 0.923 0.91491v6.6381c0 0.50527-0.41325 0.91492-0.923 0.91492s-0.92299-0.40965-0.92299-0.91492v-6.6381c0-0.50527 0.41324-0.91491 0.92299-0.91491zm7.567-8.766c0.50975 0 0.92298 0.4096 0.92298 0.91488v24.17c0 0.50528-0.41323 0.91492-0.92298 0.91492-0.50977 0-0.923-0.40964-0.923-0.91492v-24.17c0-0.50528 0.41323-0.91488 0.923-0.91488zm-11.35 1.7294c0.50975 0 0.92298 0.40959 0.92298 0.91487v20.712c0 0.50529-0.41323 0.91489-0.92298 0.91489-0.50976 0-0.92299-0.4096-0.92299-0.91489v-20.712c0-0.50528 0.41323-0.91487 0.92299-0.91487zm-3.7835 4.5917c0.50976 0 0.92299 0.40959 0.92299 0.91488v11.528c0 0.5053-0.41323 0.91491-0.92299 0.91491-0.50975 0-0.92299-0.40961-0.92299-0.91491v-11.528c0-0.50529 0.41324-0.91488 0.92299-0.91488zm-3.7835 4.5917c0.50975 0 0.92299 0.4096 0.92299 0.91488v2.3445c0 0.50527-0.41324 0.91492-0.92299 0.91492s-0.92299-0.40965-0.92299-0.91492v-2.3445c0-0.50528 0.41324-0.91488 0.92299-0.91488z"
            fill="#ffffff"/>
    </svg>
  </div>

  <!-- Player picker — bottom centre, opens upward. -->
  <div id="picker" class="ui">
    <span class="dot" id="dot" title="Live connection indicator"></span>
    <button id="player-trigger" type="button" aria-haspopup="listbox" aria-expanded="false">
      <span id="player-trigger-label">No player</span>
      <span class="caret" aria-hidden="true"></span>
    </button>
    <div id="player-panel" role="listbox" aria-label="Choose player"></div>
  </div>

  <!-- Mode icons — top left. Each <button data-mode="..."> is a tappable
       round icon. The active mode gets .active styling. SVG icons are
       inline so we can tint via currentColor. -->
  <div id="mode-picker" class="ui" role="tablist" aria-label="Display mode">
    <button class="mode-btn" data-mode="now-playing" title="Now playing" aria-label="Now playing">
      <!-- Music note -->
      <svg class="solid" viewBox="0 0 24 24"><path d="M12 3v10.55A4 4 0 1 0 14 17V7h4V3z"/></svg>
    </button>
    <button class="mode-btn" data-mode="artwork" title="Artwork" aria-label="Artwork">
      <!-- Picture frame -->
      <svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="16" rx="2"/><circle cx="9" cy="10" r="1.5"/><path d="M21 17l-5-5L7 21"/></svg>
    </button>
    <button class="mode-btn" data-mode="lyrics" title="Lyrics" aria-label="Lyrics">
      <!-- Text lines -->
      <svg viewBox="0 0 24 24"><path d="M4 6h16M4 12h16M4 18h10"/></svg>
    </button>
    <button class="mode-btn" data-mode="ambient" title="Ambient" aria-label="Ambient (clock)">
      <!-- Clock -->
      <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></svg>
    </button>
    <button class="mode-btn" data-mode="vinyl" title="Vinyl" aria-label="Vinyl">
      <!-- Vinyl disc — outer + middle ring + spindle hole -->
      <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.5"/><circle class="solid" cx="12" cy="12" r="0.8" style="fill:currentColor;stroke:none"/></svg>
    </button>
    <button class="mode-btn" data-mode="biography" title="Biography" aria-label="Biography">
      <!-- Person with text lines -->
      <svg viewBox="0 0 24 24"><circle cx="8" cy="8" r="3"/><path d="M3 20c0-3 2.5-5 5-5s5 2 5 5"/><path d="M15 9h6M15 13h6M15 17h4"/></svg>
    </button>
    <button class="mode-btn" data-mode="visualizer" title="Visualizer" aria-label="Visualizer" id="viz-btn" hidden>
      <!-- Spectrum bars -->
      <svg viewBox="0 0 24 24"><path d="M4 14v4M9 9v9M14 5v13M19 11v7"/></svg>
    </button>
  </div>

  <!-- ===== Mode: now-playing ================ -->
  <section class="mode now-playing" data-mode="now-playing">
    <div id="np-art"></div>
    <div class="np-meta">
      <div class="t-label" id="np-state">NOW PLAYING</div>
      <h1 class="t-title" id="np-title">Nothing playing</h1>
      <!-- Each value line has a tiny italic dim prefix ("by", "from", etc.)
           followed by the value. Mirrors NowPlayingShare's canvas layout. -->
      <div class="t-line" id="np-artist-line">
        <span class="t-prefix" id="np-artist-prefix">by</span><span id="np-artist"></span>
      </div>
      <div class="t-line small" id="np-composer-line" hidden>
        <span class="t-prefix">composed by</span><span id="np-composer"></span>
      </div>
      <div class="t-line small" id="np-work-line" hidden>
        <span class="t-prefix">work</span><span id="np-work"></span>
      </div>
      <div class="t-line small" id="np-album-line">
        <span class="t-prefix">from</span><span id="np-album"></span>
      </div>
      <div class="np-progress">
        <div class="np-bar"><span id="np-fill"></span></div>
        <div class="np-times"><span id="np-cur">0:00</span><span id="np-dur">0:00</span></div>
      </div>
    </div>
  </section>

  <!-- ===== Mode: artwork ==================== -->
  <section class="mode artwork" data-mode="artwork">
    <div id="art-full"></div>
    <div id="art-overlay">
      <div>
        <div class="t-label">NOW PLAYING</div>
        <h2 class="t-title small" id="art-title" style="margin-top:0.4em;">Nothing playing</h2>
        <div class="t-line small" style="margin-top:0.3em;">
          <span class="t-prefix">by</span><span id="art-artist"></span>
        </div>
        <div class="t-line small" id="art-album-line" style="margin-top:0.2em;" hidden>
          <span class="t-prefix">from</span><span id="art-album"></span>
        </div>
      </div>
    </div>
  </section>

  <!-- ===== Mode: lyrics ===================== -->
  <section class="mode lyrics" data-mode="lyrics">
    <header class="lyrics-header">
      <div id="lyr-art"></div>
      <div>
        <div class="t-title small" id="lyr-title">Nothing playing</div>
        <div class="t-line small" style="margin-top:0.3em;">
          <span class="t-prefix">by</span><span id="lyr-artist"></span>
        </div>
        <div class="t-line small" id="lyr-album-line" style="margin-top:0.2em;" hidden>
          <span class="t-prefix">from</span><span id="lyr-album"></span>
        </div>
      </div>
    </header>
    <div id="lyr-body" class="empty">Lyrics will appear here when available.</div>
  </section>

  <!-- ===== Mode: ambient ==================== -->
  <section class="mode ambient" data-mode="ambient">
    <div>
      <div id="amb-clock">--:--</div>
      <div id="amb-date"></div>
    </div>
    <div class="amb-strip">
      <div id="amb-art"></div>
      <div>
        <div class="t-line small" id="amb-title-line"><span id="amb-title">Nothing playing</span></div>
        <div class="t-line small" id="amb-meta-line" style="margin-top:0.2em;">
          <span class="t-prefix">by</span><span id="amb-artist"></span><span id="amb-sep" hidden> · </span><span id="amb-album"></span>
        </div>
      </div>
    </div>
  </section>

  <!-- ===== Mode: vinyl ======================== -->
  <section class="mode vinyl" data-mode="vinyl">
    <div class="vinyl-stage">
      <div class="vinyl-disc" id="vinyl-disc">
        <!-- Concentric rings simulate grooves; built in CSS, no images. -->
        <div class="vinyl-rings"></div>
        <div class="vinyl-shine"></div>
        <!-- Center label = album art. -->
        <div class="vinyl-label" id="vinyl-label"></div>
        <!-- Center hole -->
        <div class="vinyl-hole"></div>
      </div>
    </div>
    <div class="vinyl-meta">
      <div class="t-title small" id="vinyl-title">Nothing playing</div>
      <div class="t-line small">
        <span class="t-prefix">by</span><span id="vinyl-artist"></span>
      </div>
      <div class="t-line small" id="vinyl-album-line" hidden>
        <span class="t-prefix">from</span><span id="vinyl-album"></span>
      </div>
    </div>
  </section>

  <!-- ===== Mode: biography ==================== -->
  <!-- Two-column layout: artist image + now-playing on the left, scrolling
       biography on the right. -->
  <section class="mode biography" data-mode="biography">
    <aside class="bio-left">
      <div id="bio-art"></div>
      <div class="bio-meta">
        <div class="t-label">NOW PLAYING</div>
        <h2 class="t-title small" id="bio-title" style="margin-top:0.4em;">Nothing playing</h2>
        <div class="t-line small" style="margin-top:0.3em;">
          <span class="t-prefix">by</span><span id="bio-artist"></span>
        </div>
        <div class="t-line small" id="bio-album-line" style="margin-top:0.2em;" hidden>
          <span class="t-prefix">from</span><span id="bio-album"></span>
        </div>
      </div>
    </aside>
    <article class="bio-right">
      <h3 class="t-label" id="bio-heading">BIOGRAPHY</h3>
      <div id="bio-body" class="bio-empty">Select a track to see artist information.</div>
    </article>
  </section>

  <!-- ===== Mode: visualizer ================
       Opt-in. A hidden, muted <audio> streams the current track from LMS
       (/music/<id>/download.mp3) so a Web Audio AnalyserNode can read REAL
       frequency data. The audio is slaved to the room player via the status
       poll (seek to its position, mirror play/pause). Nothing is sent to LMS;
       it's pure client-side playback used only as an analysis source. -->
  <section class="mode visualizer" data-mode="visualizer">
    <canvas id="viz-canvas"></canvas>
    <div id="viz-hint" class="viz-hint">Starting visualizer…</div>
    <div id="viz-tuner" class="viz-tuner" hidden>
      <button id="viz-minus10" class="viz-tbtn" title="-10 ms">−10</button>
      <button id="viz-minus50" class="viz-tbtn" title="-50 ms">−50</button>
      <div class="viz-tval"><span id="viz-tms">0</span><span class="viz-tunit">ms</span></div>
      <button id="viz-plus50" class="viz-tbtn" title="+50 ms">+50</button>
      <button id="viz-plus10" class="viz-tbtn" title="+10 ms">+10</button>
      <button id="viz-tsave" class="viz-tbtn viz-tsave">Save</button>
      <button id="viz-tstyle" class="viz-tbtn viz-tstyle">Style</button>
      <!-- Calibration tones. Plays a looping click train through the current
           room so the user can nudge the offset (with the ±buttons above)
           until the visualizer's bars hit on the clicks. Each button toggles
           its own tone on/off; switching to the other tone stops the first. -->
      <button id="viz-tcal1k"  class="viz-tbtn viz-tcal" title="Start 1 kHz calibration tone">♪ 1k</button>
      <button id="viz-tcal200" class="viz-tbtn viz-tcal" title="Start 200 Hz calibration tone">♪ 200</button>
      <button id="viz-ttest" class="viz-tbtn" title="Measure system delay">⏱ Test</button>
      <div id="viz-tsaved" class="viz-tsaved" hidden>Saved</div>
      <div class="viz-tlegend">0 = passthrough · raise to delay visuals to match the room</div>
    </div>
    <!-- System-delay self-test results (hidden until ⏱ Test is run). -->
    <div id="viz-selftest" class="viz-selftest" hidden>
      <h3>System delay</h3>
      <div class="viz-stline"><span>FFT processing</span><span class="v" id="viz-st-proc">–</span></div>
      <div class="viz-stline"><span>Transport (server→browser)</span><span class="v" id="viz-st-net">–</span></div>
      <div class="viz-stline"><span>Browser draw</span><span class="v" id="viz-st-draw">–</span></div>
      <div class="viz-stline"><span>Delay buffer (your offset)</span><span class="v" id="viz-st-offset">–</span></div>
      <div class="viz-stline total"><span>Known total</span><span class="v" id="viz-st-total">–</span></div>
      <div class="viz-stnote">
        Display/TV panel latency can't be measured in software — use the ♪
        calibration to absorb it. The <b>Lead</b> makes the Visualizer capture
        ahead of the room so the delay buffer can always pull it into sync
        (raise it if visuals start behind on slow/bridged rooms).
      </div>
      <div class="viz-stlead">
        <span class="lbl">Start lead</span>
        <button id="viz-lead-minus" class="viz-tbtn" title="−50 ms">−50</button>
        <span class="lv"><span id="viz-lead-ms">0</span> ms</span>
        <button id="viz-lead-plus" class="viz-tbtn" title="+50 ms">+50</button>
      </div>
      <div class="viz-stactions">
        <button id="viz-st-close" class="viz-tbtn">Close</button>
      </div>
    </div>
  </section>

<script>
(() => {
  const BASE     = location.origin;
  // Poll interval. Kept short so track changes (and therefore lyrics/bio
  // refreshes) are detected quickly — at 10s we were often several seconds
  // into a song before fetching its lyrics, missing the opening lines. The
  // status poll is tiny (a few KB) and the per-track gates mean a faster
  // poll does NOT cause more MAI calls — lyrics/bio still only fetch when
  // the track or artist actually changes. 2.5s is a good balance of
  // responsiveness vs LAN chatter.
  const POLL_MS  = 2500;
  const $ = (id) => document.getElementById(id);

  const fmt = (s) => {
    s = Math.max(0, Math.floor(s || 0));
    const m = Math.floor(s / 60), r = s % 60;
    return m + ':' + (r < 10 ? '0' : '') + r;
  };

  // ----- Mode resolution -----
  // Priority: ?mode=<x> URL param > localStorage > default.
  // The visualizer is opt-in (admin setting); only offered when enabled.
  const VIZ_ENABLED = __NPD_VIZ_ENABLED__;
  // The visualizer is ALWAYS server-driven now: a server-side FFT helper reads
  // the dedicated Visualizer SqueezeLite's audio and streams band data to the
  // page over WebSocket. The page never touches Web Audio, so every browser
  // (including iOS Safari) is supported whenever the admin enables it.
  const VALID_MODES = ['now-playing', 'artwork', 'lyrics', 'ambient', 'vinyl', 'biography'];
  if (VIZ_ENABLED) {
    VALID_MODES.push('visualizer');
    const vb = document.getElementById('viz-btn');
    if (vb) vb.hidden = false;
  }
  const urlParams = new URLSearchParams(location.search);
  const urlMode   = urlParams.get('mode') || '';
  const urlPlayer = urlParams.get('player') || '';
  const isLocked  = urlPlayer && urlPlayer.toLowerCase() !== 'auto';

  // Priority order:
  //   1. URL ?mode= (explicit choice on this device)
  //   2. localStorage np.mode (this device's remembered choice)
  //   3. Plugin admin default (set in LMS settings; substituted at serve time)
  //   4. Hard-coded fallback
  const PLUGIN_DEFAULT_MODE = '__NPD_DEFAULT_MODE__';
  let currentMode =
        (VALID_MODES.includes(urlMode) && urlMode)
     || localStorage.getItem('np.mode')
     || (VALID_MODES.includes(PLUGIN_DEFAULT_MODE) && PLUGIN_DEFAULT_MODE)
     || 'now-playing';
  if (!VALID_MODES.includes(currentMode)) currentMode = 'now-playing';

  function setMode(mode) {
    if (!VALID_MODES.includes(mode)) return;
    currentMode = mode;
    localStorage.setItem('np.mode', mode);
    document.querySelectorAll('.mode').forEach(el => {
      el.classList.toggle('active', el.dataset.mode === mode);
    });
    // Highlight the active icon in the mode picker.
    document.querySelectorAll('.mode-btn').forEach(btn => {
      btn.classList.toggle('active', btn.dataset.mode === mode);
    });
    // Body class lets per-mode CSS adjust globals like the background blur.
    VALID_MODES.forEach(m => document.body.classList.remove(m + '-active'));
    document.body.classList.add(mode + '-active');

    // Re-apply state so the freshly-activated mode shows the right thing.
    if (lastSnap) apply(lastSnap);

    // Visualizer audio engine: only runs while its mode is active so we never
    // stream/transcode audio unless the user is actually looking at it.
    if (mode === 'visualizer') vizStart();
    else vizStop();

    // Lyrics + biography animation loops also only run while their mode is
    // active. They self-terminate by not rescheduling once currentMode moves
    // away; these starters kick them off again on re-entry.
    startLyricsTickIfNeeded();
    startBioFrameIfNeeded();
  }

  // Wire up the icon row.
  document.querySelectorAll('.mode-btn').forEach(btn => {
    btn.addEventListener('click', () => setMode(btn.dataset.mode));
  });

  // ----- Player resolution -----
  // Each browser/tab keeps its own choice — we DO NOT inherit from Material's
  // localStorage key. Earlier versions used 'lms-material::player' to follow
  // whatever Material was set to, but that meant browsers couldn't be
  // independently set (kitchen tablet to Kitchen player, lounge TV to Lounge
  // player, etc.). Now the resolution is purely:
  //
  //   URL ?player=  >  this browser's remembered choice  >  Auto
  //
  // Live override via the on-page picker writes to localStorage np.player.

  let currentPlayer =
        urlPlayer
     || localStorage.getItem('np.player')
     || 'auto';
  let knownPlayers = [];     // cached for label resolution
  let lastSnap = null;
  let lastFetch = 0;
  let pollTimer = null;
  let lastPollError = null;   // stack of the most recent poll/apply failure

  if (isLocked) {
    $('picker').style.display = 'none';
  }

  // ----- Player picker (custom: button + upward panel) -----
  async function loadPlayers() {
    if (isLocked) return;
    try {
      const r = await fetch(BASE + '/plugins/NowPlayingDisplay/players.json', { cache: 'no-store' });
      if (!r.ok) { console.error('players.json HTTP', r.status); return; }
      const d = await r.json();
      knownPlayers = (d && d.players) || [];
      renderPlayerList();
    } catch (e) {
      console.error('loadPlayers failed:', e);
    }
  }

  // Build the panel of options. Re-runs on player-list refresh and on
  // selection changes (so 'selected' / 'playing' indicators stay current).
  function renderPlayerList() {
    const panel = $('player-panel');
    panel.innerHTML = '';

    // Always include the Auto option at the top.
    panel.appendChild(makePlayerOption('auto', 'Auto (most active)', false));

    // If the current pick isn't valid any more, fall back to auto.
    if (currentPlayer !== 'auto' && !knownPlayers.find(p => p.id === currentPlayer)) {
      currentPlayer = 'auto';
    }

    for (const p of knownPlayers) {
      panel.appendChild(makePlayerOption(p.id, p.name, p.state === 'playing'));
    }

    refreshPlayerUI();
  }

  function makePlayerOption(id, name, isPlaying) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'player-option';
    btn.dataset.id = id;
    btn.setAttribute('role', 'option');

    const dot = document.createElement('span');
    dot.className = 'pdot' + (isPlaying ? ' playing' : '');
    btn.appendChild(dot);

    const label = document.createElement('span');
    label.textContent = name;
    btn.appendChild(label);

    btn.addEventListener('click', () => {
      currentPlayer = id;
      localStorage.setItem('np.player', currentPlayer);
      closePlayerPanel();
      refreshPlayerUI();
      poll();
    });
    return btn;
  }

  // Update the visible label and the selected-row highlight.
  function refreshPlayerUI() {
    const labelEl = $('player-trigger-label');
    if (currentPlayer === 'auto') {
      labelEl.textContent = 'Auto (most active)';
    } else {
      const p = knownPlayers.find(p => p.id === currentPlayer);
      labelEl.textContent = p ? p.name : currentPlayer;
    }
    document.querySelectorAll('.player-option').forEach(opt => {
      opt.classList.toggle('selected', opt.dataset.id === currentPlayer);
    });
  }

  function openPlayerPanel()  { $('picker').classList.add('open');
                                $('player-trigger').setAttribute('aria-expanded', 'true'); }
  function closePlayerPanel() { $('picker').classList.remove('open');
                                $('player-trigger').setAttribute('aria-expanded', 'false'); }

  $('player-trigger').addEventListener('click', (e) => {
    e.stopPropagation();
    if ($('picker').classList.contains('open')) closePlayerPanel();
    else openPlayerPanel();
  });

  // Tap outside closes the panel. We use 'click' (not pointerdown) so it
  // fires after our own option-click handlers above.
  document.addEventListener('click', (e) => {
    if (!$('picker').contains(e.target)) closePlayerPanel();
  });

  // ----- State poll -----
  let pollInFlight = false;
  async function poll() {
    if (pollInFlight) return;   // don't stack concurrent status queries if a
                                // poll is slow (e.g. during a stream transition)
    pollInFlight = true;
    try {
      const r = await fetch(
        `${BASE}/plugins/NowPlayingDisplay/state.json?player=${encodeURIComponent(currentPlayer)}`,
        { cache: 'no-store' }
      );
      const d = await r.json();
      const prevPid = lastSnap && lastSnap.player && lastSnap.player.id;
      const newPid  = d && d.player && d.player.id;
      apply(d);
      noteTimeFromSnap(d);
      lastSnap = d;
      if (newPid !== prevPid) {
        // Focused/followed player changed — drop any in-progress tuning so the
        // tuner reflects THIS player's saved offset (and a Save targets this
        // player), not whatever the previous player was set to.
        vizTuneMs = null;
        vizUpdateTunerLabel();
      }
      lastFetch = performance.now();
      $('dot').classList.add('live');
      // Pre-fetch the next track's lyrics so they're ready before it starts.
      prefetchNextLyrics(d);
    } catch (e) {
      // Surface the error rather than swallowing it. A throw inside apply()
      // used to vanish here, leaving modes silently un-updated (e.g. lyrics
      // and bio never fetching). Logging makes such regressions visible.
      console.error('[npd] poll/apply failed:', e);
      lastPollError = (e && e.stack) ? e.stack : String(e);
      $('dot').classList.remove('live');
    } finally {
      pollInFlight = false;
    }
  }

  // Update whatever mode is active.
  // Apply the live-config block from a poll. Updates only the values we've
  // chosen to make live (scroll speed, visualizer offset/presets). Cheap and
  // idempotent — runs every poll, only changes variables if values differ.
  function applyLiveConfig(cfg) {
    if (typeof cfg.scrollPx === 'number' && cfg.scrollPx > 0) {
      BIO_SCROLL_PX_PER_SEC = cfg.scrollPx;
    }
    if (cfg.viz && typeof cfg.viz === 'object') {
      VIZ_CFG = cfg.viz;   // viz offset is read fresh each correction, so the
                           // new value takes effect within ~1 frame
      if (cfg.viz.smoothing) vizApplySmoothing(cfg.viz.smoothing);
      if (cfg.viz.style && VIZ_STYLES.indexOf(cfg.viz.style) >= 0 && !vizStyleTouched) {
        vizStyle = cfg.viz.style;
        vizUpdateStyleLabel();
      }
    }
  }

  function apply(d) {
    // Live-updatable settings arrive with every poll under d.cfg, so changes
    // made in the plugin settings take effect on an open display within one
    // poll — no reload needed.
    if (d && d.cfg) applyLiveConfig(d.cfg);

    const idle = !d || d.state === 'stopped' || d.state === 'no_player';
    document.body.classList.toggle('idle', idle);
    document.body.classList.toggle('has-track', !idle);

    // The visualizer is server-driven (helper FFT over WebSocket); the page has
    // no local audio element to slave to the room, so nothing to do here.

    const title  = d.title  || (idle ? 'Nothing playing' : '');
    const artist = d.artist || '';
    let albumLine = d.album || '';
    if (albumLine && d.year) albumLine += ` (${d.year})`;

    // Resolve artwork URL once for whichever mode needs it.
    let artUrl = '';
    if (d.artwork) {
      artUrl = d.artwork.startsWith('http') ? d.artwork : (BASE + d.artwork);
    }
    // Keep an <img> of the current art for the radial visualizer centre. Only
    // reload when the URL actually changes.
    if (artUrl !== vizArtUrl) {
      vizArtUrl = artUrl;
      if (artUrl) {
        const im = new Image();
        im.crossOrigin = 'anonymous';
        im.onload = () => { vizArtImg = im; };
        im.onerror = () => { vizArtImg = null; };
        im.src = artUrl;
      } else {
        vizArtImg = null;
      }
    }
    if (artUrl) {
      $('bg').style.backgroundImage = `url("${artUrl}")`;
    } else {
      $('bg').style.backgroundImage = '';
    }

    // ----- now-playing -----
    if (currentMode === 'now-playing') {
      // The "NOW PLAYING" label stays static; the .state class hooks the dot.
      $('np-state').textContent  = (d.state === 'playing') ? 'NOW PLAYING'
                                 : (d.state || 'stopped').toUpperCase();
      $('np-title').textContent = title;

      // Classical layout swaps "by" → "performed by" and adds composer + work
      // lines, exactly like NowPlayingShare's canvas card.
      const isClassical = !!d.is_classical;
      $('np-artist-prefix').textContent = isClassical ? 'performed by' : 'by';
      $('np-artist').textContent = artist;

      const composerLine = $('np-composer-line');
      if (isClassical && d.composer) {
        composerLine.hidden = false;
        $('np-composer').textContent = d.composer;
      } else {
        composerLine.hidden = true;
      }

      const workLine = $('np-work-line');
      if (isClassical && d.work) {
        workLine.hidden = false;
        $('np-work').textContent = d.work;
      } else {
        workLine.hidden = true;
      }

      // Album shown only when present, otherwise hide the line entirely
      // (no orphan "from" prefix).
      const albumLineEl = $('np-album-line');
      if (albumLine) {
        albumLineEl.hidden = false;
        $('np-album').textContent = albumLine;
      } else {
        albumLineEl.hidden = true;
      }

      $('np-dur').textContent = fmt(d.duration);
      $('np-art').style.backgroundImage = artUrl ? `url("${artUrl}")` : '';
    }

    // ----- artwork -----
    if (currentMode === 'artwork') {
      $('art-full').style.backgroundImage = artUrl ? `url("${artUrl}")` : '';
      $('art-title').textContent = title;
      $('art-artist').textContent = artist;
      setAlbumLine('art-album-line', 'art-album', albumLine);
      revealOverlayIfChanged(d);
    }

    // ----- lyrics -----
    if (currentMode === 'lyrics') {
      $('lyr-art').style.backgroundImage = artUrl ? `url("${artUrl}")` : '';
      $('lyr-title').textContent = title;
      $('lyr-artist').textContent = artist;
      setAlbumLine('lyr-album-line', 'lyr-album', albumLine);
      maybeFetchLyrics(d, idle);
    }

    // ----- ambient -----
    if (currentMode === 'ambient') {
      $('amb-art').style.backgroundImage = artUrl ? `url("${artUrl}")` : '';
      $('amb-title').textContent  = title;
      $('amb-artist').textContent = artist;
      // Ambient is tight on space — show album inline with a "·" separator
      // after the artist, only when both fit. Drop the separator if empty.
      const showAlbum = !!albumLine;
      $('amb-album').textContent = showAlbum ? albumLine : '';
      $('amb-sep').hidden = !(artist && showAlbum);
    }

    // ----- vinyl -----
    if (currentMode === 'vinyl') {
      $('vinyl-label').style.backgroundImage = artUrl ? `url("${artUrl}")` : '';
      $('vinyl-title').textContent = title;
      $('vinyl-artist').textContent = artist;
      setAlbumLine('vinyl-album-line', 'vinyl-album', albumLine);
      // Disc only spins while playing.
      document.body.classList.toggle('vinyl-playing', d.state === 'playing');
    }

    // ----- biography -----
    if (currentMode === 'biography') {
      // Left column: artist image (falls back to album art) + now-playing meta.
      // Prefer MAI's stored artist image when we have an artist_id; otherwise
      // we'll let the bio fetch swap in a portrait if MAI returns one.
      let leftArt = artUrl;
      if (d.artist_id) {
        // MAI exposes artist images via /imageproxy/mai/artist/<id>/image_l.png.
        // It may 404 if MAI hasn't cached one — the <img> onerror falls back.
        leftArt = BASE + '/imageproxy/mai/artist/' + d.artist_id + '/image_l.png';
      }
      // Use an Image() probe so a 404 doesn't leave a broken artwork tile.
      setBioArt(leftArt, artUrl);

      $('bio-title').textContent = title;
      $('bio-artist').textContent = artist;
      setAlbumLine('bio-album-line', 'bio-album', albumLine);

      // Only refetch when the artist changes (poll runs every 10s; MAI is slow).
      maybeFetchBiography(d);
    }
  }

  // Try to load an artist image; if it fails, fall back to a backup URL.
  // We do this via an <Image> probe so we don't get a visible broken image
  // tile sitting in the layout.
  let bioArtCurrent = '';
  function setBioArt(primary, fallback) {
    if (!primary && !fallback) {
      $('bio-art').style.backgroundImage = '';
      bioArtCurrent = '';
      return;
    }
    if (primary === bioArtCurrent) return;
    const probe = new Image();
    probe.onload = () => {
      $('bio-art').style.backgroundImage = `url("${primary}")`;
      bioArtCurrent = primary;
    };
    probe.onerror = () => {
      if (fallback) {
        $('bio-art').style.backgroundImage = `url("${fallback}")`;
        bioArtCurrent = fallback;
      } else {
        $('bio-art').style.backgroundImage = '';
        bioArtCurrent = '';
      }
    };
    probe.src = primary;
  }

  // Cache the last artist we fetched a bio for so we don't hammer MAI.
  let bioLastFetchedFor = '';
  let bioInFlight = false;
  function maybeFetchBiography(d) {
    // Cache key now includes the album, since MAI uses it for disambiguation
    // and we may get different bios for the same artist on different albums.
    const key = (d.artist_id ? ('id:' + d.artist_id) : (d.artist || '')) + '|' + (d.album || '');
    if (!d.artist && !d.artist_id) {
      renderBiography({ html: '', artist: '' });
      bioLastFetchedFor = '';
      return;
    }
    if (key === bioLastFetchedFor) return;
    if (bioInFlight) return;
    bioInFlight = true;
    // NOTE: do NOT set bioLastFetchedFor here. We only mark a key as
    // "fetched" once we get a NON-EMPTY result back (see below). Setting it
    // up-front meant that a single empty/transient result (e.g. artist_id
    // momentarily missing, or MAI cold) would lock the key forever — the
    // gate would match on every later poll and never retry, leaving "No
    // biography available" on screen until a full browser refresh. This is
    // the client-side twin of the server-side negative-cache bug.
    const fetchKey = key;
    fetchBiography(d.artist, d.artist_id, d.album_artist, d.album)
      .then((result) => {
        if (result && result.html && result.html.trim()) {
          // Success: lock the key so we don't refetch the same bio.
          bioLastFetchedFor = fetchKey;
          renderBiography(result);
        } else {
          // Empty: render the empty state but leave the key CLEAR so the
          // next poll retries. Avoids permanently sticking on a transient
          // miss.
          bioLastFetchedFor = '';
          renderBiography({ html: '', artist: '' });
        }
      })
      .catch(() => {
        bioLastFetchedFor = '';   // allow retry on next poll
        renderBiography({ html: '', artist: '' });
      })
      .finally(() => { bioInFlight = false; });
  }

  async function fetchBiography(artist, artistId, albumArtist, album) {
    const params = new URLSearchParams();
    if (artistId)    params.set('artist_id',   artistId);
    if (artist)      params.set('artist',      artist);
    if (albumArtist) params.set('albumartist', albumArtist);
    if (album)       params.set('album',       album);
    const r = await fetch(BASE + '/plugins/NowPlayingDisplay/biography.json?' + params.toString(),
                          { cache: 'no-store' });
    if (!r.ok) throw new Error('biography HTTP ' + r.status);
    return r.json();
  }

  function renderBiography(d) {
    const body = $('bio-body');
    if (d && d.html && d.html.trim()) {
      // MAI returns trusted server-rendered HTML; we trust it because the
      // plugin owns both ends and the user is the operator.
      body.innerHTML = d.html;
      body.classList.remove('bio-empty');
    } else {
      body.textContent = 'No biography available for this artist.';
      body.classList.add('bio-empty');
    }
    // Always reset auto-scroll position when bio content changes.
    bioScrollOnContentChange();
  }

  // ============================================================
  // Lyrics (synced or plain, via Music Artist Info)
  // ============================================================
  //
  // Like biography: we only fetch when the track URL changes. The result
  // is either synced lines [{t, text}] or a plain HTML blob. For synced,
  // we tick a frame loop that interpolates current playback position from
  // the last status snapshot and highlights the active line.

  let lyrLastFetchedFor = '';
  let lyrInFlight       = false;
  let lyrInFlightUrl    = '';   // URL of the fetch currently in flight (race guard)

  // Pre-fetch cache: track URL -> lyrics payload. When the current track is
  // playing we pre-fetch the NEXT queued track's lyrics into here, so when it
  // starts, maybeFetchLyrics finds it ready and renders with zero lag. Only
  // non-empty results are cached. Bounded to a handful of entries so it can't
  // grow without limit over a long session.
  const lyrCache = new Map();
  const LYR_CACHE_MAX = 8;
  function lyrCachePut(url, payload) {
    if (!url || !payload) return;
    // Evict oldest if at capacity (Map preserves insertion order).
    if (lyrCache.size >= LYR_CACHE_MAX) {
      const oldest = lyrCache.keys().next().value;
      lyrCache.delete(oldest);
    }
    lyrCache.set(url, payload);
  }
  // The fetched payload for the current track. Two shapes:
  //   { synced: true,  lines: [{t, text}, ...] }
  //   { synced: false, html: "<p>...</p>" }
  let lyrData           = null;
  // Cached refs to the line elements (for fast highlight updates).
  let lyrLineEls        = [];
  let lyrActiveIndex    = -1;

  function maybeFetchLyrics(d, idle) {
    const body = $('lyr-body');
    if (!body) return;

    // No track playing or no URL: show empty state, clear any prior data.
    if (idle || !d.track_url) {
      lyrData = null; lyrLineEls = []; lyrActiveIndex = -1;
      lyrLastFetchedFor = '';
      body.innerHTML = '';
      body.textContent = idle
        ? 'Nothing playing.'
        : 'No lyrics available for this track.';
      body.className = 'empty';
      return;
    }

    if (d.track_url === lyrLastFetchedFor) {
      // Same track — keep tick running, no re-fetch needed.
      return;
    }

    // Pre-fetch hit: if we already fetched this track's lyrics ahead of time
    // (because it was the "next" track during the previous song), render
    // them instantly with no network round-trip or lag.
    const cached = lyrCache.get(d.track_url);
    if (cached) {
      lyrLastFetchedFor = d.track_url;
      lyrData = cached;
      renderLyrics();
      return;
    }

    if (lyrInFlight) return;
    lyrInFlight = true;
    // Track this fetch's URL separately from the "successfully fetched" key.
    // We only set lyrLastFetchedFor once we get a NON-EMPTY result, so a
    // transient empty/failed fetch doesn't lock the gate and freeze lyrics
    // until a browser refresh (same bug class as biography). The in-flight
    // URL is just for the race check (did the track change mid-fetch?).
    const fetchUrl = d.track_url;
    lyrInFlightUrl = fetchUrl;

    // Show a placeholder while we fetch — MAI can take seconds for new tracks.
    body.innerHTML = '';
    body.textContent = 'Looking up lyrics…';
    body.className = 'empty';

    fetchLyrics(d.track_url, d.track_id)
      .then((result) => {
        // Track might have changed while we were fetching; only act if the
        // URL we fetched for is still the in-flight one.
        if (lyrInFlightUrl !== fetchUrl) return;
        const hasSynced = result && result.synced && result.lines && result.lines.length;
        const hasPlain  = result && result.html && result.html.trim();
        if (hasSynced || hasPlain) {
          // Success: lock the key so we don't refetch this track, and cache.
          lyrLastFetchedFor = fetchUrl;
          lyrCachePut(fetchUrl, result);
          lyrData = result;
          renderLyrics();
        } else {
          // Empty result: show the empty state but DON'T lock the key, so
          // the next poll retries. (MAI sometimes returns empty on a cold
          // first call then succeeds on a retry.)
          lyrLastFetchedFor = '';
          lyrData = null;
          body.innerHTML = '';
          body.textContent = 'No lyrics available for this track.';
          body.className = 'empty';
        }
      })
      .catch(() => {
        if (lyrInFlightUrl !== fetchUrl) return;
        lyrLastFetchedFor = '';   // allow retry on next poll
        lyrData = null;
        body.textContent = 'Couldn\u2019t load lyrics.';
        body.className = 'empty';
      })
      .finally(() => { lyrInFlight = false; });
  }

  async function fetchLyrics(url, trackId) {
    // Send both url and track_id; the server picks the right one to query
    // MAI with (track_id for local tracks, url for remote), matching how
    // Material Skin identifies tracks. Sending both keeps the server's
    // choice authoritative without the page needing to know the rules.
    const params = new URLSearchParams();
    if (url)     params.set('url', url);
    if (trackId) params.set('track_id', trackId);
    const r = await fetch(BASE + '/plugins/NowPlayingDisplay/lyrics.json?' + params.toString(),
                          { cache: 'no-store' });
    if (!r.ok) throw new Error('lyrics HTTP ' + r.status);
    return r.json();
  }

  // Pre-fetch the NEXT queued track's lyrics into lyrCache so they're ready
  // the instant it starts playing. Called after each poll. Cheap and silent:
  // skips if there's no next track, if it's already cached, or if a prefetch
  // for it is already running. Only caches non-empty results. Runs regardless
  // of the current display mode — by the time the user is looking at lyrics
  // for the next track, they're already there.
  let prefetchInFlightKey = '';
  function prefetchNextLyrics(d) {
    if (!d) return;
    const url = d.next_track_url;
    const nid = d.next_track_id;
    if (!url) return;                       // last track in queue
    // Remote/streaming tracks (negative id) carry a rotating token in their URL
    // that changes every poll, which defeats URL-based caching and would make
    // us re-fetch lyrics (a musicartistinfo lookup that hits LMS and the
    // streaming plugin) on EVERY poll. Skip prefetch for those — lyrics lookup
    // by remote URL is unreliable anyway, and hammering it can contend with the
    // streaming source's own metadata handling.
    const isRemote = !(nid !== undefined && nid !== null && nid !== '' && /^\d+$/.test(String(nid)));
    if (isRemote) return;
    // Key the cache/in-flight guard on the STABLE track id, not the URL.
    const key = String(nid);
    if (lyrCache.has(url)) return;          // already have it (local urls are stable)
    if (prefetchInFlightKey === key) return; // already fetching this track
    prefetchInFlightKey = key;
    fetchLyrics(url, nid)
      .then((result) => {
        const hasSynced = result && result.synced && result.lines && result.lines.length;
        const hasPlain  = result && result.html && result.html.trim();
        if (hasSynced || hasPlain) lyrCachePut(url, result);
      })
      .catch(() => { /* prefetch is best-effort; ignore failures */ })
      .finally(() => { if (prefetchInFlightKey === key) prefetchInFlightKey = ''; });
  }

  function renderLyrics() {
    const body = $('lyr-body');
    if (!body || !lyrData) return;

    // Synced lyrics: build a line-per-div structure we can highlight.
    if (lyrData.synced && lyrData.lines && lyrData.lines.length) {
      // Render each line individually so we can target individual ones.
      const frag = document.createDocumentFragment();
      lyrLineEls = lyrData.lines.map((ln, i) => {
        const el = document.createElement('div');
        el.className = 'lyr-line future';
        el.textContent = ln.text || '';
        frag.appendChild(el);
        return el;
      });
      body.innerHTML = '';
      body.appendChild(frag);
      body.className = 'synced';
      lyrActiveIndex = -1;
      return;
    }

    // Plain text: render as-is. MAI returns HTML when available; otherwise
    // we fall back to a friendly message.
    lyrLineEls = [];
    lyrActiveIndex = -1;
    if (lyrData.html && lyrData.html.trim()) {
      body.innerHTML = lyrData.html;
      body.className = 'plain';
    } else {
      body.innerHTML = '';
      body.textContent = 'No lyrics available for this track.';
      body.className = 'empty';
    }
  }

  // Current playback position interpolated from the last snapshot. The
  // snapshot's `time` field is the position at the moment of the poll;
  // we extrapolate forward by however much wall-clock time has passed.
  // Frozen when the track isn't actually playing.
  let lastTimeSnap   = null;   // { time, fetchedAt, state }
  function noteTimeFromSnap(d) {
    lastTimeSnap = {
      // State snapshot exposes the play position as 'position' (in seconds).
      time:      d.position  || 0,
      fetchedAt: performance.now(),
      state:     d.state     || 'stopped',
    };
  }
  function currentPlayPosition() {
    if (!lastTimeSnap) return 0;
    if (lastTimeSnap.state !== 'playing') return lastTimeSnap.time;
    return lastTimeSnap.time + (performance.now() - lastTimeSnap.fetchedAt) / 1000;
  }

  // The synced-lyric tick: every frame while in Lyrics mode with synced
  // data, find the line whose time bracket contains the current playback
  // position, update highlight classes if it changed, smoothly scroll the
  // active line into view at roughly the upper third of the viewport.
  // Wakes once per frame ONLY while in lyrics mode. Earlier this self-
  // scheduled at the top regardless of mode, so the main thread woke every
  // frame for the page's whole lifetime in every other mode too. Now the
  // loop terminates by simply not rescheduling — setMode restarts it.
  let lyrTickActive = false;
  function lyricsTick() {
    if (currentMode !== 'lyrics') { lyrTickActive = false; return; }
    if (!lyrData || !lyrData.synced || !lyrLineEls.length) {
      requestAnimationFrame(lyricsTick);
      return;
    }

    const pos   = currentPlayPosition();
    const lines = lyrData.lines;

    // Find the index of the current line: the last line whose t <= pos.
    // Linear search is fine — lyrics typically have <200 lines.
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].t <= pos) idx = i; else break;
    }

    if (idx !== lyrActiveIndex) {

    // Update classes only for the lines whose state changed: the old
    // active and the new active. Bulk reassignment would cause CSS
    // transition jank.
    if (lyrActiveIndex >= 0 && lyrLineEls[lyrActiveIndex]) {
      lyrLineEls[lyrActiveIndex].className = 'lyr-line past';
    }
    if (idx >= 0 && lyrLineEls[idx]) {
      lyrLineEls[idx].className = 'lyr-line active';
      // Scroll the active line so it sits in the upper third of the body.
      const body = $('lyr-body');
      if (body) {
        const lineRect = lyrLineEls[idx].getBoundingClientRect();
        const bodyRect = body.getBoundingClientRect();
        const target = body.scrollTop
                     + (lineRect.top - bodyRect.top)
                     - bodyRect.height * 0.33;
        body.scrollTo({ top: target, behavior: 'smooth' });
      }
    }
    // Mark every future line above the active as past, and below as future.
    for (let i = 0; i < lyrLineEls.length; i++) {
      if (i === idx) continue;
      lyrLineEls[i].className = 'lyr-line ' + (i < idx ? 'past' : 'future');
    }

    lyrActiveIndex = idx;
    } // close if (idx !== lyrActiveIndex)

    // Reschedule only while still in lyrics mode. Outside it the loop ends
    // and the main thread gets that frame back. setMode → 'lyrics' restarts.
    requestAnimationFrame(lyricsTick);
  }
  function startLyricsTickIfNeeded() {
    if (currentMode === 'lyrics' && !lyrTickActive) {
      lyrTickActive = true;
      requestAnimationFrame(lyricsTick);
    }
  }

  // Tiny diagnostic surface so the console can inspect what the IIFE is
  // doing. Useful for ad-hoc bug hunts when something looks wrong.
  //
  // Of particular use:
  //   __npd.state()  — full picture of state-tracking variables
  //   __npd.snap()   — last status snapshot the page received
  //   __npd.lyrics() — current parsed lyrics payload
  //   __npd.bioReset() — force re-fetch on next poll (clears cache key)
  //   __npd.lyrReset() — force re-fetch on next poll (clears cache key)
  window.__npd = {
    pos:       () => currentPlayPosition(),
    snap:      () => lastSnap,
    timeSnap:  () => lastTimeSnap,
    lyrics:    () => lyrData,
    lyrActive: () => lyrActiveIndex,
    mode:      () => currentMode,
    player:    () => currentPlayer,
    viz:       () => ({
      active:      vizActive,
      style:       vizStyle,
      bass: (typeof vizRingBass !== 'undefined') ? vizRingBass : null,
      haveFrame:   !!vizServerFrame,
      haveWave:    !!vizServerWave,
    }),
    server:    () => ({
      cfgBridgeUrl:  VIZ_CFG && VIZ_CFG.bridgeUrl,
      resolvedUrl:   vizBridgeUrl(),
      ws:            vizWs ? { readyState: vizWs.readyState, url: vizWs.url } : null,
      haveFrame:     !!vizServerFrame,
      frameLen:      vizServerFrame ? vizServerFrame.length : 0,
      frameSampleDb: vizServerFrame ? Array.from(vizServerFrame.slice(0, 6)).map(v => +v.toFixed(1)) : null,
      sampleRate:    vizServerRate,
      binHz:         vizServerBinHz,
      vizActive:     vizActive,
      mode:          currentMode,
    }),
    state:     () => ({
      mode:                currentMode,
      player:              currentPlayer,
      track_url:           lastSnap && lastSnap.track_url,
      bio_last_fetched:    bioLastFetchedFor,
      bio_in_flight:       bioInFlight,
      bio_art_current:     bioArtCurrent,
      lyr_last_fetched:    lyrLastFetchedFor,
      lyr_in_flight:       lyrInFlight,
      lyr_synced:          lyrData && lyrData.synced,
      lyr_lines:           lyrData && lyrData.lines && lyrData.lines.length,
    }),
    bioReset:  () => { bioLastFetchedFor = ''; bioInFlight = false; bioArtCurrent = ''; },
    lyrReset:  () => { lyrLastFetchedFor = ''; lyrInFlight = false; lyrData = null; },
    lastError: () => lastPollError,
  };

  // ============================================================
  // Biography auto-scroll — position-comparison approach
  // ============================================================
  //
  // The loop tracks where IT WANTS the scroll to be (bioTargetTop). Every
  // frame:
  //
  //   1. If body.scrollTop differs from our target by more than a tiny
  //      tolerance, the user has touched it. Pause for 10s, sync target.
  //   2. Otherwise, advance the target by speed*dt and set scrollTop to it.
  //
  // No event listeners, no programmatic-vs-user distinction needed — we
  // detect interference by checking position directly.
  //
  // States, controlled by bioPhase:
  //   'hold-top'    — at top, holding for INITIAL_HOLD before drifting
  //   'drifting'    — actively scrolling down
  //   'hold-bottom' — at bottom, holding before snapping back
  //   'paused'      — user touched it, waiting INTERACT_HOLD before resuming

  let BIO_SCROLL_PX_PER_SEC      = __NPD_SCROLL_PX__;  // from pref; updated live via cfg
  const BIO_SCROLL_INITIAL_HOLD  = 3000;   // ms at top before drifting
  const BIO_SCROLL_BOTTOM_HOLD   = 5000;   // ms at bottom before looping
  const BIO_SCROLL_INTERACT_HOLD = 10000;  // ms after user interaction
  const BIO_SCROLL_TOLERANCE     = 3;      // px diff before we declare "user moved it"

  let bioPhase        = 'hold-top';
  let bioPhaseUntil   = 0;       // performance.now() ts at which the phase ends
  let bioTargetTop    = 0;       // where the loop wants scrollTop to be
  let bioLastTs       = 0;

  function bioScrollOnContentChange() {
    bioPhase      = 'hold-top';
    bioPhaseUntil = performance.now() + BIO_SCROLL_INITIAL_HOLD;
    bioTargetTop  = 0;
    const body = $('bio-body');
    if (body) body.scrollTop = 0;
  }

  // Wakes once per frame ONLY while in biography mode. Same fix as
  // lyricsTick: previously self-scheduled at the top in every mode.
  let bioFrameActive = false;
  function bioScrollFrame(now) {
    if (currentMode !== 'biography') { bioFrameActive = false; bioLastTs = now; return; }
    // Reschedule before doing the work so we never miss a frame to early
    // returns within the body.
    requestAnimationFrame(bioScrollFrame);

    const body = $('bio-body');
    if (!body || body.classList.contains('bio-empty')) { bioLastTs = now; return; }

    const max = body.scrollHeight - body.clientHeight;
    if (max <= 4) { bioLastTs = now; return; }   // bio fits — nothing to do

    // Did the user move the scroll? Compare actual vs our target.
    if (Math.abs(body.scrollTop - bioTargetTop) > BIO_SCROLL_TOLERANCE) {
      bioPhase      = 'paused';
      bioPhaseUntil = now + BIO_SCROLL_INTERACT_HOLD;
      bioTargetTop  = body.scrollTop;   // resume from wherever they left it
      bioLastTs     = now;
      return;
    }

    // Phase transitions driven purely by time.
    if (now >= bioPhaseUntil) {
      if (bioPhase === 'hold-top')         bioPhase = 'drifting';
      else if (bioPhase === 'hold-bottom') {
        bioPhase     = 'hold-top';
        bioPhaseUntil = now + BIO_SCROLL_INITIAL_HOLD;
        bioTargetTop = 0;
        body.scrollTop = 0;
        bioLastTs = now;
        return;
      }
      else if (bioPhase === 'paused')      bioPhase = 'drifting';
    }

    // Drift only while in 'drifting' phase.
    if (bioPhase === 'drifting') {
      const dt = bioLastTs ? Math.min(0.1, (now - bioLastTs) / 1000) : 0;
      bioTargetTop = Math.min(max, bioTargetTop + BIO_SCROLL_PX_PER_SEC * dt);
      body.scrollTop = bioTargetTop;

      if (bioTargetTop >= max - 0.5) {
        bioPhase      = 'hold-bottom';
        bioPhaseUntil = now + BIO_SCROLL_BOTTOM_HOLD;
      }
    }
    bioLastTs = now;
  }

  function startBioFrameIfNeeded() {
    if (currentMode === 'biography' && !bioFrameActive) {
      bioFrameActive = true;
      requestAnimationFrame(bioScrollFrame);
    }
  }

  // Direct taps/clicks on the bio area also pause — not just scrolling.
  // Position-comparison catches scroll changes; this catches the case
  // where the user just touches the text to read at their own pace.
  document.addEventListener('pointerdown', (e) => {
    if (currentMode !== 'biography') return;
    const body = $('bio-body');
    if (!body || !body.contains(e.target)) return;
    bioPhase      = 'paused';
    bioPhaseUntil = performance.now() + BIO_SCROLL_INTERACT_HOLD;
    bioTargetTop  = body.scrollTop;
  }, { passive: true });


  // Show or hide a "from <album>" line element. Keeps the per-mode apply
  // branches identical and avoids orphan "from" prefixes when album is empty.
  function setAlbumLine(lineId, valueId, value) {
    const line = $(lineId);
    if (!line) return;
    if (value) {
      line.hidden = false;
      $(valueId).textContent = value;
    } else {
      line.hidden = true;
    }
  }

  // Smooth progress between server polls (now-playing only).
  // tick fires every 100 ms — the rendered second only changes 10× less
  // often than that, and the fill bar's percentage change is also coarse, so
  // skip the DOM write when neither has changed. Cheap, but a layout/paint
  // each tick on a wall tablet adds up.
  let lastTickCur = '';
  let lastTickPctInt = -1;
  function tick() {
    if (currentMode !== 'now-playing') return;
    if (!lastSnap || lastSnap.state !== 'playing') return;
    const elapsed = (performance.now() - lastFetch) / 1000;
    const pos = Math.min((lastSnap.position || 0) + elapsed, lastSnap.duration || 0);
    const cur = fmt(pos);
    if (cur !== lastTickCur) {
      $('np-cur').textContent = cur;
      lastTickCur = cur;
    }
    const pct = lastSnap.duration ? (pos / lastSnap.duration) * 100 : 0;
    // Round to 0.1% — bar can't render finer than that on any realistic display.
    const pctInt = Math.round(pct * 10);
    if (pctInt !== lastTickPctInt) {
      $('np-fill').style.width = (pctInt / 10) + '%';
      lastTickPctInt = pctInt;
    }
  }

  // Ambient clock.
  function clockTick() {
    if (currentMode !== 'ambient') return;
    const now = new Date();
    const h = now.getHours();
    const m = now.getMinutes();
    $('amb-clock').textContent = h + ':' + (m < 10 ? '0' : '') + m;
    $('amb-date').textContent = now.toLocaleDateString(undefined,
      { weekday: 'long', day: 'numeric', month: 'long' });
  }

  // ----- Overlay reveal (artwork mode) -----
  // On track change, briefly show the title overlay, then fade it.
  let overlayTimer;
  let lastTitleKey = '';
  function revealOverlayIfChanged(snap) {
    const key = (snap && snap.title || '') + '|' + (snap && snap.artist || '');
    if (key === lastTitleKey) return;
    lastTitleKey = key;
    document.body.classList.add('show-overlay');
    clearTimeout(overlayTimer);
    overlayTimer = setTimeout(() => document.body.classList.remove('show-overlay'), 5000);
  }

  // ----- UI auto-hide + fullscreen on first tap -----
  // The Fullscreen API requires a user gesture. First tap anywhere on the
  // page triggers fullscreen (unless we're already in it, or the browser
  // refuses). Subsequent taps just reveal the UI chrome briefly.
  let hideTimer;
  function hideUi() {
    document.querySelectorAll('.ui').forEach(el => el.classList.add('hidden'));
  }
  function showUi() {
    document.querySelectorAll('.ui').forEach(el => el.classList.remove('hidden'));
    clearTimeout(hideTimer);
    hideTimer = setTimeout(hideUi, 5000);
  }

  async function tryFullscreen() {
    if (document.fullscreenElement) return;
    const el = document.documentElement;
    const req = el.requestFullscreen
            || el.webkitRequestFullscreen
            || el.mozRequestFullScreen
            || el.msRequestFullscreen;
    if (!req) return;
    try { await req.call(el); } catch (e) { /* user can dismiss; do not nag */ }
  }

  document.addEventListener('pointerdown', () => {
    showUi();
    tryFullscreen();
  });
  document.addEventListener('keydown', showUi);
  showUi();

  // ----- Wake lock (best-effort; only HTTPS or localhost in some browsers) -----
  let wakeLock = null;
  async function requestWake() {
    if (!('wakeLock' in navigator)) return;
    try { wakeLock = await navigator.wakeLock.request('screen'); } catch (e) {}
  }
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') requestWake();
  });
  requestWake();

  // ----- Poll lifecycle -----
  // We intentionally keep polling even when the tab/page is hidden. This is
  // a now-playing display, often the only thing on a wall-mounted tablet or
  // a backgrounded browser tab — it must keep tracking the music regardless
  // of visibility. Earlier versions paused on hidden and relied on a
  // visibilitychange 'visible' event to resume, but on tablets/PWAs that
  // event is unreliable: the page would stay alive but stop polling, so
  // lyrics and biographies silently froze until a manual browser refresh.
  // (The now-playing progress bar kept animating via the independent tick()
  // loop, which masked that polling had died.)
  function startPolling() {
    if (pollTimer) return;
    pollTimer = setInterval(poll, POLL_MS);
  }

  // When returning to visible, poll immediately for instant freshness and
  // make sure the timer is alive. We no longer stop polling when hidden.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      poll();
      startPolling();
      requestWake();
    }
  });

  // Watchdog: if for any reason the poll timer dies or a poll hasn't
  // succeeded in a while (browser throttling, suspended timer, lost
  // interval), force a fresh poll and restart the loop. Cheap insurance
  // against the "frozen until refresh" class of bug. We use an absolute
  // floor (8s) rather than a multiple of POLL_MS so it doesn't get jumpy
  // when POLL_MS is small — it should only fire on a genuine stall, not on
  // one slightly-late poll. Checked every 5s.
  const POLL_STALL_MS = 8000;
  setInterval(() => {
    const sinceLast = performance.now() - lastFetch;
    if (sinceLast > POLL_STALL_MS) {
      startPolling();   // no-op if already running
      poll();           // force an immediate refresh
    }
  }, 5000);


  // ===== Visualizer engine (server-driven) =========================
  // A server-side FFT helper reads the dedicated Visualizer SqueezeLite's
  // audio (-v shmem) and streams dB-per-bin frames (+ a decimated time-domain
  // wave) to the page over WebSocket. The page renders from those frames — it
  // never touches Web Audio, so it works on every browser including iOS/Safari
  // and smart-TV browsers. The sync offset is applied server-side by the helper
  // (it reads from a time-shifted position in its ring buffer), so what arrives
  // here is already "the audio from N ms ago".
  let vizWave = null;       // Float32Array of time-domain samples (oscilloscope)
  let vizStyle = 'segmented';  // segmented | scope | ring* | starburst | bokeh
  let vizStyleTouched = false; // true once user cycles style on-screen this session
  let vizArtImg = null;        // <img> of current album art for the radial centre
  let vizArtUrl = '';          // last loaded art URL (avoids reloading each poll)
  let vizRAF = 0;           // requestAnimationFrame handle
  let vizActive = false;

  // --------------------------------------------------------------------------
  // Server bridge connection
  // --------------------------------------------------------------------------
  function vizBridgeUrl() {
    // Prefer an explicitly configured bridgeUrl. Otherwise derive one from the
    // host the page was loaded from, on the helper's default port (8770, which
    // matches _helperPort()'s fallback when the pref is blank). Deriving means
    // "server mode on" works even with the Bridge URL field left empty — the
    // field is an optional override, not a requirement. The derived host always
    // resolves because we reached this very page through it.
    const cfg = (VIZ_CFG && VIZ_CFG.bridgeUrl) || '';
    if (cfg) return cfg;
    return 'ws://' + location.hostname + ':8770/';
  }

  // Latest FFT bin frame (dB values) from the server. Sample rate and bin
  // width are carried in each frame so the page can do correct frequency
  // mapping (handles sample-rate changes between tracks). The sync offset is
  // applied server-side (the helper reads from a time-shifted ring position),
  // so each frame is already "the audio from N ms ago" — we just store the
  // latest and render it. No client-side buffering / picking required.
  let vizServerFrame = null;       // Float32Array — dB-per-bin
  let vizServerWave  = null;       // Float32Array — time-domain samples (post-buffer-pick)
  let vizServerRate  = 44100;
  let vizServerBinHz = 0;
  // Server-mode FFT frames are now offset-adjusted by the helper itself
  // (it reads from a time-shifted position in its Python ring buffer based
  // on the current offset file value). What arrives here over the WebSocket
  // is already "the audio from N ms ago", so we just store the latest one
  // and render. No client-side buffering / picking required.
  let vizWs = null;
  let vizWsRetryT = null;
  // --- System-delay self-test instrumentation ---------------------------
  // Set when a data frame arrives; cleared when the next vizDraw paints it, so
  // we can measure receive->draw latency. The self-test (vizRunSelfTest) sends
  // {"ping":t} messages and the helper replies {"pong":t,"proc_ms":x}; we time
  // the round trip (transport) and read proc_ms (helper FFT time) from it.
  let vizFrameRecvT  = 0;       // performance.now() of the last unpainted frame
  let vizFramePend   = false;   // a frame is waiting to be drawn
  let vizSelftest    = null;    // active test accumulator, or null
  function vizServerConnect() {
    const url = vizBridgeUrl();
    if (!url) { vizHint('Server-side mode is on but no bridge URL configured'); return; }
    try {
      vizWs = new WebSocket(url);
    } catch (e) {
      vizHint('Could not open visualizer bridge: ' + e.message);
      return;
    }
    vizWs.onopen = () => { vizHint(''); };
    vizWs.onmessage = (ev) => {
      // Control messages (self-test pong) are JSON and start with '{'. Normal
      // data frames start with the sample rate (a digit), so this is an
      // unambiguous, cheap discriminator that doesn't disturb the data path.
      if (ev.data.charCodeAt(0) === 123 /* '{' */) {
        try { vizHandleControl(JSON.parse(ev.data)); } catch (e) {}
        return;
      }
      // Stamp arrival for the receive->draw latency measurement.
      vizFrameRecvT = performance.now();
      vizFramePend  = true;
      // vizfft frame format: "<sr>;<binhz>;<db0>;<db1>;...;<dbN>|<w0>;<w1>;...;<wM>"
      //  - sr     : sample rate (int)
      //  - binhz  : Hz width of each downsampled FFT bin (float)
      //  - db..   : dB-per-bin values, like getFloatFrequencyData() would give.
      //  - |w..   : time-domain samples, in [-1, 1] like getFloatTimeDomainData
      //             would give. Optional — older helpers don't include this and
      //             Scope/Ring fall back to no data in server mode.
      // Browser then runs the SAME band-binning/dB/tilt/ballistics as the
      // Web Audio path, so the look matches.
      const splitAt = ev.data.indexOf('|');
      const freqText = splitAt >= 0 ? ev.data.slice(0, splitAt) : ev.data;
      const waveText = splitAt >= 0 ? ev.data.slice(splitAt + 1) : '';

      const parts = freqText.split(';');
      if (parts.length < 4) return;
      const sr = parseInt(parts[0], 10);
      const binhz = parseFloat(parts[1]);
      if (!sr || !binhz) return;
      const n = parts.length - 2;
      if (!vizServerFrame || vizServerFrame.length !== n) {
        vizServerFrame = new Float32Array(n);
      }
      for (let i = 0; i < n; i++) {
        const v = parseFloat(parts[i + 2]);
        vizServerFrame[i] = isNaN(v) ? -120 : v;
      }
      vizServerRate = sr;
      vizServerBinHz = binhz;
      if (waveText) {
        const wparts = waveText.split(';');
        const m = wparts.length;
        if (!vizServerWave || vizServerWave.length !== m) {
          vizServerWave = new Float32Array(m);
        }
        for (let i = 0; i < m; i++) {
          const v = parseFloat(wparts[i]);
          vizServerWave[i] = isNaN(v) ? 0 : v;
        }
      } else {
        vizServerWave = null;
      }
    };
    vizWs.onclose = () => {
      // Auto-retry with backoff so a server restart heals.
      vizWs = null;
      if (vizWsRetryT) return;
      vizWsRetryT = setTimeout(() => { vizWsRetryT = null; vizServerConnect(); }, 2000);
    };
    vizWs.onerror = () => { /* close will follow; retry there */ };
  }

  function vizServerDisconnect() {
    if (vizWs) { try { vizWs.close(); } catch (e) {} vizWs = null; }
    if (vizWsRetryT) { clearTimeout(vizWsRetryT); vizWsRetryT = null; }
  }

  // --- System-delay self-test -------------------------------------------
  // Handle a JSON control reply from the helper. Currently only the pong to
  // our ping: it carries proc_ms (helper FFT processing) and lets us time the
  // round trip (transport). Both feed the active self-test accumulator.
  function vizHandleControl(msg) {
    if (!msg || typeof msg !== 'object') return;
    if ('pong' in msg && vizSelftest) {
      const rtt = performance.now() - msg.pong;
      vizSelftest.rtt.push(rtt);
      if (typeof msg.proc_ms === 'number') vizSelftest.proc.push(msg.proc_ms);
    }
  }

  function vizMedian(arr) {
    if (!arr.length) return 0;
    const a = arr.slice().sort((x, y) => x - y);
    const m = a.length >> 1;
    return a.length % 2 ? a[m] : (a[m - 1] + a[m]) / 2;
  }

  // Run a ~3s measurement: ping the helper repeatedly (transport + proc_ms) and
  // sample receive->draw latency (collected in vizDraw). Report the budget.
  function vizRunSelfTest() {
    if (!vizWs || vizWs.readyState !== 1) {
      vizHint('Visualizer not connected — can’t measure yet'); return;
    }
    if (vizSelftest) return;  // already running
    vizSelftest = { rtt: [], proc: [], draw: [] };
    const panel = document.getElementById('viz-selftest');
    if (panel) panel.hidden = false;
    setText('viz-st-proc', '…'); setText('viz-st-net', '…');
    setText('viz-st-draw', '…'); setText('viz-st-total', '…');
    setText('viz-st-offset', (vizCurrentOffsetMs() | 0) + ' ms');
    let n = 0;
    const ping = () => {
      if (!vizSelftest) return;
      if (vizWs && vizWs.readyState === 1) {
        try { vizWs.send(JSON.stringify({ ping: performance.now() })); } catch (e) {}
      }
      if (++n < 30) { setTimeout(ping, 100); }   // 30 pings over ~3s
      else { setTimeout(vizFinishSelfTest, 250); }
    };
    ping();
  }

  function vizFinishSelfTest() {
    const t = vizSelftest; vizSelftest = null;
    if (!t) return;
    const proc = vizMedian(t.proc);
    const net  = vizMedian(t.rtt) / 2;     // one-way ≈ RTT/2
    const draw = vizMedian(t.draw);
    const offs = vizCurrentOffsetMs() | 0;
    const total = proc + net + draw + offs;
    const fmt = (v) => (Math.round(v * 10) / 10) + ' ms';
    setText('viz-st-proc',   fmt(proc));
    setText('viz-st-net',    fmt(net));
    setText('viz-st-draw',   fmt(draw));
    setText('viz-st-offset', offs + ' ms');
    setText('viz-st-total',  fmt(total));
  }

  function setText(id, txt) {
    const el = document.getElementById(id);
    if (el) el.textContent = txt;
  }

  // --- Start lead (vizLeadMs): how far AHEAD of the room the Visualizer is
  // seeked at each track load, so the delay buffer can always pull it to sync.
  // Global (a property of the Visualizer's start latency, not any one room).
  // Initialized to 0 here (VIZ_CFG is declared later in the script — referencing
  // it at eval time would hit the temporal dead zone). vizWireTuner() seeds it
  // from VIZ_CFG.leadMs at start, after VIZ_CFG exists.
  let vizLeadMs = 0;
  let vizLeadSaveT = 0;
  function vizUpdateLeadLabel() { setText('viz-lead-ms', vizLeadMs | 0); }
  function vizNudgeLead(delta) {
    vizLeadMs = Math.max(0, Math.min(4000, (vizLeadMs | 0) + delta));
    vizUpdateLeadLabel();
    // Debounce the persist so rapid taps issue one request. Takes effect on the
    // next track load (the mirror seek reads vizLeadMs fresh each time).
    if (vizLeadSaveT) clearTimeout(vizLeadSaveT);
    vizLeadSaveT = setTimeout(() => {
      vizLeadSaveT = 0;
      fetch(`${BASE}/plugins/NowPlayingDisplay/setlead?ms=${vizLeadMs | 0}`)
        .then(r => r.json())
        .then((res) => { if (VIZ_CFG && res && typeof res.ms === 'number') VIZ_CFG.leadMs = res.ms; })
        .catch(() => {});
    }, 400);
  }

  function vizStart() {
    if (!VIZ_ENABLED) return;
    // Server-driven: open the WebSocket to the helper and render its frames.
    // Works on every browser (iOS / Safari / TV included) - no Web Audio.
    vizActive = true;
    const hint = document.getElementById('viz-hint');
    if (hint) { hint.textContent = 'Connecting to server visualizer...'; hint.style.opacity = '1'; }
    if (VIZ_CFG && VIZ_CFG.smoothing) vizApplySmoothing(VIZ_CFG.smoothing);
    vizServerConnect();
    vizSizeCanvas();
    vizWireTuner();
    if (VIZ_CFG && VIZ_CFG.style && VIZ_STYLES.indexOf(VIZ_CFG.style) >= 0 && !vizStyleTouched) {
      vizStyle = VIZ_CFG.style;
    }
    vizUpdateStyleLabel();
    vizShowTuner();
    if (!vizRAF) vizRAF = requestAnimationFrame(vizDraw);
  }

  function vizStop() {
    vizActive = false;
    if (vizRAF) { cancelAnimationFrame(vizRAF); vizRAF = 0; }
    const t = document.getElementById('viz-tuner');
    if (t) t.hidden = true;
    clearTimeout(vizTunerHideTimer);
    vizServerDisconnect();
  }


  // Visualizer offset resolution. Config injected from settings holds a
  // per-player offset map plus a global default. We resolve the offset for
  // whichever player this display is showing, so each room / display device
  // keeps its own dialled-in delay.
  let VIZ_CFG = __NPD_VIZ_CFG__;
  // Live tuning override (ms). When the user nudges the on-screen tuner this
  // holds the working value and takes precedence over the resolved config, so
  // changes are seen instantly. null = not tuning, use the resolved config.
  let vizTuneMs = null;

  function vizLeadSeconds() {
    if (vizTuneMs !== null) return vizTuneMs / 1000;
    let ms = (VIZ_CFG && VIZ_CFG.default != null) ? Number(VIZ_CFG.default) : 0;
    try {
      const pid = (lastSnap && lastSnap.player && lastSnap.player.id) || currentPlayer || '';
      const po = VIZ_CFG && VIZ_CFG.playerOffsets;
      if (po && pid && po[pid] != null && !isNaN(Number(po[pid]))) {
        ms = Number(po[pid]);
      }
    } catch (e) {}
    if (isNaN(ms)) ms = 0;
    return ms / 1000;
  }

  let vizHintIsStart = false;
  function vizHint(msg) {
    const hint = document.getElementById('viz-hint');
    if (!hint) return;
    vizHintIsStart = (msg === 'Tap to start the visualizer');
    if (msg) { hint.textContent = msg; hint.style.opacity = '1'; }
    else { hint.style.opacity = '0'; }
  }

  let vizCanvas = null, vizG = null, vizDPR = 1;
  function vizSizeCanvas() {
    vizCanvas = document.getElementById('viz-canvas');
    if (!vizCanvas) return;
    vizG = vizCanvas.getContext('2d');
    vizDPR = window.devicePixelRatio || 1;
    vizCanvas.width  = Math.floor(window.innerWidth  * vizDPR);
    vizCanvas.height = Math.floor(window.innerHeight * vizDPR);
  }
  window.addEventListener('resize', () => { if (vizActive) vizSizeCanvas(); });

  // ----- On-screen offset tuner -----
  let vizTunerHideTimer = 0;
  let vizTunerWired = false;

  function vizCurrentOffsetMs() {
    // Start tuning from whatever offset is currently resolved for this player.
    return Math.round(vizLeadSeconds() * 1000);
  }

  function vizShowTuner() {
    const t = document.getElementById('viz-tuner');
    if (!t) return;
    if (vizTuneMs === null) vizTuneMs = vizCurrentOffsetMs();
    vizUpdateTunerLabel();
    t.hidden = false;
    t.classList.remove('fade');
    clearTimeout(vizTunerHideTimer);
    vizTunerHideTimer = setTimeout(() => { t.classList.add('fade'); }, 6000);
  }

  function vizUpdateTunerLabel() {
    const lbl = document.getElementById('viz-tms');
    if (!lbl) return;
    // When not actively tuning (vizTuneMs null), show the offset resolved for
    // the CURRENT player, not a stale number. When tuning, show the working value.
    const v = (vizTuneMs === null) ? vizCurrentOffsetMs() : vizTuneMs;
    lbl.textContent = (v > 0 ? '+' : '') + v;
  }

  function vizNudge(delta) {
    if (vizTuneMs === null) vizTuneMs = vizCurrentOffsetMs();
    // Delay-only: 0 = passthrough (live edge), up to +2000ms of visual delay.
    vizTuneMs = Math.max(0, Math.min(2000, vizTuneMs + delta));
    vizUpdateTunerLabel();
    vizShowTuner();
    // Push the new offset to the helper via the plugin's transient-offset
    // endpoint. The helper polls its offset file every 100ms; next frame uses
    // the new value. Doesn't persist — only Save does that (via vizSaveOffset,
    // which hits /setoffset).
    fetch(`${BASE}/plugins/NowPlayingDisplay/setlivenoffset?ms=${vizTuneMs}`,
          { method: 'GET', cache: 'no-store' }).catch(() => {});
  }

  let VIZ_STYLES = ['segmented', 'scope', 'ring', 'ringVivid', 'ringZoom', 'ringClassic', 'starburst', 'bokeh'];
  // All styles work in both web-audio and server modes now: server mode sends
  // time-domain samples alongside the FFT bins, so Scope and the Ring variants
  // have what they need. (Earlier versions stripped these from server mode
  // because the helper only sent bands.)
  const VIZ_STYLE_NAMES = {
    segmented: 'Bars', scope: 'Scope',
    ring: 'Waveform Ring', ringVivid: 'Waveform Ring · Vivid',
    ringZoom: 'Waveform Ring · Zoom', ringClassic: 'Waveform Ring · Classic',
    starburst: 'Starburst', bokeh: 'Orbs'
  };
  function vizUpdateStyleLabel() {
    const b = document.getElementById('viz-tstyle');
    if (b) b.textContent = VIZ_STYLE_NAMES[vizStyle] || 'Style';
  }
  function vizCycleStyle() {
    vizStyleTouched = true;
    const idx = VIZ_STYLES.indexOf(vizStyle);
    vizStyle = VIZ_STYLES[(idx + 1) % VIZ_STYLES.length];
    vizUpdateStyleLabel();
    vizShowTuner();
    // Persist the chosen style as the new default.
    fetch(`${BASE}/plugins/NowPlayingDisplay/setstyle?style=${vizStyle}`).catch(()=>{});
  }

  function vizSaveOffset() {
    if (vizTuneMs === null) return;
    // Save for the room currently being displayed/followed, so the offset is
    // remembered per-player (not as the global default). Same player resolution
    // the calibration + lead-time code use.
    const pid = (lastSnap && lastSnap.player && lastSnap.player.id) || currentPlayer || '';
    const u = `${BASE}/plugins/NowPlayingDisplay/setoffset?ms=${vizTuneMs}`
            + (pid && pid !== 'auto' ? `&player=${encodeURIComponent(pid)}` : '');
    fetch(u)
      .then(r => r.json())
      .then((res) => {
        const s = document.getElementById('viz-tsaved');
        if (s) { s.hidden = false; setTimeout(() => { s.hidden = true; }, 1500); }
        // Reflect the save immediately so the tuner baseline is right before
        // the next state.json poll refreshes VIZ_CFG. Per-player saves update
        // the offset map; the no-player fallback updates the global default.
        if (VIZ_CFG && res && res.scope === 'player' && res.playerId) {
          VIZ_CFG.playerOffsets = VIZ_CFG.playerOffsets || {};
          VIZ_CFG.playerOffsets[res.playerId] = vizTuneMs;
        } else if (VIZ_CFG) {
          VIZ_CFG.default = vizTuneMs;
        }
      })
      .catch(() => {});
  }

  // ===== Calibration tones ===================================================
  // Plays a looping calibration tone (1 kHz or 200 Hz click train) through
  // the currently-displayed room so the user can use the existing ±10/±50
  // tuner buttons to align the visualizer bars to the audible clicks, then
  // tap Save as normal. The tone plays via LMS's standard playlist
  // mechanism — no UI lockout, no separate measurement loop, no modal:
  // the visualizer keeps rendering normally throughout.
  //
  // The /calibrate endpoint sends the player a "playlist play file://..."
  // with repeat-track on, so the 16-second WAV loops until we send a stop.
  // A long safety-stop timer (10 min) catches the case where the browser
  // tab is closed without explicitly stopping.

  let calActiveTone = null;     // '1khz' | '200hz' | null
  let calActivePlayerId = null; // player MAC the tone is playing on
  let calSafetyTimer = 0;

  // --- Calibration animation state (the bouncing-ball A/V sync view).
  // It detects each ~1Hz beep in the incoming (offset-DELAYED) captured audio —
  // i.e. exactly the audio the visualizer renders during normal music — and:
  //   • flashes on the REAL detected beep (immediate: nudge the offset and the
  //     flash moves at once, relative to the beep you hear from the room), and
  //   • bounces the ball on a CONTINUOUS beat phase that's gently pulled toward
  //     the beeps (a PLL). The ball descends on this phase (smooth anticipation)
  //     and strikes the floor at the beep. Unlike the old design — which hard-
  //     reset the bounce to every detection, so it teleported and the offset's
  //     effect was masked — the phase only ever moves continuously.
  // You tune the offset until the ball strikes / screen flashes exactly when you
  // HEAR the beep. (No room-clock tracking — your ears are the reference, same
  // as judging whether the bars hit the beat while music plays.)
  let calLastOnset  = 0;        // performance.now() of last detected beep (refractory + period)
  let calPeriod     = 1000;     // ms between beeps (gentle EMA; tone is ~1Hz)
  let calArmed      = true;     // hysteresis: ready to detect next rising edge
  let calFlashUntil = 0;        // impact flash decays until this time
  let calOnsetCount = 0;        // beeps seen since calibration started
  let calPhase      = 0;        // continuous beat phase; integer = floor strike
  let calPhaseT     = 0;        // performance.now() of last phase advance
  function vizCalReset() {
    calLastOnset = 0; calPeriod = 1000; calArmed = true;
    calFlashUntil = 0; calOnsetCount = 0; calPhase = 0; calPhaseT = 0;
  }

  function vizCalPlayerId() {
    // Resolve the player to calibrate against. Prefer the actively-playing
    // room from the most recent state snapshot (so "Auto" mode works);
    // fall back to the explicitly-selected player.
    let pid = (lastSnap && lastSnap.player && lastSnap.player.id) || null;
    if (!pid && currentPlayer && currentPlayer !== 'auto') pid = currentPlayer;
    return pid;
  }

  function vizCalToggle(tone) {
    // If this tone is already playing on a player, treat the tap as STOP.
    if (calActiveTone === tone && calActivePlayerId) {
      vizCalStop();
      return;
    }
    // If a DIFFERENT tone is playing, stop it first.
    if (calActiveTone && calActivePlayerId) {
      vizCalStop(true);   // silent: don't update tuner, we're about to restart
    }
    const pid = vizCalPlayerId();
    if (!pid) {
      // Brief flash on the tuner — no popup, no UI lockout.
      vizShowTuner();
      const sav = document.getElementById('viz-tsaved');
      if (sav) { sav.textContent = 'No active player'; sav.hidden = false; setTimeout(() => { sav.hidden = true; sav.textContent = 'Saved'; }, 1800); }
      return;
    }
    const url = BASE + '/plugins/NowPlayingDisplay/calibrate?action=start&tone='
              + encodeURIComponent(tone) + '&player=' + encodeURIComponent(pid);
    fetch(url, { method: 'GET', cache: 'no-store' })
      .then(r => r.json())
      .then(j => {
        if (!j.ok) {
          const sav = document.getElementById('viz-tsaved');
          if (sav) { sav.textContent = 'Cal failed: ' + (j.error || 'error'); sav.hidden = false; setTimeout(() => { sav.hidden = true; sav.textContent = 'Saved'; }, 2500); }
          return;
        }
        calActiveTone = tone;
        calActivePlayerId = pid;
        vizCalReset();           // clear any stale beat phase from a prior run
        vizCalUpdateButtons();
        // Safety stop: 10 minutes is plenty for any tuning session and
        // catches the "user walked away with tone still playing" case.
        clearTimeout(calSafetyTimer);
        calSafetyTimer = setTimeout(() => { vizCalStop(); }, 600000);
        vizShowTuner();
      })
      .catch(() => {});
  }

  function vizCalStop(silent) {
    clearTimeout(calSafetyTimer);
    calSafetyTimer = 0;
    const pid = calActivePlayerId;
    calActiveTone = null;
    calActivePlayerId = null;
    vizCalUpdateButtons();
    if (!pid) return;
    fetch(BASE + '/plugins/NowPlayingDisplay/calibrate?action=stop&player=' + encodeURIComponent(pid),
          { method: 'GET', cache: 'no-store' }).catch(() => {});
  }

  function vizCalUpdateButtons() {
    const b1 = document.getElementById('viz-tcal1k');
    const b2 = document.getElementById('viz-tcal200');
    if (b1) {
      b1.classList.toggle('active', calActiveTone === '1khz');
      b1.textContent = (calActiveTone === '1khz') ? '■ 1k' : '♪ 1k';
    }
    if (b2) {
      b2.classList.toggle('active', calActiveTone === '200hz');
      b2.textContent = (calActiveTone === '200hz') ? '■ 200' : '♪ 200';
    }
  }

  // Make sure a playing tone is stopped if the user navigates away.
  window.addEventListener('beforeunload', () => {
    if (calActiveTone) vizCalStop();
  });

    // Mirror the currently-displayed room's playback onto the dedicated
  // Visualizer player so the server-side FFT analyses what we're listening
  // to. The plugin's vizmirror endpoint has safety guards — it will only
  // ever command the player at the configured Visualizer-player MAC.
  function vizWireTuner() {
    if (vizTunerWired) return;
    vizTunerWired = true;
    const bind = (id, fn) => { const b = document.getElementById(id); if (b) b.addEventListener('click', fn); };
    bind('viz-minus10', () => vizNudge(-10));
    bind('viz-minus50', () => vizNudge(-50));
    bind('viz-plus10',  () => vizNudge(10));
    bind('viz-plus50',  () => vizNudge(50));
    bind('viz-tsave',   vizSaveOffset);
    bind('viz-tstyle',  vizCycleStyle);
    bind('viz-tcal1k',  () => vizCalToggle('1khz'));
    bind('viz-tcal200', () => vizCalToggle('200hz'));
    bind('viz-ttest',   vizRunSelfTest);
    bind('viz-st-close', () => {
      const p = document.getElementById('viz-selftest'); if (p) p.hidden = true;
    });
    bind('viz-lead-minus', () => vizNudgeLead(-50));
    bind('viz-lead-plus',  () => vizNudgeLead(50));
    if (VIZ_CFG && typeof VIZ_CFG.leadMs === 'number') vizLeadMs = VIZ_CFG.leadMs | 0;
    vizUpdateLeadLabel();
    // Tap anywhere in the visualizer reveals the tuner.
    const sec = document.querySelector('.mode.visualizer');
    if (sec) sec.addEventListener('pointerdown', (e) => {
      if (e.target.closest('.viz-tuner')) return;  // don't re-trigger on the panel
      if (vizActive) vizShowTuner();
    });
    // Keyboard: left/right = ±10ms, shift+arrow = ±50ms, S = save.
    window.addEventListener('keydown', (e) => {
      if (currentMode !== 'visualizer' || !vizActive) return;
      if (e.key === 'ArrowLeft')  { vizNudge(e.shiftKey ? -50 : -10); e.preventDefault(); }
      else if (e.key === 'ArrowRight') { vizNudge(e.shiftKey ? 50 : 10); e.preventDefault(); }
      else if (e.key === 's' || e.key === 'S') { vizSaveOffset(); }
      else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') { vizCycleStyle(); e.preventDefault(); }
    });
  }

  // Bar height is mapped against a defined dBFS range, like a real analyzer.
  // VIZ_DB_FLOOR = the dBFS that reads as zero height (silence/noise floor),
  // VIZ_DB_CEIL  = the dBFS that reads as full height (0 = full scale).
  // Per-band level is the energy sum of the band's bins converted back to dBFS.
  const VIZ_DB_FLOOR = -73;   // lowered from -68: recover quiet/low-volume peaks
                              // that the spectral tilt left under-reading, without
                              // touching the bass/treble balance or the ceiling.
  const VIZ_DB_CEIL  = -10;   // takes near-full-scale to fill a bar (unchanged)
  // Per-octave tilt to counter music's bass-heavy roll-off, pivoting around
  // VIZ_TILT_PIVOT_HZ: bands below it are cut, bands above are boosted, by this
  // many dB per octave from the pivot. 0 = raw/untilted.
  const VIZ_TILT_DB_PER_OCT = 4.0;   // was 3.0; steepened to pull the low-mids
                                     // (~240Hz & below) down and lift the highs
  const VIZ_TILT_PIVOT_HZ   = 1000;   // ~geometric centre of 50Hz–20kHz

  // Uniform ballistics applied per DISPLAY bar (not per FFT bin), so every bar
  // — bass or treble — rises and falls with the same feel, like a real
  // analyzer. Fast attack catches transients; slower decay is readable.
  let vizLevels = null;            // smoothed 0..1 level per bar
  let vizPeaks  = null;            // peak-hold 0..1 per bar
  // Attack/decay are set from the 'smoothing' setting (applied live). Higher
  // = snappier; lower = calmer/more decay. Defaults to 'medium'.
  let VIZ_ATTACK = 0.55;
  let VIZ_DECAY  = 0.15;
  const VIZ_PEAK_DECAY = 0.003;    // per-60fps-frame cap drift; time-scaled so real fall speed is constant
  const VIZ_BARS  = 20;            // columns — matches Eversolo (50Hz–20kHz)
  const VIZ_CELLS = 26;            // segments per column (LED matrix rows)
  // Spectrum colour sweep endpoints (HSL hue degrees): bass -> treble. Default
  // warm red/orange bass sweeping to cool cyan/blue highs (roughly opposite on
  // the colour wheel). Tune these to recolour the whole spectrum.
  const VIZ_HUE_LOW  = 12;         // bass end (red/orange)
  const VIZ_HUE_HIGH = 200;        // treble end (cyan/blue)
  // Exact Eversolo DMP-A8 band labels (log-spaced 50Hz–20kHz, ratio ~1.37).
  const VIZ_LABELS = ['50','69','94','129','176','241','331','453','620','850',
                      '1.2k','1.6k','2.2k','3.0k','4.1k','5.6k','7.7k','11k','14k','20k'];

  // Map the smoothing setting to attack/decay. Lower decay = more "hang" / less
  // lively. attack stays fairly quick so transients still register.
  function vizApplySmoothing(name) {
    switch (name) {
      case 'lively':     VIZ_ATTACK = 0.70; VIZ_DECAY = 0.22; break;
      case 'smooth':     VIZ_ATTACK = 0.45; VIZ_DECAY = 0.09; break;
      case 'verysmooth': VIZ_ATTACK = 0.35; VIZ_DECAY = 0.05; break;
      // 'medium' tuned to match the Eversolo: snappy attack, fairly quick decay
      // so bars collapse promptly when signal drops (the slow element is the
      // peak cap, not the bar).
      case 'medium':
      default:           VIZ_ATTACK = 0.55; VIZ_DECAY = 0.15; break;
    }
  }

  // Detect a beep onset in the current captured frame and render the
  // calibration view. Returns nothing; called from vizDraw while a tone runs.
  // Onset = the visualizer SEEING the beep (in the offset-delayed stream), so
  // the impact is genuinely tied to the offset.
  function vizDrawCalibration(W, H) {
    const now = performance.now();

    // --- Beep-onset detection from the captured audio ---
    // Prefer the time-domain wave (clean: ~0 between beeps, strong during).
    // Fall back to peak band energy if no wave is present.
    let level = 0;
    if (vizServerWave && vizServerWave.length) {
      let s = 0;
      for (let i = 0; i < vizServerWave.length; i++) s += vizServerWave[i] * vizServerWave[i];
      level = Math.sqrt(s / vizServerWave.length);          // RMS, ~0..0.4
    } else if (vizServerFrame && vizServerFrame.length) {
      let mx = -200;
      for (let i = 0; i < vizServerFrame.length; i++) if (vizServerFrame[i] > mx) mx = vizServerFrame[i];
      level = Math.max(0, (mx + 80) / 80);                  // crude dB->0..1
    }
    // --- Advance the continuous beat phase (free-runs at 1 / period) ---
    if (calPhaseT === 0) calPhaseT = now;
    let pdt = now - calPhaseT; calPhaseT = now;
    if (pdt < 0) pdt = 0; else if (pdt > 250) pdt = 250;   // clamp tab-switch gaps
    calPhase += pdt / calPeriod;

    // --- Onset detection (+ PLL phase correction) ---
    const ON = 0.06, OFF = 0.03;                            // hysteresis thresholds
    const REFRACTORY = 450;                                 // ms; beeps are ~1000ms apart
    if (calArmed && level > ON && (now - calLastOnset) > REFRACTORY) {
      if (calLastOnset > 0) {
        const dt = now - calLastOnset;
        if (dt > 600 && dt < 1600) calPeriod += (dt - calPeriod) * 0.15;  // gentle ~1Hz lock
      }
      calLastOnset = now;
      calFlashUntil = now + 150;     // crisp flash on the REAL beep (immediate)
      calOnsetCount++;
      calArmed = false;
      // Pull the phase toward the strike (nearest integer). Signed distance,
      // corrected 50% per beep — fast enough that an offset nudge visibly moves
      // the strike within a beat or two, smooth enough that it never teleports.
      const frac = calPhase - Math.floor(calPhase);
      const err  = (frac > 0.5) ? (frac - 1) : frac;
      calPhase -= err * 0.5;
    } else if (!calArmed && level < OFF) {
      calArmed = true;               // re-arm once the beep has died away
    }

    // --- Geometry ---
    const cx = W * 0.5;
    const floorY = H * 0.72;
    const ballR = Math.max(10, H * 0.045);
    const COL_BALL = '#4fb0d0';      // theme cyan
    const haveLock = calOnsetCount > 0;

    // Ball bounces on the CONTINUOUS phase: floor at integer phase (the strike),
    // apex at the half. Because the phase only ever moves continuously (the PLL
    // nudge above is small), the ball never teleports — it just bounces, and the
    // strike instant slides smoothly as you change the offset.
    const apexY = H * 0.10;
    const restY = floorY - ballR;
    let ballY = restY;
    if (haveLock) {
      const ph = calPhase - Math.floor(calPhase);  // 0..1
      const u = 1 - Math.abs(2 * ph - 1);          // 0 at floor, 1 at apex, 0 at floor
      const eased = Math.sin((u * Math.PI) / 2);   // slow at apex, fast near floor
      ballY = restY + (apexY - restY) * eased;
    }

    const flashing = now < calFlashUntil;
    const flashK = flashing ? Math.max(0, (calFlashUntil - now) / 150) : 0;

    // --- Draw ---
    // Floor line
    vizG.strokeStyle = 'rgba(255,255,255,0.35)';
    vizG.lineWidth = Math.max(2, H * 0.004);
    vizG.beginPath(); vizG.moveTo(0, floorY); vizG.lineTo(W, floorY); vizG.stroke();

    // Strike marker: a faint fixed pad on the floor where the ball lands, so the
    // eye has one fixed spot to watch the strike against the beep you hear.
    vizG.fillStyle = 'rgba(255,255,255,0.10)';
    const padW = ballR * 2.8, padH = Math.max(4, H * 0.006);
    vizG.fillRect(cx - padW / 2, floorY - padH, padW, padH);

    // Big flash circle, lower-left, fires on the REAL detected beep
    const fr = H * 0.14;
    vizG.beginPath();
    vizG.arc(W * 0.13, floorY, fr, 0, Math.PI * 2);
    vizG.fillStyle = flashing ? `rgba(255,255,255,${0.85 * flashK})` : 'rgba(255,255,255,0.06)';
    vizG.fill();

    // Ball
    vizG.beginPath();
    vizG.arc(cx, ballY, ballR, 0, Math.PI * 2);
    vizG.fillStyle = COL_BALL;
    vizG.fill();

    // Full-screen impact wash (brief)
    if (flashing) {
      vizG.fillStyle = `rgba(255,255,255,${0.18 * flashK})`;
      vizG.fillRect(0, 0, W, H);
    }

    // Status text
    vizG.fillStyle = 'rgba(255,255,255,0.6)';
    vizG.font = `${Math.max(12, H * 0.022)}px system-ui, sans-serif`;
    vizG.textAlign = 'center';
    const msg = haveLock
      ? 'Tune the offset until the ball strikes exactly when you hear the beep'
      : 'Waiting for calibration tone\u2026';
    vizG.fillText(msg, cx, H * 0.94);
    vizG.textAlign = 'start';
  }

  function vizDraw() {
    if (!vizActive) { vizRAF = 0; return; }
    vizRAF = requestAnimationFrame(vizDraw);
    if (!vizG) return;

    // System-delay self-test: this paint is the first since a frame arrived, so
    // (now - arrival) is the receive->draw latency for that frame. Sampled only
    // while a test is running; negligible cost otherwise.
    if (vizFramePend) {
      vizFramePend = false;
      if (vizSelftest) vizSelftest.draw.push(performance.now() - vizFrameRecvT);
    }

    // Server-driven: nothing to drive locally — we render whatever frame the
    // helper last streamed over the WebSocket (vizServerFrame / vizServerWave).

    const W = vizCanvas.width, H = vizCanvas.height;
    vizG.clearRect(0, 0, W, H);
    vizG.fillStyle = '#000';
    vizG.fillRect(0, 0, W, H);

    // While a calibration tone is running, take over the whole screen with the
    // ball/block A/V-sync view — no bars, so there's a single fixed instant
    // (the impact/flash) to align the beep against.
    if (calActiveTone) { vizDrawCalibration(W, H); return; }

    // Dispatch to the active style. All styles share the same audio plumbing;
    // they differ only in how they render the analysed data.
    if (vizStyle === 'starburst')   vizDrawStarburst(W, H);
    else if (vizStyle === 'bokeh')  vizDrawBokeh(W, H);
    else if (vizStyle === 'scope')  vizDrawScope(W, H);
    else if (vizStyle === 'ring')        vizDrawWaveRing(W, H, 'pulse');
    else if (vizStyle === 'ringVivid')   vizDrawWaveRing(W, H, 'vivid');
    else if (vizStyle === 'ringZoom')    vizDrawWaveRing(W, H, 'zoom');
    else if (vizStyle === 'ringClassic') vizDrawWaveRingClassic(W, H);
    else                            vizDrawSegmented(W, H);
  }

  // Compute the per-bar 0..1 levels from the current FFT, applying ballistics
  // and peak-hold. Shared by the bar-based styles (segmented + radial). Fills
  // vizLevels[] and vizPeaks[] and returns the bar count.
  // Update cadence. Drawing runs every animation frame (~60fps) for smooth
  // motion, but the analysis/level update is throttled a little to a slightly
  // calmer cadence than full 60fps. Crucially the ballistics below are now
  // TIME-BASED (scaled by elapsed time), so the real-time rise/fall speed stays
  // constant regardless of this cadence — changing the update rate no longer
  // changes how fast bars fall.
  let vizLastCompute = 0;
  const VIZ_UPDATE_MS = 22;   // ~45 updates/sec
  function vizComputeBands() {
    const now = performance.now();
    const dt = now - vizLastCompute;
    if (dt < VIZ_UPDATE_MS && vizLevels) return (vizLevels ? vizLevels.length : VIZ_BARS);
    vizLastCompute = now;

    // Bin data comes from our FFT helper (npd-vizfft.py) as dB-per-bin values,
    // like getFloatFrequencyData() would give. Log-binning + tilt + dB-curve +
    // ballistics give the original Bars look from the server-streamed frame.
      const bars = VIZ_BARS;
      if (!vizLevels || vizLevels.length !== bars) vizLevels = new Float32Array(bars);
      if (!vizPeaks  || vizPeaks.length  !== bars) vizPeaks  = new Float32Array(bars);
      const f = vizServerFrame;
      if (!f || f.length === 0 || !vizServerBinHz) return bars;

      const fscale = Math.min(4, dt / 16.7);
      const aRate = 1 - Math.pow(1 - VIZ_ATTACK, fscale);
      const dRate = 1 - Math.pow(1 - VIZ_DECAY,  fscale);
      const peakDrop = VIZ_PEAK_DECAY * fscale;

      const bins   = f.length;
      const hzPer  = vizServerBinHz;       // Hz width per downsampled FFT bin
      const fMin   = 50;
      const nyq    = vizServerRate / 2;
      const fMax   = Math.min(20000, nyq);
      const logMin = Math.log10(fMin);
      const logMax = Math.log10(fMax);
      const span   = VIZ_DB_CEIL - VIZ_DB_FLOOR;
      // Our FFT helper's dB values (observed ~ -30..-55 during music) already
      // sit nicely within our -73..-10 floor/ceiling, so no offset is needed.
      // Kept as a tunable: raise if bars globally too short, lower if too tall.
      const SRV_DB_OFFSET = 0;

      for (let i = 0; i < bars; i++) {
        const f0 = Math.pow(10, logMin + (i     / bars) * (logMax - logMin));
        const f1 = Math.pow(10, logMin + ((i+1) / bars) * (logMax - logMin));
        let b0 = Math.floor(f0 / hzPer);
        let b1 = Math.max(b0 + 1, Math.ceil(f1 / hzPer));
        if (b1 > bins) b1 = bins;
        // Average power across the bins in this band (NOT averaging dB).
        let power = 0, nb = 0;
        for (let b = b0; b < b1; b++) {
          const dbv = f[b];
          if (dbv <= -120) continue;     // helper's floor; treat as silent
          power += Math.pow(10, dbv / 10);
          nb++;
        }
        const avgPower = nb > 0 ? power / nb : 0;
        let bandDb = avgPower > 0 ? 10 * Math.log10(avgPower) + SRV_DB_OFFSET : -Infinity;

        // Spectral tilt — same as browser-audio path.
        const fc = Math.sqrt(f0 * f1);
        const octFromCentre = Math.log2(fc / VIZ_TILT_PIVOT_HZ);
        bandDb += VIZ_TILT_DB_PER_OCT * octFromCentre;

        let target = (bandDb - VIZ_DB_FLOOR) / span;
        if (!isFinite(target) || target < 0) target = 0;
        if (target > 1) target = 1;
        const cur = vizLevels[i];
        const rate = (target > cur) ? aRate : dRate;
        const v = cur + (target - cur) * rate;
        vizLevels[i] = v;
        if (v >= vizPeaks[i]) vizPeaks[i] = v;
        else vizPeaks[i] = Math.max(v, vizPeaks[i] - peakDrop);
      }
      return bars;
  }

  // ----- Style 1: segmented LED spectrum (the Eversolo look) -----
  function vizDrawSegmented(W, H) {
    const bars  = vizComputeBands();
    const cells = VIZ_CELLS;
    const labelH = Math.round(H * 0.06);
    const padX   = Math.round(W * 0.02);
    const gridW  = W - padX * 2;
    const gridH  = H - labelH - Math.round(H * 0.03);
    const gridTop = Math.round(H * 0.02);
    const colW   = gridW / bars;
    const cellGapX = Math.max(2, Math.round(colW * 0.16));
    const cellW  = colW - cellGapX;
    const cellGapY = Math.max(2, Math.round((gridH / cells) * 0.22));
    const cellH  = (gridH / cells) - cellGapY;

    for (let i = 0; i < bars; i++) {
      const v = vizLevels[i];
      // Sweep the base hue across the whole spectrum from VIZ_HUE_LOW (bass) to
      // VIZ_HUE_HIGH (treble) — a clean two-colour gradient low->high.
      const sweep = bars > 1 ? i / (bars - 1) : 0;
      const baseHue = VIZ_HUE_LOW + sweep * (VIZ_HUE_HIGH - VIZ_HUE_LOW);
      const x = padX + i * colW + cellGapX / 2;
      const litCells = Math.round(v * cells);
      for (let c = 0; c < cells; c++) {
        const cy = gridTop + gridH - (c + 1) * (cellH + cellGapY) + cellGapY;
        if (c < litCells) {
          // Within-bar vertical gradient: cells near the base sit at the bar's
          // base hue; cells higher up drift toward the OPPOSITE end of the
          // spectrum sweep, and gain saturation + brightness — so each bar
          // glows hotter and shifts colour as it climbs.
          const t = litCells > 1 ? c / (litCells - 1) : 1;   // 0 base, 1 top
          const hue   = baseHue + t * (VIZ_HUE_HIGH - VIZ_HUE_LOW) * 0.12;
          const sat   = 70 + t * 25;                         // 70% -> 95%
          const light = 40 + t * 26;                         // 40% -> 66%
          vizG.fillStyle = `hsl(${hue}, ${sat}%, ${light}%)`;
        } else {
          vizG.fillStyle = `hsla(${baseHue}, 40%, 50%, 0.10)`;
        }
        vizG.fillRect(x, cy, cellW, cellH);
      }
      let peakCell = Math.round(vizPeaks[i] * cells);
      if (peakCell <= litCells && litCells < cells) peakCell = litCells + 1;
      peakCell = Math.min(cells - 1, peakCell);
      if (peakCell > 0) {
        const py = gridTop + gridH - (peakCell + 1) * (cellH + cellGapY) + cellGapY;
        vizG.fillStyle = `hsl(${baseHue}, 100%, 88%)`;
        vizG.fillRect(x, py, cellW, cellH);
      }
    }

    vizG.fillStyle = 'rgba(255,255,255,0.55)';
    vizG.font = `${Math.round(labelH * 0.5)}px system-ui, sans-serif`;
    vizG.textAlign = 'center';
    vizG.textBaseline = 'middle';
    for (let i = 0; i < bars; i++) {
      const cx = padX + i * colW + colW / 2;
      vizG.fillText(VIZ_LABELS[i], cx, H - labelH / 2);
    }
  }

  // ----- Style: bokeh particles -----
  // Soft out-of-focus orbs drift across the screen; each orb is tied to a
  // frequency band and pulses in size + brightness with that band's level.
  // Warm->cool theme colours, gentle drift, glowing radial-gradient fill.
  let vizBokeh = null;
  const VIZ_BOKEH_COUNT = 80;
  function vizBokehInit(W, H, bars) {
    vizBokeh = [];
    for (let i = 0; i < VIZ_BOKEH_COUNT; i++) {
      vizBokeh.push({
        x: Math.random() * W,
        y: Math.random() * H,
        vx: (Math.random() - 0.5) * 0.25,   // slow drift
        vy: (Math.random() - 0.5) * 0.25,
        baseR: 22 + Math.random() * 110,    // wide size variety (sharp..very soft)
        band: Math.floor(Math.random() * bars),
        phase: Math.random() * Math.PI * 2, // for gentle independent shimmer
        baseAlpha: 0.18 + Math.random() * 0.5,
      });
    }
  }
  function vizDrawBokeh(W, H) {
    const bars = vizComputeBands();
    if (!vizBokeh || vizBokeh._w !== W || vizBokeh._h !== H) {
      vizBokehInit(W, H, bars);
      vizBokeh._w = W; vizBokeh._h = H;
    }
    const span = (VIZ_HUE_HIGH - VIZ_HUE_LOW);
    vizG.globalCompositeOperation = 'lighter';  // additive — overlaps glow brighter
    for (const o of vizBokeh) {
      // Drift, wrapping around the edges.
      o.x += o.vx; o.y += o.vy; o.phase += 0.02;
      const m = Math.max(o.baseR, 80);
      if (o.x < -m) o.x = W + m; else if (o.x > W + m) o.x = -m;
      if (o.y < -m) o.y = H + m; else if (o.y > H + m) o.y = -m;

      const v = vizLevels[o.band % bars] || 0;
      // Size and brightness pulse with the band level, plus a gentle shimmer.
      const shimmer = 0.85 + 0.15 * Math.sin(o.phase);
      const r = o.baseR * (0.7 + v * 0.9) * shimmer;
      const sweep = (o.band / Math.max(1, bars - 1));
      const hue = VIZ_HUE_LOW + sweep * span;
      const alpha = o.baseAlpha * (0.35 + v * 0.9) * shimmer;

      // Soft radial gradient: bright core fading to transparent — the bokeh glow.
      const g = vizG.createRadialGradient(o.x, o.y, 0, o.x, o.y, r);
      g.addColorStop(0,   `hsla(${hue}, 90%, 72%, ${Math.min(1, alpha)})`);
      g.addColorStop(0.5, `hsla(${hue}, 85%, 60%, ${Math.min(1, alpha) * 0.4})`);
      g.addColorStop(1,   `hsla(${hue}, 80%, 50%, 0)`);
      vizG.fillStyle = g;
      vizG.beginPath();
      vizG.arc(o.x, o.y, r, 0, Math.PI * 2);
      vizG.fill();
    }
    vizG.globalCompositeOperation = 'source-over';
  }

  // ----- Style: radial starburst -----
  // Solid wedges radiate 360° from the centre, length driven by the band level.
  // More wedges than bands (each band subdivided) for a finer bloom; the whole
  // form rotates; per-wedge transparency slowly DRIFTS around the disc over time
  // so different wedges fade in and out (not fixed, not flickering).
  let vizBurstAngle = 0;
  let vizBurstPhase = 0;
  let vizBurstHue = 0;               // slow palette drift over time (0..1)
  let vizBurstLastT = 0;             // last frame timestamp for dt-scaled motion
  const VIZ_BURST_SUBDIV = 3;        // wedges per band (20 bands -> 60 wedges)
  const VIZ_BURST_SPIN   = 0.011;    // rotation per 60fps-frame (time-scaled)
  const VIZ_BURST_FADESPEED = 0.06;  // how fast the transparency pattern drifts
  const VIZ_BURST_HUE_CYCLES = 3;    // times the colour gradient repeats around the disc
  const VIZ_BURST_HUE_DRIFT  = 0.003;// slow palette shift per update
  // Layer configs for the 3D/overlapping look. Each layer is the full burst at
  // a different length scale, angular offset, rotation speed and opacity, drawn
  // back-to-front so shorter/brighter wedges overlap longer/fainter ones —
  // giving a sense of stacked planes and depth.
  const VIZ_BURST_LAYERS = [
    { scale: 1.00, offset: 0.0,  spin: 1.00, alpha: 0.55, sat: 60, lift: 30 }, // back: long, faint
    { scale: 0.72, offset: 0.5,  spin: -0.6, alpha: 0.8,  sat: 75, lift: 44 }, // mid: offset, counter-rotates
    { scale: 0.48, offset: 0.25, spin: 1.7,  alpha: 1.0,  sat: 92, lift: 56 }, // front: short, crisp, brightest
  ];
  function vizDrawStarburst(W, H) {
    const bars = vizComputeBands();
    const cx = W / 2, cy = H / 2;
    const minDim = Math.min(W, H);
    const baseR = minDim * 0.05;
    const maxLen = minDim * 0.92;
    const wedges = bars * VIZ_BURST_SUBDIV;
    const slice = (Math.PI * 2) / wedges;

    // Time-scale the animation so it advances by real elapsed time, not a fixed
    // amount per frame. Per-frame increments make the rotation visibly jitter
    // whenever frame timing varies (and amplify it on the long back layer). A
    // dt-scaled step keeps the spin/drift speed constant regardless of frame
    // rate or hitches — the same principle the ballistics use.
    const nowT = performance.now();
    if (!vizBurstLastT) vizBurstLastT = nowT;
    let burstDt = (nowT - vizBurstLastT) / 16.7;   // in 60fps-frame units
    vizBurstLastT = nowT;
    if (!isFinite(burstDt) || burstDt <= 0) burstDt = 1;
    if (burstDt > 4) burstDt = 4;                  // clamp after a stall

    vizBurstAngle += VIZ_BURST_SPIN * burstDt;
    // NOTE: deliberately NOT wrapping vizBurstAngle at 2π. The layers rotate at
    // vizBurstAngle * lay.spin (spin = 1.0, -0.6, 1.7). Subtracting 2π from the
    // base angle is seamless only for the spin=1.0 layer; for the others it
    // jumps by (2π * spin) mod 2π — e.g. the front layer (1.7) snapped forward
    // ~0.7 of a turn every wrap (~every several seconds). That was the glitch.
    // sin/cos handle large angles fine, so we just let it grow.
    vizBurstPhase += VIZ_BURST_FADESPEED * burstDt;
    vizBurstHue = (vizBurstHue + VIZ_BURST_HUE_DRIFT * burstDt) % 1;

    const span = (VIZ_HUE_HIGH - VIZ_HUE_LOW);

    // Draw each layer back-to-front.
    for (let L = 0; L < VIZ_BURST_LAYERS.length; L++) {
      const lay = VIZ_BURST_LAYERS[L];
      vizG.save();
      vizG.translate(cx, cy);
      vizG.rotate(vizBurstAngle * lay.spin + lay.offset);

      for (let w = 0; w < wedges; w++) {
        const fb = (w / wedges) * bars;
        const bi = Math.floor(fb);
        const frac = fb - bi;
        const v0 = vizLevels[bi % bars];
        const v1 = vizLevels[(bi + 1) % bars];
        const v = v0 + (v1 - v0) * frac;

        // Minimum length so the gradient start/end are never coincident. A
        // degenerate createLinearGradient (start ≈ end, when a band is near
        // silent) renders unpredictably — which made quiet wedges, and whole
        // quiet layers, flicker/vanish for a frame. Flooring len keeps every
        // gradient valid.
        const len = Math.max(2, v * maxLen * lay.scale);
        const a0 = w * slice;
        const a1 = a0 + slice * 0.82;

        const cyc = ((w * VIZ_BURST_HUE_CYCLES / wedges) + vizBurstHue) % 1;
        const hue = VIZ_HUE_LOW + cyc * span;

        const waveA = Math.sin(w * 0.22 + vizBurstPhase);
        const waveB = Math.sin(w * 0.09 - vizBurstPhase * 0.6);
        const blend = (waveA * 0.6 + waveB * 0.4);
        const wedgeAlpha = (0.18 + (blend * 0.5 + 0.5) * 0.82) * lay.alpha;

        const mid = (a0 + a1) / 2;
        const gx = Math.cos(mid) * len, gy = Math.sin(mid) * len;
        const grad = vizG.createLinearGradient(0, 0, gx, gy);
        grad.addColorStop(0, `hsl(${hue}, ${lay.sat}%, ${lay.lift * 0.7}%)`);
        grad.addColorStop(1, `hsl(${hue + 18}, ${lay.sat + 8}%, ${lay.lift + 16 + v * 10}%)`);

        vizG.globalAlpha = wedgeAlpha;
        // Triangular spike: a single point at the exact centre, fanning out to a
        // flat outer edge — so all wedges converge to one centrepoint with no
        // circular hub.
        vizG.beginPath();
        vizG.moveTo(0, 0);
        vizG.lineTo(Math.cos(a0) * len, Math.sin(a0) * len);
        vizG.lineTo(Math.cos(a1) * len, Math.sin(a1) * len);
        vizG.closePath();
        vizG.fillStyle = grad;
        // shadowBlur is one of the most expensive canvas ops; doing it on every
        // wedge of every layer was a major per-frame cost and a source of frame
        // drops / jitter (worst on the long back layer). Restrict it to the
        // front layer only, where the glow actually reads.
        if (L === VIZ_BURST_LAYERS.length - 1) {
          vizG.shadowBlur = 6 + v * 18;
          vizG.shadowColor = `hsla(${hue + 12}, 100%, 70%, ${0.2 + v * 0.35})`;
        } else {
          vizG.shadowBlur = 0;
        }
        vizG.fill();
      }
      vizG.globalAlpha = 1;
      vizG.shadowBlur = 0;
      vizG.restore();
    }
  }

  // ----- Style 2: radial / circular spectrum (dormant, kept for reference) -----
  // Bars radiate outward from a centre ring; album art (if any) sits in the
  // middle. Bass starts at the top and sweeps clockwise around the circle.
  function vizDrawRadial(W, H) {
    const bars = vizComputeBands();
    const cx = W / 2, cy = H / 2;
    const minDim = Math.min(W, H);
    const innerR = minDim * 0.16;          // ring radius (art sits inside)
    const maxLen = minDim * 0.30;          // max bar length outward
    const barW   = (2 * Math.PI * innerR) / bars * 0.6;

    // Album art in the centre, if we have it.
    if (vizArtImg && vizArtImg.complete && vizArtImg.naturalWidth) {
      const d = innerR * 1.7;
      vizG.save();
      vizG.beginPath();
      vizG.arc(cx, cy, innerR * 0.92, 0, Math.PI * 2);
      vizG.closePath();
      vizG.clip();
      vizG.drawImage(vizArtImg, cx - d/2, cy - d/2, d, d);
      vizG.restore();
    }

    vizG.lineWidth = Math.max(2, barW);
    vizG.lineCap = 'round';
    for (let i = 0; i < bars; i++) {
      const v = vizLevels[i];
      const ang = (i / bars) * Math.PI * 2 - Math.PI / 2;  // start at top
      const r0 = innerR;
      const r1 = innerR + v * maxLen;
      const hue = 8 + (i / (bars - 1)) * 300;
      vizG.strokeStyle = `hsl(${hue}, 85%, ${48 + v * 22}%)`;
      vizG.beginPath();
      vizG.moveTo(cx + Math.cos(ang) * r0, cy + Math.sin(ang) * r0);
      vizG.lineTo(cx + Math.cos(ang) * r1, cy + Math.sin(ang) * r1);
      vizG.stroke();
      // Peak dot floating beyond the bar.
      const pr = innerR + vizPeaks[i] * maxLen + barW * 0.4;
      vizG.fillStyle = `hsl(${hue}, 100%, 85%)`;
      vizG.beginPath();
      vizG.arc(cx + Math.cos(ang) * pr, cy + Math.sin(ang) * pr, Math.max(1.5, barW * 0.32), 0, Math.PI * 2);
      vizG.fill();
    }
  }

  // Populate `vizWave` from whichever source the active mode provides:
  //   web-audio mode: pull fresh time-domain samples from the analyser
  //   server mode:    use the most recent wave block sent by the FFT helper
  // Returns true on success (vizWave is usable), false if no data is available.
  // Centralised so Scope and the four Ring variants stay simple and don't each
  // need their own mode dispatch.
  function vizPopulateWave() {
    if (!vizServerWave) return false;
    // Reallocate vizWave to match the server's wave length the first time we
    // see it. Same-shape Float32Array thereafter, copied in by index — cheap.
    if (!vizWave || vizWave.length !== vizServerWave.length) {
      vizWave = new Float32Array(vizServerWave.length);
    }
    vizWave.set(vizServerWave);
    return true;
  }

  // ----- Style 3: oscilloscope waveform -----
  // Draws the actual time-domain waveform as a flowing line. Uses a hue sweep
  // along the x-axis for a bit of colour.
  function vizDrawScope(W, H) {
    if (!vizPopulateWave()) return;
    const n = vizWave.length;
    const mid = H / 2;
    const amp = H * 0.40;
    vizG.lineWidth = Math.max(2, H * 0.004);
    vizG.lineJoin = 'round';
    // Draw in a few coloured segments across the width for a subtle gradient.
    const step = Math.max(1, Math.floor(n / W));
    vizG.beginPath();
    let first = true;
    for (let x = 0, i = 0; i < n; i += step, x++) {
      const px = (i / (n - 1)) * W;
      const py = mid + vizWave[i] * amp;
      if (first) { vizG.moveTo(px, py); first = false; }
      else vizG.lineTo(px, py);
    }
    vizG.strokeStyle = 'hsl(190, 90%, 60%)';
    vizG.stroke();
  }

  // ----- Style: Waveform Ring -----
  // Time-domain waveform wrapped around a circle: angle = time, amplitude
  // pushes in/out from a base radius. Silent = clean circle; audio = wobble.
  //
  // Colour: a CONIC gradient with just TWO hues. Three stops only — hue A at
  // 0, hue B at 0.5, hue A again at 1 (closing the wrap). That's exactly two
  // zones around the ring with smooth transitions between. The two hues
  // slowly advance through the full 360° hue wheel together, wrapping
  // seamlessly so the zones drift through every colour over ~40s.
  //
  // Music reactivity: bass energy (50–120 Hz, the kick range) drives the
  // brightness, saturation, line thickness and glow size — continuously,
  // not just on detected beats. Louder bass = brighter, fatter, glowier.
  let vizRingAngle = 0;
  let vizRingLastT = 0;
  let vizRingColorPhase = 0;
  let vizRingGradAngle = 0;
  let vizRingBass = 0;                  // smoothed kick-band energy 0..1
  const VIZ_RING_SPIN        = 0.004;
  const VIZ_RING_COLOR_SPEED = 0.0006;  // hue cycle: slower (~80s per full wheel)
  const VIZ_RING_GRAD_SPIN   = 0.001;   // gradient rotation: slower
  // Per-mode config for the three reactive ring variants.
  //   pulse: current default (v0.30.8.0) — modest defocus, dramatic sat pulse
  //   vivid: less defocus, more saturation push
  //   zoom:  same as vivid but shows a fraction of the waveform around the
  //          ring (zoomed in) so peaks/dips read larger
  const VIZ_RING_MODES = {
    pulse: { blurBase: 0.002, blurBass: 0.025, bloomBlurBase: 0.020, bloomBlurBass: 0.025,
             satBase: 60, satBoost: 40, zoom: 1.00 },
    vivid: { blurBase: 0.001, blurBass: 0.015, bloomBlurBase: 0.010, bloomBlurBass: 0.015,
             satBase: 55, satBoost: 45, zoom: 1.00 },
    zoom:  { blurBase: 0.001, blurBass: 0.015, bloomBlurBase: 0.010, bloomBlurBass: 0.015,
             satBase: 55, satBoost: 45, zoom: 0.40 },
  };
  function vizDrawWaveRing(W, H, mode) {
    const cfg = VIZ_RING_MODES[mode] || VIZ_RING_MODES.pulse;
    if (!vizPopulateWave()) return;
    const n = vizWave.length;
    const cx = W / 2, cy = H / 2;
    const minDim = Math.min(W, H);
    const baseR = minDim * 0.26;
    const amp   = minDim * 0.17;

    // Time-scaled animation.
    const nowT = performance.now();
    if (!vizRingLastT) vizRingLastT = nowT;
    let rdt = (nowT - vizRingLastT) / 16.7;
    vizRingLastT = nowT;
    if (!isFinite(rdt) || rdt <= 0) rdt = 1;
    if (rdt > 4) rdt = 4;
    vizRingAngle     += VIZ_RING_SPIN * rdt;
    vizRingColorPhase = (vizRingColorPhase + VIZ_RING_COLOR_SPEED * rdt) % 1;
    vizRingGradAngle += VIZ_RING_GRAD_SPIN * rdt;

    // --- Kick-drum energy in the lowest spectrum band (~50-70 Hz) ---
    // Matches the lowest bar in the Bars visualizer (which covers roughly
    // 50-67 Hz with the 20-bar log binning from 50 Hz). Narrow band = highly
    // selective — only deep kick fundamentals trigger it, not broader bass.
    //
    // dB-per-bin data arrives over the WebSocket in vizServerFrame.
    let dbBins = null, binHz = 0;
    if (vizServerFrame && vizServerBinHz) {
      dbBins = vizServerFrame;
      binHz  = vizServerBinHz;
    }
    if (dbBins && binHz) {
      const kLo = Math.max(1, Math.floor(50 / binHz));
      const kHi = Math.min(dbBins.length - 1, Math.floor(70 / binHz));
      let kPeak = 0;
      for (let b = kLo; b <= kHi; b++) {
        const db = dbBins[b];
        if (db > -120) {
          const lin = Math.pow(10, db / 20);
          if (lin > kPeak) kPeak = lin;
        }
      }
      const kickNow = Math.min(1, kPeak * 80);
      // Snappy envelope: fast attack so a kick spikes immediately, FAST decay
      // so the value returns to baseline quickly (within ~5 frames, ~80ms).
      // The slow-decay approach kept everything "pulsed" most of the time;
      // we want short, distinct pulses with calm resting state between.
      if (kickNow > vizRingBass) vizRingBass = vizRingBass * 0.2 + kickNow * 0.8;
      else                       vizRingBass = vizRingBass * 0.70 + kickNow * 0.30;
    }
    const bass = vizRingBass;

    // --- Build the waveform path ---
    // Zoomed waveform: instead of wrapping all `n` samples around the full
    // circle, wrap only the most-recent fraction (cfg.zoom) — so each sample
    // gets more angular space and peaks/dips read larger. zoom=1.0 = full
    // waveform (default for pulse/vivid); zoom=0.4 shows only ~40% of the
    // samples, magnifying the visible detail.
    const visibleN = Math.max(64, Math.floor(n * cfg.zoom));
    const points = Math.min(visibleN, 1440);
    const step = visibleN / points;
    const startOffset = n - visibleN;     // start at most-recent samples
    const lwBase = Math.max(2.5, minDim * 0.005);
    vizG.lineWidth = lwBase * (1 + bass * 0.6);     // thicker on bass
    vizG.lineJoin = 'round';
    vizG.beginPath();
    for (let p = 0; p <= points; p++) {
      const i = Math.min(n - 1, startOffset + Math.floor(p * step));
      const frac = p / points;
      const ang = vizRingAngle + frac * Math.PI * 2;
      const r = baseR + vizWave[i] * amp;
      const px = cx + Math.cos(ang) * r;
      const py = cy + Math.sin(ang) * r;
      if (p === 0) vizG.moveTo(px, py);
      else vizG.lineTo(px, py);
    }
    vizG.closePath();

    // --- Conic two-zone gradient — ONLY 3 stops so there's no rainbow ---
    // hueA at start, hueB at half-way, hueA at end (wraps). That's it.
    // Anything more creates intermediate colour bands.
    const hueA = (vizRingColorPhase * 360) % 360;
    const hueB = (hueA + 180) % 360;
    const sat  = cfg.satBase + bass * cfg.satBoost;
    const lit  = 48 + bass * 17;

    const grad = vizG.createConicGradient(vizRingGradAngle, cx, cy);
    grad.addColorStop(0,   `hsl(${hueA}, ${sat}%, ${lit}%)`);
    grad.addColorStop(0.5, `hsl(${hueB}, ${sat}%, ${lit}%)`);
    grad.addColorStop(1,   `hsl(${hueA}, ${sat}%, ${lit}%)`);
    vizG.strokeStyle = grad;

    // --- Glow ---
    vizG.shadowBlur  = minDim * (cfg.blurBase + bass * cfg.blurBass);
    const glowHue = (hueA + hueB) / 2;
    vizG.shadowColor = `hsla(${glowHue}, 100%, ${65 + bass * 25}%, ${0.1 + bass * 0.55})`;
    vizG.stroke();

    // --- Bloom on real kicks ---
    if (bass > 0.4) {
      const bloom = (bass - 0.4) / 0.6;
      vizG.lineWidth = lwBase * (1.5 + bloom * 2.5);
      vizG.globalAlpha = bloom * 0.35;
      vizG.shadowBlur = minDim * (cfg.bloomBlurBase + bloom * cfg.bloomBlurBass);
      vizG.stroke();
      vizG.globalAlpha = 1;
    }
    vizG.shadowBlur = 0;
  }

  // ----- Style: Waveform Ring (Classic) -----
  // The original calm version — static cyan→blue→violet gradient, gentle
  // glow, no music reactivity. The waveform-on-a-circle without the kick
  // pulse / colour cycling / dramatic effects of the other ring variants.
  function vizDrawWaveRingClassic(W, H) {
    if (!vizPopulateWave()) return;
    const n = vizWave.length;
    const cx = W / 2, cy = H / 2;
    const minDim = Math.min(W, H);
    const baseR = minDim * 0.26;
    const amp   = minDim * 0.17;

    // Time-scaled slow rotation (reuses the shared ring state).
    const nowT = performance.now();
    if (!vizRingLastT) vizRingLastT = nowT;
    let rdt = (nowT - vizRingLastT) / 16.7;
    vizRingLastT = nowT;
    if (!isFinite(rdt) || rdt <= 0) rdt = 1;
    if (rdt > 4) rdt = 4;
    vizRingAngle += VIZ_RING_SPIN * rdt;

    const points = Math.min(n, 1440);
    const step = n / points;

    vizG.lineWidth = Math.max(2, minDim * 0.004);
    vizG.lineJoin = 'round';
    vizG.beginPath();
    for (let p = 0; p <= points; p++) {
      const i = Math.min(n - 1, Math.floor(p * step));
      const frac = p / points;
      const ang = vizRingAngle + frac * Math.PI * 2;
      const r = baseR + vizWave[i] * amp;
      const px = cx + Math.cos(ang) * r;
      const py = cy + Math.sin(ang) * r;
      if (p === 0) vizG.moveTo(px, py);
      else vizG.lineTo(px, py);
    }
    vizG.closePath();

    const grad = vizG.createLinearGradient(cx - baseR, cy - baseR, cx + baseR, cy + baseR);
    grad.addColorStop(0,   'hsl(190, 90%, 62%)');
    grad.addColorStop(0.5, 'hsl(210, 85%, 60%)');
    grad.addColorStop(1,   'hsl(265, 80%, 64%)');
    vizG.strokeStyle = grad;
    vizG.shadowBlur = minDim * 0.012;
    vizG.shadowColor = 'hsla(200, 100%, 70%, 0.5)';
    vizG.stroke();
    vizG.shadowBlur = 0;
  }

  // ----- Boot -----
  setMode(currentMode);
  loadPlayers();
  setInterval(loadPlayers, 15000);
  setInterval(tick, 100);
  setInterval(clockTick, 1000);
  clockTick();
  poll();
  startPolling();
})();
</script>
</body>
</html>
HTML


1;
