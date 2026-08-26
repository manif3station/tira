#!/usr/bin/env perl
# TKT-516: the Task List section's own browser_providers closures, exercised
# directly - the same shape t/378 already uses for the Policies dialog's own
# four. The browser (Playwright) tests exercise these too, but only through
# a real server process outside Devel::Cover's reach, so nothing here is
# redundant with them: this is what actually keeps lib/Tira/CLI.pm's new
# closures at 100% statement+subroutine coverage.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-25T11:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Stuck', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'STS', epic_prefix => 'STE', ticket_prefix => 'STT',
);

my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
for my $name (
    qw(tasklist tasklist_add tasklist_update tasklist_next tasklist_shift tasklist_pop
       tasklist_unshift tasklist_slice tasklist_remove tasklist_import tasklist_prune
       tasklist_task_attach_add tasklist_task_attach_discard tasklist_task_ref_link tasklist_task_ref_unlink)
) {
    ok( exists $providers{$name}, "browser_providers exposes a $name closure" );
}

# --- list starts empty, add populates it ------------------------------------
is_deeply( decode_json( $providers{tasklist}->( {} ) ), [], 'a fresh project has no tasks' );

eval { $providers{tasklist_add}->( {} ) };
like( $@, qr/text is required/i, 'tasklist_add refuses an empty payload, naming why' );

my $added = decode_json( $providers{tasklist_add}->( { text => 'Write the report' } ) );
is( $added->{status}, 0, 'a new task starts pending (0)' );
my $listed = decode_json( $providers{tasklist}->( {} ) );
is( scalar @{$listed}, 1, 'the list now shows the one task' );

# --- update ------------------------------------------------------------------
eval { $providers{tasklist_update}->( {} ) };
like( $@, qr/task id is required/i, 'tasklist_update refuses without an id' );

my $updated = decode_json( $providers{tasklist_update}->( { id => $added->{id}, status => 1 } ) );
is( $updated->{status}, 1, 'update moves it to working (1)' );

# TKT-523: the browser dashboard's Task List section needs to edit a task's
# own text in place, not just its status - update must accept --text too.
my $retexted = decode_json( $providers{tasklist_update}->( { id => $added->{id}, text => 'Write the actual report' } ) );
is( $retexted->{text}, 'Write the actual report', 'update also accepts a new text' );
is( $retexted->{status}, 1, 'and leaves status alone when text-only' );
my $status_only = decode_json( $providers{tasklist_update}->( { id => $added->{id}, status => 0 } ) );
is( $status_only->{text}, 'Write the actual report', 'and a status-only update leaves text alone' );

# --- next / shift / pop -------------------------------------------------------
$providers{tasklist_update}->( { id => $added->{id}, status => 0 } );
my $peeked = decode_json( $providers{tasklist_next}->( {} ) );
is( $peeked->{id}, $added->{id}, 'next peeks the one pending item' );
is( scalar @{ decode_json( $providers{tasklist}->( {} ) ) }, 1, 'and does not remove it' );

my $second = decode_json( $providers{tasklist_add}->( { text => 'Ship it' } ) );
my $shifted = decode_json( $providers{tasklist_shift}->( {} ) );
is( $shifted->{id}, $added->{id}, 'shift returns the front item' );
is( scalar @{ decode_json( $providers{tasklist}->( {} ) ) }, 1, 'and removes it' );

my $popped = decode_json( $providers{tasklist_pop}->( {} ) );
is( $popped->{id}, $second->{id}, 'pop returns the back item' );
is( scalar @{ decode_json( $providers{tasklist}->( {} ) ) }, 0, 'the list is empty again' );

# --- unshift / slice -----------------------------------------------------------
eval { $providers{tasklist_unshift}->( {} ) };
like( $@, qr/text is required/i, 'tasklist_unshift refuses an empty payload' );
my $front = decode_json( $providers{tasklist_unshift}->( { text => 'Front of the queue' } ) );
is( $front->{text}, 'Front of the queue', 'unshift creates the item' );

eval { $providers{tasklist_slice}->( { text => 'x' } ) };
like( $@, qr/position is required/i, 'tasklist_slice refuses without a position' );
my $sliced = decode_json( $providers{tasklist_slice}->( { text => 'Middle', position => 1 } ) );
is( $sliced->{text}, 'Middle', 'slice creates the item' );

# --- remove ----------------------------------------------------------------
eval { $providers{tasklist_remove}->( {} ) };
like( $@, qr/task id is required/i, 'tasklist_remove refuses without an id' );
my $removed = decode_json( $providers{tasklist_remove}->( { id => $sliced->{id} } ) );
is( $removed->{id}, $sliced->{id}, 'remove returns the removed item' );

# --- import ------------------------------------------------------------------
eval { $providers{tasklist_import}->( {} ) };
like( $@, qr/card ref is required/i, 'tasklist_import refuses without a ref' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Has work' );
$tira->required_item_add(
    project => $root, ref => $card->{ref}, item => 'Do the thing', status => 'pending',
    column => $card->{column}, author => 'claude',
);
my $imported = decode_json( $providers{tasklist_import}->( { ref => $card->{ref} } ) );
is( scalar @{$imported}, 1, 'import brings in the one pending required-action' );

# --- prune ---------------------------------------------------------------------
$providers{tasklist_update}->( { id => $front->{id}, status => 2 } );
my $pruned = decode_json( $providers{tasklist_prune}->( {} ) );
ok( ( grep { $_->{id} eq $front->{id} } @{$pruned} ), 'prune reports the done item it removed' );
ok( !( grep { $_->{id} eq $front->{id} } @{ decode_json( $providers{tasklist}->( {} ) ) } ),
    'and the list no longer has it' );

# --- the four task sub-verbs --------------------------------------------------
my $remaining = decode_json( $providers{tasklist}->( {} ) )->[0];

eval { $providers{tasklist_task_attach_add}->( {} ) };
like( $@, qr/requires id, filename, and content/i, 'attach_add refuses an incomplete payload' );
require MIME::Base64;
my $attached = decode_json( $providers{tasklist_task_attach_add}->( {
    id => $remaining->{id}, filename => 'note.txt', content_base64 => MIME::Base64::encode_base64('hello'),
} ) );
is( scalar @{ $attached->{attachments} }, 1, 'attach_add stores one attachment' );

eval { $providers{tasklist_task_attach_discard}->( { id => $remaining->{id} } ) };
like( $@, qr/filename is required/i, 'attach_discard refuses without a filename' );
my $discarded = decode_json(
    $providers{tasklist_task_attach_discard}->( { id => $remaining->{id}, filename => 'note.txt' } ) );
is( scalar @{ $discarded->{attachments} }, 0, 'attach_discard removes it' );

eval { $providers{tasklist_task_ref_link}->( { id => $remaining->{id} } ) };
like( $@, qr/ref is required/i, 'ref_link refuses without a ref' );
my $linked = decode_json( $providers{tasklist_task_ref_link}->( { id => $remaining->{id}, ref => $card->{ref} } ) );
is_deeply( $linked->{refs}, [ $card->{ref} ], 'ref_link adds the ref' );

eval { $providers{tasklist_task_ref_unlink}->( { id => $remaining->{id} } ) };
like( $@, qr/ref is required/i, 'ref_unlink refuses without a ref' );
my $unlinked = decode_json(
    $providers{tasklist_task_ref_unlink}->( { id => $remaining->{id}, ref => $card->{ref} } ) );
is_deeply( $unlinked->{refs}, [], 'ref_unlink removes the ref' );

# --- TKT-540: session-switched mutations must not lose the session ----------
# The dashboard's tlSession input lets a viewer switch to another session's
# view (GET /tasklist?session=...), and tlPost sends that same session on
# every POST, including these six. Since TKT-538 made a session mismatch a
# hard refusal, any of the six that silently dropped the payload's session
# would now fail exactly like a nonexistent id, even though the browser is
# legitimately looking at that session's own item.
my $scoped = decode_json( $providers{tasklist_add}->( { text => 'Agent A work', session => 'agent-a' } ) );

for my $case (
    [ tasklist_update              => { id => $scoped->{id}, text => 'Agent A work, revised' } ],
    [ tasklist_task_ref_link       => { id => $scoped->{id}, ref  => $card->{ref} } ],
    [ tasklist_task_ref_unlink     => { id => $scoped->{id}, ref  => $card->{ref} } ],
    [ tasklist_task_attach_add     => { id => $scoped->{id}, filename => 'a.txt',
                                         content_base64 => MIME::Base64::encode_base64('hi') } ],
    [ tasklist_task_attach_discard => { id => $scoped->{id}, filename => 'a.txt' } ],
) {
    my ( $name, $payload ) = @{$case};
    eval { $providers{$name}->( {%$payload} ) };
    like( $@, qr/No task/, "$name with no session still refuses agent-a's item (TKT-538 intact)" );
    my $result = eval { $providers{$name}->( { %$payload, session => 'agent-a' } ) };
    ok( !$@, "$name with session=>agent-a succeeds" ) or diag($@);
}

eval { $providers{tasklist_remove}->( { id => $scoped->{id} } ) };
like( $@, qr/No task/, 'tasklist_remove with no session still refuses agent-a\'s item (TKT-538 intact)' );
my $removed_scoped = decode_json( $providers{tasklist_remove}->( { id => $scoped->{id}, session => 'agent-a' } ) );
is( $removed_scoped->{id}, $scoped->{id}, 'tasklist_remove with session=>agent-a succeeds' );

done_testing;

__END__

=head1 NAME

391-a-sticky-note-that-talks-to-the-server.t - the Task List section's browser_providers closures

=head1 DESCRIPTION

TKT-516: exercises every provider closure the dashboard's Task List section
calls through - add/list/update/next/shift/pop/unshift/slice/remove/import/
prune, plus the four per-item attach/ref sub-verbs - directly, the way
t/378 already covers the Policies dialog's own four. The Playwright test
(t/playwright/tasklist-section.js) drives the real rendered section through
a live server; this is what keeps the closures themselves inside
Devel::Cover's reach.

=cut
