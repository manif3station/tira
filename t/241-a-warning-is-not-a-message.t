#!/usr/bin/env perl
# A missing argument is refused, not warned about.
#
# Found by running every shipping entrypoint with no arguments from inside a
# board: eight of them answer a missing required argument with a Perl warning
# naming an internal hash key, a source file and a line number, and then refuse
# with a sentence about the empty string they were given -
#
#     Use of uninitialized value $args{"id"} in concatenation at Tira.pm line N
#     error: "Person '' not found"
#
# so a caller learns that a person called nothing does not exist, under
# something that reads like a crash.
#
# Nothing is damaged and that was checked rather than assumed: the value is used
# before it is validated, and the validation still catches it. This is a fault
# in what is said - but the worst form of one, because it does not look like a
# message at all.
#
# The standard is already in the tool, and the reporter of the neighbouring card
# named it himself: "Policy rule card-sandbox-missing needs --enter" takes no
# guessing.
#
# Driven through the dispatcher rather than by calling the engine, because the
# path a caller takes is the one that has to be right.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Spoken', dir => $root, members => [ 'claude', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SPS', epic_prefix => 'SPE', ticket_prefix => 'SPT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something to point the commands at' );

# Warnings caught rather than left to the terminal: a warning that reaches a
# caller is the whole subject here, so it has to be captured to be asserted on.
sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err, $warned ) = ( '', '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err, $warned );
}

# Each command, the argument it cannot work without, and enough context for the
# refusal to be about that argument rather than about something else missing.
my @commands = (
    [ 'project.people.update',     'id',      [] ],
    [ 'project.people.remove',     'id',      [] ],
    [ 'project.people.activate',   'id',      [] ],
    [ 'project.people.deactivate', 'id',      [] ],
    [ 'project.link-types.remove', 'outward', [] ],
    [ 'hierarchy.show',            'ref',     [] ],
    [ 'attachment.add',            'file',    [ '--ref', $card->{ref} ] ],
    [ 'comment.attach',            'file',    [ '--ref', $card->{ref}, '--id', 'CMT-001' ] ],
);

for my $each (@commands) {
    my ( $command, $option, $context ) = @{$each};
    my ( $status, $said, $warned ) = run( $command, @{$context} );

    isnt( $status, 0, "$command with no --$option is refused" );

    # An empty warning stream is what passes here, deliberately: the whole
    # claim is that nothing was warned about.
    is( $warned, '', "$command says it without warning about its own internals" );

    like( $said, qr/--\Q$option\E/, "$command names the option that is missing" );
    unlike( $said, qr/uninitialized|Tira\.pm line/,
        "$command does not answer with a source file and a line number" );
}

# --- and nothing was touched -------------------------------------------------
#
# What makes this a fault in what is said rather than in what is done. Asserted
# rather than assumed, because "nothing is damaged" is exactly the sort of claim
# that turns out to be wrong.

{
    my $before = $tira->project_show( project => $root );
    run('project.people.remove');
    my $after = $tira->project_show( project => $root );
    is_deeply( $after->{people}, $before->{people},
        'a refused removal leaves the people exactly as they were' );
}

# --- while supplying the argument behaves as before --------------------------

{
    my ( $status, $said ) = run( 'project.people.update', '--id', 'ada', '--name', 'Ada L' );
    is( $status, 0, 'a command given its argument still works' );
    like( $said, qr/Ada L/, 'and does what it was asked' );

    my ( $missing, $answer ) = run( 'project.people.update', '--id', 'nobody', '--name', 'X' );
    isnt( $missing, 0, 'and a person who is not there is still refused' );
    like( $answer, qr/nobody/, 'naming who was asked for' );
}

done_testing;

__END__

=head1 NAME

241-a-warning-is-not-a-message.t - refusing without leaking the internals

=head1 DESCRIPTION

Eight commands used a required argument before validating it, so a missing one
produced a Perl warning naming an internal hash key and a line number, followed
by a refusal about the empty string. Each now refuses first, naming the option
that was left out.

Nothing was ever damaged by this, which is asserted here rather than assumed:
the value reached a message, and the validation underneath still caught it.

=cut
