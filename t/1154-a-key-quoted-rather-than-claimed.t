#!/usr/bin/env perl
# TKT-1154. import_jira's key-extraction regex scans the WHOLE file as raw
# text, not scoped to each <item>'s own top-level fields. A <description>
# that quotes example markup containing a literal '<key>...</key>'-shaped
# substring (a realistic case - Jira tickets about markup or config
# commonly quote such examples) is counted as a second issue key, and the
# command wrongly refuses a perfectly valid single-issue export.
#
# WRITTEN RED: a description containing key-shaped text still trips the
# multi-issue refusal today.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;

require Tira::CLI::Records;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-24T10:00:00Z'} );
$tira->project_new(
    name => 'Jira Import', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'JQS', epic_prefix => 'JQE', ticket_prefix => 'JQT',
);
my $target = $tira->create_record(
    project => $root, type => 'ticket', title => 'Target ticket',
);

my $xml = File::Spec->catfile( $tmp, 'sample.xml' );
open my $fh, '>', $xml or die $!;
print {$fh} <<'XML';
<rss version="0.92"><channel><item>
  <title>Bug</title>
  <key id="1">PROJ-999</key>
  <summary>A real issue</summary>
  <description>Example: use a &lt;key&gt; tag like this: <key>NOT-REAL</key> in your config.</description>
</item></channel></rss>
XML
close $fh;

my $result = eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, author => 'claude', files => [$xml] }, {},
    );
};
my $error = $@;

ok( !$error, 'a description quoting key-shaped markup does not trip the multi-issue refusal' )
  or diag("import_jira refused: $error");
is( $result->{jira_key}, 'PROJ-999', 'the real key is named, not the one quoted inside the description' )
  if $result;

# --- CODEX REVIEW: a CDATA-wrapped description whose own content contains
# --- the literal text '</description>' must not end the strip early,
# --- leaving a real embedded <key> tag unstripped and counted -------------

my $cdata_xml = File::Spec->catfile( $tmp, 'cdata.xml' );
open my $cfh, '>', $cdata_xml or die $!;
print {$cfh} <<'XML';
<rss version="0.92"><channel><item>
  <title>Bug</title>
  <key id="1">PROJ-999</key>
  <summary>A real issue</summary>
  <description><![CDATA[text </description> <key>NOT-REAL</key>]]></description>
</item></channel></rss>
XML
close $cfh;

my $cdata_result = eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, author => 'claude', files => [$cdata_xml] }, {},
    );
};
ok( !$@, 'a literal "</description>" string inside CDATA does not end the strip early' )
  or diag("import_jira refused: $@");
is( $cdata_result->{jira_key}, 'PROJ-999', 'the real key is still named correctly' )
  if $cdata_result;

# --- the existing genuine multi-issue refusal still works -----------------

my $multi_xml = File::Spec->catfile( $tmp, 'multi.xml' );
open my $mfh, '>', $multi_xml or die $!;
print {$mfh} <<'XML';
<rss version="0.92"><channel>
<item><title>One</title><key id="1">PROJ-1</key><summary>First</summary></item>
<item><title>Two</title><key id="2">PROJ-2</key><summary>Second</summary></item>
</channel></rss>
XML
close $mfh;

eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, author => 'claude', files => [$multi_xml] }, {},
    );
};
like( $@, qr/takes exactly one issue at a time/,
    'a genuine multi-issue export still refuses' );

done_testing;

__END__

=head1 NAME

1154-a-key-quoted-rather-than-claimed.t - a <key>-shaped substring inside
<description> is not mistaken for a second issue

=head1 DESCRIPTION

TKT-1154. import_jira's key-extraction regex used to scan the whole file
as raw text, so a <description> quoting example markup containing a
literal '<key>...</key>' substring was counted as a second issue and the
command wrongly refused a valid single-issue export. Fixed by skipping
<description> spans before running the key regex; a genuine multi-<item>
export still refuses.

=cut
