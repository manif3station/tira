#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# TKT-1202. job.start read $args->{id} inside its "No job ... on this board"
# message before checking the id was set, so `d2 tira.job.start` with no --id
# printed a Perl "uninitialized value in concatenation" warning and then said
# "No job  on this board" with an empty name, two spaces and all. Its neighbour
# job.stop refuses the same mistake as "A job id is required". Neither said
# which option to type.
#
# What is held here: a start or a stop with no id is refused once, names --id
# and prints no warning at all; a start with an id that is not on the board is
# still answered with that id in the message.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-30T05:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Jobs', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'JBS', epic_prefix => 'JBE', ticket_prefix => 'JBT',
);

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @warned ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, tira => $tira, argv => [ '--author', 'claude', @argv ] );
    };
    return ( $status, $out . $err, \@warned );
}

sub jobs { $tira->job_list( project => $root ) }

my $before = jobs();

for my $command (qw(job.start job.stop)) {
    my ( $status, $said, $warned ) = run($command);

    isnt( $status, 0, "$command with no id is refused" );

    # non-empty is the whole claim for this one: the assertions after it look
    # for words, and would pass vacuously against a command that said nothing.
    like( $said, qr/\S/, "$command says something about it" );

    like( $said, qr/A job id is required/, "$command says the id is what is missing" );
    like( $said, qr/--id\b/, "$command names --id, the option that supplies it" );
    unlike( $said, qr/No job\s{2,}/, "$command does not name a job whose name is empty" );
    is_deeply( $warned, [], "$command emits no Perl warning at all" );
}

is_deeply( jobs(), $before, 'the refused calls changed nothing about any job on the board' );

# --- a start with an id that is not on the board still names that id ------------

{
    my ( $status, $said, $warned ) = run( 'job.start', '--id', 'JOB-NOPE' );
    isnt( $status, 0, 'job.start with an unknown id is still refused' );
    like( $said, qr/No job 'JOB-NOPE'/, 'and says which id was not found' );
    is_deeply( $warned, [], 'without a warning' );
}

done_testing;

__END__

=head1 NAME

1202-job-start-with-no-id-is-refused-quietly.t - job.start and job.stop with no id name --id and warn about nothing

=head1 DESCRIPTION

TKT-1202. C<job.start> with no C<--id> printed a Perl uninitialized-value
warning and answered C<No job  on this board> with an empty name, where
C<job.stop> said C<A job id is required>. This file holds that both commands are
refused once with that sentence and name C<--id>, emit no warning, and change
nothing, and that a start with an unknown id still names the id it was given.

=cut
