#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-08T09:00:00Z' } );

sub run_cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv );
    return ( $status, $out, $err );
}

my $root = File::Spec->catdir( $tmp, 'proj' );

# The board every command here works on, named the one way there is.
# TKT-250.
$ENV{TIRA_HOME} = $root;
$tira->project_new( name => 'MT5', dir => $root, columns => ['Backlog, Doing'], members => ['claude'] );

# Every setting stores and reads back.
my $updated = $tira->project_update(
    project => $root, collector => 'mt5', agent => 'claude',
    session => 'abc-123_XYZ', heartbeat => 15, notify_after => 90,
);
is( $updated->{collector}, 'mt5', 'the collector name is stored' );
is( $updated->{agent}, 'claude', 'the coding agent is stored' );
is( $updated->{session}, 'abc-123_XYZ', 'the session id is stored' );
is( $updated->{heartbeat}, 15, 'the heartbeat is stored in minutes' );
is( $updated->{notify_after}, 90, 'and the default staleness threshold' );
my $stored = $tira->project_show( project => $root );
is( $stored->{session}, 'abc-123_XYZ', 'the settings survive being written and read' );

# Bad values are refused and change nothing.
for my $case (
    [ { collector => 'Not A Slug' }, qr/collector/i, 'a collector name that is not a slug' ],
    [ { agent => 'codex' }, qr/Unknown project person/, 'an agent nobody registered on this project' ],
    [ { session => 'has space' }, qr/session/i, 'a session id with a space' ],
    [ { heartbeat => 0 }, qr/heartbeat/i, 'a heartbeat of zero' ],
    [ { heartbeat => 'soon' }, qr/heartbeat/i, 'a heartbeat that is not a number' ],
    [ { notify_after => -5 }, qr/notify/i, 'a negative threshold' ],
) {
    my ( $args, $error, $label ) = @{$case};
    eval { $tira->project_update( project => $root, %{$args} ) };
    like( $@, $error, "$label is refused" );
}
is( $tira->project_show( project => $root )->{session}, 'abc-123_XYZ',
    'and no refused value disturbed what was already stored' );

# Turning the collector off again is explicit.
$tira->project_update( project => $root, heartbeat => '' );
ok( !defined $tira->project_show( project => $root )->{heartbeat},
    'an empty heartbeat clears it, which is how the collector is turned off' );
$tira->project_update( project => $root, heartbeat => 15 );

# The CLI surface.
my ( $status, $out ) = run_cli( 'project.update', '--collector', 'mt-five', '--agent', 'claude', '--session', 'zz9',
    '--heartbeat', '30', '--notify-after', '45', '-o', 'json' );
is( $status, 0, 'the CLI stores every setting' );
my $payload = decode_json($out);
is( $payload->{collector}, 'mt-five', 'the collector name comes back' );
is( $payload->{heartbeat}, 30, 'and the heartbeat' );

( $status, $out ) = run_cli( 'project.update', '--agent', 'nope', '-o', 'json' );
is( $status, 2, 'an unsupported agent exits 2' );

# Whether a coding agent is installed is discovered for real, not only mocked.
# Something that is certainly on the PATH, which is not the same program
# everywhere.
ok( Tira::CLI::_agent_available( $^O eq 'MSWin32' ? 'cmd' : 'sh' ),
    'a program on the path is found' );
ok( !Tira::CLI::_agent_available('tira-no-such-agent'), 'and one that is not there is not' );
{
    local $ENV{PATH} = '';
    ok( !Tira::CLI::_agent_available('sh'), 'with nowhere to look, nothing is found' );
}

# The wizard, with no coding agent on the machine.
sub run_wizard {
    my ( $script, $available, @argv ) = @_;
    open my $fh, '<', \$script or die $!;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    no warnings 'redefine';
    local *Tira::CLI::_agent_available = sub {$available};
    my $status = Tira::CLI->run( command => 'onboard', argv => \@argv, input => $fh );
    return ( $status, $out, $err );
}

my $bare = File::Spec->catdir( $tmp, 'bare' );
( $status, $out ) = run_wizard( <<"ANSWERS", 0, '-o', 'json' );
$bare
Bare
Michael
BRS
BRE
BRT
y
Backlog, Doing
120
single
y
ANSWERS
is( $status, 0, 'onboarding completes with no coding agent installed' );
unlike( $out, qr/session id/i, 'and never asks about a session it could not use' );
unlike( $out, qr/heartbeat/i, 'nor about a heartbeat that could not fire' );
like( $out, qr/stuck/i, 'but still asks how long a card may sit still' );
is( $tira->project_show( project => $bare )->{notify_after}, 120,
    'and the threshold is stored, because staleness is useful without automation' );
ok( !defined $tira->project_show( project => $bare )->{session},
    'with nothing stored about an agent' );

# The wizard, with one installed.
my $wired = File::Spec->catdir( $tmp, 'wired' );
( $status, $out ) = run_wizard( <<"ANSWERS", 1, '-o', 'json' );
$wired
Wired
Michael
WRS
WRE
WRT
y
Backlog, Doing
60
claude
session-999

single
y
ANSWERS
is( $status, 0, 'onboarding completes with a coding agent installed' );
like( $out, qr/session id/i, 'and asks for the session id' );
my $automation = $tira->project_show( project => $wired );
is( $automation->{agent}, 'claude', 'the agent is stored' );
is( $automation->{session}, 'session-999', 'the session id is stored' );
is( $automation->{heartbeat}, 60,
    'the heartbeat follows the staleness answer rather than being asked for twice' );
is( $automation->{collector}, 'wired', 'the collector name defaults from the project name' );

# Every new question rejects a bad answer and asks again rather than storing it.
my $picky = File::Spec->catdir( $tmp, 'picky' );
( $status, $out ) = run_wizard( <<"ANSWERS", 1, '-o', 'json' );
$picky
Picky
Michael
PKS
PKE
PKT
y
Backlog, Doing
soon
0
90
codex
claude
has space
sess1
Not A Slug
good-slug
single
y
ANSWERS
is( $status, 0, 'the flow survives a bad answer to every new question' );
like( $out, qr/positive number of minutes/, 'a threshold that is not a number explains itself' );
like( $out, qr/only coding agent supported today is claude/, 'so does an unsupported agent' );
like( $out, qr/session id is letters/, 'so does a malformed session id' );
like( $out, qr/lowercase letters, digits and hyphens/, 'so does a collector name that is not a slug' );
my $corrected = $tira->project_show( project => $picky );
is( $corrected->{notify_after}, 90, 'and the corrected threshold is what is stored' );
is( $corrected->{session}, 'sess1', 'and the corrected session id' );
is( $corrected->{collector}, 'good-slug', 'and the corrected collector name' );
is( $corrected->{heartbeat}, 90, 'and the heartbeat that followed the corrected threshold' );

( $status, $out ) = run_cli( 'ticket.list', '--collector', 'x', '-o', 'json' );
is( $status, 2, 'the reminder settings are refused on commands they do not belong to' );

# Re-running pre-fills everything, so pressing enter changes nothing.
my $before = $tira->project_show( project => $wired );
( $status, $out ) = run_wizard( <<"ANSWERS", 1, '--dir', $wired, '-o', 'json' );






y





single
y
ANSWERS
is( $status, 0, 're-running onboarding on an existing project completes' );
like( $out, qr/\QWired\E/, 'and offers the stored answers back' );
my $after = $tira->project_show( project => $wired );
is( $after->{session}, $before->{session}, 'pressing enter through it keeps the session id' );
is( $after->{heartbeat}, $before->{heartbeat}, 'and the heartbeat' );
is( $after->{collector}, $before->{collector}, 'and the collector name' );
is( $after->{name}, 'Wired', 'and the project name' );
is_deeply( [ map { $_->{name} } @{ $tira->column_list( project => $wired, type => 'ticket' ) } ],
    [qw(backlog doing discard)], 'and the columns, without duplicating them' );

# Naming a different project reloads its settings rather than carrying these over.
( $status, $out ) = run_wizard( <<"ANSWERS", 1, '--dir', $wired, '-o', 'json' );
$bare











single
y
ANSWERS
is( $status, 0, 'answering a different directory completes' );
is( $tira->project_show( project => $bare )->{name}, 'Bare',
    'the other project keeps its own name' );
ok( !defined $tira->project_show( project => $bare )->{session},
    'and did not inherit the first project session id by pressing enter' );

done_testing;

__END__

=head1 NAME

49-automation.t - automation settings and re-runnable onboarding

=head1 DESCRIPTION

Proves the five settings the reminder automation needs store, read back
and refuse bad values without disturbing what was already there, and
that clearing one is explicit - which is how the collector is turned
off. Proves onboarding can be run again on an existing project with
every answer pre-filled, so pressing enter through it changes nothing,
and that naming a different directory reloads that project's settings
instead of silently carrying the first one's across. When no coding
agent is installed the questions about one never appear, because there
would be nothing to configure and nothing that could deliver.

=cut
