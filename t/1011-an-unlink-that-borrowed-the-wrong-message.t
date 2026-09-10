#!/usr/bin/env perl
# hierarchy.unlink names --ref for a command that takes --parent and
# --child, the same fault TKT-689 just fixed on hierarchy.link.
#
# TKT-1011. hierarchy_unlink calls _record_data(ref => $args{parent}) and
# _record_data(ref => $args{child}) with no pre-validation, exactly like
# hierarchy_link did before TKT-689 - so a caller who mistakenly runs
# 'd2 tira.hierarchy.unlink --ref TKT-001' (a natural mistake, since --ref
# is what every other command takes) gets "Record reference is required -
# supply it with --ref", which names a flag hierarchy.unlink does not
# take at all.
#
# TKT-689's own fix already put both messages ('A parent is required'/'A
# child is required') into %SUPPLIED_BY, so this only needs the engine-side
# die-before-_record_data checks hierarchy_unlink was missing.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-10T17:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Unlinked Right', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'ULS', epic_prefix => 'ULE', ticket_prefix => 'ULT',
);
my $epic   = $tira->create_record( project => $root, type => 'epic', title => 'Parent' );
my $ticket = $tira->create_record( project => $root, type => 'ticket', title => 'Child' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $ticket->{ref} );

sub run {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, type => $type, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- hierarchy.unlink: --ref is not the answer, because it takes none ------

{
    my ( $status, $said ) = run( 'hierarchy.unlink', '--ref', $ticket->{ref} );
    isnt( $status, 0, 'hierarchy.unlink with --ref alone is refused' );
    unlike( $said, qr/--ref\b/, 'not told to supply --ref, which hierarchy.unlink does not take' )
      or diag('the bug this card is about: still pointed at --ref');
    like( $said, qr/--parent\b/, 'told about --parent, which it does take' );

    my ( $status2, $said2 ) = run( 'hierarchy.unlink', '--parent', $epic->{ref} );
    isnt( $status2, 0, 'hierarchy.unlink with only --parent is refused' );
    like( $said2, qr/--child\b/, 'and told about --child once --parent is supplied' );
}

# --- the fix does not change a genuine unlink -------------------------------

{
    my ( $status, $said ) = run( 'hierarchy.unlink', '--parent', $epic->{ref}, '--child', $ticket->{ref} );
    is( $status, 0, 'a genuine unlink with both flags still succeeds' ) or diag($said);
}

done_testing();

__END__

=head1 NAME

1011-an-unlink-that-borrowed-the-wrong-message.t - hierarchy.unlink names
the flags it actually takes

=head1 WHY

TKT-1011. hierarchy_unlink never received TKT-689's fix, so a caller who
mistakenly passed --ref (what every other command takes) was told to
supply --ref, a flag hierarchy.unlink does not accept at all.

=head1 WHAT IS ASSERTED

That hierarchy.unlink refuses --ref alone with a message naming --parent,
not --ref; that it names --child once --parent is supplied; and that a
genuine unlink with both flags still succeeds.

=cut
