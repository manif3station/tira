#!/usr/bin/env perl
# Tira::CLI has to be an index, not the whole book.
#
# The owner's words, on TSK-183: "Tira::CLI the file is too big. Decompose it to
# different perl modules and lazy load them do not use Tira::xxx and use require
# Tira::xxx when need to. 1st when you read the file ::CLI will be lighweight
# like index and only read the one specific related to bug or enchancment that
# save some token too."
#
# The saving he asks for is a READER'S, not a runtime one - which is why this
# file asks what somebody changing one command must open, rather than what the
# process loads. lib/Tira/CLI.pm is 6,048 lines and 101 subs, and every command
# body is in it, so the answer today is "all of it".
#
# The pattern already exists in the file and is the shape to spread: DashboardWeb
# and OnboardWeb are pulled in with require at the point of use, not with use at
# the top, so a CLI invocation that never serves a board never loads Dancer2.
#
# WHAT THIS FILE MUST NOT DEMAND is a particular set of module names. The card
# asks for boundaries "by concern, not by command" and leaves the concerns to
# whoever does the work, so asserting a list of names here would decide the
# design from the test - which is the wrong way round and would need rewriting
# by whoever disagreed. It asserts the shape: modules exist, they are loaded
# lazily, and the index has shrunk to something a person can read.
#
# The last two assertions are green now and must stay green. They are the two
# properties this refactor is most likely to cost: the move path's guards run in
# a stated order that TKT-662 wrote into the POD hours ago, and every module
# under lib/ is held to 100% by a gate that discovers them - which TKT-594 made
# true tonight, and which is the whole reason this card was allowed to proceed.

use strict;
use warnings;

use File::Find ();
use Test::More;

my $index = do {
    open my $fh, '<', 'lib/Tira/CLI.pm' or die "lib/Tira/CLI.pm: $!";
    local $/;
    <$fh>;
};

# Established before anything is measured. A count over a file that failed to
# load is zero for the wrong reason - t/147's subject, and the thing that made
# t/417 fail loudly rather than silently when the front-end moved tonight.
ok( $index, 'lib/Tira/CLI.pm was read - ' . length($index) . ' bytes' );

my @lines = split /\n/, $index;

# --- the index is readable -----------------------------------------------
#
# A number rather than a proportion, because the card's complaint is absolute:
# reading it to change one command means reading all of it. 2,000 lines is the
# threshold t/426 already holds lib/Tira.pm's LINES to for the same reason, and
# reusing it means one idea of "too big to read" rather than two.

cmp_ok( scalar @lines, '<', 2_000,
    'lib/Tira/CLI.pm is short enough to read as an index - '
      . scalar(@lines) . ' lines' );

# --- and the bodies live somewhere a reader can find ---------------------

my @modules;
File::Find::find(
    { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm\z/ } },
    'lib/Tira/CLI' ) if -d 'lib/Tira/CLI';
cmp_ok( scalar @modules, '>=', 1,
    'the command bodies live in modules of their own - found '
      . ( @modules ? join( ', ', sort @modules ) : 'none' ) );

# --- loaded when needed, not at the top ----------------------------------
#
# His instruction was specific: "do not use Tira::xxx and use require Tira::xxx
# when need to". Both halves are asserted, because a file can gain requires and
# keep its uses, and then nothing is lazy about it.

my $uses     = () = $index =~ /^use Tira::CLI::/mg;
my $requires = () = $index =~ /require Tira::CLI::/g;
is( $uses, 0,
    'no command module is loaded with use at the top - found ' . $uses );
cmp_ok( $requires, '>=', 1,
    'they are required at the point of use instead - found ' . $requires );

# --- what this must not cost ---------------------------------------------
#
# Green before this card and green after.

like( $index, qr/=head2 The four guards on the move path/,
    'the move path still states its guards and their order, which a reader '
      . 'needs and which moving code is most likely to lose' );

my $gate = do {
    open my $fh, '<', 'tools/gate-run' or die "tools/gate-run: $!";
    local $/;
    <$fh>;
};
like( $gate, qr/find\s+"?\$?\w*"?\/?lib -name/,
    'and the coverage gate still finds its modules by looking, so a module '
      . 'this card creates is gated from the moment it exists' );

done_testing();

__END__

=head1 NAME

t/430-an-index-that-is-the-whole-book.t - Tira::CLI must be an index, with the
command bodies in modules of their own

=head1 DESCRIPTION

C<lib/Tira/CLI.pm> is 6,048 lines and 101 subs, and every command body is in it.
The owner asked for it to read "lighweight like index" so that changing one
command means opening that command's module and the index, rather than all of
it - a saving in what a reader must hold, not in what the process loads.

The shape already exists in the file: C<Tira::DashboardWeb> and
C<Tira::OnboardWeb> are pulled in with C<require> at the point of use, so a CLI
invocation that never serves a board never loads Dancer2. This asks for that
shape to spread.

It deliberately does not name the modules it expects. The card asks for
boundaries by concern rather than by command and leaves the concerns open, so a
test naming them would decide the design and then need rewriting by whoever
disagreed. It asserts that modules exist, that they are loaded lazily, and that
the index has shrunk.

The last two assertions are green already and are the properties this refactor
is most likely to cost: the move guards' stated order, written into the POD by
TKT-662, and a coverage gate that finds its modules by looking rather than by a
list - TKT-594, which is why a new C<Tira::CLI::Something> cannot arrive ungated.

=cut
