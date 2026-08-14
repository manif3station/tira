#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Policed', dir => $root, members => ['michael'],
    columns => ['Backlog, Doing'],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);

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
    'leftover-process'          => { pattern => 'tail -f', age => '30m' },
    'leftover-container'        => { pattern => 'perl-test', age => '30m' },
    'card-unlinked'             => { require_link => 'is-blocked-by' },
    'card-sandbox-missing'      => { enter => 'implement', sandbox => '~/sandboxes' },
    'parent-ahead-of-children'  => {},
    'column-skipped'            => { enter => 'Doing', require => 'Backlog' },
);
my $scratch = File::Spec->catdir( $tmp, 'scratch' );
$tira->project_new(
    name => 'Scratch', dir => $scratch, members => ['michael'],
    columns => ['Backlog, Doing'],
    sow_prefix => 'SCS', epic_prefix => 'SCE', ticket_prefix => 'SCT',
);
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

for my $action (qw(bridge-reminder print-reminder log-only)) {
    ok(
        eval {
            $tira->policy_add( project => $scratch, rule => 'card-stalled',
                before => 'verify', action => $action );
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
            Tira::CLI->run(
                command => shift(@argv), tira => $tira,
                argv => [ '--project', $cli_root, @argv ],
            );
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
    like( $toon, qr/\S/, 'the default listing prints the two policies' );
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
    for my $file ( glob 't/*.t' ) {
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
