#!/usr/bin/env perl
# A truncated read written back is not a shorter card, it's a shorter card by
# accident.
#
# tira.ticket.show truncates a long text field at 2000 characters by default
# and marks it truncated - honestly, the flag and the true length are both in
# the payload. What was missing is any consequence of ignoring them: update
# took the short version without complaint and the tail was gone. Measured on
# TKT-386: three read-modify-write edits shrank it from 4541 to 3187 bytes,
# invisible because tira.history.list truncates the same way, so every edit
# read as "2001 -> 2001" until the same command ran with --full.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-22T00:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );

$tira->project_new(
    name => 'Truncation', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'TCS', epic_prefix => 'TCE', ticket_prefix => 'TCT',
);

my $long = ( 'x' x 1000 ) . ( 'y' x 1000 ) . 'TAIL THAT MUST SURVIVE';
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Long description',
    description => $long );

# --- writing back an untruncated read is unaffected -----------------------------

{
    my $full = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( $full->{description}, $long, 'a full read carries the whole description' );
    my $round_tripped = eval {
        $tira->record_update( author => 'claude', project => $root, type => 'ticket', ref => $card->{ref}, description => $full->{description} );
        1;
    };
    ok( $round_tripped, 'writing back a full, untruncated read is not refused' );
}

# --- the truncated read is refused on write-back ---------------------------------

my $ellipsis = "\x{2026}";
my $truncated_view = substr( $long, 0, 2000 ) . $ellipsis;

{
    my $short = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref}, truncate => 2000 );
    is( $short->{description}, $truncated_view, 'the default read is truncated at 2000 chars, ellipsis marked' );
    ok( $short->{description_truncated}, 'and honestly flagged as truncated' );

    my $error = eval {
        $tira->record_update( author => 'claude', project => $root, type => 'ticket', ref => $card->{ref}, description => $short->{description} );
        1;
    } ? '' : $@;
    like( $error, qr/--full/, 'writing the truncated read back is refused, naming --full' );

    my $unchanged = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( $unchanged->{description}, $long, 'and the stored description is untouched by the refused write' );
}

# --- a genuinely shorter description on purpose is still allowed -----------------

{
    my $deliberate = 'Rewritten from scratch, much shorter, nothing to do with the truncated tail';
    my $ok = eval {
        $tira->record_update( author => 'claude', project => $root, type => 'ticket', ref => $card->{ref}, description => $deliberate );
        1;
    };
    ok( $ok, 'a genuinely different, shorter description is allowed - this is not a length check' );
    my $now = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( $now->{description}, $deliberate, 'and the deliberate rewrite is what is stored' );
}

# --- the same protection covers problem_or_feature and solution_needed -----------
#
# _truncate_text_slot applies identically to all three LONG_TEXT_FIELD
# entries - the defect is not description-specific, and neither is the fix.

{
    my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Other long fields',
        problem_or_feature => $long, solution_needed => $long );
    my $short = $tira->record_show( project => $root, type => 'ticket', ref => $other->{ref}, truncate => 2000 );

    my $error = eval {
        $tira->record_update( author => 'claude', project => $root, type => 'ticket', ref => $other->{ref},
            problem_or_feature => $short->{problem_or_feature} );
        1;
    } ? '' : $@;
    like( $error, qr/--full/, 'the same refusal applies to problem_or_feature' );

    $error = eval {
        $tira->record_update( author => 'claude', project => $root, type => 'ticket', ref => $other->{ref},
            solution_needed => $short->{solution_needed} );
        1;
    } ? '' : $@;
    like( $error, qr/--full/, 'and to solution_needed' );
}

done_testing;

__END__

=head1 NAME

323-a-read-that-forgot-its-own-tail.t - a truncated read written back is refused, naming --full

=head1 DESCRIPTION

C<tira.ticket.show> truncates C<description>, C<problem_or_feature>, and
C<solution_needed> at 2000 characters by default, honestly marked with
C<_truncated>/C<_length>. Before this, C<record_update> accepted a truncated
read back as though it were the whole field, so a read-modify-write silently
destroyed everything past the truncation point - measured cost on TKT-386
was about 1354 bytes lost across three edits, invisible because
C<tira.history.list> truncates the same way. C<record_update> now refuses a
write whose value exactly matches a truncated read of the current value, naming
C<--full> as the fix. A genuinely shorter description, written on purpose,
is unaffected - this is not a length check, it is an exact-match check
against what a truncated read of the current value would look like.

=cut
