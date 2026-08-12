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
my $tick = '2026-08-08T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

sub run_cli {
    my ( $command, @argv ) = @_;

    # Mirror the installed dispatcher: a board command carries its type.
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, type => $type, argv => \@argv );
    return ( $status, $out, $err );
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Warned', dir => $root, columns => ['Backlog, Doing'] );
$tira->create_record( project => $root, type => 'ticket', title => 'Some work' );
my $store = File::Spec->catfile( $root, '.tira', 'warnings.json' );

# A quiet project stays quiet.
is_deeply( $tira->warning_list( project => $root ), [], 'a project with no warnings has none' );
ok( !-e $store, 'and no warning file is created by asking' );
my ( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $root );
is( $status, 0, 'an ordinary command succeeds' );
unlike( $out, qr/Attention/, 'and prints no banner when there is nothing wrong' );

# A failure the collector could not otherwise report.
my $message = "Cannot reach the coding agent session 'abc123'; reminders are not being delivered.";
my $first = $tira->warning_add( project => $root, message => $message );
is( $first->{id}, 1, 'the first warning is numbered 1' );
is( $first->{at}, $tick, 'and stamped with when it happened' );
is( $first->{message}, $message, 'and keeps the message verbatim' );

# The same failure again must not pile up.
$tick = '2026-08-08T10:00:00Z';
my $repeat = $tira->warning_add( project => $root, message => $message );
is( $repeat->{id}, 1, 'the same message keeps the warning it already had' );
is( $repeat->{at}, '2026-08-08T09:00:00Z', 'and keeps when it was first seen' );
is( scalar @{ $tira->warning_list( project => $root ) }, 1, 'so there is still only one warning' );

my $other = $tira->warning_add( project => $root, message => 'The coding agent is not installed.' );
is( $other->{id}, 2, 'a different failure is a different warning' );
is( scalar @{ $tira->warning_list( project => $root ) }, 2, 'and both are kept' );

# Bad input is refused.
for my $case ( [ {}, 'a missing message' ], [ { message => '' }, 'an empty message' ] ) {
    my ( $args, $label ) = @{$case};
    eval { $tira->warning_add( project => $root, %{$args} ) };
    like( $@, qr/message/i, "$label is refused" );
}
is( scalar @{ $tira->warning_list( project => $root ) }, 2, 'and nothing was written by a refused call' );

# It appears under the output of an unrelated command, which is the whole point.
( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $root, '-o', 'human' );
is( $status, 0, 'the unrelated command still succeeds' );
like( $out, qr/\Q$message\E/, 'the warning appears in the output of an unrelated command' );
like( $out, qr/\[1\]/, 'the banner names the warning identifier' );
like( $out, qr/tira\.warning\.clear/, 'and the command that clears it' );
like( $out, qr/Some work/, 'and the command output itself is still there' );

# Every machine payload must stay parseable, so the banner goes to standard
# error there - including for the default format, which agents parse.
( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $root, '-o', 'json' );
is( $status, 0, 'the machine-format command succeeds' );
my $payload = eval { decode_json($out) };
ok( $payload, 'the JSON payload is still parseable' );
unlike( $out, qr/Attention/, 'because the banner is kept out of it' );
like( $err, qr/\Q$message\E/, 'and written where an agent still reads it' );

( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $root );
like( $err, qr/\Q$message\E/, 'the default format is treated as machine output too' );
unlike( $out, qr/Attention/, 'so the default payload stays parseable as well' );

# Listing warnings does not print the banner over its own output.
( $status, $out, $err ) = run_cli( 'warning.list', '--project', $root, '-o', 'json' );
is( $status, 0, 'the warning list succeeds' );
is( scalar @{ decode_json($out) }, 2, 'and returns every warning' );
is( $err, '', 'without repeating itself as a banner' );

# Clearing.
eval { $tira->warning_clear( project => $root, id => 99 ) };
like( $@, qr/Warning '99' not found/, 'clearing an unknown warning is refused' );
is( scalar @{ $tira->warning_list( project => $root ) }, 2, 'and changes nothing' );

my $cleared = $tira->warning_clear( project => $root, id => 1 );
is( scalar @{$cleared}, 1, 'clearing by identifier removes one warning' );
is( $cleared->[0]{id}, 1, 'and reports which' );
is_deeply( [ map { $_->{id} } @{ $tira->warning_list( project => $root ) } ], [2],
    'leaving the others alone' );

( $status, $out, $err ) = run_cli( 'warning.clear', '--project', $root, '--all', '-o', 'json' );
is( $status, 0, 'clearing everything succeeds' );
is( scalar @{ decode_json($out) }, 1, 'and reports what it removed' );
is_deeply( $tira->warning_list( project => $root ), [], 'the project is quiet again' );

( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $root, '-o', 'human' );
unlike( $out, qr/Attention/, 'so ordinary commands stop showing a banner' );

# The CLI surface.
( $status, $out, $err ) = run_cli( 'warning.add', '--project', $root, '--message', 'From the CLI', '-o', 'json' );
is( $status, 0, 'the CLI adds a warning' );
is( decode_json($out)->{message}, 'From the CLI', 'and returns it' );

( $status, $out, $err ) = run_cli( 'warning.add', '--project', $root, '-o', 'json' );
is( $status, 2, 'a missing message exits 2' );

( $status, $out, $err ) = run_cli( 'warning.clear', '--project', $root, '-o', 'json' );
is( $status, 2, 'clearing without saying what exits 2' );
like( $err, qr/--id|--all/, 'and says which to use' );

( $status, $out, $err ) = run_cli( 'warning.list', '--help' );
is( $status, 0, 'the command offers help' );
unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );

( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $root, '--all', '-o', 'json' );
is( $status, 2, 'the clearing options are refused on commands they do not belong to' );

done_testing;

__END__

=head1 NAME

47-warning.t - collector failures that nobody would otherwise see

=head1 DESCRIPTION

A collector runs unattended, so a delivery failure has nobody to tell
and would pass silently while the owner believed cards were being
chased. Proves that such a failure is stored once however often it
recurs, is shown under the output of whatever command anyone runs next,
names the command that clears it, and keeps appearing until somebody
does. Machine payloads stay parseable: the banner goes to standard
error there, which a human and a coding agent both still read.

=cut
