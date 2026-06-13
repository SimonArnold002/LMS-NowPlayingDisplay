package Plugins::NowPlayingDisplay::Settings;

# Plugin settings page — lives under Settings → Advanced → Now Playing
# Display in the LMS web UI.

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;

my $log   = logger('plugin.nowplayingdisplay');
my $prefs = preferences('plugin.nowplayingdisplay');

sub name {
    return 'PLUGIN_NOWPLAYINGDISPLAY';
}

sub page {
    return 'plugins/NowPlayingDisplay/settings/basic.html';
}

sub prefs {
    # Note: vizPlayerOffsets is intentionally NOT listed here. It is not a
    # simple pref_<name> form field — we parse and save it manually in
    # handler() from the per-player offset_<id> fields. Listing it here would
    # make the parent handler try to save it from absent pref_ fields and wipe
    # our values.
    return ($prefs, qw(defaultMode scrollSpeed enableVisualizer vizDelayMs vizSmoothing vizStyle vizServerMode vizBridgeUrl vizPlayerMac vizAutoFollow vizHelperEnabled vizSqueezeliteEnabled));
}

sub handler {
    my ($class, $client, $params) = @_;

    my $clampMs = sub {
        my $v = shift // 0;
        $v =~ s/[^\-\d]//g;
        $v = 0 unless $v =~ /^-?\d+$/;
        $v = -2000 if $v < -2000;
        $v =  2000 if $v >  2000;
        return int($v);   # int() guarantees JSON encodes a number, not "string"
    };

    # Global default offset (fallback for players with no per-player value).
    if (exists $params->{pref_vizDelayMs}) {
        $params->{pref_vizDelayMs} = $clampMs->($params->{pref_vizDelayMs});
    }

    # Fold any deprecated named-preset assignments into the flat per-player map
    # before we render. Idempotent / no-op once done.
    eval { Plugins::NowPlayingDisplay::Plugin::_migratePlayerOffsets(); };
    $log->error("NowPlayingDisplay offset migration failed: $@") if $@;

    # On save, parse the per-player offset fields (offset_<playerId>) out of the
    # form and rebuild vizPlayerOffsets. We detect a submission by the presence
    # of our own fields rather than a specific save-flag name. A blank field
    # clears that player's per-player offset (it then falls back to the global
    # default).
    my $submitted = 0;
    for my $k (keys %$params) {
        if ($k =~ /^offset_/) { $submitted = 1; last; }
    }
    if ($submitted) {
        eval {
            my %offs;
            for my $k (keys %$params) {
                next unless $k =~ /^offset_(.+)$/;
                my $pid = $1;
                my $raw = $params->{$k};
                next if !defined $raw || $raw =~ /^\s*$/;   # blank = no per-player offset
                $offs{$pid} = $clampMs->($raw);
            }
            $prefs->set('vizPlayerOffsets', \%offs);
        };
        $log->error("NowPlayingDisplay offset save failed: $@") if $@;
    }

    # Build data for the template: players with their current per-player offset.
    # The dedicated Visualizer SqueezeLite is infrastructure (it's the capture
    # player doing the FFT analysis, not a room), so it's never listed here and
    # never gets an offset of its own.
    my $offs = $prefs->get('vizPlayerOffsets') || {};
    $offs = {} unless ref($offs) eq 'HASH';
    my $vizMac = lc($prefs->get('vizPlayerMac') // '');
    my @players;
    for my $c (Slim::Player::Client::clients()) {
        next if $vizMac && lc($c->id // '') eq $vizMac;
        push @players, {
            name   => $c->name,
            id     => $c->id,
            offset => (defined $offs->{$c->id} ? $offs->{$c->id} : ''),
        };
    }
    @players = sort { lc($a->{name}) cmp lc($b->{name}) } @players;
    $params->{players} = \@players;

    # Helper status snapshot + relevant filesystem paths for the new server-side
    # visualizer setup section. The template uses these to show running state,
    # dep status, and copy-pasteable systemd setup instructions with the
    # correct plugin install path for this machine.
    $params->{helperStatus} = Plugins::NowPlayingDisplay::Plugin::_helperStatus();
    $params->{sqzStatus}    = Plugins::NowPlayingDisplay::Plugin::_sqzStatus();
    my $basedir = eval {
        Slim::Utils::PluginManager->allPlugins->{'NowPlayingDisplay'}->{'basedir'}
    } || '/var/lib/squeezeboxserver/cache/InstalledPlugins/Plugins/NowPlayingDisplay';
    $params->{pluginBaseDir} = $basedir;

    return $class->SUPER::handler($client, $params);
}

1;
