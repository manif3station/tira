#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json encode_json);
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

my $home = File::Spec->catdir( $tmp, 'home' );
my $config = File::Spec->catfile( $home, '.developer-dashboard', 'config', 'config.json' );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'MT5', dir => $root, columns => ['Backlog, Doing'] );

# No heartbeat, no collector.
ok( !defined $tira->collector_entry( project => $root ),
    'a project with no heartbeat produces no collector at all' );

$tira->project_update(
    project => $root, collector => 'mt5', agent => 'claude',
    session => 'sess-1', heartbeat => 10, notify_after => 60,
);
my $entry = $tira->collector_entry( project => $root );
is( $entry->{name}, 'tira.mt5', 'the entry is namespaced so two projects cannot collide' );
is( $entry->{interval}, 600, 'the heartbeat is given in seconds, because that is what it reads' );
is( $entry->{cwd}, $root, 'the entry names the project directory explicitly' );
is( $entry->{mode}, 'singleton', 'only one run at a time' );
ok( $entry->{timeout} > 30, 'with a timeout longer than the default a coding agent would blow' );
like( $entry->{command}, qr/tira-remind/, 'and it runs the reminder script' );

# Installing merges rather than clobbering.
make_path( File::Spec->catdir( $home, '.developer-dashboard', 'config' ) );
open my $seed, '>', $config or die $!;
print {$seed} encode_json( {
    collectors => [ { name => 'telegram-claude-skills', command => 'dashboard telegram-claude.check-message', interval => 5 } ],
    something_else => 'left alone',
} );
close $seed;

{
    local $ENV{HOME} = $home;
    $tira->collector_install( project => $root );
    my $written = decode_json( do { open my $fh, '<', $config or die $!; local $/; <$fh> } );
    is( scalar @{ $written->{collectors} }, 2, 'the new collector joins the existing one' );
    is( $written->{something_else}, 'left alone', 'and the rest of the file is untouched' );
    my ($mine) = grep { $_->{name} eq 'tira.mt5' } @{ $written->{collectors} };
    is( $mine->{interval}, 600, 'with the interval it was given' );
    my ($theirs) = grep { $_->{name} eq 'telegram-claude-skills' } @{ $written->{collectors} };
    is( $theirs->{interval}, 5, 'and nothing of anyone else was changed' );

    # Installing again is the same install, not a second one.
    $tira->project_update( project => $root, heartbeat => 20 );
    $tira->collector_install( project => $root );
    $written = decode_json( do { open my $fh, '<', $config or die $!; local $/; <$fh> } );
    is( scalar @{ $written->{collectors} }, 2, 'installing twice leaves one entry' );
    ($mine) = grep { $_->{name} eq 'tira.mt5' } @{ $written->{collectors} };
    is( $mine->{interval}, 1200, 'updated in place' );

    # Somebody else owning that name must not be trampled.
    my $other = File::Spec->catdir( $tmp, 'other' );
    $tira->project_new( name => 'Other', dir => $other, columns => ['Backlog, Doing'] );
    $tira->project_update( project => $other, collector => 'mt5', session => 's', heartbeat => 5 );
    eval { $tira->collector_install( project => $other ) };
    like( $@, qr/tira\.mt5.*already/i, 'a name another project owns is refused' );
    $written = decode_json( do { open my $fh, '<', $config or die $!; local $/; <$fh> } );
    ($mine) = grep { $_->{name} eq 'tira.mt5' } @{ $written->{collectors} };
    is( $mine->{cwd}, $root, 'and the entry that was there is untouched' );

    my $removed = $tira->collector_remove( project => $root );
    is( $removed->{name}, 'tira.mt5', 'removing reports what it took out' );
    $written = decode_json( do { open my $fh, '<', $config or die $!; local $/; <$fh> } );
    is( scalar @{ $written->{collectors} }, 1, 'and only its own entry' );
    is( $written->{collectors}[0]{name}, 'telegram-claude-skills', 'leaving the other alone' );

    eval { $tira->collector_remove( project => $root ) };
    like( $@, qr/No collector .* is installed/i, 'removing what is not there says so' );
}

# A project with no heartbeat cannot be installed.
{
    local $ENV{HOME} = $home;
    my $quiet = File::Spec->catdir( $tmp, 'quiet' );
    $tira->project_new( name => 'Quiet', dir => $quiet, columns => ['Backlog, Doing'] );
    eval { $tira->collector_install( project => $quiet ) };
    like( $@, qr/heartbeat/i, 'without a heartbeat there is nothing to install' );
}

# The CLI surface.
{
    local $ENV{HOME} = $home;
    my ( $status, $out ) = run_cli( 'collector.show', '--project', $root, '-o', 'json' );
    is( $status, 0, 'the CLI shows the entry' );
    is( decode_json($out)->{name}, 'tira.mt5', 'as it would be installed' );

    ( $status, $out ) = run_cli( 'collector.install', '--project', $root, '-o', 'json' );
    is( $status, 0, 'the CLI installs it' );
    ( $status, $out ) = run_cli( 'collector.remove', '--project', $root, '-o', 'json' );
    is( $status, 0, 'and removes it' );

    ( $status, $out ) = run_cli( 'collector.show', '--help' );
    is( $status, 0, 'the command offers help' );
    unlike( $out, qr/--project|TIRA_HOME/, 'help never discloses project selection' );
}

done_testing;

__END__

=head1 NAME

50-collector.t - registering the reminder job

=head1 DESCRIPTION

Proves the Developer Dashboard entry Tira computes for a project: named
so two projects cannot collide, carrying the heartbeat in the seconds
the runtime actually reads, the project directory named explicitly
rather than inherited, and a timeout longer than the thirty-second
default a coding agent would routinely blow. Installing merges into the
user's own configuration without disturbing anybody else's collectors,
is idempotent, and refuses to trample an entry another project owns.
Computing and installing spawn nothing; the sending itself lives
outside the command surface, which is what keeps Tira's no-external-
process guarantee true.

=cut
