#!/usr/bin/env perl
# TKT-1153. URGENT, owner deadline. Importing a Jira issue's exported XML,
# recording its key as a key-detail on the matching Tira ticket - no sample
# XML was provided, so this targets Jira's own standard, documented
# issue-XML export shape (Export XML action, RSS 0.92-based).
#
# WRITTEN RED.
#
# CODEX REVIEW FIXUP: the first version returned {ok=>0} on refusal, which
# the CLI dispatcher formats as a successful exit(0) - contradicting the
# documented "refuses cleanly" behavior. Every refusal here now dies, like
# every other engine verb, and is asserted through eval/$@. Also added:
# entity/CDATA decoding, multi-issue-export refusal, and the real executable
# (not just the engine sub) for at least the malformed-file and
# real-invocation paths, plus no silent 'claude' author default.

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
    name => 'Jira Import', dir => $root, members => [ 'claude', 'alice' ],
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
  <summary>Summary &amp; more &lt;text&gt;</summary>
  <status>Open</status>
  <description><![CDATA[Contains a literal </item> string that must not end the match early.]]></description>
  <parent>PROJ-100</parent>
  <subtasks><subtask id="1">PROJ-124</subtask><subtask id="2">PROJ-125</subtask></subtasks>
</item></channel></rss>
XML
close $fh;

my $result = Tira::CLI::Records::import_jira(
    $tira, { project => $root, ref => $target->{ref}, author => 'alice', files => [$xml] }, {},
);
ok( $result->{ok}, 'importing a well-formed export succeeds' );
is( $result->{jira_key}, 'PROJ-123', 'the parsed Jira key comes back in the result' );

my $after = $tira->record_show( project => $root, type => 'ticket', ref => $target->{ref} );
my $key_details_text = join( "\n", @{ $after->{key_details} // [] } );
like( $key_details_text, qr/PROJ-123/,
    'the Jira key is recorded as a key-detail on the Tira ticket' );
like( $key_details_text, qr/Summary & more <text>/,
    'XML entities are decoded rather than stored literally' );
unlike( $key_details_text, qr/CDATA|<\/item>/,
    'the CDATA-wrapped description text (with its embedded literal </item>) never reaches the key-detail - only key+summary are stored' );

# --- a malformed file refuses (dies), not a silent {ok=>0} success --------

my $bad = File::Spec->catfile( $tmp, 'bad.xml' );
open my $bfh, '>', $bad or die $!;
print {$bfh} "not xml at all, just text\n";
close $bfh;

my $before_ticket = $tira->record_show( project => $root, type => 'ticket', ref => $target->{ref} );
eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, author => 'alice', files => [$bad] }, {},
    );
};
like( $@, qr/no <key> tag found/, 'a malformed file dies naming what was expected, not a silent ok=>0' );

my $after_bad = $tira->record_show( project => $root, type => 'ticket', ref => $target->{ref} );
is_deeply( $after_bad->{key_details}, $before_ticket->{key_details},
    'the ticket is unchanged after a refused import' );

# --- a multi-issue export refuses by name, rather than silently picking ---
# --- the first issue and importing the wrong one ---------------------------

my $multi = File::Spec->catfile( $tmp, 'multi.xml' );
open my $mfh, '>', $multi or die $!;
print {$mfh} <<'XML';
<rss version="0.92"><channel>
<item><key id="1">PROJ-201</key><summary>First</summary></item>
<item><key id="2">PROJ-202</key><summary>Second</summary></item>
</channel></rss>
XML
close $mfh;

eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, author => 'alice', files => [$multi] }, {},
    );
};
like( $@, qr/PROJ-201.*PROJ-202|exactly one issue/s,
    'an export naming more than one issue refuses by name rather than silently importing the first' );

# --- no silent 'claude' author default - an unknown/unset author refuses --
# --- through the same path every other command already uses --------------

eval {
    Tira::CLI::Records::import_jira(
        $tira, { project => $root, ref => $target->{ref}, files => [$xml] }, {},
    );
};
ok( $@, 'with no --author supplied, the call refuses rather than silently attributing the import to a guessed person' );

# --- the real installed executable, not only the engine sub ---------------

my $exe = File::Spec->catfile( qw(skills import cli jira) );
ok( -x $exe, 'the real tira.import.jira executable exists and is runnable' );

my $out  = `$^X -I lib $exe --ref @{[$target->{ref}]} --file $bad --project $root --author alice 2>&1`;
my $exit = $? >> 8;
isnt( $exit, 0, 'running the real executable against a malformed file exits non-zero' );

done_testing();

__END__

=head1 NAME

1160-a-key-that-crossed-boards.t - importing a Jira issue XML export onto a Tira ticket

=head1 DESCRIPTION

TKT-1153. C<Tira::CLI::Records::import_jira> parses a Jira issue-XML export
(the standard "Export XML" action's RSS 0.92 shape) and records the Jira
issue key and summary as a key-detail on the target Tira ticket, via the
existing C<comment_add --key-detail> mechanism. XML entities and CDATA are
decoded rather than stored literally; an export naming more than one issue,
a file with no recognizable C<E<lt>keyE<gt>> tag, or a call with no author
all refuse (die) cleanly rather than succeeding silently or crashing with an
internal parser error.

=cut
