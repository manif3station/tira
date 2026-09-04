#!/usr/bin/env perl
# Police prints a Perl warning over its own findings.
#
# TKT-932, EPC-007. His terminal, 2026-09-04 23:04, forty times in one pass:
#
#   Wide character in print at .../lib/Tira.pm line 13171.
#
# That line is the print inside _atomic_write, whose handle is opened ':raw' -
# so a caller must hand it BYTES. Six hand it characters: the session record,
# four violation ledgers and the enforcement log, all
# json_object()->canonical->encode(...), while the project config two hundred
# lines away does the same job correctly with ->utf8->encode.
#
# HE PASTED TWO LINE NUMBERS AND THEY ARE ONE DEFECT. 13171 is that print in
# 5.56; 13066 is the same statement in 5.43, the version installed before
# tonight - a long-running process holds the code it loaded, so his police
# bridge reports the old file's numbers. In 5.52 onwards 13066 is a die inside
# _validated_counter, which is what made it look like a second fault.
#
# IT STARTED WITH A FIX OF MINE. The ledger only holds a non-ASCII character
# once something non-ASCII reaches it, and since 5.55 a monitor's whole block
# reaches the bridge - his Telegram lines carry an arrow and a paperclip.
#
# THE DATA IS NOT DAMAGED, which is why this is priority 4 and not 5: measured,
# the bytes on disk are correct UTF-8 and read back identical. Perl warns and
# writes the right thing. What is broken is his terminal.
#
# AND THE FIX IS ALREADY IN THE FILE, six lines above the broken writers:
# _write_yaml does utf8::is_utf8($yaml) ? encode_utf8($yaml) : $yaml - encode
# characters, pass bytes through. That shape cannot double-encode, which is the
# one way this fix could do real harm.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

my ( $tira, $root, $store );
{
    my $tmp = tempdir( CLEANUP => 1 );
    $root = File::Spec->catdir( $tmp, 'board' );
    $tira = Tira->new;
    $tira->project_new(
        project => $root, name => 'Wide', dir => $root,
        members => ['claude'], columns => ['backlog, done'],
        sow_prefix => 'WDS', epic_prefix => 'WDE', ticket_prefix => 'WDT',
    );
    require Tira::CLI::Police;
    $store = Tira::CLI::Police::_police_store($root);
}

# What a monitor's line looks like when it carries his Telegram text: an arrow
# and a paperclip, as CHARACTERS - which is what anything read back through
# json_decode is, since that is ->utf8->decode.
my $ARROW = "\x{21b3}";
my $CLIP  = "\x{1f4ce}";

sub warnings_from {
    my ($code) = @_;
    my @said;
    local $SIG{__WARN__} = sub { push @said, $_[0] };
    $code->();
    return @said;
}

# --- the warning ---------------------------------------------------------------

{
    my @said = warnings_from( sub {
        $tira->_enforcement_write( $store,
            { entries => [ { at => '2026-09-04T23:04:00+0100', kind => 'violation',
                  ref => '', detail => "JOB-006 said: caption $ARROW $CLIP" } ] } );
    } );

    is( scalar @said, 0,
        'WRITING WHAT A MONITOR SAID PRINTS NOTHING. Today every such write '
          . 'warns "Wide character in print", because the ledger is encoded '
          . 'without ->utf8 and handed to a handle opened raw - forty lines '
          . 'over the top of what police was actually saying' )
      or diag( join '', @said );
}

# --- and the data is unharmed, before and after --------------------------------
#
# The control that makes the fix safe to judge: what is on disk is correct UTF-8
# and reads back identical. This passes BEFORE the change - Perl warns and then
# writes the right bytes - and it must still pass after, which is what stops a
# fix that silences the warning by breaking the file.

{
    my $entries = $tira->enforcement_log( project => $root, store => $store );
    my $detail = ( $entries->[0] || {} )->{detail} // '';

    like( $detail, qr/\Q$ARROW\E/,
        'the arrow survives the round trip' );
    like( $detail, qr/\Q$CLIP\E/,
        'and so does the paperclip - four bytes of it' );
}

# --- a line arrives as text, at the boundary where it enters ------------------
#
# THE FIRST ATTEMPT AT THIS FIX FAILED HERE AND THE FAILURE IS THE DESIGN.
# I copied _write_yaml's guard - encode when the string is characters, pass it
# through when it is bytes - and pointed the six writers at it. A ledger is a
# MIXTURE, though: characters from anything read back through json_decode, and
# octets from a line the feeder took off a pipe. JSON returns ONE string for
# the whole structure and flags it if any value was text, so encoding it
# encoded the byte-valued parts a second time and put mojibake on disk. Real
# damage, where the warning did none.
#
# So the fix is at the boundary instead: a monitor's line is TEXT, and the
# feeder decodes it once as it arrives. Then every value in every ledger is
# characters, ->utf8 at the writers is correct, and the warning has nothing to
# complain about.
#
# FB_QUIET rather than a die, which is this file's own precedent for reading
# the bridge log: "a corrupted byte somewhere in the log must not stop the
# agent hearing the rest of it".

{
    my $job = $tira->job_add( project => $root, schedule => 'monitor',
        command => 'a-poller-with-a-caption', author => 'claude' );

    pipe my $reader, my $writer or die "pipe: $!";
    print {$writer} "caption: \xe2\x86\xb3 hint \xf0\x9f\x93\x8e PHOTO\n";
    close $writer;

    require Tira::CLI::Job::Feeder;
    Tira::CLI::Job::Feeder::feed_from_handle( $tira, { project => $root },
        $job->{id}, $reader, 1, 25 );
    close $reader;

    my ($after) = grep { ( $_->{id} // '' ) eq $job->{id} }
      @{ $tira->job_list( project => $root ) };
    my $said = ( $after->{output} || [] )->[0] // '';

    like( $said, qr/\Q$ARROW\E/,
        'A MONITOR\'S LINE REACHES THE RECORD AS TEXT. It arrives from a pipe '
          . 'as octets and is decoded once, where it enters - so a ledger holds '
          . 'characters and the writers have nothing to guess at. Today it '
          . 'stays bytes, which is what makes the six writes warn' );

    like( $said, qr/\Q$CLIP\E/,
        'including the four-byte one' );
}

# --- the shape the fix should take ---------------------------------------------
#
# Source-read, and pointed at the answer that is already in the file: the same
# guard _write_yaml uses. Asserted because "encode only what is characters" is
# the property that makes the assertion above hold by construction rather than
# by having remembered it.

my $engine = do {
    require Suite;
    Suite::engine_source();
};

like( $engine, qr/utf8::is_utf8\(\s*\$yaml\s*\)/,
    'the YAML writer already encodes only what is characters - the idiom this '
      . 'card copies rather than invents' );

my @unguarded = $engine =~ /_atomic_write\([^;]*json_object\(\)->canonical->encode/gs;

is( scalar @unguarded, 0,
    'AND NO JSON WRITER HANDS CHARACTERS TO A RAW HANDLE. Six do today - the '
      . 'session record, four violation ledgers and the enforcement log - '
      . 'while the project config does the same job with ->utf8->encode two '
      . 'hundred lines away' );

my $cli = do { require Suite; Suite::cli_source() };

like( $cli, qr/FB_QUIET|FB_DEFAULT/,
    'and the feeder decodes what it reads rather than passing octets on - '
      . 'quietly, because a corrupted byte in a monitor\'s output must not '
      . 'stop the board hearing the rest of it, which is the reason this file '
      . 'already gives for reading the bridge log that way' );

done_testing();

__END__

=head1 NAME

543-a-warning-over-what-police-said.t - Wide character in print, on every police write

=head1 WHY

TKT-932. C<_atomic_write> opens its handle C<:raw>, so callers must hand it
bytes; six hand it characters. Nothing was damaged - the bytes on disk are
correct UTF-8 and read back identical - but every write printed a Perl warning
over what police was saying, forty at a time.

It surfaced when a monitor's whole block began reaching the bridge in 5.55: his
Telegram lines carry an arrow and a paperclip.

=head1 WHAT IS ASSERTED

That writing a ledger entry containing those characters prints nothing; that the
characters survive the round trip, before and after; that an entry which is
still B<bytes> is not encoded a second time - the one way this fix could do real
harm; and that no JSON writer hands characters to a raw handle, using the guard
F<Tira.pm>'s own YAML writer already has.

=cut
