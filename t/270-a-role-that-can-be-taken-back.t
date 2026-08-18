#!/usr/bin/env perl
# A role declared by mistake can be taken back.
#
# Found by making the mistake. Probing what tira.column.roles accepts, I ran
# 'tira.column.roles --type ticket --role nonsense=backlog' against the live
# board. It was accepted and stored. There is no command that removes a role -
# column_roles_set merges what it is given into what is there and nothing
# deletes - and an empty value is refused as malformed rather than read as a
# removal. Undoing one command meant editing .tira/ticket/config.yml by hand.
#
# His answer when told: "also a card to allow agent to remove junk rules?"
#
# It matters more since roles became load-bearing. He asked for tira.next to
# pick from a column he chooses, and pointed out that the column's NAME is this
# project's only - "other project might use another name that you need to
# consider that factor" - so the board declares which of its columns means
# 'next' and the code reads the role. A vocabulary the board cannot correct is a
# worse thing to depend on than one it can.
#
# What is NOT added, and the reasoning is on TKT-384: a refusal for a role name
# no rule reads. I had written that as an acceptance criterion, reasoning from
# the existing refusal for a role pointing at a column that does not exist. It
# is wrong. Any name can be read, because a policy names one through
# --enter-role, --before-role or --column-role, and the natural order is to
# declare the vocabulary and then the policies that use it - so refusing an
# unread name would refuse the first half of every correct sequence.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T14:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Roled', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'RLS', epic_prefix => 'RLE', ticket_prefix => 'RLT',
);

# --- a role can be taken back -------------------------------------------------------

{
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { nonsense => 'backlog' } );
    my $with = $tira->column_roles( project => $root, type => 'ticket' );
    is( $with->{nonsense}, 'backlog', 'a role can be declared, as it always could' );

    ok( Tira->can('column_roles_remove'), 'and the board offers a way to take one back' );

    my $left = $tira->column_roles_remove( project => $root, type => 'ticket',
        roles => ['nonsense'], author => 'claude', reason => 'A probe left it here' );
    ok( !exists $left->{nonsense}, 'the role is gone' );

    my $reread = Tira->new( clock => sub {'2026-08-18T14:00:00Z'} )
      ->column_roles( project => $root, type => 'ticket' );
    ok( !exists $reread->{nonsense},
        'and stays gone for the next process to read, which is what editing the file by hand was for' );
}

# --- and the roles beside it are left alone --------------------------------------------
#
# Written as declare-two-remove-one after the first draft assumed a new board
# starts with backlog and done roles. It does not - this project's board carries
# them because somebody declared them - and asserting a default that does not
# exist would have been a test passing on a coincidence.

{
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { keeper => 'implement', doomed => 'done' } );

    $tira->column_roles_remove( project => $root, type => 'ticket',
        roles => ['doomed'], author => 'claude', reason => 'Not needed after all' );

    my $roles = $tira->column_roles( project => $root, type => 'ticket' );
    is( $roles->{keeper}, 'implement', 'a role beside the removed one survives' );
    ok( !exists $roles->{doomed}, 'and only the named one goes' );
}

# --- and it is accountable ---------------------------------------------------------------
#
# His requirement: "if they do. they need to provide a reason for it and there
# will be a column logs to log that reason. who and why." The precedent is
# rule.suspend, which refuses without a reason because "a silence nobody can
# account for is worse than the noise it replaces" - and a role vanishing from a
# board's vocabulary is the same kind of act, since every policy written against
# it stops meaning what it meant.

{
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { unexplained => 'done' } );

    my $silent = eval {
        $tira->column_roles_remove( project => $root, type => 'ticket',
            roles => ['unexplained'] );
        1;
    };
    ok( !$silent, 'removing a role with no reason is refused' );
    like( $@ // '', qr/reason/i, 'and the refusal asks for one' );

    $tira->column_roles_remove( project => $root, type => 'ticket',
        roles => ['unexplained'], author => 'claude',
        reason => 'Declared by a probe against the wrong board' );

    my $log = $tira->column_role_log( project => $root, type => 'ticket' );
    my ($said) = grep { ( $_->{role} // '' ) eq 'unexplained' } @{$log};
    ok( $said, 'the removal is written down' );
    is( $said->{author}, 'claude', 'with who did it' );
    like( $said->{reason} // '', qr/probe/, 'and why' );
    ok( defined $said->{at}, 'and when' );
}

# --- a role a policy depends on is not quietly removed ---------------------------------
#
# The half that keeps this from being a foot-gun. A policy naming a role that
# stops existing matches nothing at all, silently, which is the exact failure
# the declaration guard already refuses in the other direction: "a role pointing
# at nothing would make every rule written against it match nothing at all,
# silently, while somebody believed it was protecting them".

{
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { reviewing => 'implement' } );
    my $policy = $tira->policy_add( project => $root, rule => 'card-full-details',
        enter_role => 'reviewing', action => 'bridge-reminder' );

    my $removed = eval {
        $tira->column_roles_remove( project => $root, type => 'ticket',
            roles => ['reviewing'], author => 'claude', reason => 'Tidying' );
        1;
    };
    ok( !$removed, 'a role a policy names cannot be removed out from under it' );
    like( $@ // '', qr/\Q$policy->{id}\E/, 'and the refusal says which policy depends on it' );

    my $still = $tira->column_roles( project => $root, type => 'ticket' );
    is( $still->{reviewing}, 'implement', 'so the role is still there' );

    # And once the policy is gone, so may the role be.
    $tira->policy_remove( project => $root, id => $policy->{id} );
    my $after = $tira->column_roles_remove( project => $root, type => 'ticket',
        roles => ['reviewing'], author => 'claude', reason => 'Policy gone first' );
    ok( !exists $after->{reviewing}, 'and removing the policy first lets the role go' );
}

# --- removing one that was never there says so -----------------------------------------
#
# Rather than succeeding quietly, which would let a typo in the REMOVAL read as a
# removal that worked.

{
    my $gone = eval {
        $tira->column_roles_remove( project => $root, type => 'ticket',
            roles => ['never-declared'], author => 'claude', reason => 'Typo' );
        1;
    };
    ok( !$gone, 'removing a role that was never declared is refused' );
}

# --- and writing to a board nobody named is still refused --------------------------------
#
# The same promise column_roles_set makes: reading without naming a board is a
# convenience, writing to one nobody named is a surprise.

{
    my $typeless = eval {
        $tira->column_roles_remove( project => $root, roles => ['backlog'],
            author => 'claude', reason => 'No board named' );
        1;
    };
    ok( !$typeless, 'removing without naming a board is refused' );
    like( $@ // '', qr/--type/, 'and the refusal names what is missing' );
}

# --- and it is reachable from the command line ---------------------------------------
#
# The engine half proves the rule; this proves a person can get at it. Both
# halves are needed: the first --remove-role I wired had no reason flag reaching
# it at all, and an engine that demands one is no use behind a CLI that cannot
# supply it.

{
    my $sub = tempdir( CLEANUP => 1 );
    my $cli = Tira->new( clock => sub {'2026-08-18T14:00:00Z'} );
    my $cwd = File::Spec->catdir( $sub, 'cliproj' );
    $cli->project_new(
        name => 'CLId', dir => $cwd, members => ['claude'],
        columns => ['backlog, implement, done'],
        sow_prefix => 'CLS', epic_prefix => 'CLE', ticket_prefix => 'CLT',
    );

    my $run = sub {
        my (@argv) = @_;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        my $died = '';
        {
            local *STDOUT = $so;
            local *STDERR = $se;
            local $ENV{TIRA_HOME} = $cwd;
            eval { Tira::CLI->run( command => 'column.roles', tira => $cli, argv => [@argv] ); 1 }
              or $died = $@ // 'died';
        }
        # The CLI turns a refusal into stderr rather than letting it out, so
        # the complaint is whichever of the two carried it.
        return ( $died . $err, $out );
    };

    $run->( '--type', 'ticket', '--role', 'junk=done' );
    is( $cli->column_roles( project => $cwd, type => 'ticket' )->{junk}, 'done',
        'a role can be declared from the command line' );

    my ($silent) = $run->( '--type', 'ticket', '--remove-role', 'junk' );
    like( $silent, qr/reason/i, 'and removing it there needs a reason too' );

    my ($ok) = $run->( '--type', 'ticket', '--remove-role', 'junk',
        '--reason', 'Declared against the wrong board', '--author', 'claude' );
    is( $ok, '', 'with one, the removal goes through' );
    ok( !exists $cli->column_roles( project => $cwd, type => 'ticket' )->{junk},
        'the role is gone' );

    my ($logged) = grep { ( $_->{role} // '' ) eq 'junk' }
      @{ $cli->column_role_log( project => $cwd, type => 'ticket' ) };
    is( $logged->{author}, 'claude', 'and the log names who did it from the CLI' );
    like( $logged->{reason}, qr/wrong board/, 'and why' );

    # A reason with no removal would be stored nowhere and read as recorded.
    my ($stray) = $run->( '--type', 'ticket', '--role', 'other=done',
        '--reason', 'Because' );
    like( $stray, qr/--remove-role/, 'a reason with no removal is refused rather than dropped' );
}

# --- proved by putting the merge back ------------------------------------------------------
#
# Without a removal that deletes, the old behaviour is that a role sticks - which
# is what sent me into .tira with an editor.

{
    $tira->column_roles_set( project => $root, type => 'ticket',
        roles => { transient => 'done' } );

    no warnings 'redefine';
    local *Tira::column_roles_remove = sub {
        my ( $self, %args ) = @_;
        return $self->column_roles( project => $args{project}, type => $args{type} );
    };

    $tira->column_roles_remove( project => $root, type => 'ticket', roles => ['transient'],
        author => 'claude', reason => 'Proving the merge' );
    my $stuck = $tira->column_roles( project => $root, type => 'ticket' );
    is( $stuck->{transient}, 'done',
        'a removal that does not delete leaves the junk role exactly where it was' );
}

done_testing;

__END__

=head1 NAME

270-a-role-that-can-be-taken-back.t - TKT-384

=head1 DESCRIPTION

C<column_roles_set> merged and nothing deleted, so a role declared by mistake was
permanent and undoing one command meant editing C<.tira> by hand. A role can now
be removed, unless a policy names it - in which case the refusal says which one,
because a policy whose role stopped existing matches nothing at all, silently.

=cut
