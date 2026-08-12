#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $now = '2026-08-12T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0] }

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Attached', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, doing'],
    sow_prefix => 'ATS', epic_prefix => 'ATE', ticket_prefix => 'ATT',
);

my $file = File::Spec->catfile( $tmp, 'note.txt' );
open my $fh, '>', $file or die $!;
print {$fh} "the wrong file entirely\n";
close $fh;

my $card  = $tira->create_record( project => $root, type => 'ticket', title => 'Has an attachment' );
my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Has the same one' );
my $added = $tira->attachment_add( project => $root, ref => $card->{ref}, file => $file );
$tira->attachment_add( project => $root, ref => $other->{ref}, file => $file );

sub attachments_on {
    my ($ref) = @_;
    return @{ $tira->record_show( project => $root, ref => $ref )->{attachments} };
}

is( scalar( attachments_on( $card->{ref} ) ), 1, 'the card has its attachment' );

# --- discarded, not deleted ------------------------------------------------

# Everything else in Tira is set aside rather than lost: a discarded question
# keeps its answer and shows struck through. An attachment was the one place
# where something disappeared - the reference dropped out of the card and the
# stored file went with it when nothing else pointed at it.
at('2026-08-12T10:00:00Z');
my $discarded = $tira->attachment_discard(
    project => $root, ref => $card->{ref}, sha => $added->{sha},
    extension => $added->{extension}, author => 'claude' );

ok( $discarded, 'an attachment can be discarded' );

my ($still) = attachments_on( $card->{ref} );
ok( $still, 'and it is still on the card, because discarding is not deleting' );
is( $still->{sha}, $added->{sha}, 'the same one' );
is( $still->{discarded_at}, '2026-08-12T10:00:00Z', 'stamped with when' );
is( $still->{discarded_by}, 'claude', 'and with who, which is the question a log answers' );

# --- the stored file is left alone -----------------------------------------

# It is shared by content hash, so unlinking a reference is not the same as
# deleting a file - and even the last reference does not make the bytes
# somebody else's to lose.
my $stored = $tira->attachment_get( project => $root, sha => $added->{sha},
    extension => $added->{extension} );
ok( $stored, 'the stored file is still there' );

ok( ( grep { !$_->{discarded_at} } attachments_on( $other->{ref} ) ),
    'and the other card that shares it is untouched' );

# --- discarding the last reference too -------------------------------------

at('2026-08-12T10:05:00Z');
$tira->attachment_discard( project => $root, ref => $other->{ref}, sha => $added->{sha},
    extension => $added->{extension}, author => 'michael' );
ok( $tira->attachment_get( project => $root, sha => $added->{sha}, extension => $added->{extension} ),
    'the file survives even when every card has discarded it - a discard is not a delete' );

# --- the work log says so --------------------------------------------------

# Written where the change happens, so the agent cannot forget to log it and
# cannot write it either.
my @log = @{ $tira->work_log( project => $root, ref => $card->{ref} ) };
my ($event) = grep { $_->{kind} eq 'attachment-discarded' } @log;
ok( $event, 'the work log carries the discard as its own event' );
is( $event->{who}, 'claude', 'naming who did it' );
like( $event->{detail}, qr/note/, 'and what was discarded' );

ok( !Tira->can('attachment_discard_log_add'), 'and there is no way for an agent to write that entry itself' );

# --- and it cannot be discarded twice --------------------------------------

ok( !eval { $tira->attachment_discard( project => $root, ref => $card->{ref},
            sha => $added->{sha}, extension => $added->{extension}, author => 'claude' ); 1 },
    'discarding one twice is refused rather than stamped again' );
like( $@, qr/already discarded/i, 'and says why' );

# --- what the browser draws ------------------------------------------------

{
    require Tira::CLI;
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '--project', $root, '-o', 'browser' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        );
    }
    my $html = $calls[0]{render}->();

    like( $html, qr/card-attachment--discarded/,
        'the page has a way of drawing a discarded attachment' );
    like( $html, qr/\.card-attachment--discarded\{[^}]*line-through/,
        'struck through, like every other discarded thing' );
    like( $html, qr/\.card-attachment--discarded\{[^}]*opacity/,
        'and greyed out' );
    like( $html, qr/reference\.discarded_at\?" card-attachment--discarded"/,
        'and it decides from the attachment itself rather than being told' );
    like( $html, qr/drop\.disabled=!!reference\.discarded_at/,
        'with no second chance to discard one already set aside' );
}

# --- one attached to a comment --------------------------------------------

# An attachment can hang off a comment rather than the card, and a discard has
# to reach that one too - otherwise the only way to take back a file attached
# to the wrong comment is the delete that loses it.
{
    my $noted = $tira->create_record( project => $root, type => 'ticket', title => 'A card with a comment' );
    my $comment = $tira->comment_add( project => $root, ref => $noted->{ref},
        author => 'claude', text => 'with a file on it' );
    my $on_comment = $tira->attachment_add( project => $root, ref => $noted->{ref},
        comment => $comment->{id}, file => $file );

    at('2026-08-12T11:00:00Z');
    $tira->attachment_discard( project => $root, ref => $noted->{ref}, comment => $comment->{id},
        sha => $on_comment->{sha}, extension => $on_comment->{extension}, author => 'claude' );

    my ($kept) = @{ ( $tira->record_show( project => $root, ref => $noted->{ref} )->{comments} )->[0]{attachments} };
    is( $kept->{discarded_by}, 'claude', 'an attachment on a comment can be discarded too' );

    my ($event) = grep { $_->{kind} eq 'attachment-discarded' }
      @{ $tira->work_log( project => $root, ref => $noted->{ref} ) };
    ok( $event, 'and the work log carries that one as well' );

    ok( !eval { $tira->attachment_discard( project => $root, ref => $noted->{ref},
                comment => 'CMT-404', sha => $on_comment->{sha}, author => 'claude' ); 1 },
        'naming a comment that does not exist is refused' );
    like( $@, qr/not found/, 'saying so' );
}

# --- the ways in ----------------------------------------------------------

# The command line an agent types, and the route the browser posts to when
# somebody clicks the cross on a chip. Both reach the same subroutine, which is
# the point - but a provider nothing exercises is a provider nobody knows works.
{
    require Tira::CLI;

    my $third = $tira->create_record( project => $root, type => 'ticket', title => 'A third card' );
    my $attached = $tira->attachment_add( project => $root, ref => $third->{ref}, file => $file );

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run( command => 'attachment.discard', tira => $tira,
            argv => [ '--project', $root, '--ref', $third->{ref}, '--sha', $attached->{sha},
                '--extension', $attached->{extension}, '--author', 'michael', '-o', 'json' ] );
    };
    is( $status, 0, 'the command line can discard an attachment' );
    like( $out, qr/discarded_by/, 'and answers with the stamp it wrote' );

    my ($marked) = @{ $tira->record_show( project => $root, ref => $third->{ref} )->{attachments} };
    is( $marked->{discarded_by}, 'michael', 'naming who typed it' );

    # And the browser's own way in, which is what the cross on a chip posts to.
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    ok( ref $providers{attachment_discard} eq 'CODE', 'the browser is given a discard provider' );

    my $fourth = $tira->create_record( project => $root, type => 'ticket', title => 'A fourth card' );
    my $again = $tira->attachment_add( project => $root, ref => $fourth->{ref}, file => $file );
    my $answered = $providers{attachment_discard}->( {
        ref => $fourth->{ref}, sha => $again->{sha}, extension => $again->{extension},
        _signed_in => 'michael',
    } );
    like( $answered, qr/"ok":true/, 'and it answers the browser' );
    like( $answered, qr/discarded_by":"michael/, 'attributing it to whoever is signed in' );

    ok( !eval { $providers{attachment_discard}->('not an object'); 1 },
        'a payload that is not an object is refused rather than half-applied' );
}

done_testing;

__END__

=head1 NAME

100-attachment-discard.t - taking an attachment off a card without losing it

=head1 DESCRIPTION

Michael asked whether an agent can remove an attachment from the command line,
and said that if it can, removing one should be a discard like everything else
in Tira: struck through and greyed on the board rather than gone.

The finding was that a way existed and did the opposite. C<attachment_detach>
dropped the reference out of the card's list entirely, so nothing on the card
said the file had ever been there - and when no other card referenced it, the
stored file was deleted too. That was the one place in Tira where something
disappeared instead of being set aside.

So a discard keeps the reference, stamps it with when and who, leaves the
stored file alone even when it is the last reference, and is drawn struck
through and greyed. The work log entry is written by the engine, because an
agent that has to remember to log keeps a log worth nothing - and there is no
command by which it could write that entry itself.

=cut
