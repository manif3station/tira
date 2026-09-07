#!/usr/bin/env perl
# TKT-981. Found while implementing TKT-951, running its own checklist item
# about newline round-tripping - not by a report.
#
# _bridge_line (lib/Tira.pm) used to interpolate a violation's detail
# verbatim into the line it composes. Reproduced in tira:latest: a job-due
# violation whose message carried three newlines and a blank line rendered
# as four physical lines on the bridge, one of them blank - and every
# reader of the bridge (the policy bridge itself, the dashboard Bridge
# panel, an agent parsing one violation per line) splits on newlines, so
# the continuation lines reached each of them as malformed entries
# belonging to no violation.
#
# THE ROUND TRIP MUST STAY CORRECT. This is a rendering fix, not a storage
# one - a job message is a hunt instruction the agent acts on and is
# legitimately long, so the record itself has to keep every newline exactly
# as written.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $tira  = Tira->new( clock => sub {'2026-09-07T09:00:00Z'} );
my $store = File::Spec->catdir( $tmp, 'store' );

my $multiline = "First line of the hunt.\nSecond line, after a newline.\n\nFourth line after a blank one.";

# --- the composed bridge line is exactly one line ----------------------------
#
# _bridge_line directly, the way t/108 exercises bridge_write directly - this
# is the one place that knows the composed thing has to be a line, so it is
# what is driven rather than the rule that happens to produce the detail.

{
    # Counted before and after, and the DELTA is what proves the claim - a
    # backlog line grep on the violation's own id is trivially 1 either way,
    # since only the id-bearing line ever matches that pattern; the three
    # continuation lines the bug used to add carry no id and would pass
    # that check silently while still being there, unattributed, in the
    # file. TKT-981's own acceptance criterion is about the LINE COUNT one
    # violation costs the file, so that is what has to be measured.
    #
    # A harmless first write seeds the store before either count: bridge_
    # backlog prefixes a one-time "replaying N outstanding..." header on a
    # store's first ever read, which would otherwise show up as a false
    # +1 on "before" alone and make the delta look one line too many.
    $tira->bridge_write( store => $store, violations => [
        { id => 'VIO-0000', ref => 'TKT-000', rule => 'card-stalled',
            detail => 'seed', action => 'bridge-reminder', tone => 'note' } ] );
    my $before = scalar @{ $tira->bridge_backlog( store => $store, lines => 1000 ) };

    my $written = $tira->bridge_write(
        store => $store,
        violations => [
            { id => 'VIO-0001', ref => 'JOB-001', rule => 'job-due',
                detail => $multiline, action => 'bridge-reminder', tone => 'note' },
        ],
    );
    is( $written, 1, 'the violation is written' );

    my $backlog = $tira->bridge_backlog( store => $store, lines => 1000 );
    my $after = scalar @{$backlog};
    is( $after - $before, 1,
        'one violation, however many lines its own detail spans, costs the backlog exactly one line' )
      or diag( 'backlog now: ' . join( "\n---\n", @{$backlog} ) );

    my @entries = grep { /VIO-0001/ } @{$backlog};
    is( scalar @entries, 1, 'and its own id-bearing line is findable' );
    like( $entries[0] // '', qr/\S/, 'and it is there to be read' );
    like( $entries[0] // '', qr/First line of the hunt\. Second line, after a newline\. Fourth line after a blank one\./,
        'the detail survives, whitespace-collapsed rather than dropped' );
}

# --- a blank-line-only detail does not become an empty entry -----------------

{
    my $store2 = File::Spec->catdir( $tmp, 'store2' );
    $tira->bridge_write( store => $store2, violations => [
        { id => 'VIO-0000', ref => 'TKT-000', rule => 'card-stalled',
            detail => 'seed', action => 'bridge-reminder', tone => 'note' } ] );
    my $before = scalar @{ $tira->bridge_backlog( store => $store2, lines => 1000 ) };
    $tira->bridge_write(
        store => $store2,
        violations => [
            { id => 'VIO-0002', ref => 'JOB-002', rule => 'job-due',
                detail => "\n\n\n", action => 'bridge-reminder', tone => 'note' },
        ],
    );
    my $backlog = $tira->bridge_backlog( store => $store2, lines => 1000 );
    is( scalar( @{$backlog} ) - $before, 1,
        'an all-whitespace detail still costs exactly one line, not three blank ones' );
    my @entries = grep { /VIO-0002/ } @{$backlog};
    is( scalar @entries, 1, 'and its own id-bearing line is findable' );
    like( $entries[0] // '', qr/unspecified/,
        'an all-whitespace detail collapses to nothing worth showing, so it falls back to the '
          . 'same "unspecified" an absent detail already uses elsewhere in this sub - not '
          . 'fabricated content, the same honest placeholder' );
}

# --- an ordinary single-line detail is unchanged -----------------------------

{
    my $store3 = File::Spec->catdir( $tmp, 'store3' );
    $tira->bridge_write(
        store => $store3,
        violations => [
            { id => 'VIO-0003', ref => 'TKT-001', rule => 'card-stalled',
                detail => 'an ordinary single-line detail', action => 'bridge-reminder', tone => 'note' },
        ],
    );
    my $backlog = $tira->bridge_backlog( store => $store3, lines => 10 );
    my @entries = grep { /VIO-0003/ } @{$backlog};
    is( scalar @entries, 1, 'one entry, as always' );
    like( $entries[0] // '', qr/an ordinary single-line detail/,
        'byte-identical to what an unchanged single-line detail always rendered' );
}

# --- and the stored job message keeps its newlines ---------------------------
#
# The round trip this whole card is careful not to break.

{
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new( name => 'Roundtrip', dir => $root, members => ['claude'],
        columns => ['backlog, done'], sow_prefix => 'RTS', epic_prefix => 'RTE', ticket_prefix => 'RTT' );
    mkdir File::Spec->catdir( $root, '.git' );
    my $job = $tira->job_add( project => $root, schedule => '0 * * * *', message => $multiline );
    my ($stored) = grep { $_->{id} eq $job->{id} } @{ $tira->job_list( project => $root ) };
    is( $stored->{message}, $multiline,
        'the stored job message is byte-identical, newlines included - this fix must not touch it' );
}

done_testing();

__END__

=head1 NAME

590-a-violation-that-became-four-lines.t - a bridge violation is always one line

=head1 DESCRIPTION

TKT-981. A violation's detail carrying newlines used to interpolate verbatim
into C<_bridge_line>'s composed line, so a job message with newlines and a
blank line reached every bridge reader (the policy bridge, the dashboard
Bridge panel, an agent parsing one violation per line) as several malformed
entries belonging to no violation, one of them empty.

This holds the fix in place: C<_bridge_line> collapses whitespace in the
detail as the line is composed, so any source - not only a job message - is
covered, while the stored record (a job's own message, in particular) keeps
every newline exactly as written.

=cut
