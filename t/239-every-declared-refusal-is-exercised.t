#!/usr/bin/env perl
# A refusal declared in a table is a refusal something exercises.
#
# TKT-128 built this check for the rule registry, because a rule that declares
# an option it will not honour never reads that option - so a refusal that
# stops firing fails nowhere. conversation-not-folded shipped in exactly that
# state and a bug hunt found it, not the suite.
#
# There are two more tables of the same kind in the CLI and neither was
# covered. %MISLEADING_OPTIONS refuses an option that names the job another
# option does; %OPTION_READ_BY refuses an option whose readers are known.
# Measured on 2026-08-15: of four pairs then declared, two - assign.add and
# assign.remove with --assignee - appeared in no test at all, so half the table
# could have stopped refusing with the suite green.
#
# Exercised rather than scanned. A scan blesses whatever tests happen to exist;
# this runs each declared refusal, so a pair added tomorrow is covered by
# writing it down rather than by somebody remembering to test it.
#
# And the parse is counted. The first version of this guard walked to the
# newline after '],' and never saw evidence.add, which sits after a comment
# block: three pairs found where four are declared. A guard written to prove
# every declared refusal is exercised, silently covering less than it claims,
# is the fault it exists to catch one level up.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite qw(cli_source);
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Declared', dir => $root, members => [ 'claude', 'ada' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Something to run the refusals against' );

sub run {
    my ( $command, @argv ) = @_;
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, type => $type, tira => $tira,
                argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# The whole CLI layer, walked, not lib/Tira/CLI.pm by name. TKT-837 lifted both
# tables this test parses into lib/Tira/CLI/Options.pm to make room under
# t/430's cap; a named read then found nothing and this test failed reporting
# zero declared refusals, which reads as "the table is empty" rather than "the
# table moved". Same fault TKT-835 removed from the engine tests.
my $source = cli_source();

# --- what the two tables declare ---------------------------------------------
#
# Each entry becomes the same thing: a command that must refuse an option, and
# a word its message must contain, because a refusal that does not say what to
# use instead is a dead end.

sub declared_in {
    my ($text) = @_;
    my @refusals;

    my ($misleading) = $text =~ /my %MISLEADING_OPTIONS = \((.*?)\n\);/s;
    my $entries = 0;
    # Up to the bracket that closes the entry, not to a newline: the last
    # entry in the table has no newline after it inside the capture, which is
    # how the first version of this parser found three of the four declared.
    while ( $misleading =~ /'([a-z][a-z.]+)'\s*=>\s*\[(.*?\])\s*,/gs ) {
        my ( $command, $pairs ) = ( $1, $2 );
        $entries++;
        while ( $pairs =~ /\[\s*'(\w+)',\s*'(\w+)'\s*\]/g ) {
            push @refusals, { command => $command, flag => $1, names => "--$2" };
        }
    }

    # Counted, not trusted: the number of entries the table declares against
    # the number this found. A parser that stops early covers less than it says.
    my $declares = () = $misleading =~ /^\s*'[a-z][a-z.]+'\s*=>/gm;

    my ($read_by) = $text =~ /my %OPTION_READ_BY = \((.*?)\n\);/s;
    my $read_declares = () = $read_by =~ /^\s*(\w+)\s*=>\s*\{/gm;

    # Counted the same way as $declares/$entries above, and for the same
    # reason: the loop below depends on an entry ending with exactly "\n
    # },", four spaces, so an entry indented differently - or followed by a
    # comment - disappears from the run with nothing failing. This file's
    # own header describes that exact failure happening to the first table
    # and being fixed there only; this is the second half. TKT-399.
    my $read_found = 0;
    while ( $read_by =~ /(\w+)\s*=>\s*\{(.*?)\n    \},/gs ) {
        my $body = $2;
        my ($flag)     = $body =~ /flag\s*=>\s*'([^']+)'/;
        # TKT-903: two faults, both in this one line. Without /s, a commands
        # regex written across several lines - the shape both 'text' and
        # 'status' use - could not be read whole. And the qr//x form those two
        # entries use closes as "/x," rather than the bare "/," every other
        # entry closes with, which the pattern's literal "/," never matched
        # even with /s added. Either fault alone left $readers undef, and an
        # undef $readers went straight into "grep { $_ !~ /$readers/ }" below:
        # Perl treats an EMPTY pattern as "reuse the last successful match",
        # so the command chosen to exercise the refusal was picked by
        # whatever regex had matched most recently - unconnected to this
        # entry's own readers - and the test passed or failed for a reason
        # that had nothing to do with the entry it was meant to be checking.
        my ($readers)  = $body =~ /commands\s*=>\s*qr\/(.*?)\/[a-z]*,/s;
        my ($instead)  = $body =~ /instead\s*=>\s*'([^']+)'/;
        next if !defined $flag;
        $read_found++;

        # A parser that cannot read an entry must say so loudly, not warn and
        # guess - the exact failure mode this card exists to close.
        die "declared_in: could not parse a 'commands' => qr/.../, pattern "
          . "out of the '$flag' entry in \%OPTION_READ_BY - fix the entry or "
          . "this parser, do not let it warn and continue\n"
          if !defined $readers;

        # A command that is not one of its readers, so the refusal is the thing
        # being exercised rather than the reader being broken.
        my ($not_a_reader) = grep { $_ !~ /$readers/ } qw(record.update record.show);
        die "declared_in: neither record.update nor record.show is usable to "
          . "exercise the '$flag' entry - both match its own readers "
          . "($readers), so no refusal can be proved against them\n"
          if !defined $not_a_reader;
        my ($word) = ( $instead // '' ) =~ /(--[a-z-]+)/;
        push @refusals, { command => $not_a_reader, flag => $flag, names => $word // '--' };
    }

    return ( \@refusals, $entries, $declares, $read_declares, $read_found );
}

my ( $refusals, $entries, $declares, $read_declares, $read_found ) = declared_in($source);

is( $entries, $declares,
    'the parse found as many entries as the misleading-option table declares' );
cmp_ok( $read_declares, '>=', 1, 'and the other table declares at least one' );
is( $read_found, $read_declares,
    'and the parse found as many entries as the option-read-by table declares' );
cmp_ok( scalar @{$refusals}, '>=', 5, 'so there are refusals here to exercise' );

# --- and every one of them, run ----------------------------------------------

sub unexercised {
    my ($list) = @_;
    my @broken;
    for my $refusal ( @{$list} ) {
        my ( $status, $said ) =
          run( $refusal->{command}, '--ref', $card->{ref},
            '--' . $refusal->{flag}, 'ada' );
        push @broken, "$refusal->{command} --$refusal->{flag} was not refused"
          if $status == 0;
        push @broken,
          "$refusal->{command} --$refusal->{flag} was refused without naming $refusal->{names}"
          if $status != 0 && index( $said, $refusal->{names} ) < 0;
    }
    return \@broken;
}

is_deeply( unexercised($refusals), [],
    'every declared refusal fires, and names the option that was meant' );

# --- and the guard is not vacuous --------------------------------------------
#
# A check that finds nothing because its own pattern is wrong is the fault it
# exists to catch. Given a table with an entry nothing refuses, it has to say
# so - built by doctoring the source it reads rather than by adding a real
# entry, so this file cannot break the commands it is checking.

{
    my $doctored = $source;
    $doctored =~ s/(my %MISLEADING_OPTIONS = \()/$1\n    'record.show'    => [ [ 'assignee', 'person' ] ],/;

    my ($invented) = declared_in($doctored);
    my $missed = unexercised($invented);

    cmp_ok( scalar @{$missed}, '>=', 1,
        'a declared refusal that nothing refuses is reported' );
    like( join( "\n", @{$missed} ), qr/record\.show/,
        'naming the entry that does not fire' );
}

# --- and an entry the parser cannot read FAILS, it does not warn ------------
#
# TKT-903. This file's own parse of %OPTION_READ_BY's 'commands' pattern used
# to come back undef for an entry written across several lines (the shape
# 'text' and 'status' both use) and carry on regardless, warning eight times a
# run - the exact "degrades quietly" failure this whole file exists to catch,
# now happening to itself one level up. Doctoring the source the same way the
# vacuous-guard check above does, so this file cannot break the commands it
# is checking: an entry's 'commands => qr/.../,' line is corrupted (the
# trailing comma removed) so the parser's own pattern cannot match it, and
# declared_in() must die naming the broken entry rather than returning a
# result built on an undef $readers.

{
    ( my $doctored = $source ) =~
      s/(commands\s*=>\s*qr\/\\Arecord\\\.\(\?:create\|update\)\\z\/),/$1/;
    isnt( $doctored, $source,
        'the doctor actually changed something, or this proves nothing' );

    my $died = eval { declared_in($doctored); 1 } ? undef : $@;
    ok( $died, 'a commands pattern the parser cannot read makes declared_in die rather than warn and continue' );
    like( $died // '', qr/could not parse a 'commands'/,
        'naming what went wrong, not a bare Perl error' );
}

done_testing;

__END__

=head1 NAME

239-every-declared-refusal-is-exercised.t - both tables, run rather than read

=head1 DESCRIPTION

C<%MISLEADING_OPTIONS> and C<%OPTION_READ_BY> each declare refusals, and
neither was covered by the guard TKT-128 built for the rule registry. Two of
the four pairs then declared appeared in no test at all.

Each declared refusal is run here rather than searched for, so an entry added
tomorrow is covered by being written down. The parse is counted against what
the table declares, because a guard that quietly reads less than it claims is
the fault it exists to catch.

=cut
