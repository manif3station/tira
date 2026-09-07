#!/usr/bin/env perl
# TKT-629, self-filed from the 2-hourly improvement hunt. TKT-583 made a
# reused proof refusable through a two-step: --repeated-reason TEXT is
# refused and reads the item's own instruction back with a code, then
# --repeated-confirm CODE marks it done with the reason stored. Both live
# only on the command line - the browser's required_action_update provider
# forwards item, status, command and proof, and nothing else - so somebody
# working the board from the HTML dashboard who reuses evidence gets a
# refusal telling them to run again with --repeated-reason, a flag their
# interface does not have.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-07T20:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Reused', dir => $root, columns => ['backlog, doing, done'],
    members => ['claude'],
    sow_prefix => 'RUS', epic_prefix => 'RUE', ticket_prefix => 'RUT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'doing',
    required_action => [ 'First proof', 'Second proof' ] );

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Work' );
$providers{move}->( { type => 'ticket', ref => $card->{ref}, column => 'doing', _signed_in => 'claude' } );

my $record = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
my ($first)  = grep { $_->{item} eq 'First proof' } @{ $record->{required_items} };
my ($second) = grep { $_->{item} eq 'Second proof' } @{ $record->{required_items} };

# --- mark the first item done through the provider --------------------------

$providers{required_action_update}->( {
    ref => $card->{ref}, id => $first->{id}, status => 'done',
    command => ['ran it'], proof => ['looked right'], _signed_in => 'claude',
} );

# --- reusing the same proof on the second item is refused --------------------

my $refused = eval {
    $providers{required_action_update}->( {
        ref => $card->{ref}, id => $second->{id}, status => 'done',
        command => ['ran it'], proof => ['looked right'], _signed_in => 'claude',
    } );
    1;
};
ok( !$refused, 'reusing the same proof through the browser provider is refused, not silently accepted' );
like( $@, qr/repeated/i, 'and the refusal names the mechanism a browser caller can act on' );

# --- the provider forwards a reason, and gets back a code to sign -----------
# Matching the CLI's own two-step: a reason alone is still refused, reading
# THIS item's own instruction back with a code - the forced re-read TKT-583
# exists for.

eval {
    $providers{required_action_update}->( {
        ref => $card->{ref}, id => $second->{id}, status => 'done',
        command => ['ran it'], proof => ['looked right'],
        repeated_reason => 'Same fixture proves both', _signed_in => 'claude',
    } );
};
like( $@, qr/repeated-confirm|sign it/i,
    'the provider forwards repeated_reason through to the engine, which still asks for a signature' );

my ($code) = ( $@ // '' ) =~ /--repeated-confirm (\S+)/;
ok( length( $code // '' ), 'a confirmation code came back to sign' );

# Re-read the item for its stashed confirm code, the way the CLI's own second
# call reads it from the refusal rather than re-deriving it.
$record = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
($second) = grep { $_->{id} eq $second->{id} } @{ $record->{required_items} };
my $confirm_code = $second->{repeated_confirm}{code};

is( $confirm_code, $code, 'the pending confirm code is stashed on the item, same as the CLI path' );

my $confirmed = eval {
    $providers{required_action_update}->( {
        ref => $card->{ref}, id => $second->{id}, status => 'done',
        command => ['ran it'], proof => ['looked right'],
        repeated_reason => 'Same fixture proves both',
        repeated_confirm => $confirm_code, _signed_in => 'claude',
    } );
};
ok( !$@, 'supplying the confirm code through the provider marks the item done' ) or diag($@);

$record = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
($second) = grep { $_->{id} eq $second->{id} } @{ $record->{required_items} };
is( lc( $second->{status} ), 'done', 'the second item is now done' );
is( $second->{repeated_reason}, 'Same fixture proves both',
    'and the reason is stored, matching what a CLI-written one looks like' );

done_testing();

__END__

=head1 NAME

602-a-reason-the-browser-cannot-write.t - the browser dashboard can now write a
reused-proof reason

=head1 DESCRIPTION

TKT-629. TKT-583's two-step reused-proof mechanism - a refusal naming the
item's own instruction with a code, then a confirm carrying the reason -
lived only on the command line: C<lib/Tira/CLI.pm>'s C<--repeated-reason>/
C<--repeated-confirm> flags reached C<required_item_update>, but the
browser's own C<required_action_update> provider forwarded only
C<item>/C<status>/C<command>/C<proof>. Somebody reusing evidence from the
HTML dashboard got a refusal pointing at a flag their interface does not
have.

The provider now forwards C<repeated_reason> and C<repeated_confirm>
through to the same engine call the CLI already uses, so the two-step
works identically from either interface.

=cut
