#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-12T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Fresh', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'PPS', epic_prefix => 'PPE', ticket_prefix => 'PPT',
);

# card-sandbox-missing reads branches and work trees, and refuses to be
# declared where no repository can be resolved (TKT-178). This board sits
# inside one, which is the ordinary case and what a real board declaring
# that rule looks like.
mkdir File::Spec->catdir( $root, '.git' );

# --- a project nobody has set up ------------------------------------------

# Police watches a board with no policies and finds nothing, because there is
# nothing to find - and silence looks exactly like compliance. So it hands the
# owner something to give the agent rather than leaving him to write it.
my $fresh = $tira->police_prompt( project => $root );

ok( $fresh, 'a project with no policies is given a prompt' );
like( $fresh, qr/tira\.skills/, 'telling the agent to read the skill manual' );
like( $fresh, qr/tira\.usage/, 'and the command reference' );
like( $fresh, qr/tira\.policies/, 'and how policies work on this project' );
like( $fresh, qr/tira\.policy\.bridge/, 'and to run the bridge so police can reach it' );
like( $fresh, qr/keep(?:ing)? it running/i, 'and keep it running rather than run it once' );
like( $fresh, qr/one ticket|a single ticket|single backlog/i,
    'and to gather every question onto one card rather than asking piecemeal' );
like( $fresh, qr/reason/i, 'each question carrying why it is being asked' );
like( $fresh, qr/voice note/i, 'and a voice note, because that is how he answers' );

# --- and again, because remembering which run was the first is his job least of all

my $again = $tira->police_prompt( project => $root );
is( $again, $fresh, 'and it says the same thing on every run, not only the first' );

# --- a project set up before rules that now exist -------------------------

# The dangerous case: police enforcing yesterday's catalogue while rules added
# since sit unused, and nobody noticing because a rule nobody declared is
# silent in exactly the way a rule being obeyed is.
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder' );

my $behind = $tira->police_prompt( project => $root );
ok( $behind, 'a project using some rules and not others is given a prompt too' );
isnt( $behind, $fresh, 'a different one: it has been set up, it is just behind' );
like( $behind, qr/parent-ahead-of-children/,
    'naming a rule it is not using, rather than saying something new exists' );
unlike( $behind, qr/\bcard-full-details\b/,
    'and not naming the one it already uses' );
like( $behind, qr/tira\.policies/, 'still pointing at where the rules are explained' );
like( $behind, qr/one ticket|a single ticket|single backlog/i,
    'and still asking for questions on one card' );

# --- a project using everything -------------------------------------------

# Nagging somebody who has already done it is how a prompt gets ignored.
{
    my %needs = (
        'card-metrics'              => { enter => 'implement', require => 'due_date' },
        'card-duration'             => { column => 'implement', age => '10m' },
        'card-stalled'              => { before => 'implement' },
        'checklist-idle'            => { column => 'implement', age => '30m' },
        'orphan-card'               => {},
        'question-unanswered'       => { age => '1h' },
        'conversation-not-folded'   => {},
        'card-unassigned'           => {},
        'answer-waiting'            => {},
        'answer-unjudged'           => { age => '10m' },
        'answer-ok-not-folded'      => { age => '10m' },
        'answer-not-ok-no-followup' => { age => '10m' },
        'wip-limit'                 => { column => 'implement', max => 3 },
        'commit-without-card'       => {},
        'work-without-card'         => { age => '15m' },
        'unpushed-work'             => { age => '1h' },
        'board-unbacked'            => { age => '2h' },
        'gate-missing'              => { column => 'done' },
        'discard-unexplained'       => {},
        'leftover-process'          => { pattern => 'sleep', age => '30m' },
        'leftover-container'        => { pattern => 'perl-test', age => '30m' },
        'card-sandbox-missing'      => { enter => 'implement', sandbox => '/sandboxes' },
        'card-unlinked'             => { require_link => 'is-blocked-by' },
        'parent-ahead-of-children'  => {},
        'priority-skipped'          => {},
        'discard-with-open-questions' => {},
        'board-still'               => { age => '8h' },
        'bridge-unread'             => { age => '30m' },
        'column-skipped'            => { enter => 'done', require => 'implement' },
    );
    $tira->policy_add( project => $root, rule => $_, action => 'log-only', %{ $needs{$_} } )
      for sort keys %needs;

    is( $tira->police_prompt( project => $root ), undef,
        'a project using every rule is left alone' );
}

# --- and police itself prints it ------------------------------------------

# The prompt exists to be copied out of his terminal, so it has to actually
# appear there rather than only be available to anybody who calls a subroutine.
{
    require Tira::CLI;
    my $bare = File::Spec->catdir( $tmp, 'bare' );
    $tira->project_new(
        name => 'Bare', dir => $bare, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'BRS', epic_prefix => 'BRE', ticket_prefix => 'BRT',
    );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'police', tira => $tira,
            argv => [ '--project', $bare, '--once', '--store',
                File::Spec->catdir( $tmp, 'police-store' ), '-o', 'json' ] );
    }

    like( $err, qr/tira\.policies/,
        'running police prints the prompt where the owner can copy it' );
    like( $err, qr/tira\.policy\.bridge/, 'bridge and all' );
}

done_testing;

__END__

=head1 NAME

98-police-prompt.t - what police hands the owner to give the agent

=head1 DESCRIPTION

Michael runs police in a terminal of his own. What it never did was tell him
what to say to the agent, so he wrote the instructions himself every time.

Two prompts, because there are two situations and they need different things
said. A project with no policies has to be taught: read the manual, read the
usage, read how policies work here, declare what this project needs, and run
the bridge so police can reach you. A project that has policies but was set up
before rules that now exist has to be told which rules it is not using - by
name, because "something new exists" is not something anybody can act on.

A project using everything is left alone. Nagging somebody who has already done
it is how a prompt stops being read.

It prints on every run rather than the first, because remembering which run was
the first is exactly the sort of thing the owner should not have to do.

=cut
