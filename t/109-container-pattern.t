#!/usr/bin/env perl
# A rule must not speak about other people's work.
#
# leftover-container took an age and nothing else, so on a machine that runs
# more than one project it reported all of them. The first time police could
# see containers at all - 2026-08-12, the day the world was gathered for real -
# it named eleven, including a trading terminal, two web sites and an Obsidian
# server belonging to other projects. None of them anything this board could
# act on.
#
# That is worse than untidy here. The standing rule on this machine is to leave
# other projects alone - not to read their state, restart their services or
# stop their containers - and a rule that lists them by name invites exactly
# that. And a rule reporting things nobody can act on is one everybody learns
# to read past, which is the single failure a warning system cannot survive.
#
# leftover-process already took a pattern for precisely this reason.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-12T20:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Shared machine', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SMS', epic_prefix => 'SME', ticket_prefix => 'SMT',
);
my $store = File::Spec->catdir( $tmp, 'police-state' );

# One machine, several projects - which is every machine somebody actually
# works on, and the situation the rule was written as if it never happened.
my %world = (
    branches => [], worktrees => [], processes => [], commits => [],
    containers => [
        { name => 'skills-perl-test-run-abc', started_at => '2026-08-12T17:00:00' },
        { name => 'tira-board',               started_at => '2026-08-12T17:00:00' },
        { name => 'mt5-terminal',             started_at => '2026-08-01T09:00:00' },
        { name => 'zenandi-obsidian',         started_at => '2026-08-01T09:00:00' },
        { name => 'seedwise-web',             started_at => '2026-08-01T09:00:00' },
    ],
);

sub police {
    my $result = $tira->police_pass( project => $root, store => $store, world => {%world} );
    return $result->{violations};
}

sub only_policy {
    my (%policy) = @_;
    for my $existing ( @{ $tira->policy_list( project => $root ) } ) {
        $tira->policy_remove( project => $root, id => $existing->{id} );
    }
    return $tira->policy_add( project => $root, %policy );
}

# --- a pattern is not optional --------------------------------------------
#
# Refused when it is set rather than discovered later, which is how every other
# rule treats something it cannot work without. Matching everything is never
# what anybody meant on a machine with more than one project on it.

my $refused = !eval {
    $tira->policy_add( project => $root, rule => 'leftover-container',
        age => '30m', action => 'log-only' );
    1;
};
ok( $refused, 'a container policy with no pattern is refused when it is declared' );
like( $@, qr/pattern/i, 'and says what is missing' );

# --- with one, it speaks only about this project ---------------------------

only_policy( rule => 'leftover-container', pattern => 'skills-perl-test',
    age => '30m', action => 'log-only' );

my $mine = police();
is( scalar @{$mine}, 1, 'only the container this project started is reported' );
like( $mine->[0]{detail}, qr/skills-perl-test-run-abc/, 'and it is named' );

for my $someone_else (qw(mt5-terminal zenandi-obsidian seedwise-web)) {
    unlike( $mine->[0]{detail}, qr/\Q$someone_else\E/,
        "nothing is said about $someone_else, which belongs to another project" );
}

# --- the age still means what it meant -------------------------------------

only_policy( rule => 'leftover-container', pattern => 'mt5',
    age => '30d', action => 'log-only' );
is( scalar @{ police() }, 0,
    'a matching container younger than the age is still left alone' );

only_policy( rule => 'leftover-container', pattern => 'nothing-is-called-this',
    age => '30m', action => 'log-only' );
is( scalar @{ police() }, 0, 'and a pattern nothing matches reports nothing' );

# --- more than one container can match -------------------------------------

only_policy( rule => 'leftover-container', pattern => '-',
    age => '30m', action => 'log-only' );
my $several = police();
is( scalar @{$several}, 5,
    'a pattern that fits several reports each of them, so nothing is hidden by the narrowing' );

done_testing();

__END__

=head1 NAME

109-container-pattern.t - a rule must not speak about other people's work

=head1 DESCRIPTION

leftover-container took an age and nothing else, so on a machine running more
than one project it reported all of them. The first time police could see
containers at all it named eleven, most belonging to other projects entirely.

The standing rule on this machine is to leave other projects alone, and a rule
that lists their containers by name invites the opposite. It now takes a
pattern, as leftover-process always has, and refuses to be declared without
one - because matching everything is never what somebody meant.

=cut
