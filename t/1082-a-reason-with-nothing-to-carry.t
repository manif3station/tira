#!/usr/bin/env perl
# TKT-1078. --exempt-reason given with no --exempt-required at all was
# accepted and did nothing. _exempt_entries returns as soon as
# $args{required_exempt} is undef, before ever looking at
# $args{exempt_reason} - so 'd2 tira.ticket.update --ref REF --author X
# --exempt-reason "some text"' exited 0, printed the card unchanged, and
# the reason was written nowhere. Found live by Codex reviewing TKT-587's
# own documentation of this pair, the same silent-swallow shape
# TKT-281/302/431/581/1077 all fixed for other flags.
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
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Exempting', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A reason with nothing to hold' );

# --- the silent swallow --------------------------------------------------

my $error = do {
    local $@;
    eval {
        $tira->record_update( project => $root, type => 'ticket', ref => $card->{ref},
            author => 'claude', exempt_reason => ['because'] );
    };
    $@;
};
ok( $error, 'record_update with --exempt-reason and no --exempt-required refuses, rather than silently accepting' );
like( $error, qr/--exempt-required/, 'and the refusal names --exempt-required' );

my $unchanged = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
is_deeply( $unchanged->{required_exempt}, [], 'and nothing was written to the card' );

# --- and the paired-given behavior still works exactly as before ----------

my $rec = $tira->record_update( project => $root, type => 'ticket', ref => $card->{ref},
    author => 'claude', required_exempt => ['REQ-001'], exempt_reason => ['because'] );
is( scalar @{ $rec->{required_exempt} }, 1, 'exempt-required paired with exempt-reason still records the exemption' );
is( $rec->{required_exempt}[0]{item}, 'REQ-001', 'naming the exempted item' );
is( $rec->{required_exempt}[0]{reason}, 'because', 'and the reason given with it' );

# --- and exempt-required alone (no reason) still refuses as before --------

my $error2 = do {
    local $@;
    eval {
        $tira->record_update( project => $root, type => 'ticket', ref => $card->{ref},
            author => 'claude', required_exempt => ['REQ-002'] );
    };
    $@;
};
ok( $error2, 'record_update with --exempt-required and no --exempt-reason still refuses, unchanged' );
like( $error2, qr/--exempt-reason/, 'and the refusal names --exempt-reason' );

# --- and create_record, the shared helper's other caller -----------------
#
# _exempt_entries is shared by record_update and create_record - Codex
# review caught that this file only exercised the update path, leaving the
# create path's use of the same function untested.

my $error3 = do {
    local $@;
    eval {
        $tira->create_record( project => $root, type => 'ticket', title => 'Born exempt from nothing',
            exempt_reason => ['because'] );
    };
    $@;
};
ok( $error3, 'create_record with --exempt-reason and no --exempt-required refuses too' );
like( $error3, qr/--exempt-required/, 'and the refusal names --exempt-required' );

my $created = $tira->create_record( project => $root, type => 'ticket', title => 'Born exempt',
    required_exempt => ['REQ-001'], exempt_reason => ['because'] );
is( $created->{required_exempt}[0]{item}, 'REQ-001', 'create_record still records a properly paired exemption' );

done_testing;

__END__

=head1 NAME

1082-a-reason-with-nothing-to-carry.t - --exempt-reason alone refuses rather than vanishing

=head1 DESCRIPTION

TKT-1078. C<_exempt_entries> only ran its pairing check once
C<--exempt-required> was given - C<--exempt-reason> given alone returned
untouched and silently did nothing. The die message already claimed a
bidirectional requirement ("every --exempt-reason an --exempt-required")
the code never actually enforced in this direction. Fixed by moving the
check ahead of the early return, and this file also pins the two
behaviours that were already correct: paired given together still
records the exemption, and C<--exempt-required> alone still refuses.

=cut
