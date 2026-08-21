#!/usr/bin/env perl
# Where work ends, asked once.
#
# The engine reads it from the column: a column marked terminal is an ending,
# and a board that has marked nothing ends in one called done. `--terminal` is
# how a board says so and both documents describe it.
#
# The push gate read it from the column roles instead, and from one role - so
# two boards it should understand it does not:
#
#   A board that marks a column terminal without calling it done. The engine
#   answers "work ends in shipped"; the gate refused to run at all, with
#   "this board has no done column and no done column" - the same word twice,
#   because it asked for the done role with done as its own fallback.
#
#   A board with a column called done that has declared no roles, which the
#   gate's own comment says most boards are. Its endings came out empty, so a
#   finished card was judged as work in progress and asked for the whole
#   definition of a complete card. The protection against exactly that is
#   written into the tool in as many words - 61 cards here shipped under an
#   older definition and demanding those fields now would block every push for
#   ever - and it was keyed on the answer that was empty.
#
# This project's own board declares the role for all three types, which is why
# neither has ever happened here. The gate was right about one board.
#
# Same shape as TKT-241, which found what a complete card is written twice and
# moved it into the engine for the gate to ask for. This is the second such
# decision, and the answer is the same: ask.

use strict;
use warnings;

use Cwd qw(getcwd);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib', 't/lib';
use Run qw(run_capturing);
use Tira;

my $tmp   = tempdir( CLEANUP => 1 );
my $skill = File::Spec->rel2abs('.');
my $tool  = File::Spec->rel2abs( File::Spec->catfile( 'tools', 'card-holes' ) );

# A dispatcher of its own, because the dashboard is not installed in the
# container the suite runs in.
my $stub = File::Spec->catdir( $tmp, 'bin' );
mkdir $stub or die "$stub: $!";
{
    my $path = File::Spec->catfile( $stub, 'd2' );
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} <<"PL";
#!$^X
use strict;
use warnings;
use File::Spec;
my \$command = shift \@ARGV;
\$command =~ s/\\Atira\\.//;
my \@parts = split /\\./, \$command;
my \$verb = pop \@parts;
my \$entry = \@parts
  ? File::Spec->catfile( '$skill', 'skills', \@parts, 'cli', \$verb )
  : File::Spec->catfile( '$skill', 'cli', \$verb );
exec \$^X, '-I', File::Spec->catdir('$skill','lib'), \$entry, \@ARGV;
PL
    close $fh;
    chmod 0755, $path or die "chmod: $!";
}

sub gate {
    my ( $root, @about ) = @_;
    my $here = getcwd();
    chdir $tmp or die "chdir: $!";
    local $ENV{TIRA_HOME} = $root;
    local $ENV{PATH} = $stub . ':' . $ENV{PATH};
    my ( $status, $said ) = run_capturing( 'python3', $tool, @about );
    chdir $here or die "chdir back: $!";
    return ( $status, $said );
}

my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );

# --- a board that marks where work ends --------------------------------------

my $marked = File::Spec->catdir( $tmp, 'marked' );
$tira->project_new(
    name => 'Marked', dir => $marked, members => ['claude'],
    columns => ['backlog, implement, verify, shipped'],
    sow_prefix => 'MKS', epic_prefix => 'MKE', ticket_prefix => 'MKT',
);
$tira->column_update( project => $marked, type => $_, name => 'shipped', terminal => 1 )
  for qw(sow epic ticket);

is_deeply( $tira->_ending_columns( $marked, 'ticket' ), { shipped => 1 },
    'the engine reads the board: work ends in shipped' );

my $done = $tira->create_record( project => $marked, type => 'ticket',
    title => 'Work that is finished and shipped' );
$tira->record_move(author => 'claude',  project => $marked, ref => $done->{ref}, column => 'shipped' );

{
    my ( $status, $said ) = gate( $marked, $done->{ref} );

    # non-empty is the whole claim: a precondition for the two below, which
    # would both pass against a tool that printed nothing at all.
    like( $said, qr/\S/, 'and the gate has something to say about that board' );

    unlike( $said, qr/no done column/,
        'which is not that the board has no done column and no done column' );
    is( $status, 0,
        'a card in the column this board says work ends in is finished work' );
}

# --- a board with a done column and no roles ---------------------------------
#
# The gate's own comment on where work starts says most boards have declared no
# roles. This is one of them.

my $plain = File::Spec->catdir( $tmp, 'plain' );
$tira->project_new(
    name => 'Plain', dir => $plain, members => ['claude'],
    columns => ['backlog, implement, verify, done'],
    sow_prefix => 'PLS', epic_prefix => 'PLE', ticket_prefix => 'PLT',
);

my $old = $tira->create_record( project => $plain, type => 'ticket',
    title => 'Finished long ago, under an older definition' );
$tira->record_move(author => 'claude',  project => $plain, ref => $old->{ref}, column => 'done' );

{
    my ( $status, $said ) = gate( $plain, $old->{ref} );
    is( $status, 0, 'a finished card on a board that declared no roles is left alone' );
    unlike( $said, qr/\Q$old->{ref}\E \(done\) is missing/,
        'rather than asked backwards for a definition it never met' );
}

# --- while work still being done is judged -----------------------------------
#
# The half that must not be lost. Reading the board correctly must not turn the
# check off for the cards it is for.

{
    my $live = $tira->create_record( project => $plain, type => 'ticket',
        title => 'Being worked right now' );
    $tira->record_move(author => 'claude',  project => $plain, ref => $live->{ref}, column => 'implement' );

    my ( $status, $said ) = gate( $plain, $live->{ref} );
    isnt( $status, 0, 'a card being worked is still asked for what a card needs' );
    like( $said, qr/\Q$live->{ref}\E \(implement\) is missing/,
        'and told which column it is in and what is missing' );
}

done_testing;

__END__

=head1 NAME

238-where-work-ends-asked-once.t - one answer, asked by the gate and the engine

=head1 DESCRIPTION

C<lib/Tira.pm> reads where work ends from the column's terminal flag, falling
back to a column named C<done>. C<tools/card-holes> read it from the C<done>
column role alone, so it could not run at all on a board that marks its ending
rather than naming it, and judged finished cards as live work on a board that
has declared no roles - which the tool's own comment says most boards are.

The gate asks the engine, the way it already asks the engine what a complete
card is.

=cut
