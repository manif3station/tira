#!/usr/bin/env perl
# A card can be exempted from a specific column's required-action item
# (TKT-439, --exempt-required), diverging from the column's own template
# when it genuinely does not apply. But the dashboard rendered an exempted
# item exactly like a pending one - same empty checkbox, no strikethrough,
# no reason - so a card that legitimately skipped an item looked, on
# screen, exactly like a card that just never did the work. Owner's own
# reaction, seeing TKT-471 in done with its exempted items still showing
# unchecked boxes: "How do you explain this? This card became Done while
# only half-finished."
#
# A reason is now required alongside every --exempt-required, not merely
# permitted, and both are stored - {item, reason, exempted_at, author} -
# rather than the bare item text TKT-439 originally shipped. An exemption
# recorded before this ticket is still a bare string on disk and is read
# the same way a new one is, by both the move-gate check and the dashboard
# render. TKT-473.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $clock = 0;
my $tira = Tira->new( clock => sub { sprintf '2026-08-23T00:00:%02d+0100', $clock++ } );
$tira->project_new(
    name => 'Exempt', dir => $root, members => ['claude'],
    columns => [ 'backlog', 'gate', 'done' ],
    sow_prefix => 'EXS', epic_prefix => 'EXE', ticket_prefix => 'EXT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'gate', required_action => ['Ship it right'] );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    local $ENV{TIRA_AUTHOR} = "claude";
    my $status = Tira::CLI->run( command => $command, type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

# --- exempting without a reason is refused ---------------------------------

my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Needs an exemption' );
my $error = eval {
    $tira->record_update(
        project => $root, ref => $ticket->{ref}, author => 'claude',
        required_exempt => ['Ship it right'],
    );
    1;
} ? undef : $@;
like( $error, qr/needs a reason/, 'exempting a required item without --exempt-reason is refused' );

# --- a mismatched count is refused too --------------------------------------

$error = eval {
    $tira->record_update(
        project => $root, ref => $ticket->{ref}, author => 'claude',
        required_exempt => [ 'Ship it right', 'A second item' ], exempt_reason => ['Only one reason'],
    );
    1;
} ? undef : $@;
like( $error, qr/matching --exempt-reason/, 'an --exempt-required with no matching --exempt-reason is refused' );

# --- a proper pairing is stored with item, reason, exempted_at, author -----

$ticket = $tira->record_update(
    project => $root, ref => $ticket->{ref}, author => 'claude',
    required_exempt => ['Ship it right'], exempt_reason => ["Doesn't apply to a workspace-tooling card"],
);
is( scalar @{ $ticket->{required_exempt} }, 1, 'one exemption stored' );
is( $ticket->{required_exempt}[0]{item}, 'Ship it right', 'exemption names the item' );
is( $ticket->{required_exempt}[0]{reason}, "Doesn't apply to a workspace-tooling card", 'and carries the reason' );
is( $ticket->{required_exempt}[0]{author}, 'claude', 'and who exempted it' );
ok( $ticket->{required_exempt}[0]{exempted_at}, 'and when' );

# --- a card so exempted can still move out of the gated column -------------

my ($status, $out, $err) = cli( 'record.move', '--ref', $ticket->{ref}, '--column', 'gate' );
is( $status, 0, 'move into the gated column succeeds' ) or diag($err);
( $status, $out, $err ) = cli( 'record.move', '--ref', $ticket->{ref}, '--column', 'done' );
is( $status, 0, 'and the exempted card moves out of it too, despite the unmet template item' ) or diag($err);

# --- a legacy bare-string exemption (recorded before this ticket) still gates the same way --

my $legacy = $tira->create_record( project => $root, type => 'ticket', title => 'Legacy exemption shape' );
{
    my ( $path, $record ) = $tira->_record_data( project => $root, ref => $legacy->{ref} );
    $record->{required_exempt} = ['Ship it right'];
    $tira->_write_json( $path, $record );
}
( $status, $out, $err ) = cli( 'record.move', '--ref', $legacy->{ref}, '--column', 'gate' );
is( $status, 0, 'move into the gated column succeeds' ) or diag($err);
( $status, $out, $err ) = cli( 'record.move', '--ref', $legacy->{ref}, '--column', 'done' );
is( $status, 0, 'a legacy bare-string exemption still lets the card move out, same as a new one' ) or diag($err);

done_testing;

__END__

=head1 NAME

327-an-exemption-with-no-reason.t - a required-action exemption must say why

=head1 DESCRIPTION

C<--exempt-required> now requires a paired C<--exempt-reason>, refused
without one or with a mismatched count. A successful exemption is stored as
C<{item, reason, exempted_at, author}> rather than the bare item text
C<--exempt-required> originally shipped with (TKT-439). Both the move-gate
check (C<_column_required_action_violation>) and the dashboard's
required-actions rendering read either shape the same way, so an exemption
recorded before this ticket keeps gating exactly as it always did. TKT-473.

=cut
