#!/usr/bin/env perl
# The owner is told when a card moves, by police rather than by the agent.
#
# Asked for by voice: "a police sentry rather than an agent sentry" - the agent
# enables it once and police sends from then on, so telling the owner a card
# moved costs no LLM usage.
#
# He worked the design out himself and rejected the obvious version. A
# notification on leaving a column AND another on entering the next sends two
# messages about one event; ten tickets becomes twenty messages. What he
# settled on is one message per move, carrying the card reference.
#
# The hard part is "exactly once". Every other rule here compares rather than
# remembers, and comparison cannot tell "is in a column" from "just arrived" -
# a pass every few minutes would resend the same move forever. So this reads
# the move's own timestamp from the card's history and remembers the last one
# it spoke about, which is one stamp per card rather than a log to scan.
#
# Delivery is a seam the suite replaces, the way the police world is replaced:
# TELEGRAM_BOT_TOKEN and TELEGRAM_CHATID - his spelling, settled by Q-043, the
# chat id without an underscore - and nothing is sent unless both are set.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp   = tempdir( CLEANUP => 1 );
my $now   = '2026-08-18T01:30:00Z';
my $tira  = Tira->new( clock => sub {$now} );
my $root  = File::Spec->catdir( $tmp, 'proj' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Told', dir => $root, members => ['claude'],
    columns => ['backlog, implement, review, done, discard'],
    sow_prefix => 'TLS', epic_prefix => 'TLE', ticket_prefix => 'TLT',
);

my @sent;
sub notify_pass {
    my (%env) = @_;
    @sent = ();
    no warnings 'redefine';
    # The seam is the POST, not the sender. Stubbing _send_notification would
    # bypass the very check this file asserts - that nothing goes out unless
    # both variables are set - and two assertions passed for the wrong reason
    # until this moved down a level.
    local *Tira::_post_telegram = sub {
        my ( $self, $token, $chat, $text ) = @_;
        push @sent, { token => $token, chat => $chat, text => $text };
        return 1;
    };
    local $ENV{TELEGRAM_BOT_TOKEN} = $env{token} if exists $env{token};
    local $ENV{TELEGRAM_CHATID}    = $env{chat}  if exists $env{chat};
    delete local $ENV{TELEGRAM_BOT_TOKEN} if !exists $env{token};
    delete local $ENV{TELEGRAM_CHATID}    if !exists $env{chat};
    return $tira->police_pass( project => $root, store => $store, world => {} );
}

my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that will move', priority => 3 );

# --- the setting exists and is off until asked for -------------------------------

{
    ok( Tira->can('notify_moves'),
        'a board can be told to notify on moves' );

    $now = '2026-08-18T01:31:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'implement' );
    notify_pass( token => 'T', chat => 'C' );
    is_deeply( \@sent, [],
        'and nothing is sent until it is switched on, because it is opt-in' );
}

$tira->notify_moves( project => $root, enabled => 1 );

# --- one message per move ---------------------------------------------------------
#
# The half he reasoned out: two messages about one event is what he rejected.

{
    $now = '2026-08-18T01:32:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'review' );

    notify_pass( token => 'T', chat => 'C' );
    is( scalar @sent, 1, 'a move sends exactly one message' );
    like( $sent[0]{text} // '', qr/\Q$card->{ref}\E/, 'carrying the card reference' );
    like( $sent[0]{text} // '', qr/review/, 'and where it went' );
}

# --- and not again for the same move ----------------------------------------------
#
# The hard part. A pass every few minutes must not resend what it already said.

{
    notify_pass( token => 'T', chat => 'C' );
    is_deeply( \@sent, [],
        'a second pass over the same move says nothing, which is what makes this usable' );
}

# --- a column switched off says nothing --------------------------------------------
#
# His example: discard. He does not need to be told a card was set aside.

{
    $tira->notify_moves( project => $root, column => 'discard', enabled => 0 );
    $now = '2026-08-18T01:33:00Z';
    $tira->record_move( project => $root, ref => $card->{ref}, column => 'discard' );

    notify_pass( token => 'T', chat => 'C' );
    is_deeply( \@sent, [], 'a move into a column switched off is not announced' );
}

# --- both variables or nothing ------------------------------------------------------

{
    my $other = $tira->create_record( project => $root, type => 'ticket',
        title => 'Another card that moves', priority => 3 );
    $now = '2026-08-18T01:34:00Z';
    $tira->record_move( project => $root, ref => $other->{ref}, column => 'implement' );

    notify_pass( token => 'T' );
    is_deeply( \@sent, [], 'a token with no chat id sends nothing' );

    notify_pass( chat => 'C' );
    is_deeply( \@sent, [], 'a chat id with no token sends nothing' );

    notify_pass( token => 'T', chat => 'C' );
    is( scalar @sent, 1, 'and both together send the one message' );
}

# --- and the way an agent actually switches it on --------------------------------------
#
# The engine is what the blocks above drive, and the engine is not what he will
# use. He asked for a setting the agent turns on once, so the command line is
# the whole feature from where he stands - and it went in with no test through
# it, which the coverage gate caught before he did.

{
    my ( $out, $err ) = ( '', '' );
    my $status = do {
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => 'notify.moves', tira => $tira,
            argv => [ '--column', 'discard', '--watch', '-o', 'json' ] );
    };

    is( $status, 0, 'the command line can switch a column on' );
    like( $out, qr/discard/, 'and says which column it acted on' );

    # Read back through the engine rather than trusting the printed answer,
    # because printing the card back is exactly how the dropped-option bugs
    # looked like confirmation.
    $now = '2026-08-18T01:35:00Z';
    my $back = $tira->create_record( project => $root, type => 'ticket',
        title => 'A card set aside after the switch was flipped', priority => 3 );
    $now = '2026-08-18T01:36:00Z';
    $tira->record_move( project => $root, ref => $back->{ref}, column => 'discard' );

    notify_pass( token => 'T', chat => 'C' );
    is( scalar @sent, 1,
        'and the column switched off above is announced again, so the verb is a switch' );
}

# --- proved by forgetting what was already said ---------------------------------------

{
    no warnings 'redefine';
    local *Tira::_notified_move_at = sub { return };

    my $again = notify_pass( token => 'T', chat => 'C' );
    cmp_ok( scalar @sent, '>', 0,
        'forgetting the last move announced resends it, which is why the stamp is kept' );
}

done_testing;

__END__

=head1 NAME

265-a-move-the-owner-is-told-about.t - one message per card move, sent by police

=head1 DESCRIPTION

Asked for by voice: police tells the owner when a card moves, so the agent does
not spend tokens doing it. One message per move rather than one on leaving and
another on arriving - the design he considered and rejected. Off until enabled,
switchable per column, and silent unless both C<TELEGRAM_BOT_TOKEN> and
C<TELEGRAM_CHATID> are set.

=cut
