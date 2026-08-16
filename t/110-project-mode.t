#!/usr/bin/env perl
# A project says whether one agent works it or a chain of them does.
#
# Michael's design, 2026-08-12: multi-agent is built on single agent, not
# beside it. The single agent is the one you get when you type claude into a
# terminal and it owns everything. A chain is that same agent stepping out of
# the work and onto the top of a chain of command, with an agent per card.
#
# Several rules mean different things between the two, and nothing anywhere
# recorded which this project is. Guessing from the board would be wrong the
# first day a single agent assigns two cards to two names.
#
# His answer to how a project says which it is: at onboarding. The agent reads
# the instructions and asks before doing anything else, and Tira stores the
# answer and reads it back later.
#
# The default is the part that matters most. A project that has never been
# asked must behave exactly as it does today, or every existing board changes
# underneath its owner for a feature nobody asked it to turn on.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-12T21:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Either kind', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'EKS', epic_prefix => 'EKE', ticket_prefix => 'EKT',
);

# --- never asked ----------------------------------------------------------

is( $tira->project_mode( project => $root ), undef,
    'a project nobody has asked has no answer, rather than a guess' );

# --- both answers ---------------------------------------------------------

is( $tira->project_mode( project => $root, mode => 'chain' ), 'chain',
    'a project can say it is worked by a chain of agents' );
is( $tira->project_mode( project => $root ), 'chain',
    'and says so afterwards, because it was written down rather than remembered' );

is( $tira->project_mode( project => $root, mode => 'single' ), 'single',
    'and can say it is worked by one agent' );
is( $tira->project_mode( project => $root ), 'single', 'which also survives' );

# --- and nothing else -----------------------------------------------------
#
# Refused rather than stored, because a mode nothing understands is a setting
# that reads as configured while behaving as unset - the same silence this
# whole subsystem exists to remove.

my $refused = !eval { $tira->project_mode( project => $root, mode => 'multi' ); 1 };
ok( $refused, 'a word that is not one of the two is refused' );
like( $@, qr/single|chain/, 'and the refusal says what the two are' );
is( $tira->project_mode( project => $root ), 'single',
    'and the answer that was already there is not damaged by the attempt' );

# --- it travels with the project ------------------------------------------

my $config = $tira->project_show( project => $root );
is( $config->{mode}, 'single',
    'the answer is in the project config, so it travels with the project and anybody can read it' );

# --- and it is asked at onboarding ----------------------------------------
#
# Asked, not defaulted. An agent that is told to guess will guess consistently
# and be wrong on somebody's board for months.

my $questions = $tira->onboarding_questions;
my ($mode_question) = grep { $_->{id} eq 'mode' } @{$questions};
ok( $mode_question, 'onboarding asks which kind of project this is' );
like( $mode_question->{text}, qr/agent/i, 'in words that say what is being asked' );
is_deeply( [ sort @{ $mode_question->{options} } ], [ 'chain', 'single' ],
    'offering exactly the two answers there are' );

# --- through the command an agent actually types ---------------------------
#
# The engine being right is not the same claim as the command working. Six
# rules shipped correct and unreachable on this project for exactly that
# reason, so the command is exercised rather than assumed.

use Tira::CLI;

sub run_mode {
    my (@arguments) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        $status = do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'project.mode', tira => $tira,
            argv => [ @arguments, '-o', 'json' ],
        ) };
    }
    return ( $out . $err, $status );
}

my ( $said, $status ) = run_mode();
is( $status, 0, 'the command answers' );
like( $said, qr/"mode"\s*:\s*"single"/, 'and says what this project is' );

( $said, $status ) = run_mode( '--mode', 'chain' );
is( $status, 0, 'the command sets it' );
like( $said, qr/"mode"\s*:\s*"chain"/, 'and says what it set' );
is( $tira->project_mode( project => $root ), 'chain', 'which the engine agrees with' );

( $said, $status ) = run_mode( '--mode', 'nonsense' );
isnt( $status, 0, 'and refuses a word that is not one of the two' );

done_testing();

__END__

=head1 NAME

110-project-mode.t - a project says whether one agent works it or a chain does

=head1 DESCRIPTION

Several rules mean different things depending on whether one agent works a
board or a chain of them does, and nothing recorded which. The answer is asked
at onboarding, stored with the project, and read back by whatever needs it.

The default carries the weight: a project that has never been asked behaves
exactly as it does today, because that is the common case and every existing
board is one.

=cut
