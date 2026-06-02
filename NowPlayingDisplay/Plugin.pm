package Plugins::NowPlayingDisplay::Plugin;

# NowPlaying — a standalone now-playing display page for LMS.
#
# This is a strictly read-only plugin:
#   - No event subscriptions (no callback storms)
#   - No forking (no runaway processes)
#   - No external binaries (no platform issues)
#   - HTTP endpoints, all idempotent:
#       /plugins/NowPlayingDisplay/page             -> display HTML
#       /plugins/NowPlayingDisplay/state.json       -> per-player snapshot
#       /plugins/NowPlayingDisplay/players.json     -> list of players for the dropdown
#       /plugins/NowPlayingDisplay/biography.json   -> artist biography via MAI
#
# If anything in here goes wrong, it can only break itself, not LMS.

use strict;
use warnings;
use base qw(Slim::Plugin::Base);

use JSON::XS;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Web::Pages;
use Slim::Web::HTTP;
use Slim::Control::Request;
use Slim::Networking::SimpleAsyncHTTP;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.nowplayingdisplay',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_NOWPLAYINGDISPLAY',
});

# Plugin preferences. LMS persists these across restarts in a prefs file.
# The settings page module (Settings.pm) reads and writes these.
my $prefs = preferences('plugin.nowplayingdisplay');
$prefs->init({
    defaultMode    => 'now-playing',
    scrollSpeed    => 'medium',     # low | medium | high
    enableVisualizer => 0,          # opt-in: stream muted audio to react to it
    vizDelayMs     => 80,           # visualizer sync offset, signed ms
    vizSmoothing   => 'medium',     # meter responsiveness: lively|medium|smooth|verysmooth
    vizStyle       => 'segmented',  # visualizer style: segmented|radial|scope
});

sub initPlugin {
    my $class = shift;
    $class->SUPER::initPlugin(@_);

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
        qr{^/plugins/NowPlayingDisplay/setstyle\b},      \&_handleSetStyle,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/streamurl\b},     \&_handleStreamUrl,
    );
    Slim::Web::Pages->addRawFunction(
        qr{^/plugins/NowPlayingDisplay/streamproxy\b},   \&_handleStreamProxy,
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

    # The resolved stream URL for remote tracks is NOT read here (that would
    # touch the live song object on every poll). The visualizer fetches it
    # on demand, once per track, via the /streamurl endpoint instead.
    $snap->{stream_url} = '';

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

sub _playerList {
    my @out;
    for my $c (Slim::Player::Client::clients()) {
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

# Persist the visualizer default offset from the on-screen tuner. Accepts
# ?ms=<signed int>. Clamped to the same range as the settings field. Returns
# the saved value as JSON so the page can confirm.
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
    $prefs->set('vizDelayMs', $ms);
    _send($httpClient, $response, 'application/json',
          encode_json({ ok => \1, ms => $ms }), no_cache => 1);
}

# Persist the visualizer style from the on-screen Style button.
sub _handleSetStyle {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $style = $q{style} // '';
    my %valid = map { $_ => 1 } qw(segmented scope starburst bokeh);
    $style = 'segmented' unless $valid{$style};
    $prefs->set('vizStyle', $style);
    _send($httpClient, $response, 'application/json',
          encode_json({ ok => \1, style => $style }), no_cache => 1);
}

# On-demand resolved stream URL for the visualizer. Called only when the
# visualizer is active on a remote/streaming track, and only once per track
# change — NOT on every status poll. Reads the resolved CDN URL the streaming
# plugin (Qobuz, Bandcamp, etc.) stored on the current Song object. Returns it
# as JSON so the page can fetch/analyse the actual audio. Local tracks and
# sources that only expose an internal protocol URL return an empty url.
# Same-origin stream proxy for CORS-blocked streaming services (Bandcamp, etc.).
# The browser can't run Web Audio analysis on a cross-origin stream whose CDN
# doesn't send CORS headers. So the page fetches the audio FROM US instead:
# we fetch the resolved public CDN URL server-side and relay the bytes. Because
# the browser talks to our own origin, CORS doesn't apply and the analyser can
# read the samples.
#
# SAFETY: this only ever fetches the public URL passed in ?url= (which the
# visualizer resolved). It never touches the player/song object, so it cannot
# affect playback.
#
# This version relays a FINITE resource (a track file, e.g. Bandcamp). It is
# NOT suitable for an endless live stream (e.g. Radio Paradise) — that needs a
# true chunked relay, handled separately.
sub _handleStreamProxy {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $url = $q{url} // '';

    unless ($url =~ m{^https?://}i) {
        $response->code(400);
        _send($httpClient, $response, 'text/plain', 'bad url', no_cache => 1);
        return;
    }

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $ct   = $http->headers->content_type || 'application/octet-stream';
            my $body = $http->content;
            $response->code(200);
            $response->header('Content-Type'   => $ct);
            $response->header('Content-Length'  => length($body));
            $response->header('Access-Control-Allow-Origin' => '*');
            $response->header('Cache-Control'  => 'no-store');
            $response->content($body);
            Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$body);
        },
        sub {
            my $http  = shift;
            my $error = shift || 'fetch failed';
            $log->warn("NowPlayingDisplay stream proxy failed: $error");
            $response->code(502);
            my $b = 'proxy fetch failed';
            $response->header('Content-Type'  => 'text/plain');
            $response->header('Content-Length' => length($b));
            Slim::Web::HTTP::addHTTPResponse($httpClient, $response, \$b);
        },
        { timeout => 30 },
    )->get($url);
}

sub _handleStreamUrl {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $playerId = $q{player} // '';
    my $debug    = $q{debug};

    my $client;
    if ($playerId eq '' || lc($playerId) eq 'auto') {
        $client = _autoActivePlayer();
    } else {
        $client = Slim::Player::Client::getClient($playerId);
    }

    my $url = '';
    my $needsProxy = \0;   # JSON false; true for CORS-blocked sources
    my %dbg;
    if ($client) {
        eval {
            my $song = $client->playingSong;
            $dbg{have_song} = $song ? 1 : 0;
            if ($song) {
                my $su = $song->streamUrl;
                $dbg{stream_url_raw} = defined $su ? $su : '(undef)';
                my $tr = eval { $song->track ? $song->track->url : '' };
                $dbg{track_url_raw} = $tr // '';
                eval {
                    for my $k (qw(streamUrl url gapless_url)) {
                        my $v = $song->pluginData($k);
                        $dbg{"pluginData_$k"} = $v if defined $v && !ref $v;
                    }
                };
                $url = $su if $su && $su =~ m{^https?://};

                # Decide whether this source needs the same-origin proxy. This
                # is by SOURCE PROTOCOL (deterministic) rather than runtime
                # timing/error guessing. Qobuz's CDN allows CORS so it plays
                # direct; Bandcamp and Radio Paradise are CORS-blocked and must
                # go through our proxy. Default unknown remote sources to proxy
                # (safer — works even if their CDN blocks CORS).
                my $proto = ($tr && $tr =~ m{^([a-z0-9\+\-]+)://}i) ? lc($1) : '';
                $dbg{source_proto} = $proto;
                if ($proto eq 'qobuz') {
                    $needsProxy = \0;          # direct works
                } elsif ($proto) {
                    $needsProxy = \1;          # bandcamp, radioparadise, others
                }
            }
        };
        $dbg{eval_error} = $@ if $@;
    } else {
        $dbg{have_client} = 0;
    }

    my $out = { url => $url, needsProxy => $needsProxy };
    $out->{debug} = \%dbg if $debug;
    _send($httpClient, $response, 'application/json',
          encode_json($out), no_cache => 1);
}

sub _handleStateJson {
    my ($httpClient, $response) = @_;
    my %q = $response->request->uri->query_form;
    my $playerId = $q{player} // '';

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
    my $presets = $prefs->get('vizPresets')   || [];
    my $pmap    = $prefs->get('vizPlayerMap') || {};
    my $vizDefault = $prefs->get('vizDelayMs');
    $vizDefault = 0 unless defined $vizDefault && $vizDefault =~ /^-?\d+$/;
    return {
        scrollPx  => ($speedMap{$scrollSpeed} // 50),
        viz       => {
            presets   => $presets,
            playerMap => $pmap,
            default   => $vizDefault + 0,
            smoothing => ($prefs->get('vizSmoothing') // 'medium'),
            style     => ($prefs->get('vizStyle') // 'segmented'),
        },
    };
}

# Pick whichever player is "most active" right now. Used when the page
# requests player=auto (or omits the param) — common for TVs and ambient
# displays where there's no human to choose.
sub _autoActivePlayer {
    my @clients = Slim::Player::Client::clients();
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
        $LYR_CACHE{$cache_key} = { ts => time(), body => $payload };
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
        $BIO_CACHE{$key} = { ts => time(), body => $payload };
    }

    _send($httpClient, $response, 'application/json',
          encode_json($payload), no_cache => 1);
}

# Return any currently-connected player client object, or undef if none.
# MAI's biography handler is registered with needsClient=0 but in practice
# behaves more reliably with a real client, matching what Material does.
sub _anyConnectedClient {
    my @clients = Slim::Player::Client::clients();
    return $clients[0] || undef;
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

    # Visualizer offset resolution. We support named delay presets and a
    # per-player assignment of a preset. The page resolves its own offset from
    # these using its ?player= id. Shapes:
    #   vizPresets   = [ { name=>'Lounge', ms=>215 }, ... ]
    #   vizPlayerMap = { '<player_id>' => '<preset name>', ... }
    #   vizDelayMs   = legacy/global default offset (fallback)
    my $presets = $prefs->get('vizPresets')   || [];
    my $pmap    = $prefs->get('vizPlayerMap') || {};
    my $vizDefault = $prefs->get('vizDelayMs');
    $vizDefault = 0 unless defined $vizDefault && $vizDefault =~ /^-?\d+$/;
    my $vizCfg = encode_json({
        presets   => $presets,
        playerMap => $pmap,
        default   => $vizDefault + 0,
        smoothing => ($prefs->get('vizSmoothing') // 'medium'),
        style     => ($prefs->get('vizStyle') // 'segmented'),
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
      <div id="viz-tsaved" class="viz-tsaved" hidden>Saved</div>
    </div>
    <audio id="viz-audio" preload="auto" playsinline></audio>
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
  // iOS Safari routes MediaElementSource to the speakers instead of through
  // the Web Audio graph, so silent analysis is impossible — the visualizer is
  // unsupported there and we don't offer it.
  const VIZ_IS_IOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
                  || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const VALID_MODES = ['now-playing', 'artwork', 'lyrics', 'ambient', 'vinyl', 'biography'];
  if (VIZ_ENABLED && !VIZ_IS_IOS) {
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
      apply(d);
      noteTimeFromSnap(d);
      lastSnap = d;
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

    // Keep the visualizer's audio source slaved to the room player. Wrapped so
    // any visualizer/stream error can NEVER break the main display update.
    if (currentMode === 'visualizer') { try { vizSync(d); } catch(e){ console.warn('[npd viz] sync error', e); } }

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
  function lyricsTick() {
    requestAnimationFrame(lyricsTick);
    if (currentMode !== 'lyrics') return;
    if (!lyrData || !lyrData.synced || !lyrLineEls.length) return;

    const pos   = currentPlayPosition();
    const lines = lyrData.lines;

    // Find the index of the current line: the last line whose t <= pos.
    // Linear search is fine — lyrics typically have <200 lines.
    let idx = -1;
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].t <= pos) idx = i; else break;
    }

    if (idx === lyrActiveIndex) return;

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
  }
  requestAnimationFrame(lyricsTick);

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
    viz:       () => {
      const el = document.getElementById('viz-audio');
      let amax = null, asample = null;
      try {
        if (vizAnalyser && vizData) {
          vizAnalyser.getFloatFrequencyData(vizData);
          let m = -Infinity;
          for (let i = 0; i < vizData.length; i++) if (isFinite(vizData[i]) && vizData[i] > m) m = vizData[i];
          amax = m;
          asample = Array.from(vizData.slice(0, 5));
        }
      } catch(e) { amax = 'err:' + e.message; }
      return {
        ctxState:    vizCtx ? vizCtx.state : '(no ctx)',
        sampleRate:  vizCtx ? vizCtx.sampleRate : null,
        hasAnalyser: !!vizAnalyser,
        hasSource:   !!vizSource,
        analyserMaxDb: amax,
        analyserSample: asample,
        el: el ? {
          crossOrigin: el.crossOrigin,
          src:         (el.src || '').slice(0, 70),
          paused:      el.paused,
          muted:       el.muted,
          currentTime: el.currentTime,
          readyState:  el.readyState,
          error:       el.error ? el.error.code : null,
        } : '(no element)',
        active:      vizActive,
        trackId:     vizTrackId,
        streamUrl:   (vizStreamUrl || '').slice(0, 70),
      };
    },
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

  function bioScrollFrame(now) {
    requestAnimationFrame(bioScrollFrame);
    if (currentMode !== 'biography') { bioLastTs = now; return; }

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

  requestAnimationFrame(bioScrollFrame);

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
  function tick() {
    if (currentMode !== 'now-playing') return;
    if (!lastSnap || lastSnap.state !== 'playing') return;
    const elapsed = (performance.now() - lastFetch) / 1000;
    const pos = Math.min((lastSnap.position || 0) + elapsed, lastSnap.duration || 0);
    $('np-cur').textContent = fmt(pos);
    const pct = lastSnap.duration ? (pos / lastSnap.duration) * 100 : 0;
    $('np-fill').style.width = pct + '%';
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


  // ===== Visualizer engine =========================================
  // Plays the current track (muted) purely as an analysis source, slaved to
  // the room player. Real FFT via Web Audio drives a spectrum visual. Never
  // touches LMS playback; no player is registered.
  let vizCtx = null;        // AudioContext
  let vizAnalyser = null;   // AnalyserNode
  let vizSource = null;     // MediaElementSourceNode
  let vizData = null;       // Uint8Array of frequency bins
  let vizWave = null;       // Float32Array of time-domain samples (oscilloscope)
  let vizStyle = 'segmented';  // segmented | radial | scope
  let vizStyleTouched = false; // true once user cycles style on-screen this session
  let vizArtImg = null;        // <img> of current album art for the radial centre
  let vizArtUrl = '';          // last loaded art URL (avoids reloading each poll)
  let vizRAF = 0;           // requestAnimationFrame handle
  let vizActive = false;
  let vizTrackId = null;    // track_id currently loaded into the audio el
  let vizStreamUrl = '';    // resolved remote stream URL currently loaded (Qobuz etc.)
  let vizRemoteTid = null;  // track_id of the remote track we last fetched a stream URL for
  let vizStreamTimeout = 0; // detects continuous streams that never become playable
  let vizLastSeek = 0;      // perf.now() of last position correction
  let vizRoomPos = 0;       // room position (s) at last poll
  let vizRoomPosAt = 0;     // perf.now() when that position was sampled
  let vizRoomState = false; // was the room playing at last poll
  let vizGestureArmed = false;
  const vizAudio = () => document.getElementById('viz-audio');

  let vizGain = null;
  function vizBuildGraph() {
    if (vizCtx) return;
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) { console.error('[npd viz] No Web Audio support'); return; }
    vizCtx = new AC();
    const el = vizAudio();
    vizSource = vizCtx.createMediaElementSource(el);
    vizAnalyser = vizCtx.createAnalyser();
    vizAnalyser.fftSize = 8192;   // 4096 bins @ ~5.4Hz — enough resolution to
                                  // separate the low bass bands (50/69/94Hz),
                                  // which 2048 (21.5Hz/bin) smeared together
    vizAnalyser.smoothingTimeConstant = 0.0;  // we apply uniform per-bar ballistics
    vizAnalyser.minDecibels = -100;
    vizAnalyser.maxDecibels = 0;
    vizData = new Float32Array(vizAnalyser.frequencyBinCount);
    vizWave = new Float32Array(vizAnalyser.fftSize);   // time-domain for scope
    // Route source -> analyser -> gain(0) -> destination. We need a path to the
    // destination because iOS Safari will otherwise BYPASS the Web Audio graph
    // and play the element straight to the speakers (the "it just plays the
    // audio" bug). A GainNode pinned to 0 keeps the graph live (so the analyser
    // receives data) while producing silence. Desktop is happy with this too.
    vizGain = vizCtx.createGain();
    vizGain.gain.value = 0;
    vizSource.connect(vizAnalyser);
    vizAnalyser.connect(vizGain);
    vizGain.connect(vizCtx.destination);
  }

  function vizStart() {
    if (!VIZ_ENABLED) return;
    // iOS Safari bypasses the Web Audio graph and plays the element straight
    // to the speakers (no silent analysis possible), so the visualizer is not
    // supported there. Show a message instead of ever playing audio aloud.
    if (VIZ_IS_IOS) {
      vizActive = false;
      vizHint('Visualizer isn\u2019t supported on iOS / iPadOS');
      return;
    }
    vizActive = true;
    const hint = document.getElementById('viz-hint');
    if (hint) { hint.textContent = 'Starting visualizer…'; hint.style.opacity = '1'; }
    vizBuildGraph();
    // AudioContext often starts suspended until a user gesture. Switching to
    // this mode is usually itself a gesture, but not always (e.g. mode set via
    // URL on load). Resume now, and ALSO arm a one-time gesture listener so a
    // tap/click anywhere guarantees the context (and thus the analyser data)
    // wakes up. Without this the bars can sit dead with the autoplay warning.
    vizResume();
    if (!vizGestureArmed) {
      vizGestureArmed = true;
      const wake = () => { vizResume(); };
      window.addEventListener('pointerdown', wake, { once: false });
      window.addEventListener('keydown', wake, { once: false });
      document.addEventListener('visibilitychange', () => { if (!document.hidden) vizResume(); });
      window.addEventListener('focus', wake);
    }
    vizSizeCanvas();
    vizWireTuner();
    if (VIZ_CFG && VIZ_CFG.smoothing) vizApplySmoothing(VIZ_CFG.smoothing);
    if (VIZ_CFG && VIZ_CFG.style && VIZ_STYLES.indexOf(VIZ_CFG.style) >= 0 && !vizStyleTouched) {
      vizStyle = VIZ_CFG.style;
    }
    vizUpdateStyleLabel();
    vizShowTuner();
    if (lastSnap) vizSync(lastSnap);
    if (!vizRAF) vizRAF = requestAnimationFrame(vizDraw);
  }

  function vizResume() {
    if (vizCtx && vizCtx.state === 'suspended') {
      vizCtx.resume().then(() => {
        const el = vizAudio();
        if (vizActive && el && el.paused && vizRoomState) el.play().catch(()=>{});
      }).catch(()=>{});
    }
  }

  function vizStop() {
    vizActive = false;
    if (vizRAF) { cancelAnimationFrame(vizRAF); vizRAF = 0; }
    clearTimeout(vizStreamTimeout);
    const t = document.getElementById('viz-tuner');
    if (t) t.hidden = true;
    clearTimeout(vizTunerHideTimer);
    const el = vizAudio();
    if (el) { try { el.pause(); el.playbackRate = 1.0; } catch(e){} el.removeAttribute('src'); el.load(); }
    vizTrackId = null;
    if (vizCtx && vizCtx.state === 'running') vizCtx.suspend().catch(()=>{});
  }

  // Called every poll while in visualizer mode. Rather than continuously
  // chasing the room (which stutters) or seeking only once (which drifts), we
  // RE-ANCHOR precisely on the events that actually break sync — track change,
  // track restart, a room seek, and a pause->play resume — and free-run
  // smoothly between them. These are exactly the moments sync was being lost.
  function vizSync(d) {
    if (!vizActive || !d) return;
    const el = vizAudio();
    if (!el) return;
    const tid = d.track_id;
    const playing = d.state === 'playing';
    const pos = d.position || 0;

    const isLocal = tid !== undefined && tid !== null && tid !== '' && /^\d+$/.test(String(tid));
    if (!isLocal) {
      // Remote/streaming track. The resolved CDN URL isn't in the poll payload
      // (that would touch the live song object every 2.5s); we fetch it ONCE
      // per track from the /streamurl endpoint. tid identifies the track (even
      // for remote tracks it's a stable negative id), so we refetch only when
      // it changes.
      if (String(tid) !== String(vizRemoteTid)) {
        vizRemoteTid = String(tid);
        vizStreamUrl = '';
        vizTrackId = null;
        const pid = (lastSnap && lastSnap.player && lastSnap.player.id) || currentPlayer || 'auto';
        vizHint('Resolving stream…');
        fetch(`${BASE}/plugins/NowPlayingDisplay/streamurl?player=${encodeURIComponent(pid)}`)
          .then(r => r.json())
          .then(j => {
            if (String(tid) !== String(vizRemoteTid)) return;  // track moved on
            const su = (j && j.url) || '';
            if (!su) { vizHint('Visualizer is only available for local library tracks'); return; }
            vizStreamUrl = su;
            const myTid = String(tid);
            const needsProxy = !!(j && j.needsProxy);
            // The server tells us, by source protocol, whether this stream is
            // CORS-blocked and must go through our same-origin proxy. Qobuz
            // plays direct (CORS-friendly); Bandcamp/RP use the proxy. This is
            // deterministic — no runtime timing/error guessing.
            const loadSrc = needsProxy
              ? `${BASE}/plugins/NowPlayingDisplay/streamproxy?url=${encodeURIComponent(su)}`
              : su;

            const cleanup = () => {
              el.removeEventListener('canplay', onReady);
              el.removeEventListener('error', onError);
            };
            const onReady = () => {
              if (String(tid) !== myTid) { cleanup(); return; }
              clearTimeout(vizStreamTimeout);
              cleanup();
              if (vizRoomState) el.play().catch(()=>{});
              vizHint('');
            };
            const onError = () => {
              if (String(tid) !== myTid) { cleanup(); return; }
              clearTimeout(vizStreamTimeout);
              cleanup();
              vizStreamUrl = '';
              vizHint('This stream can\u2019t be visualized');
            };

            el.addEventListener('canplay', onReady);
            el.addEventListener('error', onError);
            // crossOrigin is needed ONLY for the genuinely cross-origin direct
            // path (Qobuz CDN, which sends CORS headers). The proxy is
            // same-origin, so we must NOT set it there — Safari would taint a
            // same-origin element that has crossOrigin set. (Even though the
            // proxy sends ACAO:*, clearing the attribute is the safe choice and
            // matches the local-file handling.)
            if (needsProxy) {
              el.removeAttribute('crossorigin');
            } else {
              el.crossOrigin = 'anonymous';
            }
            el.src = loadSrc;
            el.load();

            // For proxied streams, a continuous live stream (RP "regular") never
            // finishes buffering so canplay never fires — watchdog nudges toward
            // the interactive/FLAC channel.
            if (needsProxy) {
              clearTimeout(vizStreamTimeout);
              vizStreamTimeout = setTimeout(() => {
                if (String(tid) === myTid && (!el.readyState || el.readyState < 2)) {
                  cleanup();
                  try { el.removeAttribute('src'); el.load(); } catch(e){}
                  vizStreamUrl = '';
                  vizHint('This continuous stream can\u2019t be visualized — try the interactive/FLAC version of the channel');
                }
              }, 8000);
            }
          })
          .catch(() => { vizHint('Visualizer is only available for local library tracks'); });
      }
      // Mirror play/pause for an already-loaded stream.
      if (vizStreamUrl) {
        if (playing) { if (el.paused && el.readyState >= 2) el.play().catch(()=>{}); }
        else { if (!el.paused) el.pause(); }
      }
      vizRoomState = playing;
      return;
    }
    // Local track — clear any remote-stream state.
    if (vizStreamUrl || vizRemoteTid) { vizStreamUrl = ''; vizRemoteTid = null; clearTimeout(vizStreamTimeout); }

    // Work out whether something discontinuous happened to the room since the
    // last poll. If it was playing, we expect position to have advanced by
    // about the elapsed wall-clock time. A large mismatch means a seek or a
    // restart; a backward jump means a restart/seek-back.
    const nowMs = performance.now();
    let expectedPos = vizRoomPos;
    if (vizRoomState && vizRoomPosAt) {
      expectedPos = vizRoomPos + (nowMs - vizRoomPosAt) / 1000;
    }
    const jumped = Math.abs(pos - expectedPos) > 1.5;     // seek/restart
    const trackChanged = String(tid) !== String(vizTrackId);
    const wentDown = pos + 0.5 < expectedPos;             // position fell back

    // Update our anchor sample to the freshest poll values.
    vizRoomPos   = pos;
    vizRoomPosAt = nowMs;
    vizRoomState = playing;

    // --- Track change: load the new file, anchor on canplay ---
    if (trackChanged) {
      vizTrackId = String(tid);
      // Same-origin local file: do NOT set crossOrigin. Safari taints a
      // same-origin media element that has crossOrigin set if the response
      // lacks CORS headers (LMS's /music/ endpoint doesn't send them), which
      // silences the analyser even though audio plays. Clearing it here also
      // resets any value left over from a previous streaming track.
      el.removeAttribute('crossorigin');
      el.src = `${BASE}/music/${vizTrackId}/download.mp3`;
      el.load();
      vizHint('');
      const onReady = () => {
        el.removeEventListener('canplay', onReady);
        vizSeekTo(vizEstimatedRoomPos() + vizLeadSeconds());
        if (vizRoomState) el.play().catch(()=>{});
      };
      el.addEventListener('canplay', onReady);
      return;   // play/pause + anchor handled on canplay
    }

    // --- Re-anchor only when the POSITION actually moved discontinuously ---
    // (restart of same track, or a seek). A plain pause->play does NOT move the
    // position, so we must NOT seek on resume — seeking re-buffers the MP3 and
    // causes a multi-second stall. On a clean resume we just un-pause below and
    // both clocks continue from where they paused, still aligned.
    if ((jumped || wentDown) && el.readyState >= 2) {
      vizSeekTo(pos + vizLeadSeconds());
    }

    // --- Mirror play/pause ---
    if (playing) {
      if (el.paused && el.readyState >= 2) el.play().catch(()=>{});
    } else {
      if (!el.paused) el.pause();
    }
  }

  // Estimate the room's current playback position by extrapolating from the
  // last poll sample (position advances in real time while playing).
  function vizEstimatedRoomPos() {
    if (!vizRoomState) return vizRoomPos;
    return vizRoomPos + (performance.now() - vizRoomPosAt) / 1000;
  }

  // Drift safety-net. Event re-anchoring (in vizSync) handles the big sync
  // breakers; this only catches SLOW drift accumulating over a long track from
  // the two clocks running at fractionally different rates. Rare and gentle so
  // it never fights the event anchoring or stutters the display.
  function vizCorrect() {
    const el = vizAudio();
    if (!el || !vizActive || el.paused || el.readyState < 2) return;
    if (vizTrackId === null) return;
    if (el.playbackRate !== 1.0) el.playbackRate = 1.0;
    const now = performance.now();
    if (now - vizLastSeek < 8000) return;        // at most every 8s
    const target = vizEstimatedRoomPos() + vizLeadSeconds();
    if (!isFinite(el.currentTime)) return;
    // Only correct sustained drift beyond ~0.5s — tighter than before (since
    // we're not constantly seeking) but still rare enough to stay smooth.
    if (Math.abs(el.currentTime - target) > 0.5) vizSeekTo(target);
  }

  // Visualizer offset resolution. Config injected from settings holds named
  // presets and a per-player preset assignment, plus a default. We resolve the
  // offset for whichever player this display is showing, so different rooms /
  // display devices can each have their own dialled-in delay.
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
      const presetName = VIZ_CFG && VIZ_CFG.playerMap && VIZ_CFG.playerMap[pid];
      if (presetName && VIZ_CFG.presets) {
        const p = VIZ_CFG.presets.find(x => x.name === presetName);
        if (p && p.ms != null && !isNaN(Number(p.ms))) ms = Number(p.ms);
      }
    } catch (e) {}
    if (isNaN(ms)) ms = 0;
    return ms / 1000;
  }

  function vizSeekTo(t) {
    const el = vizAudio();
    if (!el) return;
    try { el.currentTime = Math.max(0, t); } catch(e){}
    vizLastSeek = performance.now();
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
    if (lbl) lbl.textContent = (vizTuneMs > 0 ? '+' : '') + vizTuneMs;
  }

  function vizNudge(delta) {
    if (vizTuneMs === null) vizTuneMs = vizCurrentOffsetMs();
    vizTuneMs = Math.max(-2000, Math.min(2000, vizTuneMs + delta));
    vizUpdateTunerLabel();
    vizShowTuner();
    // Instant re-seek so the shift is visible immediately against the music.
    const el = vizAudio();
    if (el && el.readyState >= 2 && vizTrackId !== null) {
      vizSeekTo(vizEstimatedRoomPos() + vizTuneMs / 1000);
    }
  }

  const VIZ_STYLES = ['segmented', 'scope', 'starburst', 'bokeh'];
  const VIZ_STYLE_NAMES = { segmented: 'Bars', scope: 'Scope', starburst: 'Starburst', bokeh: 'Bokeh' };
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
    fetch(`${BASE}/plugins/NowPlayingDisplay/setoffset?ms=${vizTuneMs}`)
      .then(r => r.json())
      .then(() => {
        const s = document.getElementById('viz-tsaved');
        if (s) { s.hidden = false; setTimeout(() => { s.hidden = true; }, 1500); }
        // Fold the saved value into the config default so it persists as the
        // resolved offset and we can clear the live override.
        if (VIZ_CFG) VIZ_CFG.default = vizTuneMs;
      })
      .catch(() => {});
  }

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
  const VIZ_TILT_DB_PER_OCT = 3.0;
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

  function vizDraw() {
    if (!vizActive) { vizRAF = 0; return; }
    vizRAF = requestAnimationFrame(vizDraw);
    if (!vizG || !vizAnalyser) return;

    // If the AudioContext is still suspended (browsers start it that way until
    // a user gesture), keep trying to resume every frame.
    if (vizCtx && vizCtx.state === 'suspended') {
      vizResume();
      vizHint('Tap to start the visualizer');
    } else if (vizCtx && vizCtx.state === 'running' && vizHintIsStart) {
      vizHint('');   // clear the start hint once running
    }

    vizCorrect();   // keep audio position locked to room + offset

    const W = vizCanvas.width, H = vizCanvas.height;
    vizG.clearRect(0, 0, W, H);
    vizG.fillStyle = '#000';
    vizG.fillRect(0, 0, W, H);

    // Dispatch to the active style. All styles share the same audio plumbing;
    // they differ only in how they render the analysed data.
    if (vizStyle === 'starburst')   vizDrawStarburst(W, H);
    else if (vizStyle === 'bokeh')  vizDrawBokeh(W, H);
    else if (vizStyle === 'scope')  vizDrawScope(W, H);
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
    if (dt < VIZ_UPDATE_MS && vizLevels) return VIZ_BARS;
    vizLastCompute = now;
    // Scale factor relative to a 60fps frame (16.7ms). Clamp so a long stall
    // (e.g. tab backgrounded) can't produce a huge jump.
    const fscale = Math.min(4, dt / 16.7);
    vizAnalyser.getFloatFrequencyData(vizData);
    const bins   = vizData.length;
    const nyq    = (vizCtx ? vizCtx.sampleRate : 44100) / 2;
    const hzPer  = nyq / bins;
    const fMin   = 50;
    const fMax   = Math.min(20000, nyq);
    const bars   = VIZ_BARS;
    const logMin = Math.log10(fMin);
    const logMax = Math.log10(fMax);
    const span   = VIZ_DB_CEIL - VIZ_DB_FLOOR;

    if (!vizLevels || vizLevels.length !== bars) vizLevels = new Float32Array(bars);
    if (!vizPeaks  || vizPeaks.length  !== bars) vizPeaks  = new Float32Array(bars);

    // Convert the per-frame attack/decay fractions into time-scaled rates.
    // 1-(1-r)^fscale gives the equivalent fraction over `fscale` frames.
    const aRate = 1 - Math.pow(1 - VIZ_ATTACK, fscale);
    const dRate = 1 - Math.pow(1 - VIZ_DECAY,  fscale);
    const peakDrop = VIZ_PEAK_DECAY * fscale;

    for (let i = 0; i < bars; i++) {
      const f0 = Math.pow(10, logMin + (i     / bars) * (logMax - logMin));
      const f1 = Math.pow(10, logMin + ((i+1) / bars) * (logMax - logMin));
      let b0 = Math.floor(f0 / hzPer);
      let b1 = Math.max(b0 + 1, Math.ceil(f1 / hzPer));
      if (b1 > bins) b1 = bins;
      let power = 0, nb = 0;
      for (let b = b0; b < b1; b++) {
        const db = vizData[b];
        if (db === -Infinity || isNaN(db)) continue;
        power += Math.pow(10, db / 10);
        nb++;
      }
      // Average power per bin (not sum). Summing would massively favour the
      // wide treble bands (which span 50-240 bins) over the narrow bass bands
      // (2-3 bins), making the high end read artificially boosted. Averaging
      // gives each band its true level regardless of how many bins it spans.
      const avgPower = nb > 0 ? power / nb : 0;
      let bandDb = avgPower > 0 ? 10 * Math.log10(avgPower) : -Infinity;

      // Spectral tilt, pivoting around the spectrum CENTRE so it both CUTS the
      // bass and BOOSTS the treble (a bottom-anchored tilt only lifts highs and
      // leaves the bass as high as before). Bands below centre are attenuated,
      // bands above are lifted, by VIZ_TILT_DB_PER_OCT per octave from centre.
      const fc = Math.sqrt(f0 * f1);                 // band centre (geometric)
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
  const VIZ_BURST_SUBDIV = 3;        // wedges per band (20 bands -> 60 wedges)
  const VIZ_BURST_SPIN   = 0.022;    // rotation per update (higher = faster)
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

    vizBurstAngle += VIZ_BURST_SPIN;
    if (vizBurstAngle > Math.PI * 2) vizBurstAngle -= Math.PI * 2;
    vizBurstPhase += VIZ_BURST_FADESPEED;
    vizBurstHue = (vizBurstHue + VIZ_BURST_HUE_DRIFT) % 1;

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

        const len = v * maxLen * lay.scale;   // from the very centre (no core)
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
        vizG.shadowBlur = (6 + v * 18) * (L === VIZ_BURST_LAYERS.length - 1 ? 1 : 0.4);
        vizG.shadowColor = `hsla(${hue + 12}, 100%, 70%, ${0.2 + v * 0.35})`;
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

  // ----- Style 3: oscilloscope waveform -----
  // Draws the actual time-domain waveform as a flowing line. Uses a hue sweep
  // along the x-axis for a bit of colour.
  function vizDrawScope(W, H) {
    if (!vizWave) return;
    vizAnalyser.getFloatTimeDomainData(vizWave);
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
