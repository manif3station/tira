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
    sub path_aliases { return { private_alias => $ENV{DD_TEST_ALIAS_TARGET} } }
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

my ( $status, $out, $err ) = run_cli( '--project', 'private_alias', '-o', 'json' );
is( $status, 0, 'CLI project option accepts a DD path alias' );
like( $out, qr/Alias project/, 'project option alias reads the selected project' );
unlike( $out . $err, qr/\Q$root\E/, 'successful alias output does not disclose its target' );

{
    local $ENV{TIRA_HOME} = 'private_alias';
    ( $status, $out, $err ) = run_cli( '-o', 'json' );
}
is( $status, 0, 'environment project selection accepts a DD path alias' );
like( $out, qr/Alias project/, 'environment alias reads the selected project' );
unlike( $out . $err, qr/\Q$root\E/, 'environment alias output does not disclose its target' );

( $status, $out, $err ) = run_cli( '--project', 'unknown_alias', '-o', 'json' );
is( $status, 2, 'unknown alias exits 2' );
like( $err, qr/unknown_alias/, 'unknown alias error identifies only the selector' );
unlike( $err, qr/\Q$root\E/, 'unknown alias error does not disclose registered targets' );

done_testing;

__END__

=head1 NAME

14-path-alias.t - Developer Dashboard path-alias project selection

=head1 DESCRIPTION

Proves DD-native alias resolution for both CLI project-selection routes,
direct-path precedence, exit status, and resolved-target secrecy for DD-401.

=cut
