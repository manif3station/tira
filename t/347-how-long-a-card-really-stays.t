#!/usr/bin/env perl
# Every card's journal already records field=column for both its creation
# (op=create, before=null) and every later move - the board already knows
# exactly how long work spends in each column, and nothing aggregated it.
# Every card-duration threshold on this board was picked by hand and never
# checked against what the board itself records. TKT-366.
#
# dwell_report is dwell_list's historical sibling: dwell_list (tira.stale)
# answers "how long has this card sat here NOW"; this answers "how long
# does a card usually stay here" - median, p90, max, from completed passes.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-23T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Dwelling', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'DWS', epic_prefix => 'DWE', ticket_prefix => 'DWT',
);

sub at { $now = $_[0]; return $now; }

# --- card A: one clean pass, still resting in its current column -----------
#
# backlog 100s, implement 300s, verify 50s, then into done - where it still
# sits, so done contributes nothing: that span is not a completed pass.

at('2026-08-23T09:00:00Z');
my $a = $tira->create_record( project => $root, type => 'ticket', title => 'A' );
at('2026-08-23T09:01:40Z');    # +100s
$tira->record_move( author => 'claude', project => $root, ref => $a->{ref}, column => 'implement' );
at('2026-08-23T09:06:40Z');    # +300s
$tira->record_move( author => 'claude', project => $root, ref => $a->{ref}, column => 'verify' );
at('2026-08-23T09:07:30Z');    # +50s
$tira->record_move( author => 'claude', project => $root, ref => $a->{ref}, column => 'done' );

# --- card B: revisits implement and verify - both passes must count --------
#
# backlog 200s, implement 400s (first visit), verify 10s (first visit, brief),
# implement 700s (second visit), then back into verify - where it still
# sits, so that second verify visit is not a completed pass either.

at('2026-08-23T09:00:00Z');
my $b = $tira->create_record( project => $root, type => 'ticket', title => 'B' );
at('2026-08-23T09:03:20Z');    # +200s
$tira->record_move( author => 'claude', project => $root, ref => $b->{ref}, column => 'implement' );
at('2026-08-23T09:10:00Z');    # +400s
$tira->record_move( author => 'claude', project => $root, ref => $b->{ref}, column => 'verify' );
at('2026-08-23T09:10:10Z');    # +10s
$tira->record_move( author => 'claude', project => $root, ref => $b->{ref}, column => 'implement' );
at('2026-08-23T09:21:50Z');    # +700s
$tira->record_move( author => 'claude', project => $root, ref => $b->{ref}, column => 'verify' );

# --- card C: never moved - contributes nothing to anything ------------------

at('2026-08-23T09:00:00Z');
$tira->create_record( project => $root, type => 'ticket', title => 'C' );

my $report = $tira->dwell_report( project => $root, type => 'ticket' );
my %by_column = map { $_->{column} => $_ } @{$report};

is( scalar @{$report}, 3, 'backlog, implement and verify each report - done and the still-open verify visit do not' );

is( $by_column{backlog}{count}, 2, 'two completed backlog passes (A and B)' );
is( $by_column{backlog}{median_seconds}, 100, 'the smaller of 100 and 200, by nearest-rank' );
is( $by_column{backlog}{max_seconds}, 200, 'and the larger is the max' );

is( $by_column{implement}{count}, 3, 'three completed implement passes: A once, B twice' );
is( $by_column{implement}{median_seconds}, 400, 'the middle of 300/400/700 by nearest-rank' );
is( $by_column{implement}{max_seconds}, 700, 'and the max is the longest revisit' );

is( $by_column{verify}{count}, 2, 'two completed verify passes: A once, B once - not B\'s still-open second visit' );
is( $by_column{verify}{median_seconds}, 10, 'the smaller of 10 and 50' );
is( $by_column{verify}{max_seconds}, 50, 'and the larger is the max' );

ok( !exists $by_column{done}, 'done has no completed pass yet, so it does not appear at all' );

# --- p90 --------------------------------------------------------------------

is( $by_column{implement}{p90_seconds}, 700, 'p90 of three values, nearest-rank, is the top one' );

# --- a card whose journal does not begin with its own creation --------------
#
# Simulates a card predating journaling: the opening span (backlog, in this
# case) is unmeasurable and must be excluded rather than invented, the same
# principle dwell_list already applies to a card with no journal at all.

{
    my $legacy = $tira->create_record( project => $root, type => 'ticket', title => 'Legacy' );
    at('2026-08-23T09:05:00Z');    # +300s in backlog, which will be dropped
    $tira->record_move( author => 'claude', project => $root, ref => $legacy->{ref}, column => 'implement' );
    at('2026-08-23T09:15:00Z');    # +600s in implement, which must still count
    $tira->record_move( author => 'claude', project => $root, ref => $legacy->{ref}, column => 'verify' );

    my $path = $tira->_journal_path( $root, $legacy->{ref} );
    open my $fh, '<:raw', $path or die $!;
    my @lines = <$fh>;
    close $fh;
    @lines = grep { index( $_, '"op":"create"' ) < 0 } @lines;
    open my $out, '>:raw', $path or die $!;
    print {$out} @lines;
    close $out;

    my $legacy_report = $tira->dwell_report( project => $root, type => 'ticket' );
    my %legacy_by_column = map { $_->{column} => $_ } @{$legacy_report};

    is( $legacy_by_column{backlog}{count}, 2,
        "the legacy card's opening backlog span is excluded - still only A and B's two passes" );
    is( $legacy_by_column{implement}{count}, 4,
        "but its implement span, which is bounded by two real entries, still counts - "
          . 'the three from before plus this one' );
}

# --- and the command a caller actually types --------------------------------

{
    use Tira::CLI;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'dwell.report', tira => $tira,
                argv => [ '--type', 'ticket', '-o', 'json' ] );
        };
    };
    is( $status, 0, 'tira.dwell.report answers, scoped to one board' );
    my $said = Tira::json_decode($out);
    ok( ( grep { $_->{column} eq 'implement' } @{$said} ),
        'and reports the same columns the engine method does' );
}

{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'dwell.report', tira => $tira, argv => [ '-o', 'json' ] );
        };
    };
    is( $status, 0, 'and with no --type, answers across every board' );
}

done_testing;

__END__

=head1 NAME

347-how-long-a-card-really-stays.t - median, p90 and max dwell per column, from real history

=head1 DESCRIPTION

Every card's journal already records when it entered and left each column;
nothing aggregated that into a reading a person or a policy threshold could
use. C<dwell_report> computes median/p90/max/count per column per type from
completed passes only - a card's current column is not a completed pass and
is excluded, and a card whose journal does not begin with its own creation
has its unmeasurable opening span excluded rather than invented, the same
principle C<dwell_list> already applies to a card with no journal at all.

=cut
