#!/usr/bin/env perl
# Asking a command how to use it should not answer about a different command.
#
# Every record command shares one usage line and the line names create. So
# 'tira.ticket.move --help' answers 'Usage: dashboard tira.ticket.create
# --title TITLE', and so do discard, restore, clone, list, show and update, on
# all three boards. Measured before this was written: 21 of the 24 record verbs
# print a line naming a command that is not the one asked about, and the three
# that are right are the three creates, by coincidence of create being the line
# it returns.
#
# It adapts the board - tira.sow.list answers with tira.sow.create - so it
# reads as considered rather than as a fallback, which is why it has stood. A
# wrong answer that looks specific is not questioned.
#
# Found while looking for the command that makes a card, because the command
# reference did not name it either. That was TKT-233; this is the other half.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use Tira::CLI;
# Tira::CLI::Usage holds these since 4.74 (TKT-607). Tira::CLI requires it at
# the point one of its verbs runs, so a caller reaching in directly has to
# ask for it itself.
require Tira::CLI::Usage;

my @verbs = qw(clone create discard list move restore show update);

# --- every record verb answers about itself --------------------------------

my @wrong;
for my $type (qw(sow epic ticket)) {
    for my $verb (@verbs) {
        my $usage = Tira::CLI::Usage::_usage( "record.$verb", $type );
        push @wrong, "tira.$type.$verb -> $usage"
          if $usage !~ /\Qtira.$type.$verb\E/;
    }
}
is_deeply( \@wrong, [],
    'every record command names itself when asked how to use it' )
  or diag( "answered about another command:\n" . join( '', @wrong ) );

# --- and says something about its own arguments ----------------------------
#
# Naming itself is not enough. A line that names the command and then describes
# create's arguments is the same fault with the first word changed.

like( Tira::CLI::Usage::_usage( 'record.move', 'ticket' ), qr/--ref/,
    'moving a card says which card' );
like( Tira::CLI::Usage::_usage( 'record.move', 'ticket' ), qr/--column/,
    'and where it is going' );
unlike( Tira::CLI::Usage::_usage( 'record.move', 'ticket' ), qr/--title/,
    'and not the argument for making one' );

like( Tira::CLI::Usage::_usage( 'record.create', 'ticket' ), qr/--title/,
    'while making a card still says so' );
like( Tira::CLI::Usage::_usage( 'record.list', 'sow' ), qr/tira\.sow\.list/,
    'and the board is still the one that was asked' );

# --- and a record verb the table has not heard of ---------------------------
#
# The eight verbs are the eight that ship. A ninth would otherwise be described
# with whatever the table happened to return, so it is named rather than
# described - still an answer about the command that was asked, which is the
# whole point of this card.

my $unknown = Tira::CLI::Usage::_usage( 'record.rehome', 'ticket' );
like( $unknown, qr/tira\.ticket\.rehome/,
    'a record verb this does not know is still named rather than described as another' );
unlike( $unknown, qr/--title/,
    'and is not given create\'s arguments to be going on with' );

# --- the commands that are not records are untouched ------------------------

like( Tira::CLI::Usage::_usage( 'checklist.add', undef ), qr/tira\.checklist\.add/,
    'a command outside the three boards answers about itself as it always did' );
like( Tira::CLI::Usage::_usage( 'project.create', undef ), qr/tira\.project\.create --name/,
    'and the one with its own line keeps it' );

done_testing;

__END__

=head1 NAME

228-help-that-describes-itself.t - the answer is about the question

=head1 DESCRIPTION

Every record command shared one usage line naming C<create>, so 21 of the 24
record verbs answered about a command that was not the one asked about. It
adapted the board, which is why it read as considered rather than as a
fallback.

Each verb names itself now and describes its own arguments, because a line that
names the command and then lists create's options is the same fault with the
first word changed.

=cut
