#!/usr/bin/env perl
# TKT-939. Michael, via Telegram (msg 7012, 2026-09-05): a screenshot of his
# terminal, flooded with repeated "Wide character in print at
# .../lib/Tira.pm line 13171" warnings, captioned "still happening".
#
# THE STANDING MONITOR IS WHAT KEEPS IT COMING BACK: d2 tira.policy.bridge
# (JOB-004) runs police_run's watch loop every interval, forever, and its
# terminal print (lib/Tira/CLI/Police.pm line 131, and the once-mode
# equivalent at line 1044) writes each entry of $result->{terminal} straight
# to STDERR - which Tira::CLI::run sets :raw on purpose (line 49) - without
# passing it through Tira::CLI::_utf8_bytes first, unlike every other output
# path in this same file (line 402, 687, 699, 1007, 2570 and Tira::CLI's own
# 498/699). A violation whose terminal line carries non-ASCII text (a card
# title or comment in Cantonese - this board is worked in both languages)
# still holds Perl's internal UTF8 flag when it reaches that print, and a
# flagged string with a character above U+00FF written to a :raw handle is
# exactly what "Wide character in print" warns about - and then writes a
# mangled byte instead of the character. This exact class of bug was already
# found and fixed twice in this file's own history (see the comments above
# _bridge_write's and _journal_flush's own print calls); the once-mode and
# watch-loop terminal prints were missed both times.
#
# police_pass itself is mocked here rather than driven through a real
# escalation: which violations reach $result->{terminal} at all depends on
# an escalation ladder (seen counts, quiet intervals) that has nothing to do
# with this bug - the bug is what the print sites do with whatever terminal
# text they are handed, once something is in it. A canned result carrying a
# Cantonese line proves that directly, without reverse-engineering the
# ladder to make a real violation escalate on the first pass.
#
# WRITTEN RED.

use strict;
use warnings;
use utf8;

use Cwd qw(getcwd);
use Encode ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-05T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Cantonese Board', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'CBS', epic_prefix => 'CBE', ticket_prefix => 'CBT',
);
mkdir File::Spec->catdir( $root, '.git' );

my $store = File::Spec->catdir( $tmp, 'police-state' );

# "Police prints a wide-character warning" - the exact free text a
# violation's own detail carries through to the terminal line unmangled,
# the way a card title or comment already does (_violation_terminal_notice,
# Tira.pm ~9297, includes $violation->{detail} verbatim).
my $cantonese_line = '2026-09-05T09:00:00Z | VIO-0001 | CBT-001 | 警察印出寬字元警告 | '
  . 'seen 1 times, needs your attention | hand to the core agent: d2 tira.ticket.show --ref CBT-001';

no warnings 'redefine';
local *Tira::police_pass = sub {
    return {
        watching => 1, violations => [], settled => [], upgraded => undef,
        terminal => [$cantonese_line],
    };
};

sub run_once_capturing_stderr {
    my $err = '';
    open my $se, '>', \$err or die $!;
    my $warnings = '';
    local $SIG{__WARN__} = sub { $warnings .= $_[0] };
    my $was = getcwd();
    chdir $root or die "cannot enter $root: $!";
    {
        local *STDERR = $se;
        Tira::CLI->run( command => 'police', tira => $tira,
            argv => [ '--once', '--store', $store ] );
    }
    chdir $was or die "cannot return to $was: $!";
    return ( $err, $warnings );
}

my ( $stderr, $warnings ) = run_once_capturing_stderr();

# non-empty is the whole claim: the mocked terminal line has to have reached
# STDOUT/STDERR for the checks below to mean anything.
like( $stderr, qr/\S/, 'the once-mode police run printed something to STDERR' );

unlike( $warnings, qr/Wide character in print/,
    'printing a violation terminal line that carries non-ASCII text does not '
      . 'warn - the whole of TKT-939, since a warning here is the bug reaching '
      . "the owner's own terminal every time the standing monitor polls" );

# The bytes themselves have to be valid UTF-8, not just warning-free - a wide
# string silently truncated to its low byte per character would pass the
# check above and still be unreadable on the far end.
my $decoded = eval { Encode::decode( 'UTF-8', $stderr, Encode::FB_CROAK ) };
ok( !$@, 'the captured STDERR bytes decode cleanly as UTF-8' )
  or diag("decode failed: $@");
like( $decoded, qr/警察印出寬字元警告/,
    'and the Cantonese text in the terminal line is legible in it, not mangled' );

done_testing();

__END__

=head1 NAME

559-a-warning-that-keeps-coming-back.t - the police watch loop's terminal print stops warning on non-ASCII violation text

=head1 DESCRIPTION

TKT-939. C<police_run>'s once-mode and watch-loop terminal prints
(C<lib/Tira/CLI/Police.pm> lines 131 and 1044) write each line of
C<$result-E<gt>{terminal}> straight to a C<:raw> STDERR without
C<Tira::CLI::_utf8_bytes> first, unlike every other output path in the file. A
violation whose terminal line carries non-ASCII text - a card title or
comment in Cantonese, since this board is worked in English and Cantonese -
triggers "Wide character in print" on every poll of the standing
C<d2 tira.policy.bridge> monitor, which is why Michael saw it keep recurring
rather than fire once.

=cut
