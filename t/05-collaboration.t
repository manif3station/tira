#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = 0;
my $tira = Tira->new( clock => sub { sprintf '2026-08-05T01:00:%02d+0100', $tick++ } );
my $root = File::Spec->catdir( $tmp, 'collaboration' );
$tira->create_project( name => 'Collaboration', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );
$tira->person_add( project => $root, id => 'grace', name => 'Grace' );

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'SOW' );
my $epic = $tira->create_record(
    project => $root, type => 'epic', title => 'Epic',
    description => 'Full epic description', assignee => 'ada', priority => 3,
);
my $ticket1 = $tira->create_record( project => $root, type => 'ticket', title => 'Ticket 1' );
my $ticket2 = $tira->create_record( project => $root, type => 'ticket', title => 'Ticket 2' );

$tira->hierarchy_link( project => $root, parent => $sow->{ref}, child => $epic->{ref} );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $ticket1->{ref} );
is( $tira->record_show( project => $root, ref => $epic->{ref} )->{linkage}{sow_ref}, $sow->{ref}, 'epic uplink is recorded' );
is_deeply( $tira->record_show( project => $root, ref => $sow->{ref} )->{linkage}{epic_refs}, [ $epic->{ref} ], 'SOW downlink is recorded' );
my $tree = $tira->hierarchy_show( project => $root, ref => $sow->{ref}, recursive => 1 );
is( $tree->{children}[0]{children}[0]{ref}, $ticket1->{ref}, 'recursive hierarchy reaches ticket' );
is( $tree->{children}[0]{description}, 'Full epic description', 'recursive hierarchy retains child record description' );
is( $tree->{children}[0]{assignee}, 'ada', 'recursive hierarchy retains child record assignee' );
is( $tree->{children}[0]{priority}, 3, 'recursive hierarchy retains child record priority' );
is_deeply( $tree->{children}[0]{linkage}{ticket_refs}, [ $ticket1->{ref} ],
    'recursive hierarchy retains child record linkage' );

$tira->subitem_link( project => $root, parent => $ticket1->{ref}, child => $ticket2->{ref} );
is( $tira->record_show( project => $root, ref => $ticket2->{ref} )->{linkage}{parent_ticket_ref}, $ticket1->{ref}, 'subitem uplink recorded' );
eval { $tira->subitem_link( project => $root, parent => $ticket2->{ref}, child => $ticket1->{ref} ) };
like( $@, qr/cycle/, 'subitem cycle is rejected' );
$tira->subitem_unlink( project => $root, parent => $ticket1->{ref}, child => $ticket2->{ref} );

$tira->link_add( project => $root, from => $ticket1->{ref}, type => 'blocks', to => $ticket2->{ref} );
is( $tira->link_list( project => $root, ref => $ticket2->{ref}, type => 'is-blocked-by' )->[0]{ref}, $ticket1->{ref}, 'reciprocal typed link recorded' );
$tira->link_remove( project => $root, from => $ticket1->{ref}, type => 'blocks', to => $ticket2->{ref} );
is_deeply( $tira->link_list( project => $root, ref => $ticket1->{ref} ), [], 'typed link can be removed' );

$tira->assignment_add( project => $root, ref => $ticket1->{ref}, person => 'ada' );
$tira->assignment_set( project => $root, ref => $ticket1->{ref}, people => ['grace'] );
is_deeply( $tira->assignment_list( project => $root, ref => $ticket1->{ref} ), ['grace'], 'singular assignee can be replaced' );
$tira->assignment_remove( project => $root, ref => $ticket1->{ref}, person => 'grace' );

my $comment = $tira->comment_add( project => $root, ref => $ticket1->{ref}, author => 'ada', text => 'Initial', format => 'markdown' );
is( $comment->{id}, 'CMT-001', 'comment gets stable ID' );
$comment = $tira->comment_update( project => $root, ref => $ticket1->{ref}, comment => $comment->{id}, text => 'Corrected' );
is( $comment->{body}, 'Corrected', 'comment can be updated' );

my ( $fh, $file ) = tempfile( DIR => $tmp, SUFFIX => '.bin' );
binmode $fh;
print {$fh} "binary\0content";
close $fh;
my $attachment = $tira->attachment_add( project => $root, ref => $ticket1->{ref}, file => $file );
like( $attachment->{sha}, qr/^[0-9a-f]{64}$/, 'attachment uses SHA-256 ID' );
is( $tira->attachment_get( project => $root, sha => $attachment->{sha}, extension => 'bin' )->{content}, "binary\0content", 'attachment raw content can be retrieved' );
$tira->comment_attach( project => $root, ref => $ticket1->{ref}, comment => 'CMT-001', file => $file );
is( scalar @{ $tira->comment_list( project => $root, ref => $ticket1->{ref} )->[0]{attachments} }, 1, 'comment has its own attachment refs' );

my $clone = $tira->record_clone( project => $root, ref => $ticket1->{ref}, title => 'Clone' );
is( scalar @{ $clone->{attachments} }, 1, 'clone preserves record attachment refs' );
is( $tira->link_list( project => $root, ref => $clone->{ref}, type => 'is-cloned-by' )->[0]{ref}, $ticket1->{ref}, 'clone link is reciprocal' );

my $evidence = $tira->evidence_add( project => $root, ref => $ticket1->{ref}, summary => 'CI', uri => 'https://example.test/run', author => 'ada' );
is( $evidence->{summary}, 'CI', 'evidence can be appended' );
my $gate = $tira->gate_add( project => $root, ref => $ticket1->{ref}, gate => 'Security', result => 'pass', details => 'Clean', author => 'ada' );
is( $gate->{result}, 'pass', 'gate result can be appended' );

is( $tira->search( project => $root, text => 'ticket', type => 'ticket' )->{count}, 2, 'search scans matching records' );
my $dashboard = $tira->dashboard( project => $root, type => 'all' );
ok( exists $dashboard->{ticket}{backlog}, 'dashboard groups records by board and column' );

my $removed = $tira->attachment_remove( project => $root, sha => $attachment->{sha}, extension => 'bin' );
ok( $removed->{deleted_at}, 'attachment removal records timestamp' );
my $deleted = $tira->attachment_get( project => $root, sha => $attachment->{sha}, extension => 'bin' );
is( $deleted->{deleted}, 1, 'deleted attachment returns marker state' );
like( $deleted->{content}, qr/^Deleted at /, 'deleted marker contains timestamp' );
my $restored = $tira->attachment_add( project => $root, ref => $ticket2->{ref}, file => $file );
is( $restored->{sha}, $attachment->{sha}, 'identical content restores the same object' );

$tira->hierarchy_unlink( project => $root, parent => $epic->{ref}, child => $ticket1->{ref} );
ok( !defined $tira->record_show( project => $root, ref => $ticket1->{ref} )->{linkage}{epic_ref}, 'hierarchy can be unlinked' );

done_testing;

__END__

=head1 NAME

05-collaboration.t - Tira links, collaboration, attachment, and reporting behavior

=head1 DESCRIPTION

Exercises hierarchy, subitems, typed links, assignment, comments, attachments,
cloning, evidence, gates, search, and dashboard behavior for DD-389.

=cut
