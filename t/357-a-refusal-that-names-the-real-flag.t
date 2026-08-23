#!/usr/bin/env perl
# tira.link.add and tira.link.remove take --from, --type and --to, and have
# no --ref at all. Missing one of the three, both used to refuse with the
# same message no matter which - "Record reference is required - supply it
# with --ref" - the shared, correct refusal forty other commands raise for
# a genuinely missing --ref, rewritten by the CLI-layer table into a flag
# link.add does not take. Supplying --ref did nothing; two of the three real
# flags produced the identical message, so it never said which was missing.
# TKT-396.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Linked', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'LKS', epic_prefix => 'LKE', ticket_prefix => 'LKT',
);
my $one = $tira->create_record( project => $root, type => 'ticket', title => 'One' );
my $two = $tira->create_record( project => $root, type => 'ticket', title => 'Two' );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME}   = $root;
        local $ENV{TIRA_AUTHOR} = 'claude';
        Tira::CLI->run( command => $command, argv => [@argv] );
    };
    return ( $status, $out . $err );
}

# --- each of the three, omitted in turn, names itself and only itself -------

{
    my ( $status, $said ) = run( 'link.add', '--type', 'blocks', '--to', $two->{ref} );
    isnt( $status, 0, 'link.add with --from missing is refused' );
    like( $said, qr/--from/, 'and names --from' );
    unlike( $said, qr/--ref\b/, 'not --ref, which the command does not take' );
}

{
    my ( $status, $said ) = run( 'link.add', '--from', $one->{ref}, '--to', $two->{ref} );
    like( $said, qr/--type/, 'link.add with --type missing names --type' );
    unlike( $said, qr/--ref\b/, 'not --ref' );
}

{
    my ( $status, $said ) = run( 'link.add', '--from', $one->{ref}, '--type', 'blocks' );
    like( $said, qr/--to\b/, 'link.add with --to missing names --to' );
    unlike( $said, qr/--ref\b/, 'not --ref' );
}

# --- nothing at all names the first of the three checked, not a generic cry -

{
    my ( $status, $said ) = run('link.add');
    isnt( $status, 0, 'link.add with nothing at all is refused' );
    like( $said, qr/--from/, 'and names the first thing it checks' );
    unlike( $said, qr/--ref\b/, 'still not --ref' );
}

# --- link.remove has the identical shape, and is fixed the same way ---------

{
    my ( $status, $said ) = run( 'link.remove', '--type', 'blocks', '--to', $two->{ref} );
    like( $said, qr/--from/, 'link.remove with --from missing names --from' );
    unlike( $said, qr/--ref\b/, 'not --ref' );
}

# --- and supplying every real flag still works, unaffected ------------------

{
    my ( $status, $said ) = run( 'link.add', '--from', $one->{ref}, '--type', 'blocks', '--to', $two->{ref} );
    is( $status, 0, 'link.add with all three real flags still succeeds' );
}

done_testing;

__END__

=head1 NAME

357-a-refusal-that-names-the-real-flag.t - link.add/link.remove name the flag that is missing

=head1 DESCRIPTION

C<tira.link.add> and C<tira.link.remove> refused a missing C<--from>,
C<--type> or C<--to> with the same message every time - naming C<--ref>, a
flag the command does not take, and never distinguishing which of the
three real flags was actually absent. This proves each is now named on its
own, that C<--ref> never appears in the refusal, and that supplying every
real flag still works.

=cut
