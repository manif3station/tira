#!/usr/bin/env perl
# project.update --agent accepted only the literal string 'claude', not any
# person a project had actually registered as its agent.
#
# Found live: a project whose agent is registered under a different person
# id ('zenbot') could not declare it - refused with "Unknown coding agent
# 'zenbot'; the only one supported today is claude", even though 'zenbot'
# was already a real, active person on that project. The validator
# conflated "which AI product" with "which person id identifies the agent
# on this project" - card-changed-by-owner (and anything else reading
# _agent_declared_for) needs the latter, and a project whose agent is not
# literally named 'claude' could never supply it.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new;
$tira->project_new(
    name => 'Agents', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'AGS', epic_prefix => 'AGE', ticket_prefix => 'AGT',
);
$tira->person_add( project => $root, id => 'zenbot', name => 'Zenandi Developer' );

# --- an agent named for a real, registered person succeeds ------------------

my $updated = $tira->project_update( project => $root, agent => 'zenbot' );
is( $updated->{agent}, 'zenbot', 'a registered person id is accepted as the agent, not just literally claude' );

# --- an unregistered id refuses, naming what is wrong ------------------------

ok( !eval { $tira->project_update( project => $root, agent => 'nobody-here' ); 1 },
    'an id nobody registered is refused' );
like( $@, qr/nobody-here/, 'naming the id that was refused' );

# --- an inactive person is refused too, same as assignee/reporter already are --

$tira->person_deactivate( project => $root, id => 'zenbot' );
ok( !eval { $tira->project_update( project => $root, agent => 'zenbot' ); 1 },
    'a deactivated person cannot be declared the agent either' );
like( $@, qr/inactive/i, 'and says why' );

# --- the still-legitimate literal 'claude' keeps working, unaffected --------

$tira->person_add( project => $root, id => 'claude', name => 'Claude' )
  unless grep { $_->{id} eq 'claude' } @{ $tira->person_list( project => $root ) };
my $back = $tira->project_update( project => $root, agent => 'claude' );
is( $back->{agent}, 'claude', 'the literal claude still works, as any other registered person would' );

done_testing;

__END__

=head1 NAME

320-an-agent-with-a-real-name.t - project.update --agent accepts any registered person, not just the literal string 'claude'

=head1 DESCRIPTION

The agent field validator hardcoded acceptance of the single literal
string C<claude>, so a project whose agent was registered under any other
person id could never declare it - blocking C<card-changed-by-owner>
entirely on that project. C<--agent> now validates the same way
C<assignee>/C<reporter> already do: any registered, active person on the
project. TKT-459.

=cut
