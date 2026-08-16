#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Pipelined', dir => $root, members => ['michael'],
    columns => ['todo, shaping, doing, qa, audit, shipping, live, archived'],
    sow_prefix => 'PPS', epic_prefix => 'PPE', ticket_prefix => 'PPT',
);

# --- a board that has said nothing keeps working --------------------------

# Roles are an addition, not a migration. A project that never declares one
# must behave exactly as it did before, or this becomes something everybody has
# to do before anything else works.
is_deeply( $tira->column_roles( project => $root, type => 'ticket' ), {},
    'a board with no roles declared has none, rather than being given defaults' );

my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'Nothing declared' );
$tira->record_move( project => $root, ref => $bare->{ref}, column => 'doing' );
$tira->policy_add( project => $root, rule => 'card-full-details',
    enter => 'doing', action => 'bridge-reminder' );
is( scalar( grep { $_->{rule} eq 'card-full-details' }
        @{ $tira->policy_evaluate( project => $root ) } ), 1,
    'and a rule naming a column outright still works exactly as before' );

# --- saying which column is which -----------------------------------------

# His words: what is backlog means WHICH COLUMN IS the backlog. So one command
# answers all of them, and every role may be left unset - most projects have no
# column for most of these, and the absence of one is not a problem to report.
my $declared = $tira->column_roles_set(
    project => $root, type => 'ticket',
    roles => {
        backlog => 'todo', planning => 'shaping', 'in-progress' => 'doing',
        testing => 'qa', 'security-check' => 'audit', deploying => 'shipping',
        'deployed-production' => 'live', done => 'archived',
    },
);
is( $declared->{'in-progress'}, 'doing', 'a role says which column plays it' );
is( scalar keys %{ $tira->column_roles( project => $root, type => 'ticket' ) }, 8,
    'and all of them are remembered' );

ok( !exists $tira->column_roles( project => $root, type => 'ticket' )->{'ready-to-deploy'},
    'a role nobody named is simply absent, not empty or invented' );

# The vocabulary is the project's own. Tira matches roles without needing to
# understand them, so a project can describe work Tira has never heard of.
$tira->column_roles_set( project => $root, type => 'ticket',
    roles => { 'waiting-on-legal' => 'audit' } );
is( $tira->column_roles( project => $root, type => 'ticket' )->{'waiting-on-legal'}, 'audit',
    'a project may invent a role of its own' );

ok( !eval { $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { backlog => 'no-such-column' } ); 1 },
    'but a role cannot name a column that does not exist' );
is( $tira->column_roles( project => $root, type => 'ticket' )->{backlog}, 'todo',
    'and the refused change left the existing one alone' );

# --- a rule written against a role ----------------------------------------

$tira->policy_add( project => $root, rule => 'card-stalled',
    before_role => 'testing', action => 'bridge-reminder' );
$tira->checklist_add( project => $root, ref => $bare->{ref}, item => 'the work', status => 'done' );
my @stalled = grep { $_->{rule} eq 'card-stalled' } @{ $tira->policy_evaluate( project => $root ) };
is( scalar @stalled, 1, 'a rule written against a role fires on the column carrying it' );

# --- and it survives the column being renamed -----------------------------

# This is the whole point. A rule tied to a column name says nothing the moment
# somebody renames the column; a rule tied to a role follows the meaning.
$tira->column_rename( project => $root, type => 'ticket', name => 'qa', new_name => 'testing-lane' );
$tira->column_roles_set( project => $root, type => 'ticket',
    roles => { testing => 'testing-lane' } );
@stalled = grep { $_->{rule} eq 'card-stalled' } @{ $tira->policy_evaluate( project => $root ) };
is( scalar @stalled, 1, 'and it still fires once the role points at the new name' );

# --- a role nothing carries is said, not silently matched nothing ---------

$tira->policy_add( project => $root, rule => 'card-full-details',
    enter_role => 'deployed-demo', action => 'bridge-reminder' );
my $unresolved = $tira->policy_unresolved( project => $root );
ok( scalar( grep { $_->{detail} =~ /deployed-demo/ } @{$unresolved} ),
    'a rule naming a role no column carries is reported rather than quietly matching nothing' );

$tira->column_roles_set( project => $root, type => 'ticket',
    roles => { 'deployed-demo' => 'live' } );
ok( !scalar( grep { $_->{detail} =~ /deployed-demo/ } @{ $tira->policy_unresolved( project => $root ) } ),
    'and once a column carries it, there is nothing left to say' );

# --- two columns can share a role -----------------------------------------

$tira->column_roles_set( project => $root, type => 'ticket',
    roles => { 'in-progress' => 'doing', 'in-progress-too' => 'shipping' } );
my $roles = $tira->column_roles( project => $root, type => 'ticket' );
is( $roles->{'in-progress'}, 'doing', 'roles stay distinct even when they mean similar things' );
is( $roles->{'in-progress-too'}, 'shipping', 'and each names its own column' );

# --- asking without naming a board ----------------------------------------

# The owner types this to see what his columns mean. Answering "Unsupported
# record type ''" names an internal argument he did not use and does not say
# what to type instead - and there is no need to ask him at all, because the
# question has an answer for every board.
{
    require Tira::CLI;

    $tira->column_roles_set( project => $root, type => 'epic',
        roles => { 'in-progress' => 'doing' } );

    my $everything = $tira->column_roles( project => $root );
    is_deeply( [ sort keys %{$everything} ], [qw(epic sow ticket)],
        'asking without naming a board answers for all three' );
    is( $everything->{epic}{'in-progress'}, 'doing',
        'each with its own roles, because columns are per board' );
    is_deeply( $everything->{sow}, {}, 'and a board that has declared none says so' );

    # Reading is one thing; writing to a board nobody named is another.
    ok( !eval { $tira->column_roles_set( project => $root,
                roles => { 'in-progress' => 'doing' } ); 1 },
        'setting a role without naming a board is refused' );
    like( $@, qr/--type/, 'and the refusal names the argument that is missing' );
    like( $@, qr/tira\.column\.roles/, 'in a command that can be run as it stands' );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'column.roles', tira => $tira,
            argv => [ '-o', 'json' ] ) };
    };
    is( $status, 0, 'and the command itself answers rather than failing' );
    like( $out, qr/"ticket"/, 'with every board named in what it returns' );
}

done_testing;

__END__

=head1 NAME

88-column-roles.t - which column is the backlog

=head1 DESCRIPTION

A rule that names a column outright is tied to one board's vocabulary: it says
nothing on a project that calls the same thing something else, and it says
nothing the moment somebody renames the column. Roles fix that. The agent
declares which column is the backlog, which is in progress, which is deployed
to production, and rules can then be written against the meaning.

The vocabulary is the project's own. Tira matches a role without needing to
understand it, so a project can describe work Tira has never heard of - and
anything police needs to say about a card moving forwards or backwards comes
from the column order rather than from the role name.

Every role is optional, because most projects have no column for most of them,
and the absence of a column is not something to report. A board that declares
no roles at all must behave exactly as it did before: this is an addition, not
a migration.

The refusal that matters is a role naming a column that does not exist. It is
neither accepted quietly nor guessed at - a role pointing at nothing would make
every rule written against it silently match nothing, which is the worst
possible failure for a rule somebody believes is protecting them.

=cut
