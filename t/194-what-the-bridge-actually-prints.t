#!/usr/bin/env perl
# The channel that reports corruption does not produce it.
#
# Reported by the owner while tailing the bridge:
#
#     Wide character in print at .../lib/Tira/CLI.pm line 1932
#
# Tira::CLI::run puts standard output into :raw on purpose - Perl adds a
# text-mode layer on Windows that rewrites every newline, so the bytes leaving
# the process would not be the bytes Tira produced, and Tira compares output
# bytes in its own cache. Everything that formats output therefore encodes to
# UTF-8 itself, through _utf8_bytes, which exists for exactly this and is used
# by the formatted-output path, the banner, the error path and the cache.
#
# Three prints bypass it and hand decoded characters straight to a raw handle:
# the --refs-only listing, the bridge replay, and the bridge follow loop.
#
# The warning is the milder half. Above U+00FF Perl warns and then writes UTF-8
# anyway, so the text arrives intact with a warning stitched into the middle of
# whatever is reading. That is what he saw.
#
# The silent half is worse and is why this is a P5. Between U+0080 and U+00FF
# there is no warning at all: Perl writes a single latin-1 byte, which is not
# valid UTF-8. A card title carrying an accented name, a plus-or-minus, or a
# multiplication sign written as U+00D7 puts a bad byte into the bridge and says
# nothing about it - the same byte tira.doctor exists to repair, emitted by the
# channel that reports it. Every violation's text comes from a card, so anything
# anybody can type into a title reaches these prints.

use strict;
use warnings;

use Encode qw(decode FB_CROAK);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-15T12:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'board' );
my $store = File::Spec->catdir( $tmp, 'police' );

$tira->project_new(
    name => 'Printing', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'PRS', epic_prefix => 'PRE', ticket_prefix => 'PRT',
);

# One character from each half of the fault, in a place a person would put them:
# U+00D7 is the multiplication sign that started the whole damaged-file thread
# and warns about nothing, U+2014 is an em dash and is what warned.
my $title = "Workflow finder \x{d7}2 \x{2014} three refuters";
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => $title )->{ref};
$tira->record_move( project => $root, ref => $card, column => 'discard' );
# The characters have to be in what the bridge PRINTS, not merely on the card.
# The first draft put them in the title and asserted against the output, and the
# output was pure ASCII - discard-unexplained does not quote the title - so the
# "everything is valid UTF-8" assertion passed on a stream with nothing in it to
# get wrong. A test that cannot fail is worse than no test, and this one said so
# by failing the two assertions that actually looked for the characters.
#
# A policy message is where a person's own words reach the bridge, and people
# write policies in their own language. That is the real path.
$tira->policy_add( project => $root, rule => 'discard-unexplained',
    action => 'bridge-reminder',
    message => "set aside without a word \x{2014} finder \x{d7}2 wanted a reason" );

my $pass = $tira->police_pass( project => $root, store => $store,
    world => { branches => [], worktrees => [], processes => [], containers => [] } );
$tira->bridge_write( store => $store, project => $root,
    violations => $pass->{violations}, settled => $pass->{settled} );

# --- what actually leaves the process ------------------------------------------------
#
# Captured as bytes, because the whole question is which bytes. A string handle
# in :raw takes exactly what print gave it.

my ( $out, $warned ) = ( '', '' );
{
    open my $handle, '>', \$out or die $!;
    binmode $handle, ':raw';
    local *STDOUT = $handle;
    local $SIG{__WARN__} = sub { $warned .= shift };
    do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'policy.bridge', tira => $tira,
        argv => [ '--store', $store, '--once' ] ) };
    close $handle;
}

ok( length $out, 'the bridge printed something' );

# --- and it is valid UTF-8 --------------------------------------------------------------
#
# The assertion that catches the silent half. A latin-1 0xD7 alone is not valid
# UTF-8 and a strict decode refuses it, which is precisely how the damage this
# project has spent a week on is detected everywhere else.

my $decoded = eval { decode( 'UTF-8', $out, FB_CROAK ) };
ok( defined $decoded, 'everything the bridge printed is valid UTF-8' )
  or diag( 'strict decode refused it: ' . ( $@ || 'unknown' ) );

like( $decoded // '', qr/\x{d7}/,
    'and the multiplication sign somebody typed is still a multiplication sign' );
like( $decoded // '', qr/\x{2014}/, 'and the em dash survived too' );

# --- with nothing warned ------------------------------------------------------------------

# Asserted as emptiness rather than as absence, which t/147 insists on and is
# right to: "no wide character in $warned" passes just as happily when $warned
# is empty because the command never ran. Nothing here has any business warning
# at all, so that is what is asserted.
is( $warned, '',
    'and nothing warned about a wide character, which is what he was reading' );

# --- the follow loop prints the same way ---------------------------------------------------
#
# Two prints, one decision. Fixing the replay and leaving the loop would fix the
# first screen and leave every line after it wrong, which is the worse half:
# a tail is what an agent leaves running.

{
    my ( $tail, $tail_warned ) = ( '', '' );
    open my $handle, '>', \$tail or die $!;
    binmode $handle, ':raw';
    {
        local *STDOUT = $handle;
        local $SIG{__WARN__} = sub { $tail_warned .= shift };
        Tira::CLI::_bridge_follow( $tira, $store, rounds => 1, sleeper => sub { } );
    }
    close $handle;

    my $read = eval { decode( 'UTF-8', $tail, FB_CROAK ) };
    ok( defined $read, 'the follow loop prints valid UTF-8 as well' )
      or diag( 'strict decode refused it: ' . ( $@ || 'unknown' ) );
    is( $tail_warned, '', 'and warns about nothing' );
}

# --- and so does the listing that shares the shape -------------------------------------------
#
# --refs-only is the third print of the same form. References are ASCII today, so
# this is latent rather than live - which is exactly the kind of thing that is
# cheap to fix now and expensive to find later.

{
    my $refs = '';
    open my $handle, '>', \$refs or die $!;
    binmode $handle, ':raw';
    {
        local *STDOUT = $handle;
        # record.list with a type, which is what tira.ticket.list resolves to:
        # the refs-only guard names record.list and search by those names.
        do { local $ENV{TIRA_HOME} = $root; Tira::CLI->run( command => 'record.list', type => 'ticket', tira => $tira,
            argv => [ '--refs-only', '-o', 'human' ] ) };
    }
    close $handle;

    ok( defined eval { decode( 'UTF-8', $refs, FB_CROAK ) },
        'the refs-only listing prints valid UTF-8' );
}

done_testing;

__END__

=head1 NAME

194-what-the-bridge-actually-prints.t - the bridge emits UTF-8, not whatever Perl guesses

=head1 DESCRIPTION

Standard output is deliberately C<:raw>, so every output path encodes to UTF-8
itself. Three prints did not: the bridge replay, the bridge follow loop and the
C<--refs-only> listing handed decoded characters straight to the handle.

Above U+00FF that warns and still writes UTF-8. Between U+0080 and U+00FF it
writes a single latin-1 byte and says nothing, putting into the bridge exactly
the kind of byte C<tira.doctor> exists to repair.

=cut
