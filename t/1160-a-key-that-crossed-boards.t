#!/usr/bin/env perl
# TKT-1153. URGENT, owner deadline. Importing a Jira issue's exported XML,
# recording its key as a key-detail on the matching Tira ticket - no sample
# XML was provided, so this targets Jira's own standard, documented
# issue-XML export shape (Export XML action, RSS 0.92-based).
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp ();
use Test::More;

use lib 'lib';
use Tira;

require Tira::CLI;
require Tira::CLI::Records;

my $tmp  = File::Temp::tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-09-23T19:00:00Z'} );
$tira->project_new(
    name => 'Jira Import', dir => $root, members => ['claude'],
    columns    => ['backlog, done'],
    sow_prefix => 'JIS', epic_prefix => 'JIE', ticket_prefix => 'JIT',
);
my $target = $tira->create_record(
    project => $root, type => 'ticket', title => 'A ticket waiting for its Jira ref',
);

ok( Tira::CLI::Records->can('import_jira'),
    'the record layer can import a Jira XML export' );

my $xml = File::Spec->catfile( $tmp, 'sample.xml' );
open my $fh, '>', $xml or die $!;
print {$fh} <<'XML';
<rss version="0.92"><channel><item>
  <title>[PROJ-123] Summary text</title>
  <key id="12345">PROJ-123</key>
  <summary>Summary text</summary>
  <status>Open</status>
  <description>The full description body.</description>
  <parent>PROJ-100</parent>
  <subtasks><subtask id="1">PROJ-124</subtask><subtask id="2">PROJ-125</subtask></subtasks>
</item></channel></rss>
XML
close $fh;

my $result = Tira::CLI::Records::import_jira(
    $tira, { project => $root, ref => $target->{ref}, files => [$xml] }, {},
);
ok( $result->{ok}, 'importing a well-formed export succeeds' )
  or diag( $result->{error} // 'no error message' );
is( $result->{jira_key}, 'PROJ-123', 'the parsed Jira key comes back in the result' );

my $after = $tira->record_show( project => $root, type => 'ticket', ref => $target->{ref} );
my $key_details_text = join( "\n", @{ $after->{key_details} // [] } );
like( $key_details_text, qr/PROJ-123/,
    'the Jira key is recorded as a key-detail on the Tira ticket' );
like( $key_details_text, qr/Summary text/,
    'and the Jira summary travels with it' );

# --- a malformed file refuses cleanly, not with an internal parser error ---

my $bad = File::Spec->catfile( $tmp, 'bad.xml' );
open my $bfh, '>', $bad or die $!;
print {$bfh} "not xml at all, just text\n";
close $bfh;

my $before_ticket = $tira->record_show( project => $root, type => 'ticket', ref => $target->{ref} );
my $bad_result = eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, files => [$bad] }, {},
    );
};
my $refused = $@ || ( ref($bad_result) eq 'HASH' && !$bad_result->{ok} );
ok( $refused, 'a malformed file refuses rather than crashing with an internal error' );

my $after_bad = $tira->record_show( project => $root, type => 'ticket', ref => $target->{ref} );
is_deeply( $after_bad->{key_details}, $before_ticket->{key_details},
    'the ticket is unchanged after a refused import' );

done_testing();

__END__

=head1 NAME

1160-a-key-that-crossed-boards.t - importing a Jira issue XML export onto a Tira ticket

=head1 DESCRIPTION

TKT-1153. C<Tira::CLI::Records::import_jira> parses a Jira issue-XML export
(the standard "Export XML" action's RSS 0.92 shape) and records the Jira
issue key and summary as a key-detail on the target Tira ticket, via the
existing C<comment_add --key-detail> mechanism. A malformed file refuses
cleanly instead of dying with an internal parser error.

=cut
