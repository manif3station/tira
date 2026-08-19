#!/usr/bin/env perl
# A card is raised under its parent in one command, not two.
#
# Every record used to be created parentless and given a parent by a second
# command, hierarchy.link - so between the two commands it was an orphan, and
# orphan-card said so. Measured on this project's own board: 1361 findings,
# 55 percent of its entire violation history, 4x the next-largest category.
# It compounds, because fixing one orphan by making it a parent record makes
# the parent record an orphan too, until you reach a root.
#
# Create was also refusing --parent with the message written for update,
# which names the ref to link - except at create time there is no ref yet,
# so the refusal printed the literal placeholder "<this record>". An agent
# that copied it got "Invalid record type in <this record>". The advice was
# unrunnable exactly when it was needed most.
#
# What changes: create accepts --parent and performs the same link
# hierarchy.link performs - applying its own hierarchy validation, and
# failing the whole creation (no card left behind) if the link is invalid.
# update --parent keeps refusing exactly as before; TKT-012 already
# established that accepting it there and doing nothing is the wrong answer,
# and this ticket is not about weakening that.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-19T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Parented', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PAS', epic_prefix => 'PAE', ticket_prefix => 'PAT',
);
$tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );

sub run {
    my ( $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'record.' . shift(@argv), type => $type, tira => $tira,
            argv => [@argv],
        ) };
    };
    return ( $status, $out, $err );
}

sub orphaned_refs {
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police' ), world => {} );
    return { map { $_->{ref} => 1 }
          grep { ( $_->{rule} // '' ) eq 'orphan-card' } @{ $pass->{violations} } };
}

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'The work',
    labels => ['standalone'] );

# --- create with --parent links in the same command, epic under sow -------

my ( $status, $out, undef ) = run( 'epic', 'create', '--title', 'Raised under its parent',
    '--parent', $sow->{ref}, '-o', 'json' );
is( $status, 0, 'epic.create with --parent succeeds' );
my $epic_ref = decode_json($out)->{ref};

# Read it back rather than trusting the command's own answer - the same
# discipline t/89 established for update, applied here to create.
is( $tira->record_show( project => $root, type => 'epic', ref => $epic_ref )->{parent},
    $sow->{ref}, 'and the parent really is set, checked by reading it back' );
is( $tira->hierarchy_show( project => $root, ref => $sow->{ref} )->{children}[0]{ref},
    $epic_ref, 'hierarchy.show lists it as a child' );
ok( !orphaned_refs()->{$epic_ref}, 'and orphan-card never fires on it in between' );

# --- and ticket under epic, the other valid hierarchy ----------------------

( $status, $out, undef ) = run( 'ticket', 'create', '--title', 'A child of a child',
    '--parent', $epic_ref, '-o', 'json' );
is( $status, 0, 'ticket.create with --parent succeeds' );
my $ticket_ref = decode_json($out)->{ref};

is( $tira->record_show( project => $root, type => 'ticket', ref => $ticket_ref )->{parent},
    $epic_ref, 'the ticket\'s parent is set too' );
ok( !orphaned_refs()->{$ticket_ref}, 'and it is never an orphan either' );

# --- an invalid hierarchy fails the whole creation, no card left behind ----

my @before = @{ $tira->record_list( project => $root, type => 'ticket', refs_only => 1 ) };

( $status, undef, my $err ) = run( 'ticket', 'create', '--title', 'Should never exist',
    '--parent', $sow->{ref}, '-o', 'json' );
isnt( $status, 0, 'create refuses a hierarchy hierarchy.link would refuse too' );
like( $err, qr/Hierarchy requires SOW-to-epic or epic-to-ticket/,
    'with hierarchy.link\'s own message, not a create-time invention' );
unlike( $err, qr/<this record>/,
    'and never the placeholder a create-time refusal cannot fill in' );

my @after = @{ $tira->record_list( project => $root, type => 'ticket', refs_only => 1 ) };
is_deeply( \@after, \@before, 'and no half-raised ticket was left behind' );

# --- update --parent keeps refusing, unchanged ------------------------------

( $status, undef, $err ) = run( 'ticket', 'update', '--ref', $ticket_ref,
    '--parent', $epic_ref, '-o', 'json' );
isnt( $status, 0, 'update --parent is still refused' );
like( $err, qr/A parent is set with hierarchy\.link, not by updating the record/,
    'with its existing message, intact' );

# --- create without --parent behaves exactly as before ----------------------

( $status, $out, undef ) = run( 'ticket', 'create', '--title', 'Nobody said where this belongs',
    '-o', 'json' );
is( $status, 0, 'create with no --parent still succeeds' );
my $plain_ref = decode_json($out)->{ref};
is( $tira->record_show( project => $root, type => 'ticket', ref => $plain_ref )->{parent},
    undef, 'and it has no parent, exactly as before' );

done_testing;

__END__

=head1 NAME

287-a-card-raised-under-its-parent.t - create takes --parent and links in one command

=head1 DESCRIPTION

Creating a record and parenting it were two commands, so every record was an
orphan in between - 1361 findings, 55 percent of this board's violation
history. The refusal that told a caller what to do instead named a command
that could not be run yet: at create time there is no ref, so it printed the
placeholder "<this record>".

This covers C<create --parent> linking atomically, an invalid hierarchy
failing the whole creation with hierarchy.link's own message and no card left
behind, C<update --parent> continuing to refuse exactly as before, and a plain
create with no C<--parent> behaving exactly as it always has.

=cut
