package App::resolvetable;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

use Color::ANSI::Util qw(ansifg);
use Time::HiRes qw(time);

our %SPEC;

# colorize majority values with green, minority values with red
sub _colorize_maj_min {
    my $hash = shift;

    my %freq;
    my @keys = keys %$hash;
    for (@keys) {
        next unless defined $hash->{$_};
        next if $_ eq 'name';
        $freq{ $hash->{$_} }++;
    }
    my @vals_by_freq = sort { $freq{$b} <=> $freq{$a} } keys %freq;

    # no defined values
    return unless @vals_by_freq;

    my $green = "33cc33";
    my $red   = "33cc33";

    my %colors_by_val;
    my $freq;
    my $decreased;
    for my $val (@vals_by_freq) {
        if (!defined $freq) {
            $freq = $freq{$val};
            $colors_by_val{$val} = $green;
            next;
        }
        if (!$decreased) {
            if ($freq > $freq{$val}) {
                $decreased++;
            }
        }
        $colors_by_val{$val} = $decreased ? $red : $green;
    }
    for (@keys) {
        my $val = $hash->{$_};
        next unless defined $val;
        next if $_ eq 'name';
        $hash->{$_} = ansifg($colors_by_val{$val}) . $hash->{$_} . "\e[0m";
    }
}

# colorize the shortest time with green
sub _colorize_shortest_time {
    my $hash = shift;
    no warnings 'numeric';

    my %time;
    my @keys = keys %$hash;
    for (@keys) {
        next unless defined $hash->{$_};
        next if $_ eq 'name';
        my $time =
            $hash->{$_} =~ /^\s*</ ? 0.01 :
            $hash->{$_} =~ /^\s*>/ ? 4001 : $hash->{$_}+0;
        $time{ $hash->{$_} } = $time;
    }
    my @times_from_shortest = sort { $time{$a} <=> $time{$b} } keys %time;

    # no defined values
    return unless @times_from_shortest;

    my $green = "33cc33";

    for (@keys) {
        my $val = $hash->{$_};
        next unless defined $val;
        next if $_ eq 'name';
        $hash->{$_} = ansifg($green) . $hash->{$_} . "\e[0m"
            if $hash->{$_} eq $times_from_shortest[0];
    }
}

sub _mark_undef_with_x {
    my $row = shift;
    for (keys %$row) {
        next if $_ eq 'name';
        next if defined $row->{$_};
        $row->{$_} = ansifg("ff0000")."X"."\e[0m";
    }
}

$SPEC{'resolvetable'} = {
    v => 1.1,
    summary => 'Produce a colored table containing DNS resolve results of '.
        'several names from several servers/resolvers',
    args => {
        action => {
            schema => ['str*', in=>[qw/show-addresses show-timings/]],
            default => 'show-addresses',
            cmdline_aliases => {
                timings => {is_flag=>1, summary=>'Shortcut for --action=show-timings', code=>sub { $_[0]{action} = 'show-timings' }},
            },
            description => <<'_',

The default action is to show resolve result (`show-addresses`). If set to
`show-timings`, will show resolve times instead to compare speed among DNS
servers/resolvers.

_
        },
        servers => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'server',
            schema => ['array*', of=>'str*'], # XXX hostname
            cmdline_aliases => {s=>{}},
            req => 1,
        },
        names => {
            'x.name.is_plural' => 1,
            'x.name.singular' => 'name',
            schema => ['array*', of=>'str*'],
            cmdline_src => 'stdin_or_args',
            req => 1,
            pos => 0,
            slurpy => 1,
        },
        type => {
            summary => 'Type of DNS record to query',
            schema => ['str*'],
            default => 'A',
            cmdline_aliases => {t=>{}},
        },
        colorize => {
            schema => 'bool*',
        },
    },
    examples => [
        {
            src => 'cat names.txt | [[prog]] --colorize -s 8.8.8.8 -s my.dns.server -s my2.dns.server',
            src_plang => 'bash',
            test => 0,
            'x.doc.show_result' => 0,
        },
    ],
};
sub resolvetable {
    require Net::DNS::Async;

    my %args = @_;
    my $type = $args{type} // "A";
    my $names   = $args{names};
    my $servers = $args{servers};
    my $action  = $args{action} // 'show-addresses';

    my %res;       # key=name, val={server=>result, ...}
    my %starttime; # key=name, val={server=>time, ...}
    my %endtime  ; # key=name, val={server=>time, ...}

    log_info "Resolving ...";
    my $resolver = Net::DNS::Async->new(QueueSize => 30, Retries => 2);
    for my $name (@$names) {
        for my $server (@$servers) {
            $starttime{$name}{$server} = time();
            $resolver->add({
                Nameservers => [$server],
                Callback    => sub {
                    my $time = time();
                    my $pkt = shift;
                    return unless defined $pkt;
                    my @rr = $pkt->answer;
                    for my $r (@rr) {
                        my $k = $r->owner;
                        $res{ $k }{$server} //= "";
                        $res{ $k }{$server} .=
                            (length($res{ $k }{$server}) ? ", ":"") .
                            $r->address
                            if $r->type eq $type;
                        $endtime{$name}{$server} //= $time;
                    }
                },
            }, $name, $args{type});
        }
    }
    $resolver->await;

    log_trace "Returning table result ...";
    my @rows;
    for my $name (@$names) {
        my $row;
        if ($action eq 'show-addresses') {
            $row = {
                name => $name,
                map { $_ => $res{$name}{$_} } @$servers,
            };
            _colorize_maj_min($row) if $args{colorize};
            _mark_undef_with_x($row) if $args{colorize};
        } elsif ($action eq 'show-timings') {
            $row = {
                name => $name,
                map {
                    my $server = $_;
                    my $starttime = $starttime{$name}{$_};
                    my $endtime   = $endtime{$name}{$_};
                    my $val;
                    if (defined $endtime) {
                        my $ms = ($endtime - $starttime)*1000;
                        if ($ms > 4000) {
                            $val = ">4000ms";
                        } elsif ($ms <= 0.5) {
                            $val = "<=0.5ms";
                        } else {
                            $val = sprintf("%3.0fms", $ms);
                        }
                    } else {
                        $val = undef;
                    }
                    ($server => $val);
                } @$servers,
            };
        } else {
            die "Unknown action '$action'";
        }
        _colorize_shortest_time($row) if $args{colorize};
        _mark_undef_with_x($row)      if $args{colorize};
        push @rows, $row;
    }

    [200, "OK", \@rows, {'table.fields'=>['name', @$servers]}];
}

1;
# ABSTRACT:
