#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use IO::Pty;
use Test::More;

use lib 'lib';
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );

# --- a leading tilde means home, wherever it is typed --------------------
{
    local $ENV{HOME} = '/home/someone';
    is( Tira::CLI::_expand_home('~/foo/bar'), '/home/someone/foo/bar',
        'a tilde path expands to the home directory' );
    is( Tira::CLI::_expand_home('~'), '/home/someone', 'a bare tilde expands' );
    is( Tira::CLI::_expand_home('/absolute/path'), '/absolute/path',
        'an absolute path is untouched' );
    is( Tira::CLI::_expand_home('relative/path'), 'relative/path',
        'a relative path is untouched' );
    is( Tira::CLI::_expand_home('~user/path'), '~user/path',
        'another user\'s home is left alone rather than guessed at' );
    is( Tira::CLI::_expand_home(undef), undef, 'an absent path stays absent' );
}
{
    local $ENV{HOME} = '';
    is( Tira::CLI::_expand_home('~/foo'), '~/foo',
        'with no home to expand to, the text is left as typed' );
}

# --- editing, driven through a real terminal ------------------------------
sub edited {
    my ( $keystrokes, %opt ) = @_;
    my $pty = IO::Pty->new;
    my $slave = $pty->slave;
    # The terminal driver must not pre-chew the keystrokes: in canonical mode
    # it treats DEL as erase and Ctrl-U as kill itself, which would let a
    # broken editor pass by accident. Raw first, then send.
    $slave->set_raw;
    print {$pty} $keystrokes if length $keystrokes;
    # Reading a terminal with nothing left to send blocks forever, so the
    # end-of-input case must actually close the other end.
    close $pty if $opt{closed};
    my $shown = '';
    open my $capture, '>', \$shown or die $!;
    my $answer = do {
        local *STDOUT = $capture;
        Tira::CLI::_ask( $slave, 'Question', '' );
    };
    return ( $answer, $shown );
}

my ( $answer, $shown ) = edited("hello\r");
is( $answer, 'hello', 'plain typing is read at a terminal' );
like( $shown, qr/Question/, 'the prompt is drawn' );

is( ( edited("hello\x01X\r") )[0], 'Xhello',
    'Ctrl-A moves to the first character, as asked' );
is( ( edited("hello\x01X\x05Y\r") )[0], 'XhelloY',
    'Ctrl-E moves to the end of the line, as asked' );
is( ( edited("hello\x7f\x7f\r") )[0], 'hel', 'backspace deletes backwards' );
is( ( edited("hello\x01\x7fX\r") )[0], 'Xhello',
    'backspace at the start of the line deletes nothing' );
is( ( edited("hello\x15fresh\r") )[0], 'fresh', 'Ctrl-U clears the line' );
is( ( edited("hello\x01\x0bkept\r") )[0], 'kept', 'Ctrl-K kills to the end' );
is( ( edited("abc\e[D\e[DX\r") )[0], 'aXbc', 'the left arrow moves the cursor' );
is( ( edited("abc\e[D\e[D\e[CX\r") )[0], 'abXc', 'the right arrow moves it back' );
is( ( edited("abc\e[HX\r") )[0], 'Xabc', 'Home moves to the start' );
is( ( edited("abc\e[H\e[FX\r") )[0], 'abcX', 'End moves to the finish' );
is( ( edited("abc\e[D\e[D\e[D\e[DX\r") )[0], 'Xabc',
    'the cursor never runs off the start of the line' );
is( ( edited("ab\e[C\e[CX\r") )[0], 'abX', 'nor off the end' );
is( ( edited("abc\eZX\r") )[0], 'abcX', 'an unknown escape sequence is ignored' );
is( ( edited("a\tb\r") )[0], 'ab', 'a non-printing character is ignored' );
is( ( edited("hello\n") )[0], 'hello', 'a newline finishes the line too' );

is( ( edited("half\x03") )[0], undef, 'Ctrl-C abandons the prompt' );
is( ( edited("half\x04") )[0], undef, 'Ctrl-D abandons the prompt' );
is( ( edited( '', closed => 1 ) )[0], undef, 'reaching the end of input abandons the prompt' );

# --- away from a terminal, nothing changes --------------------------------
{
    my $script = "typed\n";
    open my $plain, '<', \$script or die $!;
    my $shown_plain = '';
    open my $capture, '>', \$shown_plain or die $!;
    my $plain_answer = do {
        local *STDOUT = $capture;
        Tira::CLI::_ask( $plain, 'Question', 'fallback' );
    };
    is( $plain_answer, 'typed', 'a piped answer is read exactly as before' );
    like( $shown_plain, qr/\[fallback\]/, 'and the default is still shown' );
    ok( !defined Tira::CLI::_raw_mode($plain),
        'a handle that is not a terminal never enters raw mode' );
}

done_testing;

__END__

=head1 NAME

43-line-editing.t - tilde answers and line editing at prompts

=head1 DESCRIPTION

Proves that a leading tilde expands to the user's home directory wherever
a path is accepted, and that prompts support real line editing at a
terminal: Ctrl-A and Ctrl-E as the owner asked, plus Ctrl-U, Ctrl-K,
backspace, arrows, Home and End, with Ctrl-C and Ctrl-D abandoning the
prompt. The terminal behaviour is exercised through a real pseudo-
terminal rather than excluded from coverage, and the plain read used
away from a terminal is pinned unchanged.

=cut
