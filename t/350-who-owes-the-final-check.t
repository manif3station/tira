#!/usr/bin/env perl
# No command answered who owes a card's final check. In chain mode a card is
# managed by the agent that owns its parent - "the chain makes that
# computable from the parent" - so the answer is one lookup away: the
# card's own parent's assignee, not a guess and not a walk past the
# immediate parent. TKT-372.
#
# Reported alongside a fuller "final check" review gate; two of its four
# checks (evidence exists, the todo list is really done) are already
# gate-missing and checklist-unmoved/card-stalled, composable on a
# final-check column with no new code. The judgement check (does the code
# align with the card) stays a person/LLM's job, and nothing here moves a
# card automatically - police asks and moves nothing, deliberately. This is
# the one missing piece: who to ask.

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
    name => 'Owed', dir => $root, members => [ 'claude', 'ada', 'ben' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'OWS', epic_prefix => 'OWE', ticket_prefix => 'OWT',
);

# --- a ticket whose parent epic is assigned: the parent owes the check -----

{
    my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Parent epic' );
    $tira->record_update( project => $root, ref => $epic->{ref}, author => 'claude', assignee => 'ada' );
    my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Child ticket',
        parent => $epic->{ref} );

    my $owed = $tira->check_owner( project => $root, ref => $ticket->{ref} );
    is( $owed->{owner}, 'ada', "the parent epic's assignee owes the check" );
    is( $owed->{via}, $epic->{ref}, 'named as the parent consulted' );
}

# --- a card with no parent: it owes its own check ---------------------------

{
    my $standalone = $tira->create_record( project => $root, type => 'epic', title => 'No parent',
        labels => ['standalone'] );
    $tira->record_update( project => $root, ref => $standalone->{ref}, author => 'claude', assignee => 'ben' );

    my $owed = $tira->check_owner( project => $root, ref => $standalone->{ref} );
    is( $owed->{owner}, 'ben', 'with no parent, the card owes its own check' );
    ok( !defined $owed->{via}, 'and names no parent, because there is none' );
}

# --- a parent with no assignee: no owner, not a guess and not a walk further up --

{
    my $unassigned_epic = $tira->create_record( project => $root, type => 'epic', title => 'Unassigned parent' );
    my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Its child',
        parent => $unassigned_epic->{ref} );

    my $owed = $tira->check_owner( project => $root, ref => $ticket->{ref} );
    ok( !defined $owed->{owner}, 'an unassigned parent reports no owner, rather than guessing' );
    is( $owed->{via}, $unassigned_epic->{ref}, 'still names the parent that was consulted' );
}

# --- and the command a caller actually types ---------------------------------

{
    use Tira::CLI;
    my $epic = $tira->create_record( project => $root, type => 'epic', title => 'CLI parent' );
    $tira->record_update( project => $root, ref => $epic->{ref}, author => 'claude', assignee => 'ada' );
    my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'CLI child',
        parent => $epic->{ref} );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => 'check.owner', tira => $tira,
                argv => [ '--ref', $ticket->{ref}, '-o', 'json' ] );
        };
    };
    is( $status, 0, 'tira.check.owner answers' );
    like( $out, qr/"owner":"ada"/, 'and names the same owner the engine method does' );
}

done_testing;

__END__

=head1 NAME

350-who-owes-the-final-check.t - who a card's final check falls to

=head1 DESCRIPTION

In chain mode a card is managed by the agent that owns its parent, so who
owes a card's final check is computable from the parent - one lookup, not
a walk up the whole ancestry and not a guess when the parent has nobody
assigned. This proves the lookup against an assigned parent, a card with
no parent at all, and a parent with no assignee, plus the CLI command a
caller actually types.

=cut
