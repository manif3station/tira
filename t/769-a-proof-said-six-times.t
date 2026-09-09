#!/usr/bin/env perl
# required_item_update takes one --id per call, even when the same
# --command/--proof genuinely covers several sibling required-action items -
# a case this project's own design already sanctions (TKT-585's
# --repeated-reason), it just costs one full invocation per id. A new,
# additive --ids flag lets one call name several ids with the one pair,
# all-or-nothing: a bad id anywhere refuses the whole call, and --ids
# combined with --item (which renames) is refused outright.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $now  = '2026-09-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'A proof said six times', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PST', epic_prefix => 'PSE', ticket_prefix => 'PST2',
);
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Gated' );

my $a = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'Audit fields', status => 'pending' );
my $b = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'Check comments', status => 'pending' );
my $c = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'Check missing fields', status => 'pending' );

# --- --ids marks all three ids with one command/proof pair -----------------

my $result = $tira->required_item_update(
    author => 'claude', project => $root, ref => $card->{ref},
    ids => [ $a->{id}, $b->{id}, $c->{id} ], status => 'done',
    command => ['d2 tira.ticket.show --ref TKT-001'], proof => ['card looks correct'],
);
is( ref $result, 'ARRAY', '--ids returns an array of updated entries' );
is( scalar @{$result}, 3, 'all three ids were marked' );

my $record = $tira->record_show( project => $root, ref => $card->{ref} );
my %by_id = map { $_->{id} => $_ } @{ $record->{required_items} };
is( $by_id{ $a->{id} }{status}, 'done', 'first id is done' );
is( $by_id{ $b->{id} }{status}, 'done', 'second id is done' );
is( $by_id{ $c->{id} }{status}, 'done', 'third id is done' );

# --- a bad id anywhere refuses the whole call, nothing marked ---------------

my $d = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'Fourth', status => 'pending' );
my $e = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'Fifth', status => 'pending' );

eval {
    $tira->required_item_update(
        author => 'claude', project => $root, ref => $card->{ref},
        ids => [ $d->{id}, 'REQ-999', $e->{id} ], status => 'done',
        command => ['d2 tira.ticket.missing --ref TKT-001'], proof => ['clean'],
    );
};
like( $@, qr/REQ-999/, 'the refusal names the bad id' );

$record = $tira->record_show( project => $root, ref => $card->{ref} );
%by_id = map { $_->{id} => $_ } @{ $record->{required_items} };
is( $by_id{ $d->{id} }{status}, 'pending', 'the fourth id was NOT marked - all or nothing' );
is( $by_id{ $e->{id} }{status}, 'pending', 'the fifth id was NOT marked either' );

# --- --ids combined with --item is refused ----------------------------------

eval {
    $tira->required_item_update(
        author => 'claude', project => $root, ref => $card->{ref},
        ids => [ $d->{id}, $e->{id} ], item => 'Renamed', status => 'done',
        command => ['x'], proof => ['y'],
    );
};
like( $@, qr/--item/, '--ids combined with --item is refused' );

# --- a single --id call is completely unaffected ----------------------------

my $single = $tira->required_item_update(
    author => 'claude', project => $root, ref => $card->{ref},
    id => $d->{id}, status => 'done',
    command => ['solo command'], proof => ['solo proof'],
);
is( $single->{status}, 'done', 'a single --id call still works exactly as before' );

# --- --repeated-reason is still required against a PRE-EXISTING item -------
# --- outside the batch that already carries this exact command/proof ------

my $f = $tira->required_item_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'Sixth', status => 'pending' );
eval {
    $tira->required_item_update(
        author => 'claude', project => $root, ref => $card->{ref},
        ids => [ $f->{id} ], status => 'done',
        command => ['solo command'], proof => ['solo proof'],
    );
};
like( $@, qr/repeated-reason/i, 'reusing an outside item\'s exact proof via --ids still requires --repeated-reason' );

eval {
    $tira->required_item_update(
        author => 'claude', project => $root, ref => $card->{ref},
        ids => [ $f->{id} ], status => 'done',
        command => ['solo command'], proof => ['solo proof'], repeated_reason => 'one run proves both',
    );
};
like( $@, qr/confirm/i, 'the first --repeated-reason attempt is refused with a code to confirm, matching single-id behaviour' );

my $card_now = $tira->record_show( project => $root, ref => $card->{ref} );
my ($f_entry) = grep { $_->{id} eq $f->{id} } @{ $card_now->{required_items} };
my $code = $f_entry->{repeated_confirm}{code};
ok( $code, 'a confirmation code was stashed on the item' );

my $with_reason = $tira->required_item_update(
    author => 'claude', project => $root, ref => $card->{ref},
    ids => [ $f->{id} ], status => 'done',
    command => ['solo command'], proof => ['solo proof'],
    repeated_reason => 'one run proves both', repeated_confirm => $code,
);
is( $with_reason->[0]{status}, 'done', 'repeating with the confirmation code lets the reused proof through' );

done_testing();

__END__

=head1 NAME

t/769-a-proof-said-six-times.t - required_item_update's new --ids flag
marks several ids with one command/proof pair, all-or-nothing

=head1 DESCRIPTION

TKT-769. A gated column's entry actions are typically several near-
identical items whose honest evidence is the same command's output -
already sanctioned once-per-item via C<--repeated-reason> (TKT-585), but
costing one full C<required_item_update> invocation per id. C<--ids>
(an arrayref of ids, accepted alongside the existing single C<--id>)
validates every named id exists before marking any of them, refusing the
whole call if one does not - the same all-or-nothing principle TKT-485
established elsewhere - and refuses outright when combined with
C<--item>, since renaming several entries identically in one call is a
different, riskier operation than marking several done with one proof.

=cut
