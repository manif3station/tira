#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-11T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Honest', dir => $root, members => ['michael'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'HNS', epic_prefix => 'HNE', ticket_prefix => 'HNT',
);

# The dispatcher turns skills/ticket/cli/update into record.update with a
# type, so driving it by any other name tests a command that does not exist -
# which three assertions in the first draft of this file did, and passed.
sub run {
    my ( $type, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run(
            command => 'record.' . shift(@argv), type => $type, tira => $tira,
            argv => [ @argv ],
        ) };
    };
    return ( $status, $out, $err );
}

my $epic = $tira->create_record( project => $root, type => 'epic', title => 'A parent' );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'A child' );

# --- the defect ----------------------------------------------------------

# Every ticket on this project's own board was an orphan while the agent
# believed the tree was built, because record.update accepted --parent,
# answered with a successful record, and did nothing with it. The owner saw
# the dash on the card before the agent noticed.
#
# Silent success is the worst of the three possible outcomes. An error would
# have been fixed in seconds. Doing the work would have been right. Reporting
# success while doing nothing cost a whole board's hierarchy.
my ( $status, undef, $err ) = run( 'ticket', 'update', '--ref', $ticket->{ref},
    '--parent', $epic->{ref}, '-o', 'json' );

isnt( $status, 0, 'passing --parent to an update is refused rather than swallowed' );
like( $err, qr/hierarchy\.link/, 'and the refusal names the command that does the job' );
like( $err, qr/\Q$epic->{ref}\E/, 'with the reference already filled in, so the fix is one paste' );

# Read the record back rather than trusting the command's own answer. The
# original defect was invisible precisely because the answer looked right.
my $after = $tira->record_show( project => $root, type => 'ticket', ref => $ticket->{ref} );
is( $after->{parent}, undef, 'and the parent really is unset, checked by reading it back' );

# --- the same on every board that shares the dispatcher ------------------

for my $kind (qw(sow epic)) {
    my $record = $tira->create_record( project => $root, type => $kind, title => "A $kind" );
    my ( $kind_status, undef, $kind_err ) =
      run( $kind, 'update', '--ref', $record->{ref}, '--parent', $epic->{ref}, '-o', 'json' );
    isnt( $kind_status, 0, "$kind.update refuses it too" );
    like( $kind_err, qr/hierarchy\.link/, "and says the same thing for $kind" );
}

# --- what does work still works ------------------------------------------

ok( $tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $ticket->{ref} ),
    'the command the refusal names does the job' );
is( $tira->record_show( project => $root, type => 'ticket', ref => $ticket->{ref} )->{parent},
    $epic->{ref}, 'and the parent is set, read back from the record' );

# An ordinary update is untouched by any of this.
( $status ) = run( 'ticket', 'update', '--ref', $ticket->{ref}, '--title', 'Renamed', '-o', 'json' );
is( $status, 0, 'an update with no misplaced argument still succeeds' );
is( $tira->record_show( project => $root, type => 'ticket', ref => $ticket->{ref} )->{title},
    'Renamed', 'and does what it was asked' );

done_testing;

__END__

=head1 NAME

89-silent-arguments.t - an argument a command cannot honour is refused

=head1 DESCRIPTION

C<record.update> accepted C<--parent>, answered with a successful record and
did nothing with it. Every ticket on this project's own board was an orphan
while the agent believed the tree was built, and the owner saw the empty parent
field on a card before the agent noticed.

Silent success is the worst of the three possible outcomes. An error would have
been fixed in seconds; doing the work would have been correct; reporting
success while doing nothing cost a whole board's hierarchy and was invisible
until somebody looked at the board with their own eyes.

So the refusal names the command that does the job and fills the reference in,
because a refusal that leaves somebody guessing is only half an improvement.
And the record is read back rather than trusted, since the original defect was
invisible precisely because the command's own answer looked correct.

=cut
