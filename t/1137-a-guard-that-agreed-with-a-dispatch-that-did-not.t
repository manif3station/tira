#!/usr/bin/env perl
# TKT-1079. lib/Tira/CLI.pm's own option guard says:
#     die "Nested belongs to the project.new, project.create and onboard
#     commands\n" if $option->{nested} && $command !~
#     /\A(?:project\.(?:new|create)|onboard)\z/;
# which accepts --nested for project.create as a legitimate reader. But the
# dispatch line right below it never passes it on:
#     return $tira->create_project( name => $option->{name}, dir =>
#     $option->{dir} // '.' ) if $command eq 'project.create';
# Tira->create_project itself forwards %args straight through to
# _refuse_nesting fine - the bug is entirely in the CLI dispatch dropping
# nested on the floor before create_project ever sees it. So
# `d2 tira.project.create --dir DIR --nested` inside an existing project's
# tree still refuses, exactly as if --nested had never been typed, which is
# the opposite of what the guard above already promises.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_AUTHOR} = 'ada';
    my $status = Tira::CLI->run( command => $command, type => undef, argv => \@argv );
    return ( $status, $out, $err );
}

# --- an outer project, then a directory inside it ---------------------------

my $outer = File::Spec->catdir( $tmp, 'outer' );
my ( $status, $out, $err ) = cli( 'project.create', '--name', 'Outer', '--dir', $outer );
is( $status, 0, 'the outer project was created' ) or diag("stderr: $err");

my $inner = File::Spec->catdir( $outer, 'src', 'deeper' );

# --- without --nested, the guard is right to refuse --------------------------

( $status, $out, $err ) = cli( 'project.create', '--name', 'Inner', '--dir', $inner );
isnt( $status, 0, 'project.create inside an existing project refuses by default' );
like( $err, qr/pass --nested/, 'and says --nested is the way out' );
ok( !-f File::Spec->catfile( $inner, '.tira', 'project.yml' ), 'and nothing was created' );

# --- with --nested, the CLI's own guard already calls this a legitimate
# reader of the flag - the dispatch owes it the same answer -----------------

( $status, $out, $err ) = cli( 'project.create', '--name', 'Inner', '--dir', $inner, '--nested' );
is( $status, 0, 'project.create --nested inside an existing project succeeds' )
  or diag("stderr: $err");
ok( -f File::Spec->catfile( $inner, '.tira', 'project.yml' ),
    'and the nested project was actually created on disk' );

done_testing;

__END__

=head1 NAME

1137-a-guard-that-agreed-with-a-dispatch-that-did-not.t - project.create's
--nested guard and its dispatch used to disagree

=head1 DESCRIPTION

TKT-1079. C<lib/Tira/CLI.pm>'s option guard already names C<project.create>
as a legitimate reader of C<--nested>, alongside C<project.new> and
C<onboard> - but the dispatch line for C<project.create> called
C<< $tira->create_project >> with only C<name> and C<dir>, never forwarding
C<nested>. So C<< d2 tira.project.create --dir DIR --nested >> inside an
existing project's tree still refused, exactly as if C<--nested> were never
typed - the opposite of what the guard's own acceptance implied.

C<Tira::create_project> and C<_refuse_nesting> were never at fault; both
already forward and read C<%args> correctly. The break was entirely in the
CLI dispatch dropping the flag before it ever reached them.

=cut
