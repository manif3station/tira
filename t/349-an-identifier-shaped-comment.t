#!/usr/bin/env perl
# TKT-302 refused --comment on every command that will not record it,
# naming tira.comment.add as the one that does - exempting comment.* and
# attachment.discard, the commands that DO read --comment. But on
# attachment.discard, --comment is a comment IDENTIFIER (which comment to
# detach the attachment from), not a reason, so the exemption pointed the
# guard away from the one command where the confusion is worst.
#
# Measured on installed 2.58: 'tira.attachment.discard --ref REF --sha SHA
# --comment "Set aside because it was the wrong file"' answered
# {"error":"Comment 'Set aside because it was the wrong file' not found"}
# and recorded nothing - the caller's sentence quoted back as a missing
# identifier. TKT-373.

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
    name => 'Shaped', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SHS', epic_prefix => 'SHE', ticket_prefix => 'SHT',
);

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME}   = $root;
            local $ENV{TIRA_AUTHOR} = 'claude';
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Has an attachment' );
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'A comment' );
my ($comment) = @{ $tira->record_show( project => $root, ref => $card->{ref} )->{comments} };

# --- a sentence, the confusion this ticket is about -------------------------

{
    my ( $status, $said ) = run( 'attachment.discard', '--ref', $card->{ref},
        '--sha', ( 'a' x 64 ), '--comment', 'Set aside because it was the wrong file' );

    isnt( $status, 0, 'a sentence passed to --comment on attachment.discard is refused' );
    like( $said, qr/--comment/, 'naming the option' );
    like( $said, qr/comment\.add/, 'and the command that records a reason - the same message TKT-302 ships' );
    unlike( $said, qr/not found/, 'not the misleading "comment not found" that used to come back' );
}

# --- a real comment id still works -------------------------------------------

{
    my ( $status, $said ) = run( 'attachment.discard', '--ref', $card->{ref},
        '--sha', ( 'a' x 64 ), '--comment', $comment->{id} );

    # Refused for an unrelated reason - no such attachment sha - but not by
    # the --comment guard, which is the one thing this proves.
    unlike( $said, qr/does not act on --comment/,
        'a real comment id is not refused by the --comment guard' );
}

# --- and the other exempted commands are untouched ---------------------------

{
    my ($status) = run( 'comment.update', '--ref', $card->{ref},
        '--comment', $comment->{id}, '--text', 'Edited' );
    is( $status, 0, 'comment.update still reads --comment as an id, unaffected' );
}

done_testing;

__END__

=head1 NAME

349-an-identifier-shaped-comment.t - attachment.discard's --comment is an id, not a reason

=head1 DESCRIPTION

TKT-302's --comment guard exempted attachment.discard because it genuinely
reads the option - but as a comment identifier, not the reason a caller
might plausibly type there. This proves a sentence is refused with the
same message TKT-302 ships, a real comment id still works, and the other
exempted commands (which read --comment as an id unambiguously) are
unaffected.

=cut
