#!/usr/bin/env perl
# A role the documents offer can be given.
#
# The command reference says a policy can name a column by role with
# --enter-role, --before-role or --column-role. Two of the three work. The third
# was never in the parser: policy.add answered "Unknown option: column-role" and
# refused the whole command.
#
# The engine has always been ready for it. column_role is declared beside the
# other two in the list of role fields, and evaluated in the same loop. Only the
# way to put a value there was missing.
#
# Why 100% coverage did not catch it, which is the more useful half. The loop
# runs over three fields and its statements are executed by the tests that set
# the other two, so every line is covered; the column_role pass reaches
# "next if !defined" - a covered line - and stops. A field can be declared,
# evaluated, documented and fully covered, and still have never once held a
# value. Coverage says a line ran, not that a case was tried.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $now  = '2026-08-16T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Roled', dir => $root, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'RDS', epic_prefix => 'RDE', ticket_prefix => 'RDT',
);
$tira->column_roles_set( project => $root, type => 'ticket',
    roles => { 'in-progress' => 'implement' } );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- the two that worked, so the third is a gap rather than a misreading -----

# Each with a rule that needs the column that role stands in for, since naming
# it by role is how the requirement is met.
for my $pair ( [ 'card-full-details', 'enter-role' ], [ 'card-stalled', 'before-role' ] ) {
    my ( $rule, $role ) = @{$pair};
    my ( $status, $said ) = run( 'policy.add', '--rule', $rule,
        '--action', 'log-only', "--$role", 'in-progress' );
    is( $status, 0, "--$role is accepted, as the documents say" ) or diag $said;
}

# --- and the one the documents promise the same way -------------------------

{
    my ( $status, $said ) = run( 'policy.add', '--rule', 'card-duration',
        '--action', 'log-only', '--column-role', 'in-progress', '--age', '30m' );

    is( $status, 0, '--column-role is accepted too' ) or diag $said;

    # What a command that accepts an option says: the policy it made. That is
    # what makes the denial below mean something rather than pass on silence.
    like( $said, qr/card-duration/, 'answering with the policy it declared' );
    unlike( $said, qr/Unknown option/,
        'rather than refusing the whole command as an unknown option' );
}

# --- and the value reaches the policy ----------------------------------------
#
# Accepting an option and dropping it is the fault this project has spent the
# morning on. The stored record is asked, not the command's own output.

{
    my ($stored) = grep { ( $_->{rule} // '' ) eq 'card-duration' }
      @{ $tira->policy_list( project => $root ) };

    ok( $stored, 'the policy is on the board' );
    is( $stored->{column_role}, 'in-progress',
        'carrying the role it was given, where the engine already looks for it' );
}

# --- and it is read like the other two ---------------------------------------
#
# The engine resolves a role to whatever column that board says it means, so a
# rule declared by role must watch the column the role names.

{
    my $card = $tira->create_record( project => $root, type => 'ticket',
        title => 'Sitting in the column the role names' );
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );

    # The clock is moved rather than a time passed in: the age is measured
    # against the engine's own clock, so handing police a later moment as an
    # argument changes nothing and the rule would say nothing for a reason that
    # has nothing to do with roles.
    $now = '2026-08-16T11:00:00Z';
    my $pass = $tira->police_pass( project => $root,
        store => File::Spec->catdir( $tmp, 'police' ), world => {} );

    my @duration = grep { ( $_->{rule} // '' ) eq 'card-duration' }
      @{ $pass->{violations} };
    ok( scalar @duration,
        'and a card in that column is reported, so the role was resolved' );
}

done_testing;

__END__

=head1 NAME

242-a-role-the-documents-promise.t - the third role, which could not be given

=head1 DESCRIPTION

The command reference offers C<--enter-role>, C<--before-role> and
C<--column-role>. The last was never in the parser, so it refused the command
it appeared in, while the engine declared and evaluated the field it fills.

Covered but never exercised: the loop that handles all three roles had every
line run by the tests for the other two, and the pass for this one stopped at a
covered C<next>. Coverage says a line ran, not that a case was tried.

=cut
