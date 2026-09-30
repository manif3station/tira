#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Data::Dumper;
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# TKT-1203. The sweep behind TKT-1202 found two more refusals of a missing
# required option that named a thing rather than the option: release.record
# said "Gate name is required" (its usage line requires --gate) and job.add said
# "A schedule is required - a cron expression, or 'monitor'" (it requires
# --schedule). Both refuse correctly and write nothing; they were only absent
# from the %SUPPLIED_BY table in lib/Tira/CLI/Usage.pm.
#
# What is held here: each names its option, still exits non-zero, prints no
# Perl warning and leaves the board as it was.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-30T05:50:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Named', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NMS', epic_prefix => 'NME', ticket_prefix => 'NMT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that a refused call must not touch', priority => 3 );

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

sub snapshot {
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Indent   = 0;
    return Dumper( [ $shown, $tira->job_list( project => $root ) ] );
}

my @cases = (
    [ 'release.record', [ '--ref', $card->{ref} ], '--gate' ],
    [ 'job.add',        [ '--message', 'a note' ], '--schedule' ],
);

my $before = snapshot();
for my $case (@cases) {
    my ( $command, $argv, $option ) = @$case;
    my ( $status, $said, $warned ) = run( $command, @$argv );

    isnt( $status, 0, "$command with the value left out is still refused" );

    # non-empty is the whole claim for this one: the assertions after it look
    # for words, and would pass vacuously against a command that said nothing.
    like( $said, qr/\S/, "$command says something about it" );

    like( $said, qr/\Q$option\E\b/, "$command names $option, the option that supplies it" );
    is_deeply( $warned, [], "$command emits no Perl warning at all" );
}
is( snapshot(), $before, 'no refused call changed any field of the card or any job' );

# --- a call that does supply the value is unchanged -----------------------------

{
    my ( $status, $said ) = run( 'job.add', '--schedule', '0 * * * *', '--message', 'a note' );
    is( $status, 0, 'job.add with --schedule still succeeds' );
    isnt( snapshot(), $before, 'and the snapshot notices the new job, so it can catch a refused call that wrote one' );
}

done_testing;

__END__

=head1 NAME

1203-two-more-refusals-that-name-their-option.t - release.record and job.add say which option to supply

=head1 DESCRIPTION

TKT-1203. C<release.record> with no gate and C<job.add> with no schedule
refused in words that named a thing rather than C<--gate> or C<--schedule>.
This file holds that each names its option, still exits non-zero, prints no
Perl warning and changes nothing, and that a C<job.add> which supplies the
schedule works and is visible to the snapshot.

=cut
