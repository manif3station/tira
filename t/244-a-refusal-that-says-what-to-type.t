#!/usr/bin/env perl
# A refusal that says what is missing says what to type.
#
# Measured by running every shipping entrypoint with no arguments from inside a
# board: 83 refuse with a message naming no option at all. Forty of them say
# "Record reference is required" and not one says --ref. The message is right
# and a reader still has to guess, which is the family this project has now had
# reported from outside four times.
#
# The engine raises those messages and has no notion of a command line, which
# is why they name a thing rather than a flag - so the translation lives at the
# boundary, where flag names already live, and the engine keeps no table of
# them.
#
# A declared table can drift from the messages it translates, so this runs the
# commands rather than reading the table: a message reworded out of the table
# stops naming its option and this says so. What it deliberately does not cover
# is a refusal about the state of things - "no collector is installed", "this
# project has no heartbeat" - which is not a missing argument and has no option
# to name. Those are counted and reported rather than passed over in silence.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-16T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Spoken', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'SPS', epic_prefix => 'SPE', ticket_prefix => 'SPT',
);

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local $SIG{__WARN__} = sub { };
        local *STDOUT = $so;
        local *STDERR = $se;
        do {
            local $ENV{TIRA_HOME} = $root;
            Tira::CLI->run( command => $command, tira => $tira, argv => [@argv] );
        };
    };
    return ( $status, $out . $err );
}

# --- the commands that ask for something ---------------------------------------
#
# One per distinct message rather than all eighty-three, because eighty-three
# invocations of the same translation prove nothing the first one did not - and
# each is a command a person actually runs.

my @asking = (
    [ 'assign.list',      'ref' ],
    [ 'checklist.add',    'item' ],
    [ 'checklist.update', 'item' ],
    [ 'question.ask',     'text' ],
    [ 'import',           'file' ],
    [ 'replace',          'pattern' ],
    [ 'warning.add',      'message' ],
    [ 'login.register',   'password' ],
    [ 'attachment.discard', 'ref' ],
);

for my $each (@asking) {
    my ( $command, $flag ) = @{$each};
    my ( $status, $said ) = run($command);

    isnt( $status, 0, "$command with nothing is refused" );
    like( $said, qr/--\Q$flag\E\b/,
        "$command says to supply it with --$flag" );
}

# --- and the message underneath is unchanged -----------------------------------
#
# The engine's own words are what a reader recognises, and this adds to them
# rather than replacing them.

{
    my ( undef, $said ) = run('assign.list');
    like( $said, qr/Record reference is required/,
        'the engine still says what is missing, in its own words' );
}

# --- while a refusal about the state of things is left alone -------------------
#
# "No collector is installed" is not a missing argument and has no option to
# name. Adding one would be inventing advice.

{
    my ( $status, $said ) = run('collector.remove');
    isnt( $status, 0, 'a refusal about how things stand is still a refusal' );
    unlike( $said, qr/supply it with/,
        'and is not given advice about an option it never wanted' );
}

# --- every message the table carries, by construction ---------------------------
#
# The nine above prove the wiring on commands a person runs. This covers the
# table itself, so an entry added tomorrow is covered by being written down
# rather than by somebody remembering to run it - and the count is checked
# against what the table declares, because a parser that stops early covers
# less than it claims.

{
    open my $fh, '<', File::Spec->catfile(qw(lib Tira CLI.pm)) or die $!;
    my $source = do { local $/; <$fh> };
    close $fh;

    my ($table) = $source =~ /my %SUPPLIED_BY = \((.*?)\n\);/s;
    my @entries = $table =~ /^\s*(?:'([^']+)'|"([^"]+)")\s*=>\s*\[\s*'([^']+)'/gm;

    my @said;
    while (@entries) {
        my ( $single, $double, $flag ) = splice @entries, 0, 3;
        push @said, [ ( defined $single ? $single : $double ), $flag ];
    }

    # Counted by the shape of an entry rather than by the shape of its key:
    # one key contains the quote character the other keys are written with,
    # so a pattern built around quoting misses it - which it did, and the
    # count said so on the first run.
    my $declares = () = $table =~ /^\s*\S.*=>\s*\[/gm;
    is( scalar @said, $declares,
        'the parse found every message the table declares' );
    cmp_ok( scalar @said, '>=', 25, 'and there are messages here to translate' );

    my @silent;
    for my $each (@said) {
        my ( $message, $flag ) = @{$each};
        my $answered = Tira::CLI::_names_the_option($message);
        push @silent, "$message -> $answered" if $answered !~ /--\Q$flag\E\b/;
    }
    is_deeply( \@silent, [], 'and every one of them comes back naming its option' );
}

# --- and a message that already names its option is left alone -------------------
#
# The guard against saying it twice. No message in the table names its own
# option today, so nothing a command prints reaches this line - it is there
# because a message reworded to include its flag would otherwise be given the
# advice a second time, appended to itself. Asserted directly rather than
# through a command, because there is no command that produces it.

{
    my $already = 'Record reference is required - supply it with --ref';
    is( Tira::CLI::_names_the_option($already), $already,
        'a message that already names its option is returned unchanged' );

    my $count = () = Tira::CLI::_names_the_option($already) =~ /--ref/g;
    is( $count, 1, 'so the advice is not appended to advice' );
}

# --- and nothing is said twice --------------------------------------------------
#
# A message that already names its option is left as it is, or the advice would
# be appended to advice.
#
# column.list was the original example here and, since TKT-409, no longer
# refuses at all with no --type - it answers for all three record kinds
# instead. column.update is the same family (a command genuinely narrowed to
# one board) and still carries the identical message.

{
    my ( undef, $said ) = run( 'column.update' );
    like( $said, qr/--type/, 'a message that already names its option still does' );
    my $count = () = $said =~ /--type/g;
    is( $count, 1, 'once' );
}

done_testing;

__END__

=head1 NAME

244-a-refusal-that-says-what-to-type.t - the thing, and the flag that supplies it

=head1 DESCRIPTION

Eighty-three refusals named what was missing and never the option that supplies
it - forty of them "Record reference is required", none of them C<--ref>. The
engine has no notion of a command line, so the translation is done at the
boundary and the engine keeps no table of flags.

Run rather than read, because a declared table can drift from the messages it
translates: a message reworded out of the table stops naming its option, and
these assertions fail.

=cut
