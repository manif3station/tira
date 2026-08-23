#!/usr/bin/env perl
# description_truncated is a value the tool holds and never told a reader
# what to do about. The flag and the true length were both in the payload,
# honestly, but not the fix - a reader had to already know --full exists.
# Measured live: about 1354 bytes lost across three read-modify-write edits
# on TKT-386 before the round number 2001 gave the truncation away and
# --full was found by guessing. TKT-402.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Hinted', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'HNS', epic_prefix => 'HNE', ticket_prefix => 'HNT',
);

my $long = ( 'x' x 2500 );
my $long_card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Long description', description => $long );
my $short_card = $tira->create_record( project => $root, type => 'ticket',
    title => 'Short description', description => 'brief' );

# --- a truncated read names the fix in the same output ----------------------

{
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $long_card->{ref}, truncate => 2000 );
    ok( $shown->{description_truncated}, 'the flag is set, as it always was' );
    is( $shown->{description_hint}, 'use --full to read it whole',
        'and the hint names --full in the same output' );
}

# --- an untruncated read carries no such hint --------------------------------

{
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $short_card->{ref} );
    ok( !$shown->{description_truncated}, 'a short description is not truncated' );
    ok( !exists $shown->{description_hint}, 'and carries no hint - a hint that always appears is furniture' );
}

# --- --full suppresses truncation, and so the hint along with it ------------
#
# The CLI's --full maps to calling record_show with no truncate argument at
# all (lib/Tira/CLI.pm: truncate is undef, then deleted from %args) - that
# is the engine's own "whole record" path, proven directly here rather than
# through the CLI layer.

{
    my $full = $tira->record_show( project => $root, type => 'ticket', ref => $long_card->{ref} );
    ok( !exists $full->{description_hint}, 'reading with no truncate limit at all carries no hint either' );
    is( $full->{description}, $long, 'and gets the whole text' );
}

# --- every other field in the read is unaffected -----------------------------

{
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $long_card->{ref}, truncate => 2000 );
    is( $shown->{title}, 'Long description', 'title is untouched' );
    is( $shown->{ref}, $long_card->{ref}, 'ref is untouched' );
}

# --- break it: remove the hint and watch the assertion fail, not the number -

{
    no warnings 'redefine';
    local *Tira::_truncate_text_slot = sub {
        my ( $container, $key, $limit ) = @_;
        my $value = $container->{$key};
        return if !defined $value || ref $value;
        my $length = length $value;
        return if $limit > 0 && $length <= $limit;
        $container->{$key} = substr( $value, 0, $limit ) . "\x{2026}" if $limit > 0;
        $container->{"${key}_truncated"} = Cpanel::JSON::XS::true;
        $container->{"${key}_length"} = $length;
        return;
    };
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $long_card->{ref}, truncate => 2000 );
    ok( $shown->{description_truncated}, 'with the hint removed, the flag is still set (the number stays the same)' );
    ok( !exists $shown->{description_hint}, 'but the hint is gone - proving the assertions above test the hint, not the flag' );
}

done_testing;

__END__

=head1 NAME

358-a-flag-that-said-nothing-to-do-about-it.t - description_truncated names its own fix

=head1 DESCRIPTION

C<description_truncated> was a flag the tool held and never told a reader
what to do about - the fix (C<--full>) had to already be known. This proves
a truncated read carries a hint naming C<--full> in the same output, an
untruncated read carries no such hint, every other field is unaffected,
and a version with the hint removed still sets the flag - so the
assertions above are proven to test the hint specifically.

=cut
