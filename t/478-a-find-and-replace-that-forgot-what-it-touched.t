#!/usr/bin/env perl
# TKT-690. replace_records lists comments and checklist among its mutable
# fields, and _replace_value recurses into every array and hash it meets,
# rewriting every scalar leaf. Those two fields are not prose - their
# leaves include identity (id), status, timestamps and recorded evidence
# (a checklist item's proof array). A pattern aimed at ordinary text could
# silently rewrite a checklist status every gate reads, corrupt an id, or
# turn a valid timestamp into one no validator would ever accept on the
# way in.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-01T16:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Guarded', dir => $root, members => ['ada'],
    columns => ['backlog, doing'],
    sow_prefix => 'GRS', epic_prefix => 'GRE', ticket_prefix => 'GRT',
);
my $ticket = $tira->create_record( project => $root, author => 'ada', type => 'ticket', title => 'Some work' );

# --- a checklist item's status, id and timestamps survive a text replace ----

my $item = $tira->checklist_add( project => $root, ref => $ticket->{ref}, item => 'run it done', status => 'pending', author => 'ada' );
$tira->checklist_update(
    project => $root, ref => $ticket->{ref}, id => $item->{id}, status => 'done', author => 'ada',
    command => ['prove -lr t'], proof => ['All tests successful. done.'],
);
my $before = $tira->record_show( project => $root, ref => $ticket->{ref} );
my ($before_item) = grep { $_->{id} eq $item->{id} } @{ $before->{checklist} };

$tira->replace_records( project => $root, pattern => 'done', with => 'FINISHED', field => 'checklist' );

my $after = $tira->record_show( project => $root, ref => $ticket->{ref} );
my ($after_item) = grep { $_->{id} eq $item->{id} } @{ $after->{checklist} };

is( $after_item->{status}, $before_item->{status}, 'a checklist item\'s status is not rewritten by a text replace' );
is( $after_item->{id}, $before_item->{id}, 'a checklist item\'s id is not rewritten' );
is( $after_item->{created_at}, $before_item->{created_at}, 'a checklist item\'s created_at is not rewritten' );
is( $after_item->{last_updated}, $before_item->{last_updated}, 'a checklist item\'s last_updated is not rewritten by the replace itself' );
is_deeply( $after_item->{proof}, $before_item->{proof}, 'recorded proof is not rewritten' );
like( $after_item->{item}, qr/FINISHED/, 'the item TEXT is still replaced - that is the feature' );

# --- a digit pattern does not corrupt an id or a timestamp ------------------

my $item2 = $tira->checklist_add( project => $root, ref => $ticket->{ref}, item => 'step 1', status => 'pending', author => 'ada' );
$tira->replace_records( project => $root, pattern => '0', with => '9', field => 'checklist' );
my $reread = $tira->record_show( project => $root, ref => $ticket->{ref} );
my ($item2_after) = grep { $_->{id} eq $item2->{id} } @{ $reread->{checklist} };
is( $item2_after->{id}, $item2->{id}, 'a digit pattern does not corrupt the id' );
unlike( $item2_after->{created_at}, qr/9/, 'a digit pattern does not corrupt the timestamp' )
  if $item2->{created_at} !~ /9/;

# --- a comment's author and identity survive; the body still replaces ------

my $comment = $tira->comment_add( project => $root, ref => $ticket->{ref}, author => 'ada', text => 'ada said done' );
$tira->replace_records( project => $root, pattern => 'ada', with => 'grace', field => 'comments' );
my $reread2 = $tira->record_show( project => $root, ref => $ticket->{ref} );
my ($comment_after) = grep { $_->{id} eq $comment->{id} } @{ $reread2->{comments} };
is( $comment_after->{author}, 'ada', 'a comment author is not rewritten by a body-aimed replace' );
like( $comment_after->{body}, qr/grace/, 'the comment BODY is still replaced - that is the feature' );

# --- a pattern that would have hit a protected leaf is reported ------------

my $item3 = $tira->checklist_add( project => $root, ref => $ticket->{ref}, item => 'nothing matches here', status => 'pending', author => 'ada' );
my $report = $tira->replace_records( project => $root, pattern => 'pending', with => 'blocked', field => 'checklist' );
ok( defined $report->{protected_hits} && @{ $report->{protected_hits} } > 0,
    'a pattern matching a protected leaf (status "pending") is reported rather than silently skipped' );

done_testing;

__END__

=head1 NAME

t/478-a-find-and-replace-that-forgot-what-it-touched.t - tira.replace only
edits prose, never identity, status, timestamps or recorded evidence

=head1 DESCRIPTION

C<_replace_value> recursed into every array and hash a mutable field held
and rewrote every scalar leaf it found. C<comments> and C<checklist> are
structured, not prose - their leaves include C<id>, C<status>,
C<created_at>/C<last_updated>, and a checklist item's C<proof> array, none
of which a find-and-replace should ever touch. C<replace_records> now
restricts these two fields to their genuine prose leaves - a comment's
C<body> and a checklist item's C<item> text - and reports rather than
silently skips a pattern that would have matched a protected leaf. TKT-690.

=cut
