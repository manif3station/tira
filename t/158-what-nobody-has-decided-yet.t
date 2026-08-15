#!/usr/bin/env perl
# The party that can declare a policy can ask what it has not declared.
#
# mt5-ai lost eighty-four minutes to a rule that had never been declared. An
# owner's answer sat answered-and-unread, then read-and-unmarked, and nothing
# said so, because answer-waiting was not set. It had not been declined either -
# it was never considered. Police behaved correctly throughout: an undeclared
# rule cannot fire.
#
# The agent is the only party that can declare a policy, and until now there was
# no command by which it could discover what it had not. policy.list answers
# what is declared, policy.declined answers what was refused on purpose, and
# nothing answered the rest. They checked policy.undeclared, policy.rules and
# policy.catalogue against the release and all three were unknown commands.
#
# The fact existed. Police prints the undeclared rules for the owner to paste
# across, every run - but that lands on a terminal the agent cannot read, and it
# is printed when police STARTS. Theirs had been running eight hours, so it was
# printed once, hours earlier, to somebody asleep. They are explicit that they
# are not asking for the owner's prompt to change, and it does not.
#
# A rule declared nowhere is the quietest failure here. It is not a rule firing
# wrongly or a channel gone silent - it is a rule nobody asked for, and nothing
# on any board says so. The declined list exists precisely so a deliberate no
# can be told from an omission, and without its complement the agent cannot draw
# that distinction at all.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Shipped qw(runnable_ok);
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-14T12:00:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Undecided', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'UDS', epic_prefix => 'UDE', ticket_prefix => 'UDT',
);

my $every = $tira->policy_rules;

# --- a project that has decided nothing --------------------------------------------

my $undeclared = $tira->policy_undeclared( project => $root );
is_deeply( $undeclared, $every,
    'a project that has declared nothing has every rule still to decide' );

# --- declaring one answers it -------------------------------------------------------

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );
my %left = map { $_ => 1 } @{ $tira->policy_undeclared( project => $root ) };
ok( !$left{'card-full-details'}, 'a rule that has been declared is no longer waiting to be' );
ok( $left{'answer-waiting'}, 'while the rest still are' );

# --- and so does declining it --------------------------------------------------------
#
# The distinction the whole card is about. A rule somebody looked at and said no
# to is answered; a rule nobody has considered is not, and only the second is
# worth telling anybody about.

$tira->policy_decline( project => $root, rule => 'wip-limit',
    reason => 'this board is worked by one agent, so a limit says nothing' );
%left = map { $_ => 1 } @{ $tira->policy_undeclared( project => $root ) };
ok( !$left{'wip-limit'}, 'a rule that was declined is answered, not undeclared' );

# --- the rule their miss was about ----------------------------------------------------

ok( $left{'answer-waiting'},
    'answer-waiting is reported as undeclared, which is what nothing could say for eighty-four minutes' );

# --- a project that has decided everything ---------------------------------------------
#
# An empty answer rather than a missing command. Their report named three
# commands they had tried and found unknown, and an unknown command reads as
# "this cannot be asked" rather than "there is nothing to say".

for my $rule ( @{ $tira->policy_undeclared( project => $root ) } ) {
    $tira->policy_decline( project => $root, rule => $rule,
        reason => 'considered and not wanted on this board' );
}
is_deeply( $tira->policy_undeclared( project => $root ), [],
    'a project that has decided every rule is told there is nothing left' );

# --- one decision, not two --------------------------------------------------------------
#
# Police already computed this to print for the owner. A second copy would be
# two answers to one question, and this project has spent a long night on what
# happens when those drift.

{
    open my $fh, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;
    my ($prompt) = $source =~ /sub police_prompt \{(.*?)\n\}/s;
    like( $prompt, qr/policy_undeclared/,
        'police asks the same question rather than working it out again' );
}

# --- and an agent can actually type it ----------------------------------------------------

{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'policy.undeclared', tira => $tira,
            argv => [ '--project', $root, '-o', 'json' ] );
    };
    is( $status, 0, 'the command runs' );
    is_deeply( Tira::json_decode($out), [], 'and answers with what is left to decide' );
}

runnable_ok( File::Spec->catfile(qw(skills policy cli undeclared)),
    'and it ships as an entrypoint an agent can reach' );

# --- named where a reader of the reference will find it -------------------------------------
#
# mt5-ai have now reported three command families they could not find because
# they were documented outside the manual they had captured. A new command that
# only the manual names would be the fourth.

for my $document (qw(SKILLS.md docs/commands.md)) {
    open my $fh, '<', $document or die "$document: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr/tira\.policy\.undeclared/, "$document names it" );
}

done_testing;

__END__

=head1 NAME

158-what-nobody-has-decided-yet.t - the agent can ask what it has not declared

=head1 DESCRIPTION

An agent is the only party that can declare a policy and had no way to discover
what it had not declared: C<policy.list> answers what is declared,
C<policy.declined> what was refused, and nothing answered the rest. A project
lost eighty-four minutes to a rule that had never been considered.

C<tira.policy.undeclared> answers it. A declined rule is answered rather than
undeclared, a project that has decided everything gets an empty answer rather
than an unknown command, and police asks the same question it prints for the
owner rather than working it out a second time.

=cut
