#!/usr/bin/env perl

# TKT-771. column_rename's required_items retag walk (lib/Tira.pm, TKT-613)
# renames the column directory and its config entry inside the project
# lock, THEN walks every record under the board rewriting any stale
# required_items column tag. Filed by Codex review during TKT-613's own
# verify gate: if one record on that walk cannot be read - corrupt JSON, a
# permission error, anything _json_from_content or _replace_record throws
# on - File::Find::find's own wanted callback dies uncaught, which aborts
# the ENTIRE walk. Every record File::Find had not reached yet is left
# with its stale column tag, invisible to the push/departure gate, and the
# caller gets no report of which refs did not retag - the directory and
# config rename have already committed by this point, so there is nothing
# to roll back to either.
#
# Michael's answer (Q-160/Q-161, both marked ok): make the retag loop
# resilient - catch a per-record failure, continue the walk, and report
# which refs failed to retag.
#
# WRITTEN RED: before this ticket, one corrupt record file aborts the walk
# after retagging it (or not, depending on where the corruption hits) and
# every later record silently keeps its stale tag - column_rename's return
# carries no field naming what failed.

use strict;
use warnings;

use Cpanel::JSON::XS ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-16T00:00:00Z'} );

$tira->project_new(
    name => 'Retagged', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'review', 'done' ],
    sow_prefix => 'RTS', epic_prefix => 'RTE', ticket_prefix => 'RTT',
);

my @good;
for my $title (qw(First Second Third)) {
    my $record = $tira->create_record( project => $root, type => 'ticket', title => $title );
    $tira->record_move( project => $root, ref => $record->{ref}, type => 'ticket', column => 'review', author => 'claude' );
    $tira->required_item_add(
        project => $root, ref => $record->{ref}, type => 'ticket', column => 'review',
        item => "Check $title", status => 'pending', author => 'claude',
    );
    push @good, $record->{ref};
}

# Corrupt one record file directly on disk, between the good ones - File::Find
# walks in directory order, which on most filesystems is not creation order,
# so this is not relying on the corrupt one being walked last.
my $corrupt_file = File::Spec->catfile( $root, '.tira', 'ticket', 'review', "$good[1].json" );
ok( -f $corrupt_file, 'found the second record\'s own file to corrupt' )
  or diag "corrupt_file=$corrupt_file good=@good";

open my $fh, '>', $corrupt_file or die "Cannot write '$corrupt_file': $!";
print {$fh} '{ this is not valid json';
close $fh;

my $result = $tira->column_rename( project => $root, type => 'ticket', name => 'review', new_name => 'verify' );

for my $ref ( $good[0], $good[2] ) {
    my $after = $tira->record_show( project => $root, ref => $ref, type => 'ticket' );
    my ($tagged) = grep { $_->{item} =~ /^Check / } @{ $after->{required_items} // [] };
    is( $tagged->{column}, 'verify',
        "$ref retagged to the new column name despite the corrupt record between it and its siblings" );
}

ok( exists $result->{retag_failed}, 'column_rename reports which refs failed to retag' )
  or diag explain $result;
is_deeply( $result->{retag_failed}, [ $good[1] ],
    'naming exactly the ref whose record could not be read - not silently dropped, not the whole walk' );

is( $result->{name}, 'verify', 'the column itself still renamed successfully - a stale record does not undo that' );

# --- a record whose own content names a DIFFERENT ref than its filename ----
#
# Codex review, TKT-771: writing back by the record's own embedded ref
# rather than the filename the walk just read would send _replace_record
# looking for a different file entirely on a mismatch - this proves the
# walk refuses that rather than writing to the wrong card.

{
    my $record4 = $tira->create_record( project => $root, type => 'ticket', title => 'Fourth' );
    $tira->record_move( project => $root, ref => $record4->{ref}, type => 'ticket', column => 'verify', author => 'claude' );
    $tira->required_item_add(
        project => $root, ref => $record4->{ref}, type => 'ticket', column => 'verify',
        item => 'Check Fourth', status => 'pending', author => 'claude',
    );
    my $record4_file = File::Spec->catfile( $root, '.tira', 'ticket', 'verify', "$record4->{ref}.json" );

    # Claims to BE an existing, real record - $good[0] - rather than a ref
    # that simply does not exist, so a version of the guard that only
    # checked "does the embedded ref resolve to a file" rather than "does
    # it match the file actually being read" would still be proved wrong.
    my $victim = $tira->record_show( project => $root, ref => $record4->{ref}, type => 'ticket' );
    $victim->{ref} = $good[0];
    open my $fh, '>', $record4_file or die "Cannot write '$record4_file': $!";
    print {$fh} Cpanel::JSON::XS->new->canonical->encode($victim);
    close $fh;

    # Captured AFTER the corruption above, not before it - the assertion
    # below is that column_rename's own walk left this file untouched, not
    # that this test's own setup did.
    open my $before_fh, '<', $record4_file or die "Cannot read '$record4_file': $!";
    my $before_content = do { local $/; <$before_fh> };
    close $before_fh;

    my $good0_file = File::Spec->catfile( $root, '.tira', 'ticket', 'verify', "$good[0].json" );
    open my $good0_before_fh, '<', $good0_file or die "Cannot read '$good0_file': $!";
    my $good0_before_content = do { local $/; <$good0_before_fh> };
    close $good0_before_fh;

    my $second_rename = $tira->column_rename( project => $root, type => 'ticket', name => 'verify', new_name => 'signed-off' );
    ok( ( grep { $_ eq $record4->{ref} } @{ $second_rename->{retag_failed} } ),
        "the mismatched file's own filename ref is reported failed - not the ref (an existing OTHER card) it wrongly claims to be" )
      or diag explain $second_rename->{retag_failed};

    my $record4_file_now = File::Spec->catfile( $root, '.tira', 'ticket', 'signed-off', "$record4->{ref}.json" );
    open my $raw, '<', $record4_file_now or die "Cannot read '$record4_file_now': $!";
    my $raw_content = do { local $/; <$raw> };
    close $raw;
    is( $raw_content, $before_content,
        'the mismatched file itself is byte-identical to before the rename - refusing means refusing, not writing anyway' );

    my $good0_file_now = File::Spec->catfile( $root, '.tira', 'ticket', 'signed-off', "$good[0].json" );
    open my $good0_raw, '<', $good0_file_now or die "Cannot read '$good0_file_now': $!";
    my $good0_raw_content = do { local $/; <$good0_raw> };
    close $good0_raw;
    isnt( $good0_raw_content, $good0_before_content,
        "the OTHER card the mismatched file claimed to be - $good[0], the actual target a naive fix would have "
          . 'overwritten - genuinely was retagged by its own real file, untouched by record4\'s corruption' );
}

done_testing;

__END__

=head1 NAME

1107-a-walk-that-quit-on-the-first-bad-file.t - column_rename's retag walk survives one bad record

=head1 WHY

TKT-771, filed by Codex review during TKT-613's own verify gate: the
required_items retag walk that TKT-613 added dies on the first record it
cannot read, aborting silently for everything File::Find had not reached
yet, with no report of what failed. Michael's answer (Q-160/Q-161): make
the walk resilient, continue past a per-record failure, and report which
refs did not retag.

=head1 WHAT IS ASSERTED

A corrupt record between two good ones does not stop the good ones from
being retagged, the corrupt one's own ref is reported back in a new
C<retag_failed> field, and the column rename itself still succeeds - a bad
record file does not undo the directory/config rename that already
committed before the walk started.

=cut
