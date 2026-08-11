#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-08T09:00:00Z' } );
my $home = File::Spec->catdir( $tmp, 'home' );
my $config = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );

sub run_wizard {
    my ( $script, @argv ) = @_;
    open my $fh, '<', \$script or die $!;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    no warnings 'redefine';
    local *Tira::CLI::_agent_available = sub { 1 };
    my $status = Tira::CLI->run( command => 'onboard', argv => \@argv, input => $fh );
    return ( $status, $out, $err );
}

sub config_collectors {
    return [] if !-f $config;
    open my $fh, '<', $config or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    return decode_json($body)->{collectors} // [];
}

# The owner's first complaint: two questions both wanting a number of minutes.
my $root = File::Spec->catdir( $tmp, 'mt5' );
my ( $status, $out ) = do {
    local $ENV{HOME} = $home;
    run_wizard( <<"ANSWERS", '--dir', $root, '-o', 'json' );
$root
MT5
Michael
M5S
M5E
M5T
y
Backlog, Doing
45
claude
sess-1
mt5
y
ANSWERS
};
is( $status, 0, 'onboarding completes' );
is( scalar( () = $out =~ /[Mm]inutes/g ), 1, 'a number of minutes is asked for exactly once' );

my $project = $tira->project_show( project => $root );
is( $project->{notify_after}, 45, 'the answer sets how long a card may sit still' );
is( $project->{heartbeat}, 45,
    'and the heartbeat follows it, because looking more often than that finds nothing new' );

# The worst of the four: the name went into the project file and nowhere else.
my $collectors = config_collectors();
is( scalar @{$collectors}, 1, 'onboarding registers the collector it just asked about' );
is( $collectors->[0]{name}, 'tira.mt5', 'under the name it will really answer to' );
is( $collectors->[0]{cwd}, $root, 'pointed at this project' );
is( $collectors->[0]{interval}, 45 * 60, 'with the heartbeat in the seconds the runtime reads' );

# And it says so, using the name that actually starts it.
like( $out, qr/tira\.mt5/, 'onboarding reports the name it registered' );
like( $out, qr/collector start/, 'and the command that starts it' );

# An explicit heartbeat still wins over the derived one.
my $tuned = File::Spec->catdir( $tmp, 'tuned' );
( $status, $out ) = do {
    local $ENV{HOME} = $home;
    run_wizard( <<"ANSWERS", '--dir', $tuned, '--heartbeat', '5', '-o', 'json' );
$tuned
Tuned
Michael
TNS
TNE
TNT
y
Backlog, Doing
90
claude
sess-2
tuned
y
ANSWERS
};
is( $status, 0, 'onboarding completes with an explicit heartbeat' );
is( $tira->project_show( project => $tuned )->{heartbeat}, 5,
    'an explicit heartbeat is not overwritten by the derived one' );
is( $tira->project_show( project => $tuned )->{notify_after}, 90, 'and the threshold is still the answer' );

# Nothing to deliver to means nothing registered.
my $quiet = File::Spec->catdir( $tmp, 'quiet' );
( $status, $out ) = do {
    local $ENV{HOME} = $home;
    run_wizard( <<"ANSWERS", '--dir', $quiet, '-o', 'json' );
$quiet
Quiet
Michael
QTS
QTE
QTT
y
Backlog, Doing


claude


y
ANSWERS
};
is( $status, 0, 'onboarding completes with no reminder settings' );
is( scalar @{ config_collectors() }, 2, 'and registers nothing when there is nothing to deliver to' );
unlike( $out, qr/collector start/, 'and does not claim to have registered one' );

# Registering this way must leave everybody else alone, like the command does.
my ($mine) = grep { $_->{name} eq 'tira.mt5' } @{ config_collectors() };
is( $mine->{cwd}, $root, 'the first project is still registered as it was' );

# The last complaint: the directory question should offer what is already there.
{
    local $ENV{HOME} = $home;
    local $ENV{TIRA_HOME} = $root;
    ( $status, $out ) = run_wizard( "\n" x 14, '-o', 'json' );
    like( $out, qr/Project directory \[\Q$root\E\]/,
        'the directory question offers the project that is already resolvable' );
    is( $status, 0, 'and pressing enter through it works from anywhere' );
}

done_testing;

__END__

=head1 NAME

55-onboard-collector.t - onboarding that collected settings and did nothing with them

=head1 DESCRIPTION

The owner filled in the reminder settings during onboarding and found
no collector anywhere afterwards: the name was written to the project
file and registering it with Developer Dashboard was a separate command
that nothing called. Proves onboarding now registers the job itself,
reports the name it will really answer to and how to start it, asks for
a number of minutes only once with the heartbeat following the
staleness answer, and offers the already-resolvable project as the
directory rather than making somebody type it.

=cut
