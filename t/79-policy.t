#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();
use Test::More;

use lib 'lib', 't/lib';
use Suite qw(assertion_files);
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Policed', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['Backlog, Doing'],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);
$tira->project_update( project => $root, agent => 'claude' );

# card-sandbox-missing reads branches and work trees, and refuses to be
# declared where no repository can be resolved (TKT-178). This board sits
# inside one, which is the ordinary case and what a real board declaring
# that rule looks like.
mkdir File::Spec->catdir( $root, '.git' );

# --- nothing to begin with -----------------------------------------------

is_deeply( $tira->policy_list( project => $root ), [],
    'a project starts with no policies, which is an empty list rather than an error' );

# --- declaring one -------------------------------------------------------

my $full = $tira->policy_add(
    project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder',
);
like( $full->{id}, qr/\APOL-\d{3}\z/, 'a policy is given a reference of its own' );
is( $full->{rule}, 'card-full-details', 'which remembers its rule' );
is( $full->{action}, 'bridge-reminder', 'and its action' );
is( $full->{enter}, 'implement', 'and the parameters it was given' );

my $duration = $tira->policy_add(
    project => $root, rule => 'card-duration', column => 'implement',
    age => '10m', action => 'bridge-reminder',
    message => 'this card has been in implement for more than ten minutes',
);
is( $duration->{age}, '10m', 'an age is kept as written' );
is( $duration->{message}, 'this card has been in implement for more than ten minutes',
    'and so is the message the owner wants said' );

is( scalar @{ $tira->policy_list( project => $root ) }, 2, 'both are listed back' );
is_deeply(
    [ map { $_->{id} } @{ $tira->policy_list( project => $root ) } ],
    [ 'POL-001', 'POL-002' ],
    'in the order they were set' );

# Policies belong to the project, so they travel with it and can be reviewed
# rather than living in one agent's head.
my $reread = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );
is( scalar @{ $reread->policy_list( project => $root ) }, 2,
    'and they survive for the next process to read' );

# --- refusing what police could not follow -------------------------------

# Refusing at the moment a policy is set is the whole point: a policy police
# cannot follow is worse than no policy, because it reads as cover.
ok( !eval { $tira->policy_add( project => $root, rule => 'invent-a-rule', action => 'bridge-reminder' ); 1 },
    'an unknown rule is refused' );
like( $@, qr/card-stalled/, 'and the refusal names rules that do exist' );

ok( !eval { $tira->policy_add( project => $root, rule => 'card-stalled', before => 'verify', action => 'shout-loudly' ); 1 },
    'an unknown action is refused' );
like( $@, qr/bridge-reminder/, 'and that refusal names the actions that do exist' );

ok( !eval { $tira->policy_add( project => $root, rule => 'card-stalled' ); 1 },
    'a policy with no action is refused' );

ok( !eval { $tira->policy_add( project => $root, rule => 'card-duration',
        column => 'implement', action => 'bridge-reminder' ); 1 },
    'a rule that needs an age is refused without one' );
like( $@, qr/age/, 'and says which parameter is missing' );

ok( !eval { $tira->policy_add( project => $root, rule => 'card-duration',
        column => 'implement', age => 'soonish', action => 'bridge-reminder' ); 1 },
    'an age that is not a duration is refused' );

ok( !eval { $tira->policy_add( project => $root, rule => 'wip-limit',
        column => 'implement', action => 'bridge-reminder' ); 1 },
    'a limit rule is refused without its limit' );

is( scalar @{ $tira->policy_list( project => $root ) }, 2,
    'and none of the refused ones were written' );

# --- the same policy twice -----------------------------------------------

my $again = $tira->policy_add(
    project => $root, rule => 'card-full-details',
    enter => 'implement', action => 'bridge-reminder',
);
is( $again->{id}, 'POL-001', 'setting the same policy twice returns the one that exists' );
is( scalar @{ $tira->policy_list( project => $root ) }, 2, 'rather than doubling it' );

# A policy differing only in its parameters is a different policy, not a
# duplicate - watching two columns is two intentions.
my $other_column = $tira->policy_add(
    project => $root, rule => 'card-full-details',
    enter => 'verify', action => 'bridge-reminder',
);
isnt( $other_column->{id}, 'POL-001', 'the same rule on another column is its own policy' );
is( scalar @{ $tira->policy_list( project => $root ) }, 3, 'and is added' );

# --- removing one --------------------------------------------------------

ok( $tira->policy_remove( project => $root, id => 'POL-002' ), 'a policy can be removed' );
is_deeply(
    [ map { $_->{id} } @{ $tira->policy_list( project => $root ) } ],
    [ 'POL-001', 'POL-003' ],
    'and the rest are left alone' );
ok( !eval { $tira->policy_remove( project => $root, id => 'POL-404' ); 1 },
    'removing one that was never there is an error rather than a quiet success' );

# Numbers are never reused, so a reference in an old log always means the
# policy it meant when it was written.
my $after_removal = $tira->policy_add(
    project => $root, rule => 'orphan-card', action => 'bridge-reminder' );
is( $after_removal->{id}, 'POL-004', 'a new policy takes the next number, never a freed one' );

# --- the catalogue is real ------------------------------------------------

# Every rule this project claims to support must be settable. A rule that is
# documented but cannot be declared is a promise the tool does not keep.
my %needs = (
    'card-full-details'         => { enter => 'implement' },
    'card-metrics'              => { enter => 'implement', require => 'start_date,due_date' },
    'card-duration'             => { column => 'implement', age => '10m' },
    'card-stalled'              => { before => 'verify' },
    'checklist-idle'            => { column => 'implement', age => '30m' },
    'checklist-unmoved'         => {},
    'orphan-card'               => {},
    'monitor-dead'              => {},
    'rules-undeclared'          => {},
    'card-still'                => { age => '2h' },
    'question-unanswered'       => { age => '1h' },
    'conversation-not-folded'   => {},
    'card-unassigned'           => {},
    'card-agentless'            => { enter => 'implement' },
    'answer-waiting'            => {},
    'answer-unjudged'           => { age => '10m' },
    'answer-ok-not-folded'      => { age => '10m' },
    'agent-still'               => { age => '10m' },
    'answer-not-ok-no-followup' => { age => '10m' },
    'wip-limit'                 => { column => 'implement', max => 3 },
    'commit-without-card'       => {},
    'work-without-card'         => { age => '15m' },
    'unpushed-work'             => { age => '1h' },
    'task-unlinked'             => { age => '30m' },
    'task-card-mismatch'        => { column => 'implement' },
    'task-changed'              => {},
    'job-due'                   => {},
    'board-unbacked'            => { age => '2h' },
    'gate-missing'              => { column => 'done' },
    'discard-unexplained'       => {},
    'leftover-process'          => { pattern => 'tail -f', age => '30m' },
    'leftover-container'        => { pattern => 'perl-test', age => '30m' },
    'card-unlinked'             => { require_link => 'is-blocked-by' },
    'card-sandbox-missing'      => { enter => 'implement', sandbox => '~/sandboxes' },
    'parent-ahead-of-children'  => {},
    'priority-skipped'          => {},
    'card-changed-by-owner'     => {},
    'discard-with-open-questions' => {},
    'board-still'               => { age => '8h' },
    'bridge-unread'             => { age => '30m' },
    'column-unwatched'          => {},
    'column-skipped'            => { enter => 'Doing', require => 'Backlog' },
);
my $scratch = File::Spec->catdir( $tmp, 'scratch' );
$tira->project_new(
    name => 'Scratch', dir => $scratch, members => [ 'michael', 'claude' ],
    columns => ['Backlog, Doing'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);

# card-sandbox-missing reads branches and work trees, and refuses to be
# declared where no repository can be resolved (TKT-178). This board sits
# inside one, which is the ordinary case and what a real board declaring
# that rule looks like.
mkdir File::Spec->catdir( $scratch, '.git' );

# And card-changed-by-owner settles by asking whether a change was the agent's
# own, so it refuses a board that has not said which agent works it - the same
# shape as the repository above, for the same reason. TKT-376.
$tira->project_update( project => $scratch, agent => 'claude' );
for my $rule ( sort keys %needs ) {
    ok(
        eval {
            $tira->policy_add( project => $scratch, rule => $rule,
                action => 'bridge-reminder', %{ $needs{$rule} } );
        },
        "the $rule rule can actually be declared" ) or diag $@;
}
is( scalar @{ $tira->policy_list( project => $scratch ) }, scalar keys %needs,
    'every rule in the catalogue is settable' );

is_deeply(
    [ sort @{ Tira::policy_rules() } ],
    [ sort keys %needs ],
    'and the catalogue the tool offers is exactly the catalogue that was designed' );

# One scope per action, because declaring the same rule on the same scope with
# a different action is refused since TKT-339 - and that refusal is the whole
# of that card: zen-framework changed a wip-limit and got a second policy while
# the first went on enforcing the old value. Three actions on one scope is
# three answers to one question, which is precisely what may no longer happen.
#
# The claim here is that each action is accepted, and it is unchanged: each is
# declared on a column of its own.
my %action_scope = (
    'bridge-reminder' => 'verify',
    'print-reminder'  => 'implement',
    'log-only'        => 'review',
);
for my $action ( sort keys %action_scope ) {
    ok(
        eval {
            $tira->policy_add( project => $scratch, rule => 'card-stalled',
                before => $action_scope{$action}, action => $action );
        },
        "the $action action can be declared" ) or diag $@;
}

# --- through the dispatcher ----------------------------------------------

# The engine is only half of it: an agent reaches these through the command
# line, so the argument parsing and the output contract are covered here too.
{
    require Tira::CLI;
    my $cli_root = File::Spec->catdir( $tmp, 'cli' );
    $tira->project_new(
        name => 'Cli', dir => $cli_root, members => ['michael'],
        columns => ['Backlog, Doing'],
        sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
    );

    my $run = sub {
        my (@argv) = @_;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        my $status = do {
            local *STDOUT = $so;
            local *STDERR = $se;
            do { local $ENV{TIRA_HOME} = $cli_root; Tira::CLI->run(
                command => shift(@argv), tira => $tira,
                argv => [ @argv ],
            ) };
        };
        return ( $status, $out, $err );
    };

    my ( $status, $out ) = $run->( 'policy.add', '--rule', 'card-stalled',
        '--before', 'verify', '--action', 'bridge-reminder', '-o', 'json' );
    is( $status, 0, 'policy.add exits clean' );
    my $added = Cpanel::JSON::XS->new->decode($out);
    is( $added->{rule}, 'card-stalled', 'and answers with the policy it declared' );

    ( $status, $out ) = $run->( 'policy.add', '--rule', 'card-duration',
        '--column', 'implement', '--age', '10m', '--action', 'print-reminder',
        '--message', 'still on this one?', '-o', 'json' );
    is( Cpanel::JSON::XS->new->decode($out)->{message}, 'still on this one?',
        'every parameter reaches the engine, including the message' );

    ( $status, $out ) = $run->( 'policy.list', '-o', 'json' );
    is( scalar @{ Cpanel::JSON::XS->new->decode($out) }, 2, 'policy.list returns them' );

    ( $status, my $toon ) = $run->('policy.list');
    # Both of them, by name. This said qr/\S/ under the same description, so a
    # listing that printed one policy - or the word "none" - passed a check
    # claiming it printed two. TKT-196.
    like( $toon, qr/card-stalled/,  'the default listing prints the first policy' );
    like( $toon, qr/card-duration/, 'and the second, which is what "the two policies" claimed' );
    unlike( $toon, qr/"rule"\s*:/, 'and answers TOON by default like every other command' );

    ( $status, $out ) = $run->( 'policy.remove', '--id', 'POL-001', '-o', 'json' );
    is( $status, 0, 'policy.remove exits clean' );
    is( scalar @{ Cpanel::JSON::XS->new->decode( ( $run->( 'policy.list', '-o', 'json' ) )[1] ) },
        1, 'and the policy is gone' );

    ( $status, undef, my $err ) = $run->( 'policy.add', '--rule', 'nope',
        '--action', 'bridge-reminder', '-o', 'json' );
    isnt( $status, 0, 'a bad rule fails through the dispatcher too' );
    like( $err, qr/Unknown policy rule/, 'with the engine message intact' );
}

# --- every declared requirement is exercised -----------------------------------
#
# The other half of the same promise. A rule declares what it cannot work
# without, and the guide says so in as many words: "Anything a rule cannot work
# without is refused when the policy is set, rather than discovered later."
# TKT-128 built the guard for what a rule refuses; nothing proved what a rule
# requires. Scanned on 2026-08-15: 21 rules declare a required parameter and 14
# of those declarations had no test asserting the refusal when it is left out.
#
# A lost requirement costs more than a lost refusal. A rule declared without its
# age reaches the comparison with undef, so it either fires on everything the
# moment it is declared or never fires at all - and both read as the rule being
# broken rather than the policy being incomplete.
#
# Exercised rather than scanned: every requirement is left out in turn and the
# refusal asserted, so a rule added tomorrow is covered without anybody
# extending this. The values come from the catalogue above, which already has a
# good one for every parameter any rule needs.

{
    open my $engine, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
    my $source = do { local $/; <$engine> };
    close $engine;

    my ($table) = $source =~ /my %POLICY_RULES = \((.*?)\n\);/s;

    my ( @required, $entries );
    while ( $table =~ /'([a-z][a-z0-9-]+)'\s*=>\s*\{(.*?)\},?\s*$/gm ) {
        my ( $rule, $body ) = ( $1, $2 );
        $entries++;
        my ($needs) = $body =~ /needs\s*=>\s*\[([^\]]*)\]/;
        next if !defined $needs;
        push @required, [ $rule, $_ ] for $needs =~ /'([a-z_]+)'/g;
    }

    # Counted rather than trusted. A parser that stops early covers less than
    # it claims, which is the fault this guard exists to catch one level up -
    # and TKT-142's guard did exactly that, finding three entries where four
    # were declared.
    my $declares = () = $table =~ /^\s*'[a-z][a-z0-9-]+'\s*=>/gm;
    is( $entries, $declares, 'the parse found every rule the table declares' );
    cmp_ok( scalar @required, '>=', 20,
        'and rules declare parameters they cannot work without' );

    my $bare = File::Spec->catdir( $tmp, 'requirements' );
    $tira->project_new(
        name => 'Requirements', dir => $bare, members => ['michael'],
        columns => ['Backlog, implement, verify, done'],
        sow_prefix => 'RQS', epic_prefix => 'RQE', ticket_prefix => 'RQT',
    );
    mkdir File::Spec->catdir( $bare, '.git' );

    my @accepted;
    for my $requirement (@required) {
        my ( $rule, $missing ) = @{$requirement};
        my %supplied = %{ $needs{$rule} // {} };

        # Every other parameter this rule needs, and this one left out.
        delete $supplied{$missing};

        my $added = eval {
            $tira->policy_add( project => $bare, rule => $rule,
                action => 'bridge-reminder', %supplied );
        };
        next if !$added;

        push @accepted, "$rule was declared without $missing";

        # Removed by the id the add returned, and never allowed to decide the
        # verdict. An earlier version of this removed by rule name, which
        # policy_remove does not take - so on the one path that matters, the
        # rule having been wrongly accepted, it died and took every assertion
        # after it out of the file with it. A test that dies does not only lose
        # its own verdict.
        eval { $tira->policy_remove( project => $bare, id => $added->{id} ); 1 };
    }

    is_deeply( \@accepted, [],
        'every declared requirement is refused when it is left out' );
}

# --- every declared refusal is exercised somewhere -----------------------------
#
# A rule may declare an option it will not honour, and the refusal is real the
# moment it is written. What is not automatic is anything noticing if it stops:
# the rule never reads the option, so a lost refusal fails nowhere - it is
# simply accepted and does nothing.
#
# conversation-not-folded shipped with a declared refusal and no test giving it
# that option, found by a bug hunt rather than by the suite. This is the check
# that would have found it the day it was written.

{
    open my $engine, '<', File::Spec->catfile(qw(lib Tira.pm)) or die $!;
    my $source = do { local $/; <$engine> };
    close $engine;

    my ($table) = $source =~ /my %POLICY_RULES = \((.*?)\n\);/s;
    my @declared;
    while ( $table =~ /'([a-z][a-z0-9-]+)'\s*=>\s*\{[^}]*forbids\s*=>\s*\[([^\]]*)\]/g ) {
        my ( $rule, $list ) = ( $1, $2 );
        push @declared, [ $rule, $_ ] for $list =~ /'([a-z_]+)'/g;
    }
    ok( scalar @declared, 'some rules declare an option they will not honour' );

    my $tests = '';
    for my $file ( assertion_files() ) {
        open my $fh, '<', $file or next;
        $tests .= do { local $/; <$fh> };
        close $fh;
    }

    my @unproved;
    for my $pair (@declared) {
        my ( $rule, $option ) = @{$pair};
        push @unproved, "$rule forbids $option"
          if $tests !~ /rule\s*=>\s*'\Q$rule\E'[^;]*\b\Q$option\E\s*=>/s;
    }
    is_deeply( \@unproved, [],
        'and every one of them has a test that gives it that option' );
}

done_testing;

__END__

=head1 NAME

79-policy.t - TKT-014 declaring what this project cares about

=head1 DESCRIPTION

Police can only watch for what it has been told to watch for, so this is the
surface an agent uses to say so. Policies live in the project config, which
means they travel with the project and can be read by anybody rather than
living in one agent's head.

Everything is refused at the moment it is set rather than discovered later by
police: an unknown rule, an unknown action, a rule declared without the
parameter it needs, an age that is not a duration. A policy police cannot
follow is worse than no policy at all, because it reads as cover.

The last section is the check that matters most for a catalogue. Every rule
the tool claims to support is declared for real, and the list the tool offers
is compared against the list that was designed - in both directions, so a rule
that was documented but never implemented, or implemented but never designed,
shows up here rather than in somebody's disappointment.

=cut
