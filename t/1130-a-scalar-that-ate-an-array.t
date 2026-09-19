#!/usr/bin/env perl
# TKT-1130: `record_update`'s generic setter for evidence/attachments/
# gate_passing_log wrote whatever it was given straight into the record,
# with no check that it was actually the array-of-hashrefs shape every
# reader expects. `--evidence` is the one of the three with a real CLI
# flag; `attachments`/`gate_passing_log` have none but are the same
# recognised, corruptible keys for a direct Perl caller. A plain string
# (what the CLI always hands `--evidence` through as, since it never
# builds an arrayref from an option value) corrupted the field silently:
# `ticket.update` returned success and printed the card back, and every
# later `ticket.show` died with "Can't use string (...) as an ARRAY ref
# while strict refs in use". Self-caught live 2026-09-19 on TKT-1028's own
# production record while trying to attach a push-gate evidence summary
# that way.
#
# record_clone legitimately passes a real ARRAY ref of attachment hashrefs
# through this same path (TKT-609) - that case must keep working.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-19T00:00:00Z'} );
$tira->project_new( name => 'Proj', dir => $root, members => ['claude'] );

my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card', author => 'claude',
    description => 'd', problem_or_feature => 'p', solution_needed => 's',
);
my $ref = $ticket->{ref};

# --- the corrupting case: a plain string, exactly what the CLI hands it ----
# --evidence is the only one of these three actually reachable from the CLI
# (Tira::CLI.pm defines no --attachments/--gate-passing-log flag at all);
# attachments and gate_passing_log are protected the same way because they
# are recognised, settable keys at the engine level - reachable from any
# direct Perl caller, record_clone's own passthrough included.

my %verb = ( evidence => 'evidence.add', attachments => 'attachment.add', gate_passing_log => 'gate.add' );
for my $field (qw(evidence attachments gate_passing_log)) {
    eval { $tira->record_update( project => $root, ref => $ref, author => 'claude', $field => 'not an array' ) };
    like( $@, qr/\Q$field\E/, "record_update refuses a plain-string $field rather than writing it in" );
    like( $@, qr/\Q$verb{$field}\E/, "and names $verb{$field} as the correct verb" );
    for my $other ( grep { $_ ne $verb{$field} } values %verb ) {
        unlike( $@, qr/\Q$other\E/, "and does not also name $other, the wrong verb for $field" );
    }

    # And the record itself must still be readable afterwards - the whole
    # point is that the refusal happens BEFORE anything is corrupted.
    my $after = $tira->record_show( project => $root, ref => $ref );
    is( ref $after->{$field}, 'ARRAY', "the card's own $field is still a real array after the refused call" );
}

# --- the corrupting case one level deeper: a real array, but of scalars
# rather than the hash records every reader expects to find inside it -----

for my $field (qw(evidence attachments gate_passing_log)) {
    eval { $tira->record_update( project => $root, ref => $ref, author => 'claude', $field => ['not a hashref'] ) };
    like( $@, qr/\Q$field\E/, "record_update also refuses an array of $field whose entries are not hash records" );
    my $after = $tira->record_show( project => $root, ref => $ref );
    is( ref $after->{$field}, 'ARRAY', "the card's own $field is still a real array after this refusal too" );
    my @not_hash = grep { ref $_ ne 'HASH' } @{ $after->{$field} };
    is( scalar @not_hash, 0, "and every surviving entry in $field is still a hash record" );
}

# --- the legitimate case: record_clone's own real ARRAY ref of hashes ------
# (not an empty one - the point is a non-empty array of hash records must
# still pass through record_update's new shape check unchanged)

my $file = File::Spec->catfile( $tmp, 'evidence.txt' );
open my $fh, '>', $file or die "Cannot write $file: $!";
print {$fh} "attached content\n";
close $fh;
$tira->attachment_add( project => $root, ref => $ref, author => 'claude', file => $file );

my $clone = $tira->record_clone( project => $root, ref => $ref, author => 'claude', title => 'A clone' );
is( ref $clone->{attachments}, 'ARRAY', 'record_clone can still carry a real attachments array through record_update' );
is( scalar @{ $clone->{attachments} }, 1, 'and the one real attachment on the source card survived the clone' );
is( ref $clone->{attachments}[0], 'HASH', 'as a hash record, not just an array slot' );
is( $clone->{attachments}[0]{original_filename}, 'evidence.txt', 'carrying the original attachment content through, not a stub' );

done_testing();

__END__

=head1 NAME

1130-a-scalar-that-ate-an-array.t - record_update refuses to overwrite a
structured-list field with a scalar

=head1 DESCRIPTION

C<record_update>'s generic setter for C<evidence>/C<attachments>/
C<gate_passing_log> (TKT-1130) used to write whatever value it was given
straight into the record, with no check on its shape. Every reader expects
an array of hash records; the CLI always hands C<--evidence>'s option value
through as a plain string (C<attachments>/C<gate_passing_log> have no CLI
flag at all, but are the same recognised, corruptible keys for a direct
Perl caller), so C<d2 ticket.update --ref REF --evidence TEXT> silently
replaced the array with a string, corrupting the card for every future
C<ticket.show>. The fix refuses, for any of these three keys, a value that
is not already an ARRAY ref, or an ARRAY ref whose entries are not
themselves hash refs - naming the field and the one correct dedicated verb
for it (C<evidence.add>, C<attachment.add>, or C<gate.add>) - while leaving
C<record_clone>'s own legitimate ARRAY ref passthrough (TKT-609) untouched.

=cut
