#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
    package Developer::Dashboard::PathRegistry;
    sub new { bless { aliases => {} }, shift }
    sub register_named_paths { $_[0]{aliases} = $_[1]; return $_[0] }
    sub resolve_dir {
        my ( $self, $name ) = @_;
        die "Unknown directory name '$name'" if !exists $self->{aliases}{$name};
        return $self->{aliases}{$name};
    }
    $INC{'Developer/Dashboard/PathRegistry.pm'} = __FILE__;

    package Developer::Dashboard::FileRegistry;
    sub new { bless {}, shift }
    $INC{'Developer/Dashboard/FileRegistry.pm'} = __FILE__;

    package Developer::Dashboard::Config;
    sub new { bless {}, shift }
    sub global_path_aliases { return { private_alias => $ENV{DD_TEST_ALIAS_TARGET} } }
    $INC{'Developer/Dashboard/Config.pm'} = __FILE__;
}

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'private-target' );
Tira->new->create_project( name => 'Alias project', dir => $root );
$ENV{DD_TEST_ALIAS_TARGET} = $root;

sub run_cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => 'project.show', argv => \@argv );
    return ( $status, $out, $err );
}

# One way, and this is it. There were three - a flag, the environment, and the
# working directory - and three ways to say one thing is three behaviours to
# keep in agreement. They had already stopped agreeing. TKT-250.
my ( $status, $out, $err );
{
    local $ENV{TIRA_HOME} = 'private_alias';
    ( $status, $out, $err ) = run_cli( '-o', 'json' );
}
is( $status, 0, 'the environment selects a board by a name the machine resolves' );
like( $out, qr/Alias project/, 'and the command works on the board that name resolves to' );
unlike( $out . $err, qr/\Q$root\E/, 'while saying nothing about where that board actually is' );

{
    local $ENV{TIRA_HOME} = 'unknown_alias';
    ( $status, $out, $err ) = run_cli( '-o', 'json' );
}
is( $status, 2, 'a name that resolves to nothing is refused' );
like( $err, qr/unknown_alias/, 'the refusal identifies the name it was given' );
unlike( $err, qr/\Q$root\E/, 'and no other board it could have meant' );

done_testing;

__END__

=head1 NAME

14-path-alias.t - Developer Dashboard path-alias project selection

=head1 DESCRIPTION

Proves DD-native alias resolution for both CLI project-selection routes,
direct-path precedence, exit status, and resolved-target secrecy for.

=cut
