package App::resolvetable;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;
use Log::ger;

our %SPEC;

$SPEC{'resolvetable'} = {
    v => 1.1,
    summary => 'Produce a colored table containing DNS resolve results of '.
        'several names from several servers',
    args => {
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
    },
};
sub resolvetable {
    require Net::DNS::Async;

    my %args = @_;
    my $type = $args{type} // "A";
    my $names   = $args{names};
    my $servers = $args{servers};

    my %res; # key=name, val={server=>result, ...}

    log_info "Resolving ...";
    my $resolver = Net::DNS::Async->new(QueueSize => 30, Retries => 2);
    for my $name (@$names) {
        for my $server (@$servers) {
            $resolver->add({
                Nameservers => [$server],
                Callback    => sub {
                    my $pkt = shift;
                    my @rr = $pkt->answer;
                    for my $r (@rr) {
                        use DD; dd $r;
                        my $k = $r->owner;
                        $res{ $k }{$server} //= "";
                        $res{ $k }{$server} .=
                            (length($res{ $k }{$server}) ? ", ":"") .
                            $r->address
                            if $r->type eq $type;
                    }
                },
            }, $name, $args{type});
        }
    }
    $resolver->await;

    log_trace "Returning table result ...";
    my @res;
    for my $name (@$names) {
        push @res, {
            name => $name,
            map { $_ => $res{$name}{$_} } @$servers,
        };
    }

    [200, "OK", \@res, {'table.fields'=>['name']}];
}

1;
# ABSTRACT:
