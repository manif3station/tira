#!/usr/bin/env perl
# A board that cannot deliver a notification says so.
#
# He asked for police to tell him on Telegram when a card moves. It shipped in
# 2.58 with evidence and four gate runs, and has never delivered one message. He
# asked twice; the second time: "This isn't the first time. Treat this like a
# problem to solve."
#
# The problem was three silences in a row:
#
#   1. The board never had the setting. notify_moves was absent from
#      tira.project.show, so the feature was off and nothing said so.
#   2. TELEGRAM_CHATID was absent from the running police process, which had the
#      bot token and two other TELEGRAM_* variables but not that one.
#   3. _send_notification returns 0 when it is missing:
#
#          my $chat = $ENV{TELEGRAM_CHATID};
#          return 0 if !defined $chat || $chat eq '';
#
#      No warning, no log, no exit code anybody sees.
#
# So the code was correct, tested, and dead. What it lacked was any way to tell
# anybody it was not delivering.
#
# The reason it stayed dead for a day is worth writing down here rather than only
# on the card: TKT-375 recorded that TELEGRAM_CHATID was unset and I filed it as
# "his to set" - treating a missing variable as the owner's chore instead of as
# the thing that makes a shipped feature silently useless. A feature that cannot
# work should say so itself rather than wait to be asked about twice.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-18T16:30:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Quiet', dir => $root, members => ['claude'], agent => 'claude',
    columns => ['backlog, implement, done'],
    sow_prefix => 'QS', epic_prefix => 'QE', ticket_prefix => 'QT',
);

# --- the engine can be asked whether a notification could actually be sent -----------
#
# Asked as a question with an answer, not as a side effect of trying. The point
# is that somebody can find out BEFORE relying on it.

{
    ok( Tira->can('notification_delivery'),
        'the engine can say whether a notification could be delivered' );
}

# --- and it names what is missing ------------------------------------------------------

{
    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID};
    delete $ENV{TELEGRAM_CHATID};

    my $state = $tira->notification_delivery( project => $root );
    ok( !$state->{deliverable}, 'with no chat id, nothing can be delivered' );
    like( $state->{reason} // '', qr/TELEGRAM_CHATID/,
        'and the reason names the variable that is missing, not a generic failure' );
}

{
    local $ENV{TELEGRAM_CHATID} = '398296603';
    local $ENV{TELEGRAM_BOT_TOKEN};
    delete $ENV{TELEGRAM_BOT_TOKEN};

    my $state = $tira->notification_delivery( project => $root );
    ok( !$state->{deliverable}, 'with no token, nothing can be delivered either' );
    like( $state->{reason} // '', qr/TELEGRAM_BOT_TOKEN/,
        'and it names that one instead' );
}

{
    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID}    = '398296603';

    my $state = $tira->notification_delivery( project => $root );
    ok( $state->{deliverable}, 'with both present, it reports deliverable' );
    is( $state->{reason}, undef, 'and offers no reason, because there is nothing wrong' );
}

# --- police says it out loud, once, where somebody will see it ---------------------------
#
# The whole complaint is that nothing said anything. So the statement has to
# reach the same place the undeclared-policy list reaches - the prompt police
# prints when it starts - rather than a return value only a caller would see.

{
    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID};
    delete $ENV{TELEGRAM_CHATID};

    $tira->notify_moves( project => $root, enabled => 1 );
    my $prompt = $tira->police_prompt( project => $root );
    like( $prompt, qr/TELEGRAM_CHATID/,
        'a board with notifications on and no chat id says so when police starts' );
    like( $prompt, qr/notif/i, 'and says what it is about' );
}

# --- and stays quiet when there is nothing to say ------------------------------------------
#
# The other half. A warning that appears on every board is one nobody reads, and
# this one must not fire where notifications were never asked for.

{
    my $off = File::Spec->catdir( $tmp, 'off' );
    my $second = Tira->new( clock => sub {'2026-08-18T16:30:00Z'} );
    $second->project_new(
        name => 'Off', dir => $off, members => ['claude'], agent => 'claude',
        columns => ['backlog, done'],
        sow_prefix => 'OS', epic_prefix => 'OE', ticket_prefix => 'OT',
    );

    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID};
    delete $ENV{TELEGRAM_CHATID};

    my $prompt = $second->police_prompt( project => $off );
    unlike( $prompt, qr/TELEGRAM_CHATID/,
        'a board that never turned notifications on is not nagged about them' );
}

{
    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID}    = '398296603';

    $tira->notify_moves( project => $root, enabled => 1 );
    my $prompt = $tira->police_prompt( project => $root );
    unlike( $prompt, qr/TELEGRAM_CHATID/,
        'and neither is a board that can actually deliver' );
}

# --- set once by the agent, which is what he actually asked for -------------------------
#
# The card's title says "set once by the agent". Reading the destination out of
# $ENV{TELEGRAM_CHATID} is why it never worked: the agent cannot set an
# environment variable on a police process somebody else started, so there was no
# way for it to be set once by anybody. The board is the thing the agent CAN
# write, and it is where every other per-board setting already lives.

{
    my $where = File::Spec->catdir( $tmp, 'settable' );
    my $third = Tira->new( clock => sub {'2026-08-18T16:30:00Z'} );
    $third->project_new(
        name => 'Settable', dir => $where, members => ['claude'], agent => 'claude',
        columns => ['backlog, done'],
        sow_prefix => 'SS', epic_prefix => 'SE', ticket_prefix => 'ST',
    );

    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID};
    delete $ENV{TELEGRAM_CHATID};

    my $before = $third->notification_delivery( project => $where );
    ok( !$before->{deliverable}, 'with nothing set anywhere, it cannot deliver' );

    $third->notify_moves( project => $where, enabled => 1, chat => '398296603' );

    my $after = $third->notification_delivery( project => $where );
    ok( $after->{deliverable},
        'once the agent sets the destination on the board, it can - with no environment variable' );

    my $reread = Tira->new( clock => sub {'2026-08-18T16:30:00Z'} )
      ->notification_delivery( project => $where );
    ok( $reread->{deliverable}, 'and it stays set for the next process, which is what "once" means' );

    my $prompt = $third->police_prompt( project => $where );
    unlike( $prompt, qr/TELEGRAM_CHATID/,
        'and the board stops being warned, because there is nothing left to warn about' );
}

# --- the environment still works, for anyone already relying on it -------------------------

{
    my $envonly = File::Spec->catdir( $tmp, 'envonly' );
    my $fourth = Tira->new( clock => sub {'2026-08-18T16:30:00Z'} );
    $fourth->project_new(
        name => 'EnvOnly', dir => $envonly, members => ['claude'], agent => 'claude',
        columns => ['backlog, done'],
        sow_prefix => 'ES', epic_prefix => 'EE', ticket_prefix => 'ET',
    );

    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID}    = '111222333';

    my $state = $fourth->notification_delivery( project => $envonly );
    ok( $state->{deliverable},
        'a board with nothing stored still delivers from the environment, as it always did' );
}

# --- proved by taking the statement away ---------------------------------------------------
#
# Every assertion above about the prompt is a regex over a long string, and a
# regex that finds nothing passes an unlike() no matter why. So the positive case
# is re-established here with the subject proved present first.

{
    local $ENV{TELEGRAM_BOT_TOKEN} = 'a-token';
    local $ENV{TELEGRAM_CHATID};
    delete $ENV{TELEGRAM_CHATID};

    $tira->notify_moves( project => $root, enabled => 1 );
    my $prompt = $tira->police_prompt( project => $root );
    ok( length $prompt, 'the prompt has content, so the unlike assertions above meant something' );
    my @lines = grep { /TELEGRAM_CHATID/ } split /\n/, $prompt;
    is( scalar @lines, 1, 'the board is told once, not on every line' );
}

done_testing;

__END__

=head1 NAME

274-a-notification-nobody-could-receive.t - TKT-349

=head1 DESCRIPTION

C<_send_notification> returned 0 when C<TELEGRAM_CHATID> was unset, silently, so
the move-notification feature shipped in 2.58 and never delivered a message
without anything saying why. A board can now be asked whether a notification
could be delivered, and one that has notifications on and cannot deliver says so
in the prompt police prints when it starts.

=cut
