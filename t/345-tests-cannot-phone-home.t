#!/usr/bin/env perl
# t/86-police-end-to-end.t declares agent-still and calls police_pass()
# several times without ever mocking the Telegram send or neutralizing the
# environment - unlike t/266 and t/294, which both do. Any host shell that
# happens to have real TELEGRAM_BOT_TOKEN/TELEGRAM_CHATID exported (this
# session's own shell does, for the tg reply bridge) sends a real message to
# the owner's real phone every time that file runs outside Docker.
#
# Confirmed live: the owner screenshotted three "the agent has stopped"
# messages naming test-fixture paths and card refs (STT-001, EVT-001..010),
# one of them the same alert he had asked about earlier as a possible false
# alarm. TKT-482.
#
# Docker runs are unaffected - docker-compose.testing.yml declares no
# environment: passthrough - but nothing stopped the next test file written
# with agent-still or a configured notify_moves chat from making the same
# mistake on the host. This is the safety net: every file capable of
# reaching a real Telegram send must also neutralize it.

use strict;
use warnings;

use Test::More;

my @files = glob('t/*.t');
my @risky;
for my $file (@files) {
    open my $fh, '<', $file or die "Cannot read $file: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    next if $text !~ /police_pass/;

    # Either path can reach _send_notification: agent-still declared, or a
    # project's notify_moves configured with enabled - the same two
    # ingredients t/86 and (in principle) any notify_moves test could combine.
    my $reachable = $text =~ /'agent-still'/
      || ( $text =~ /notify_moves/ && $text =~ /enabled\s*=>\s*1/ );
    next if !$reachable;

    # Any of these means the file cannot reach the real network regardless
    # of what the invoking shell has exported.
    my $guarded = $text =~ /_post_telegram|_send_notification|TELEGRAM_BOT_TOKEN/;
    push @risky, $file if !$guarded;
}

is_deeply( \@risky, [],
    'every test that can reach agent-still or an enabled notify_moves chat '
      . 'through police_pass() neutralizes the real Telegram send' );

done_testing;

__END__

=head1 NAME

345-tests-cannot-phone-home.t - no test file can reach a real phone

=head1 DESCRIPTION

Scans every test file for the two ingredients that can make C<police_pass()>
reach C<_send_notification> for real - C<agent-still> declared, or a
project's C<notify_moves> configured enabled - and requires any file
carrying either to also mock the send or reference
C<TELEGRAM_BOT_TOKEN>, so a future test file cannot repeat TKT-482's
mistake and message the owner's real phone from a host-side test run.

=cut
