#!/usr/bin/env perl
# A command named for the owner's watcher is the owner's; the rest are the
# agent's, and their names say so.
#
# He sent a transcript of another project's agent working this out, and it took
# three corrections:
#
#   > do not run the police command
#   Understood - I've stopped.
#   > is mine
#   Understood - police is yours. I won't run it or treat myself as its consumer.
#   > you need to keep the policy.bridge and watch for any message. that is yours
#   Understood - the split is clean: police is yours; the bridge is mine.
#   > tira.police.log is fine. but tira.police is mine
#   Precisely - that's a three-way split, not two.
#
# and its own summary of what went wrong: "My two previous commits got this
# boundary wrong in both directions - first too narrow, then too broad."
#
# tira.police runs the owner's watching loop. tira.police.log reads the
# enforcement log and writes nothing. They share a prefix and nothing else, so
# an agent told "police is mine" gives up the read too - and stops seeing every
# suspension and escalation ever recorded. That failure is silent in both
# directions: a read nobody makes and an empty read look identical.
#
# So the read is named for what it reads. tira.policy.bridge.logs sits beside
# tira.policy.bridge, which that agent had already been told was its own, and
# tira.police is left meaning exactly one thing.
#
# The old name keeps working. Renaming a shipped command breaks every board that
# used it on upgrade; it simply stops being documented.

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
my $tira = Tira->new( clock => sub {'2026-08-13T17:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Whose', dir => $root, members => [ 'michael', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'WSS', epic_prefix => 'WSE', ticket_prefix => 'WST',
);
my $store = File::Spec->catdir( $tmp, 'police' );

# Something in the log to read: a suspension is written by police rather than by
# the agent, which is the whole reason the log is worth reading.
$tira->police_suspend( project => $root, store => $store, seconds => 60,
    reason => 'chasing one failing test', author => 'ada' );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => shift(@argv), tira => $tira,
            argv => [ '--store', $store, @argv ] ) };
    };
    return ( $status, $out, $err );
}

# --- the name that says what it reads -------------------------------------------

my ( $status, $out ) = run( 'policy.bridge.logs', '-o', 'json' );
is( $status, 0, 'the read has a name of its own, beside the bridge' );
my $read = decode_json($out);
ok( scalar @{$read}, 'and it reads the enforcement log' );
like( decode_json($out)->[0]{detail}, qr/chasing one failing test/,
    'including a suspension, which is what police writes and the agent reads' );

# --- and the old one still answers ----------------------------------------------
#
# Every board that already runs police.log keeps working. A rename that breaks
# on upgrade is a rename nobody forgives.

my ( $old_status, $old_out ) = run( 'police.log', '-o', 'json' );
is( $old_status, 0, 'the old name still answers' );
is_deeply( decode_json($old_out), $read, 'with exactly what the new one says' );

# --- the owner's watcher is untouched --------------------------------------------
#
# Nothing here may quietly rename the thing he runs. tira.police stays what it
# was, because that is the one command this whole card exists to leave alone.

my %shipped;
for my $path ( 'cli/police', File::Spec->catfile(qw(skills police cli log)) ) {
    $shipped{$path} = -f $path ? 1 : 0;
}
is( $shipped{'cli/police'}, 1, 'tira.police still ships, unchanged' );
is( $shipped{ File::Spec->catfile(qw(skills police cli log)) }, 1,
    'and so does the old entrypoint, because upgrading must not take it away' );
ok( -f File::Spec->catfile(qw(skills policy skills bridge cli logs)),
    'the new name ships as its own entrypoint' );

# --- the documents carry the new name and explain the old ------------------------

my $reference = do {
    open my $handle, '<', 'docs/commands.md' or die $!;
    local $/;
    <$handle>;
};
like( $reference, qr/tira\.policy\.bridge\.logs/, 'the reference documents the new name' );
like( $reference, qr/police\.log/,
    'and still mentions the old one, because somebody reading a script will meet it' );

# --- and says whose each command is ----------------------------------------------
#
# The sentence that did not exist. The name is what made the confusion
# expensive; nothing saying the boundary out loud is what made it possible.

like( $reference, qr/tira\.police.{0,400}owner/is,
    'the reference says which police command belongs to the owner' );

done_testing;

__END__

=head1 NAME

134-whose-command-is-it.t - the read is named for what it reads

=head1 DESCRIPTION

C<tira.police> runs the owner's watching loop; C<tira.police.log> reads the
enforcement log and writes nothing. Sharing a prefix cost another project's
agent three corrections before it had the boundary right, and getting it wrong
means silently giving up every suspension and escalation ever recorded.

The read is now C<tira.policy.bridge.logs>, beside C<tira.policy.bridge> which
that agent had already been told was its own. The old name still answers, so no
board breaks on upgrade, and the documents carry the new one and say whose each
command is.

=cut
