#!/usr/bin/env perl
# TKT-742. A card about a CLI option names that option in its title, so titles
# beginning with two dashes are ordinary on this board. Passed as a separate
# argument, the parser reads the value as the next option:
#
#     ticket create --title "--set-scope-in refuses a plain-text file ..."
#     error: "Unknown option: set-scope-in
#             Did you mean:
#               --set-scope-in
#               --set-scope-out"
#
# THE SUGGESTION IS THE SHARP EDGE, not the parse. It names back the exact
# string the caller just typed, so it reads as a correct option being rejected -
# and sends them looking at the option rather than at the quoting. Nothing in the
# refusal mentions that --title=VALUE works, which it does.
#
# The parse itself is Getopt::Long's documented behaviour and is NOT what this
# file asks to change: =VALUE is the standard answer and already works. What must
# change is what the refusal says.
#
# THE CONTROL THAT MATTERS: a genuine typo must still get TKT-298's message,
# which is the whole reason that message exists. A fix that told every unknown
# option to try =VALUE would trade one useless refusal for another.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );

my $tira = Tira->new;
$tira->project_new(
    name => 'Dashes', dir => $root, members => ['claude'],
    columns    => [ 'backlog', 'implement', 'done' ],
    sow_prefix => 'DSS', epic_prefix => 'DSE', ticket_prefix => 'DST',
);

sub cli {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>',     \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME} = $root;
    my $status = Tira::CLI->run(
        command => 'record.create', type => 'ticket', argv => \@argv );
    return ( $status, $out, $err );
}

my $TITLE = '--set-scope-in refuses a plain-text file';

# --- THE CARD. The refusal must not hand back the caller's own string ---------

my ( $status, undef, $err ) = cli( '--title', $TITLE );

isnt( $status, 0, 'a title beginning with two dashes, passed separately, is refused' );

# Guards everything below. Both assertions that follow are of the "does not say"
# form, and an empty stderr would satisfy them while the defect stood.
ok( length($err), 'and the refusal says something' )
  or diag('stderr was empty, so the assertions below prove nothing');

ok( length($err) && $err !~ /Did you mean/,
    'the refusal does not offer a "Did you mean" list for what was a VALUE - '
      . 'suggesting the string the caller just typed reads as a correct option '
      . 'being rejected. Said: ' . ( $err || '(nothing)' ) );

like( $err, qr/--option=--set-scope-in/,
    'and it shows the value joined to an option with =, using the actual '
      . 'rejected value rather than guessing which option was expecting it - '
      . 'said: ' . ( $err || '(nothing)' ) );

# The message must not name --title specifically. This function only sees the
# rejected token, not which earlier option was consuming it as a value, so a
# fix that always wrote "--title=..." would be right for this one call and
# wrong for every other command - the earlier version of this fix did exactly
# that and was caught only by testing a second, unrelated option below.
unlike( $err, qr/--title=--set-scope-in/,
    'and does NOT claim the value belongs to --title specifically - this '
      . 'function cannot know that' );

# --- the message does not hardcode the option this card was filed against ----
#
# _unknown_option_message only ever sees the rejected token and the command's
# spec - it has no way to know which earlier option was expecting a value, so
# it must never guess one. A fix that hardcoded --title (right for the repro
# above, wrong for every other command) would pass every assertion so far.
#
# title:s is the ONLY option in this CLI with an optional value - grep confirms
# it - which is why title alone reproduces "Unknown option" for a value that
# begins with two dashes: every other string option is =s (required value),
# and Getopt::Long simply takes the next token as an =s option's value
# whatever it looks like, never raising this warning at all. Measured: feeding
# the identical string to --description (=s) is accepted outright, no refusal.
# So a second CLI-level repro through a different option does not exist to
# test against, and the function itself is unit-tested directly instead.

require Tira::CLI::Usage;

{
    my $msg = Tira::CLI::Usage::_unknown_option_message(
        ['from-fixture'], [ 'from-fixture=s', \my $x, 'title:s', \my $y ] );
    like( $msg, qr/--option=--from-fixture/,
        'called directly with an unrelated bad token, the message echoes '
          . 'THAT token - said: ' . ( $msg || '(nothing)' ) );
    unlike( $msg, qr/set-scope-in|--title\b/,
        'and mentions neither the earlier repro\'s value nor --title, which '
          . 'this call never touched' );
}

# --- the form that works, and must keep working ------------------------------
#
# Green today. If a fix ever changed the parse instead of the message, this is
# what would catch it.

{
    my ( $s, $o ) = cli( "--title=$TITLE", '-o', 'json' );
    is( $s, 0, 'the --title=VALUE form creates the card' ) or diag($o);
    like( $o, qr/\Qrefuses a plain-text file\E/,
        'and the title survives intact, dashes and all' );
}

# --- CONTROL. A genuine typo still gets TKT-298's message --------------------
#
# The refusal this card is about was built by TKT-298 and is right for the case
# it was written for. A fix that made every unknown option mention =VALUE would
# be a regression dressed as a fix.

{
    my ( $s, undef, $e ) = cli( '--titel', 'A real typo' );
    isnt( $s, 0, 'a misspelled option is still refused' );
    ok( length($e) && $e =~ /Unknown option/,
        'and still says the option is unknown' );
    ok( length($e) && $e =~ /Did you mean/ && $e =~ /--title\b/,
        'and still suggests the option that was meant - TKT-298 unchanged. '
          . 'Said: ' . ( $e || '(nothing)' ) );
}

# --- CONTROL. A genuinely missing value still refuses readably ----------------

{
    my ( $s, undef, $e ) = cli( '--title' );
    isnt( $s, 0, 'a --title with no value at all is refused' );
    ok( length($e), 'and says something rather than failing silently. Said: '
          . ( $e || '(nothing)' ) );
}

done_testing();

__END__

=head1 NAME

t/440-a-refusal-that-suggests-what-you-just-typed.t - a value beginning with two
dashes must not be answered by suggesting that value back

=head1 DESCRIPTION

Passing C<--title "--set-scope-in ..."> as two arguments makes Getopt::Long read
the value as the next option, and the refusal then computes its "Did you mean"
list from the caller's own value - suggesting, as the correction, the exact
string that was just typed.

The parse is not the fault and is not changed here: C<--title=VALUE> is the
standard answer and works today. The refusal is the fault.

=head2 The controls

Two cases must not change. A misspelled option must still get TKT-298's
unknown-option message with its suggestion, because that message is right for
the case it was written for; and C<--title> with no value at all must still
refuse. A fix that made every unknown option mention C<=VALUE> would satisfy the
first assertion in this file and break both.

=cut
