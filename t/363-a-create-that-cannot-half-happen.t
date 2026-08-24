#!/usr/bin/env perl
# ticket.create landing in a column with required_actions writes the record
# first, then populates required_items via required_item_add - which
# requires --author. A create with no author (and no TIRA_AUTHOR) failed
# AFTER the record already existed: an orphaned, unattributed card on disk,
# and a retry with --author created a second, duplicate ticket for the same
# work rather than completing the first. TKT-485.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Orphaned', dir => $root, members => ['claude'],
    columns => ['backlog, gated, ungated, done'],
    sow_prefix => 'ORS', epic_prefix => 'ORE', ticket_prefix => 'ORT',
);
$tira->column_update( project => $root, type => 'ticket', name => 'gated',
    required_action => ['left a note'] );

sub run {
    my ( $command, %env ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        local $ENV{TIRA_AUTHOR} = $env{TIRA_AUTHOR};
        delete local $ENV{TIRA_AUTHOR} if !defined $env{TIRA_AUTHOR};
        Tira::CLI->run( command => $command, type => 'ticket', argv => $env{argv} );
    };
    return ( $status, $out . $err );
}

sub refs_now {
    return $tira->record_list( project => $root, type => 'ticket', refs_only => 1 );
}

# --- no author, landing in a column with required_actions: refused, no orphan

{
    my $before = refs_now();
    my ( $status, $said ) = run( 'record.create',
        argv => [ '--title', 'Gated with no author', '--column', 'gated' ] );
    isnt( $status, 0, 'create with no author into a gated column is refused' );
    like( $said, qr/needs to say who is making it/i, 'naming the real problem' );
    is_deeply( refs_now(), $before,
        'and no record was written - the refusal happened before any write, not after' );
}

# --- no author, landing in a column with NO required_actions: unaffected ----

{
    my $before = refs_now();
    my ( $status, $said ) = run( 'record.create',
        argv => [ '--title', 'Ungated with no author', '--column', 'ungated' ] );
    is( $status, 0, 'create with no author into an ungated column still works, unchanged' );
    is( scalar( @{ refs_now() } ), scalar( @{$before} ) + 1, 'and a record was written' );
}

# --- TIRA_AUTHOR (no --author), landing in a gated column: works -----------

{
    my $before = refs_now();
    my ( $status, $said ) = run( 'record.create',
        argv => [ '--title', 'Gated with TIRA_AUTHOR', '--column', 'gated' ],
        TIRA_AUTHOR => 'claude' );
    is( $status, 0, 'create with TIRA_AUTHOR set (no --author) into a gated column works' );
    is( scalar( @{ refs_now() } ), scalar( @{$before} ) + 1, 'and a record was written' );
}

# --- --author itself still works, unaffected --------------------------------

{
    my $before = refs_now();
    my ( $status, $said ) = run( 'record.create',
        argv => [ '--title', 'Gated with --author', '--column', 'gated', '--author', 'claude' ] );
    is( $status, 0, 'create with --author into a gated column still works, unchanged' );
    is( scalar( @{ refs_now() } ), scalar( @{$before} ) + 1, 'and a record was written' );
}

done_testing;

__END__

=head1 NAME

363-a-create-that-cannot-half-happen.t - record.create refuses before writing, not after

=head1 DESCRIPTION

C<record.create> landing in a column with C<required_actions> wrote the
record, then required an author for the required-items population it
still needed to do - failing after the write, leaving an orphaned,
unattributed card a retry with C<--author> then duplicated instead of
completing. This proves the refusal now happens before any write (no
matching record exists afterward), that a column with no required_actions
is unaffected, and that C<--author> or C<TIRA_AUTHOR> either one still
works exactly as before.

=cut
