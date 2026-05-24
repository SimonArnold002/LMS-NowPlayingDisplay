package Plugins::NowPlayingDisplay::Settings;

# Plugin settings page — lives under Settings → Advanced → Now Playing
# Display in the LMS web UI.

use strict;
use warnings;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.nowplayingdisplay');
my $prefs = preferences('plugin.nowplayingdisplay');

sub name {
    return 'PLUGIN_NOWPLAYINGDISPLAY';
}

sub page {
    return 'plugins/NowPlayingDisplay/settings/basic.html';
}

sub prefs {
    # Note: vizPresets and vizPlayerMap are intentionally NOT listed here. They
    # are not simple pref_<name> form fields — we parse and save them manually
    # in handler() from the dynamic preset_name_N / assign_<id> fields. Listing
    # them here would make the parent handler try to save them from absent
    # pref_ fields and wipe our values.
    return ($prefs, qw(defaultMode scrollSpeed enableVisualizer vizDelayMs vizSmoothing));
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

    # Legacy/global default offset.
    if (exists $params->{pref_vizDelayMs}) {
        $params->{pref_vizDelayMs} = $clampMs->($params->{pref_vizDelayMs});
    }

    # On save, parse the dynamic preset rows and per-player assignments out of
    # the form. We detect a submission by the presence of our own fields rather
    # than relying on a specific save-flag name (which varies), so this fires on
    # any POST that includes the preset editor.
    my $submitted = 0;
    for my $k (keys %$params) {
        if ($k =~ /^preset_name_\d+$/ || $k =~ /^assign_/) { $submitted = 1; last; }
    }
    if ($submitted) {
        eval {
            my @presets;
            my %seen;
            for my $k (keys %$params) {
                next unless $k =~ /^preset_name_(\d+)$/;
                my $i = $1;
                my $name = $params->{"preset_name_$i"};
                $name =~ s/^\s+|\s+$//g if defined $name;
                next if !defined $name || $name eq '';
                next if $seen{$name}++;             # unique names
                my $ms = $clampMs->($params->{"preset_ms_$i"});
                push @presets, { name => $name, ms => $ms };
            }
            $prefs->set('vizPresets', \@presets);

            my %pmap;
            my %validName = map { $_->{name} => 1 } @presets;
            for my $k (keys %$params) {
                next unless $k =~ /^assign_(.+)$/;
                my $pid = $1;
                my $sel = $params->{$k};
                next if !defined $sel || $sel eq '' || !$validName{$sel};
                $pmap{$pid} = $sel;
            }
            $prefs->set('vizPlayerMap', \%pmap);
        };
        $log->error("NowPlayingDisplay preset save failed: $@") if $@;
    }

    # Build data for the template: players (with current assignment) + presets.
    my $pmap    = $prefs->get('vizPlayerMap') || {};
    my $presets = $prefs->get('vizPresets')   || [];
    my @players;
    for my $c (Slim::Player::Client::clients()) {
        push @players, {
            name     => $c->name,
            id       => $c->id,
            assigned => $pmap->{$c->id} // '',
        };
    }
    @players = sort { lc($a->{name}) cmp lc($b->{name}) } @players;
    $params->{players}    = \@players;
    $params->{vizPresets} = $presets;

    return $class->SUPER::handler($client, $params);
}

1;
