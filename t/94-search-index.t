#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-12T09:00:00Z' } );

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Indexed', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'IXS', epic_prefix => 'IXE', ticket_prefix => 'IXT',
);

my $index_path = File::Spec->catfile( $root, '.tira', 'search.db' );

my $needle = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card about herrings' );
$tira->record_update( project => $root, ref => $needle->{ref},
    description => 'the description mentions kippers' );
my $other = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card about nothing in particular' );

sub found {
    my ($text) = @_;
    return $tira->search( project => $root, text => $text, refs_only => 1 );
}

# --- before there is an index ---------------------------------------------

# Nothing anywhere pays for a feature it does not use. A project that never
# asks for an index has no database, needs no SQLite, and reads exactly as it
# read before any of this existed.
ok( !-e $index_path, 'a project has no index until somebody asks for one' );
is_deeply( found('herrings'), [ $needle->{ref} ], 'and search answers from the files' );
is_deeply( found('kippers'), [ $needle->{ref} ], 'including what is inside a card' );

my $unindexed = found('card');
is( scalar @{$unindexed}, 2, 'and finds everything it should' );

# --- building one ----------------------------------------------------------

my $built = $tira->search_index( project => $root );
ok( -e $index_path, 'building an index writes one' );
is( $built->{indexed}, 2, 'covering every card on the board' );

# --- and the answers do not change ----------------------------------------

# The only thing an index is allowed to change is how long a read takes.
is_deeply( found('herrings'), [ $needle->{ref} ], 'the same card is found with an index' );
is_deeply( found('kippers'), [ $needle->{ref} ], 'and by the same words' );
is_deeply( found('card'), $unindexed, 'and every answer is the answer the files gave' );

# --- the files win --------------------------------------------------------

# Written behind Tira's back, the way a stale index really happens: somebody
# edits a file, restores a backup, or pulls a branch.
sub rewrite {
    my ( $ref, $from, $to ) = @_;
    my ($path) = grep { -f } map {
        File::Spec->catfile( $root, '.tira', 'ticket', $_, "$ref.json" )
    } qw(backlog implement done);
    open my $in, '<:raw', $path or die $!;
    my $body = do { local $/; <$in> };
    close $in;
    $body =~ s/\Q$from\E/$to/g or die "nothing to rewrite in $path";
    open my $out, '>:raw', $path or die $!;
    print {$out} $body;
    close $out;
    return $path;
}

rewrite( $needle->{ref}, 'herrings', 'mackerel' );

is_deeply( found('mackerel'), [ $needle->{ref} ],
    'a card edited behind the index is found by what the file now says' );
is_deeply( found('herrings'), [],
    'and not by what the index still remembers' );

# --- a corrupt index ------------------------------------------------------

# Rubbish where a database was. Answering wrongly here would be worse than
# failing, and failing would be worse than reading the files.
{
    open my $fh, '>:raw', $index_path or die $!;
    print {$fh} 'this is not a database, it is a sentence';
    close $fh;

    is_deeply( found('mackerel'), [ $needle->{ref} ],
        'a corrupt index degrades to reading the files' );
    is_deeply( found('card'), $unindexed, 'with nothing lost from the answer' );
}

# --- an index that vanishes -----------------------------------------------

unlink $index_path;
is_deeply( found('mackerel'), [ $needle->{ref} ],
    'and so does an index that is not there at all' );

# --- an index that describes a card that is gone --------------------------

# The dangerous direction: the index says a card matches, and the card does not
# exist. A read must never return something the files do not say.
$tira->search_index( project => $root );
my $removed = ( grep { -f } map {
    File::Spec->catfile( $root, '.tira', 'ticket', $_, "$other->{ref}.json" )
} qw(backlog implement done) )[0];
unlink $removed;

my $after = found('card');
is( scalar @{$after}, 1, 'a card whose file is gone is not found' );
is_deeply( $after, [ $needle->{ref} ], 'however sure the index is that it is there' );

# --- the index keeps up with ordinary work --------------------------------

# A write already holds the project lock and is already writing, so it refreshes
# the row it just changed. Nobody has to remember to rebuild.
$tira->record_update( project => $root, ref => $needle->{ref},
    description => 'now it is about anchovies' );
is_deeply( found('anchovies'), [ $needle->{ref} ],
    'a card edited through Tira is findable without rebuilding' );
is_deeply( found('kippers'), [], 'and what it no longer says is no longer found' );

my $fresh = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card about sardines' );
is_deeply( found('sardines'), [ $fresh->{ref} ], 'and so is a card that did not exist' );

# --- one definition of what a card says -----------------------------------

# The index and the live read must not be able to disagree about what the text
# of a card is. Two copies of that definition drift, and the drift is invisible
# until somebody cannot find a card they know is there. A question's answer is
# searchable, so it is searchable through the index too.
{
    my $question = $tira->question_add( project => $root, ref => $fresh->{ref},
        author => 'claude', text => 'which fish?' );
    $tira->question_answer( project => $root, ref => $fresh->{ref},
        id => $question->{id}, text => 'pilchards, obviously' );

    $tira->search_index( project => $root );
    is_deeply( found('pilchards'), [ $fresh->{ref} ],
        'a card is found by the answer to a question on it, with an index' );
    is_deeply( found( $question->{id} ), [ $fresh->{ref} ],
        'and by the question reference, which is how somebody quotes one' );
}

# --- rebuilding -----------------------------------------------------------

# Rebuilt from the files, always: there is nothing in the index that did not
# come from them, so throwing it away costs only the time to read them again.
{
    unlink $index_path;
    my $again = $tira->search_index( project => $root );
    is( $again->{indexed}, 2, 'rebuilding from nothing covers the board' );
    is_deeply( found('anchovies'), [ $needle->{ref} ], 'and the answers are the same' );
}

# --- a machine with no SQLite ---------------------------------------------

# Reading a board must not depend on it. A project that has never asked for an
# index does not need SQLite installed, and one that asks for it where it is
# missing is told what to install rather than shown a Perl module failing to
# load.
{
    no warnings 'redefine';
    local *Tira::_sqlite_available = sub { 0 };

    is_deeply( found('anchovies'), [ $needle->{ref} ],
        'search reads the board with no SQLite anywhere' );

    eval { $tira->search_index( project => $root ) };
    my $error = $@;
    like( $error, qr/SQLite/, 'and asking to build one names SQLite' );
    like( $error, qr/install/i, 'and says to install it' );
    unlike( $error, qr/\@INC|BEGIN failed|Can't locate/,
        'rather than leaking a module load failure at the reader' );
}

# --- the agent cannot write into it ---------------------------------------

# Every row is derived from a file. There is no command that puts a row in by
# hand, because a row nobody can trace to a file is the one row that could lie.
ok( !Tira->can('search_index_add'), 'there is no command to add a row' );
ok( !Tira->can('search_index_update'), 'nor to change one' );

done_testing;

__END__

=head1 NAME

94-search-index.t - an index that cannot disagree with the files

=head1 DESCRIPTION

Settled by Michael on 2026-08-11: the index may only ever be a rebuildable
cache, and the files always win when the two disagree.

The filesystem being the database is the premise the whole tool rests on. An
index is a second copy of the truth, and the moment a read believes the copy
every guarantee built on that premise is gone. So the index is keyed by the
content hash of the file it describes: a row can never describe anything but
the exact bytes on disk, because a changed file has a different hash and misses.
There is no such thing as a stale row to fall back from.

What it buys is the decode. A card whose text cannot match is skipped without
being parsed, and parsing is the expensive part of reading a board.

The tests below are the three the owner asked for - corrupt it, delete it, edit
a file behind it - plus the one that worried me more than any of those: an
index that is certain about a card whose file is gone.

=cut
