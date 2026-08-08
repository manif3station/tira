#!/usr/bin/env perl

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# Under taint mode a spawn needs its paths proven clean first, and this is the
# one test that spawns anything at all.
sub untaint {
    my ($value) = @_;
    $value =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe path '$value'";
    return $1;
}

my $tmp = untaint( tempdir( CLEANUP => 1 ) );
my $tick = '2026-08-08T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );
my $script = untaint( abs_path('collector/tira-remind') );
my $bin = File::Spec->catdir( $tmp, 'bin' );
my $log = File::Spec->catfile( $tmp, 'called.log' );
make_path($bin);

# A stub coding agent: records that it was asked, and fails when told to.
my $stub = File::Spec->catfile( $bin, 'agent-stub' );
open my $fh, '>', $stub or die $!;
print {$fh} <<'STUB';
#!/usr/bin/env perl
use strict; use warnings;
open my $out, '>>', $ENV{STUB_LOG} or die $!;
my $args = join( "\x1f", @ARGV );
$args =~ s/\n/\\n/g;                 # one line per call, whatever the message
print {$out} "$args\n";
close $out;
exit( $ENV{STUB_EXIT} // 0 );
STUB
close $fh;
chmod 0755, $stub;

sub calls {
    return 0 if !-f $log;
    open my $in, '<', $log or die $!;
    my @lines = <$in>;
    close $in;
    return wantarray ? @lines : scalar @lines;
}

sub remind {
    my ( $root, %opt ) = @_;
    unlink $log;
    local $ENV{PATH} = untaint("$bin:/usr/bin:/bin");
    local $ENV{STUB_LOG} = $log;
    local $ENV{STUB_EXIT} = $opt{exit} // 0;
    local $ENV{TIRA_AGENT_BIN} = $opt{agent} // 'agent-stub';
    my $status = system( untaint($^X), $script, untaint($root) );
    return $status >> 8;
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Nagged', dir => $root, columns => ['Backlog, Doing'] );
$tira->column_update( project => $root, type => 'ticket', name => 'doing', notify_after => 30 );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Stuck work' );

# Nothing stale: nothing is sent, and that is not a failure.
$tira->project_update( project => $root, session => 'sess-1', agent => 'claude', heartbeat => 5 );
is( remind($root), 0, 'with nothing stale the collector exits cleanly' );
is( scalar calls(), 0, 'and says nothing to the agent' );

$tira->record_move( project => $root, ref => $card->{ref}, column => 'doing' );
$tick = '2026-08-08T13:00:00Z';

# No agent installed: still not a failure, still silent.
is( remind( $root, agent => 'tira-no-such-agent' ), 0,
    'with no coding agent installed the collector exits cleanly' );
is( scalar calls(), 0, 'and does not pretend to have sent anything' );
is_deeply( $tira->notification_list( project => $root ), [],
    'and records nothing, so escalation is not advanced by a message nobody got' );

# No session configured: the same.
$tira->project_update( project => $root, session => '' );
is( remind($root), 0, 'with no session configured the collector exits cleanly' );
is( scalar calls(), 0, 'and sends nothing' );
$tira->project_update( project => $root, session => 'sess-1' );

# A real delivery.
is( remind($root), 0, 'a delivered reminder exits cleanly' );
my @sent = calls();
is( scalar @sent, 1, 'the agent is asked exactly once' );
like( $sent[0], qr/--resume\x1fsess-1/, 'and asked to resume the configured session' );
like( $sent[0], qr/\Q$card->{ref}\E/, 'with the card named in the message' );
like( $sent[0], qr/Stuck work/, 'and what the card is' );
is( scalar @{ $tira->notification_list( project => $root ) }, 1,
    'and the card is recorded, once it really was delivered' );
is( $tira->notification_level( project => $root, ref => $card->{ref}, column => 'doing' ), 1,
    'at the column it is sitting in' );

# Escalation rises across heartbeats.
is( remind($root), 0, 'a second heartbeat delivers again' );
is( $tira->notification_level( project => $root, ref => $card->{ref}, column => 'doing' ), 2,
    'and the card escalates' );

# A delivery that fails is retried once, then told to somebody.
is( remind( $root, exit => 3 ), 0,
    'a failed delivery still exits cleanly, so the runtime watchdog is not fed' );
is( scalar calls(), 2, 'the agent is tried twice, because a session can go stale mid-flight' );
is( $tira->notification_level( project => $root, ref => $card->{ref}, column => 'doing' ), 2,
    'nothing is recorded for a message that never arrived' );
my $warnings = $tira->warning_list( project => $root );
is( scalar @{$warnings}, 1, 'and a warning is left where somebody will see it' );
like( $warnings->[0]{message}, qr/sess-1/, 'naming the session that failed' );
like( $warnings->[0]{message}, qr/tira\.project\.update/, 'and how to put it right' );

# The same failure again must not pile up.
remind( $root, exit => 3 );
is( scalar @{ $tira->warning_list( project => $root ) }, 1, 'a repeated failure stays one warning' );

# A project that cannot be read at all.
is( remind( File::Spec->catdir( $tmp, 'nowhere' ) ), 0, 'an unreadable project exits cleanly' );

done_testing;

__END__

=head1 NAME

51-remind.t - DD-463 the reminder collector, driven against a stub agent

=head1 DESCRIPTION

Proves the one part of Tira that runs another program. Nothing stale, no
coding agent installed and no session configured each exit cleanly and
send nothing: none is a fault, and failing every heartbeat would light
an error indicator and feed the runtime watchdog for no reason. A real
delivery is recorded only once it has happened, so escalation never
counts a message nobody saw; a failure is retried once and then written
where the next command will show it, naming the session and how to fix
it.

=cut
