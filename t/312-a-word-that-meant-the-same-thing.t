#!/usr/bin/env perl
# docs/commands.md documents checklist.add/checklist.update's --status as free
# text, and the engine validates only that it is non-empty - any string is
# accepted, confirmed by t/151's own --status todo example. But card-stalled,
# checklist-unmoved, and the required-action move-out/backward-reset checks
# all compare against the exact lowercase string 'done'. A checklist or
# required item marked --status Done or --status DONE reads as complete to
# any person looking at the board, and is silently invisible to all four
# rules: card-stalled never reports the stall, checklist-unmoved keeps
# reporting the item as outstanding, and a move refuses forever with a
# confusing "not done" message even though it plainly says Done.
#
# Duplicate report TKT-444 (reporter michael, zen-framework project) gave a
# concrete live repro: ZSD-233's item marked --status Done refused a move
# with "required actions not done", and re-setting the identical item to
# --status done (lowercase only) succeeded immediately with nothing else
# changed.
#
# The fix is a case-insensitive comparison, not a restriction: --status todo
# and every other non-done value must behave exactly as before.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

sub cli {
    my ( $root, $command, @argv ) = @_;
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

# --- card-stalled: a checklist finished in someone else's words -----------
{
    my $root = File::Spec->catdir( $tmp, 'stalled' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Stalled', dir => $root, members => ['claude'],
        columns => [ 'backlog', 'tests-red', 'implement' ],
        sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
    );
    $tira->policy_add( project => $root, rule => 'card-stalled', before => 'implement', action => 'bridge-reminder' );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Stuck', reporter => 'claude' );
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'do the work', status => 'Done' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'tests-red', author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'store-stalled' ), world => {} );
    is( scalar @{ $pass->{violations} // [] }, 1,
        'card-stalled treats --status Done the same as --status done - the stall is still reported' );
}

# --- checklist-unmoved: nothing outstanding, spelled in capitals ----------
{
    my $step  = 0;
    my @times = map { sprintf '2026-08-15T10:%02d:00Z', $_ } 0 .. 59;
    my $tira  = Tira->new( clock => sub { $times[ $step++ ] // $times[-1] } );
    my $root  = File::Spec->catdir( $tmp, 'unmoved' );
    $tira->project_new(
        project => $root, name => 'Unmoved', dir => $root, members => ['claude'],
        columns => [ 'backlog', 'tests-red', 'implement' ],
        sow_prefix => 'UMS', epic_prefix => 'UME', ticket_prefix => 'UMT',
    );
    $tira->policy_add( project => $root, rule => 'checklist-unmoved', action => 'bridge-reminder' );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Finished', reporter => 'claude' );
    $tira->checklist_add( author => 'claude', project => $root, ref => $card->{ref}, item => 'do the work', status => 'DONE' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'tests-red', author => 'claude' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'claude' );

    my $pass = $tira->police_pass( project => $root, store => File::Spec->catdir( $tmp, 'store-unmoved' ), world => {} );
    is( scalar @{ $pass->{violations} // [] }, 0,
        'checklist-unmoved treats --status DONE the same as --status done - nothing outstanding, nothing reported' );
}

# --- required-action move-out: refuses to be told "not done" wrongly ------
{
    my $root = File::Spec->catdir( $tmp, 'gate' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Gate', dir => $root, members => ['claude'],
        columns => [ 'backlog', 'planning', 'doc' ],
        sow_prefix => 'GTS', epic_prefix => 'GTE', ticket_prefix => 'GTT',
    );
    $tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['left a note'] );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Gated' );
    cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
    my ($item) = grep { $_->{item} eq 'left a note' }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    cli( $root, 'required-action.update', '--ref', $card->{ref}, '--id', $item->{id}, '--status', 'Done',
        '--command', 'left it', '--proof', 'note left' );

    my ( $status, $out, $err ) = cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
    is( $status, 0, '--status Done satisfies the required-action move-out gate the same as --status done' )
      or diag($err);
}

# --- required-action backward-reset: a capitalized Done still resets ------
{
    my $root = File::Spec->catdir( $tmp, 'reset' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Reset', dir => $root, members => ['claude'],
        columns => [ 'backlog', 'planning', 'doc', 'review' ],
        sow_prefix => 'RSS', epic_prefix => 'RSE', ticket_prefix => 'RST',
    );
    # required_action on doc, not planning: the destination of the backward
    # move below is always excluded from what resets (it is where the card
    # is arriving, not a column being backed out of - t/309 established
    # this), so the item under test needs to be tagged with a column
    # strictly between the new destination and the old position.
    $tira->column_update( project => $root, type => 'ticket', name => 'doc', required_action => ['left a note'] );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Resettable' );
    cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
    cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
    my ($item) = grep { $_->{item} eq 'left a note' }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    cli( $root, 'required-action.update', '--ref', $card->{ref}, '--id', $item->{id}, '--status', 'Done',
        '--command', 'left it', '--proof', 'note left' );
    cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'review' );

    cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
    my $shown = $tira->record_show( project => $root, ref => $card->{ref} );
    my ($after) = grep { $_->{item} eq 'left a note' } @{ $shown->{required_items} };
    is( $after->{status}, 'pending',
        'a required item marked Done still resets on a backward move, the same as done would' );
}

# --- an unrelated free-text value is entirely unaffected -------------------
{
    my $root = File::Spec->catdir( $tmp, 'todo' );
    my $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Todo', dir => $root, members => ['claude'],
        columns => [ 'backlog', 'planning', 'doc' ],
        sow_prefix => 'TDS', epic_prefix => 'TDE', ticket_prefix => 'TDT',
    );
    $tira->column_update( project => $root, type => 'ticket', name => 'planning', required_action => ['left a note'] );
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Untouched' );
    cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'planning' );
    my ($item) = grep { $_->{item} eq 'left a note' }
      @{ $tira->required_item_list( project => $root, ref => $card->{ref} ) };
    cli( $root, 'required-action.update', '--ref', $card->{ref}, '--id', $item->{id}, '--status', 'todo' );

    my ( $status, $out, $err ) = cli( $root, 'record.move', '--ref', $card->{ref}, '--column', 'doc' );
    isnt( $status, 0, 'a genuinely unfinished item (--status todo) still refuses the move, exactly as before' );
    like( $err, qr/left a note/, 'naming it' );
}

done_testing;

__END__

=head1 NAME

312-a-word-that-meant-the-same-thing.t - "done" is recognized case-insensitively everywhere it gates a rule

=head1 DESCRIPTION

Covers TKT-434: card-stalled, checklist-unmoved, and the required-action
move-out and backward-reset checks all now compare a status against 'done'
case-insensitively, so --status Done, DONE, dOne etc. are recognized the
same as --status done everywhere they gate a rule. The field itself stays
genuinely free text - a value like todo continues to be treated as
unfinished exactly as before, and checklist_add/checklist_update are
unchanged.

=cut
