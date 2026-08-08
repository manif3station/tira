#!/usr/bin/env perl

use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
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

my $outer = File::Spec->catdir( $tmp, 'outer' );
$tira->project_new( name => 'Outer', dir => $outer, columns => ['Backlog, Doing'] );

# Straight inside.
my $inside = File::Spec->catdir( $outer, 'inside' );
eval { $tira->project_new( name => 'Inner', dir => $inside ) };
like( $@, qr/Outer/, 'creating inside an existing project names the project it found' );
like( $@, qr/\Q$outer\E/, 'and where that project is' );
ok( !-e $inside, 'and writes nothing' );

# Buried several directories down, which is the case that actually happens.
my $deep = File::Spec->catdir( $outer, 'a', 'b', 'c' );
eval { $tira->project_new( name => 'Deep', dir => $deep ) };
like( $@, qr/Outer/, 'however deep inside it is' );
ok( !-d File::Spec->catdir( $deep, '.tira' ), 'and still writes no project' );

# The older command had the same defect, so it gets the same guard.
eval { $tira->create_project( name => 'Inner', dir => $inside ) };
like( $@, qr/Outer/, 'the older creation command refuses it too' );
ok( !-e $inside, 'and writes nothing either' );

# Deliberate nesting is still possible for anyone who wants it.
my $wanted = File::Spec->catdir( $outer, 'wanted' );
my $nested = $tira->project_new( name => 'Wanted', dir => $wanted, nested => 1 );
is( $nested->{project}{name}, 'Wanted', 'nesting on purpose is allowed' );
ok( -d File::Spec->catdir( $wanted, '.tira' ), 'and really creates the project' );

# Everything that was fine before is still fine.
my $beside = File::Spec->catdir( $tmp, 'beside' );
is( $tira->project_new( name => 'Beside', dir => $beside )->{project}{name}, 'Beside',
    'creating beside a project is unaffected' );
my $clean = File::Spec->catdir( $tmp, 'clean', 'deeper' );
make_path($clean);
is( $tira->project_new( name => 'Clean', dir => $clean )->{project}{name}, 'Clean',
    'so is creating where nothing is above' );

# A directory that is already a project is adoption, not nesting.
is( $tira->project_new( name => 'Beside', dir => $beside )->{project}{name}, 'Beside',
    're-running on a project that is already there still works' );

# The CLI.
my ( $status, $out, $err ) = run_cli( 'project.new', '--name', 'FromCli',
    '--dir', File::Spec->catdir( $outer, 'cli' ), '-o', 'json' );
is( $status, 2, 'the CLI refuses it too' );
like( $err, qr/Outer/, 'and says which project is in the way' );
ok( !-e File::Spec->catdir( $outer, 'cli' ), 'and wrote nothing' );

( $status, $out, $err ) = run_cli( 'project.new', '--name', 'FromCli', '--nested',
    '--dir', File::Spec->catdir( $outer, 'cli' ), '-o', 'json' );
is( $status, 0, 'and allows it when asked deliberately' );

( $status, $out, $err ) = run_cli( 'ticket.list', '--project', $outer, '--nested', '-o', 'json' );
is( $status, 2, 'the option is refused on commands it does not belong to' );

done_testing;

__END__

=head1 NAME

54-nesting.t - DD-447 creating a project inside another one

=head1 DESCRIPTION

Without a directory, creation happens where the person is standing, and
if that is anywhere inside an existing project the new one is buried in
the old one. Project discovery walks upward, so afterwards either
project may answer depending on where a command runs, and nobody is
ever told. Proves creation now refuses that, names the project it found
and where, writes nothing when it refuses, and still allows nesting for
anyone who asks for it on purpose.

=cut
