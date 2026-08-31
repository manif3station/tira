#!/usr/bin/env perl
# A checklist's completion was computed by hand, every read, though the tool
# holds every status it would need - checklist[10]{...} already names the
# TOTAL in the array header, and nothing names how many of those are done.
# The same three-line manual count (sum(status=='done') over len(checklist))
# was run by hand at least six times in one session. TKT-407.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Counted', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'CKS', epic_prefix => 'CKE', ticket_prefix => 'CKT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Mixed checklist' );

# A known, deliberate mix - 4 done, 6 todo, one of the done ones ticked with
# an uppercase status, the same case-insensitivity checklist-idle and
# card-stalled already apply.
for my $i ( 1 .. 3 ) {
    $tira->checklist_add( project => $root, author => 'claude', ref => $card->{ref},
        item => "done item $i", status => 'done' );
}
$tira->checklist_add( project => $root, author => 'claude', ref => $card->{ref},
    item => 'done item 4, uppercase', status => 'DONE' );
for my $i ( 1 .. 6 ) {
    $tira->checklist_add( project => $root, author => 'claude', ref => $card->{ref},
        item => "todo item $i", status => 'To Do' );
}

# --- the count is present and correct on a mixed checklist ------------------

{
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( scalar @{ $shown->{checklist} }, 10, 'the existing checklist array is unchanged - still 10 rows' );
    is( $shown->{checklist_done}, 4, 'checklist_done counts the 4 done rows, uppercase status included' );
    is( $shown->{checklist_total}, 10, 'checklist_total matches the array length' );
}

# --- ticket.list reports the same pair -----------------------------------

{
    my $listed = $tira->record_list( project => $root, type => 'ticket' );
    my ($row) = grep { $_->{ref} eq $card->{ref} } @{$listed};
    is( $row->{checklist_done}, 4, 'ticket.list reports the same done count' );
    is( $row->{checklist_total}, 10, 'and the same total' );
}

# --- a card with no checklist reads cleanly, not an error --------------------

{
    my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'No checklist' );
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $bare->{ref} );
    is( $shown->{checklist_done}, 0, 'a checklist-less card reports 0 done' );
    is( $shown->{checklist_total}, 0, 'and 0 total, not an error' );
}

# --- the count is never written back to disk ---------------------------------
#
# record_show(%args) is the "before" object nearly every mutation in this
# file reads, modifies, and hands to _replace_record - comment_add among
# them. Adding checklist_done/checklist_total unconditionally to
# record_show's return value meant the very first comment added to any
# card persisted them to the stored JSON and journaled two spurious
# "changed" entries, discovered only because an unrelated rule (t/173)
# went red reading the journal it polluted.

{
    $tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'A comment' );
    my $path = ( glob "$root/.tira/ticket/*/$card->{ref}.json" )[0];
    open my $fh, '<:raw', $path or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    like( $raw, qr/"ref"\s*:\s*"$card->{ref}"/, 'the stored file was actually read - not an empty denial' );
    unlike( $raw, qr/checklist_done|checklist_total/,
        'checklist_done/checklist_total never reach the stored JSON, however many mutations round-trip a read' );

    my $journal = "$root/.tira/history/$card->{ref}.jsonl";
    open my $jfh, '<:raw', $journal or die $!;
    my $entries = do { local $/; <$jfh> };
    close $jfh;
    like( $entries, qr/"field":"title"/, 'the journal was actually read too - not an empty denial' );
    unlike( $entries, qr/"field":"checklist_(?:done|total)"/,
        'and no spurious journal entry is written for either' );
}

# --- break it: omit the field and watch the count fail, not the array -------

{
    no warnings 'redefine';
    local *Tira::_checklist_progress = sub { return; };
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( scalar @{ $shown->{checklist} }, 10, 'with the count omitted, the checklist array assertion still passes' );
    ok( !defined $shown->{checklist_done}, 'but the count assertion would now fail - proving it tests the count, not the array' );
}

done_testing;

__END__

=head1 NAME

361-a-count-nobody-had-to-fold.t - checklist_done/checklist_total ride alongside checklist

=head1 DESCRIPTION

A checklist's completion was computed by hand on every read - the array
header already named the total, but nothing named how many were done. This
proves C<checklist_done>/C<checklist_total> are correct on a mixed
checklist (case-insensitive C<done>, matching card-stalled's own
convention), present the same way on C<ticket.list>, read cleanly as 0/0
on a checklist-less card, and that omitting the computation breaks the
count assertion while leaving the existing checklist array untouched.

=cut
