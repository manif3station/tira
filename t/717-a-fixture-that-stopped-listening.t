#!/usr/bin/env perl
# A fixture standing in for the card dialog's /record payload has to keep
# listening to what the real payload actually carries.
#
# Three fixtures drifted from the thing they mock in one session, found only
# by accident: t/playwright/dashboard-browser.js and
# t/playwright/source-attachment-preview.js both mock an attachment inside a
# /record payload, and the shape of that mock is exactly what
# Tira::CLI::_stamp_attachment_types puts on a real one (TKT-645). Nothing
# compared the two, so either fixture could gain or lose a key relative to
# the real payload and every Playwright assertion would keep passing against
# a shape nobody's browser will ever actually receive.
#
# The comparison is about the KEY SET, not the values: a fixture may still
# invent whatever sha, filename or timestamp is convenient for the scenario
# it drives. What it may not do is silently start mocking a field the real
# route does not send, or silently stop carrying one the dialog depends on.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

require Tira::CLI::Browser;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-09T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'A fixture that stopped listening',
    dir           => $root,
    members       => ['claude'],
    columns       => ['backlog, done'],
    sow_prefix    => 'FSS',
    epic_prefix   => 'FSE',
    ticket_prefix => 'FST',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'A card with a file' );

my $file = File::Spec->catfile( $tmp, 'notes.txt' );
open my $fh, '>', $file or die "cannot write $file: $!";
print {$fh} "hello";
close $fh;

$tira->attachment_add(
    project => $root, ref => $card->{ref}, filename => 'notes.txt', file => $file );

my %provider = Tira::CLI::Browser::providers( tira => $tira, project => $root );
my $decode = Tira::json_object();

my $json   = $provider{detail}->( { ref => $card->{ref} } );
my $record = $decode->decode($json);

ok( scalar @{ $record->{attachments} }, 'the real record carries the attachment just added' );

my @real_keys = sort keys %{ $record->{attachments}[0] };

# --- the fixtures that stand in for this exact payload -----------------------

for my $fixture (qw(t/playwright/dashboard-browser.js t/playwright/source-attachment-preview.js)) {
    open my $fh, '<', $fixture or die "cannot read $fixture: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    # Scoped to an attachments array literal rather than to the whole file -
    # the fixture's card-level fields (title, priority, ...) are a different
    # shape entirely, and comparing those against an attachment would fail
    # for a reason that has nothing to do with what this file is about. Named
    # either inline (`attachments: [`) or through a constant a fixture
    # defines once and reuses (`const ATTACHMENTS = [`).
    my ($object) = $source =~ /(?:attachments:|ATTACHMENTS\s*=)\s*\[\s*\{([^}]*)\}/;
    next if !defined $object;    # this fixture carries no attachment - nothing to check

    # Keys only - a bare \w+: also matches inside an ISO timestamp value
    # ('...T10:00:00+0100'), so a key is only counted where it opens a
    # property: right after the object's own '{' or after a ',' separating
    # properties.
    my @fixture_keys = sort "{$object," =~ /(?:\{|,)\s*(\w+):/g;

    is_deeply( \@fixture_keys, \@real_keys,
        "$fixture attachment mock carries the same keys the real /record "
          . "payload does - real: [@real_keys], fixture: [@fixture_keys]" );
}

done_testing();

__END__

=head1 NAME

t/717-a-fixture-that-stopped-listening.t - a Playwright fixture's attachment
mock is checked against the real /record payload's shape

=head1 DESCRIPTION

TKT-717. Three fixtures drifted from what they mock in one session and each
was found by accident. This file compares the KEY SET of an attachment inside
the real card-dialog payload (built the same way C<Tira::CLI::Browser>'s
C<detail> provider builds one, stamped with C<content_type> by
C<Tira::CLI::_stamp_attachment_types>) against the key set the Playwright
fixtures use to mock one, so a future field added or removed on either side
is caught here rather than by an unrelated card that happens to touch it.

Values are never compared - a fixture may still invent whatever filename,
sha, or timestamp its scenario needs. Only the shape is checked.

=cut
