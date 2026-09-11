#!/usr/bin/env perl
# TKT-1046. The per-item attachment/ref subverb block (TKT-508: --attach on
# add, tasklist.task.attach.add/discard, tasklist.task.ref.link/unlink) is
# independent of the tasklist-reads-without-a-card concern
# t/390-a-list-that-does-not-need-a-ticket.t exists to prove, and was lifted
# out of that file - 566 lines before this split - as its own concern, the
# same reason TKT-1041/1042/1043/1044/1045 lifted five other files' own
# separable concerns the same week.
#
# The shared preamble ($tmp/$tira/$root and the cli() dispatcher helper) is
# duplicated from t/390 rather than shared, since each .t file is its own
# process and there is no shared-setup helper for this fixture yet.

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
my $tira = Tira->new( clock => sub { '2026-08-24T20:00:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Tasked', dir => $root, members => ['claude'],
    columns => [ 'backlog, implement, done' ],
    sow_prefix => 'TAS', epic_prefix => 'TAE', ticket_prefix => 'TAT',
);

sub cli {
    my ( $command, @argv ) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>:raw', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local $ENV{TIRA_HOME}   = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    my $status = Tira::CLI->run( command => $command, argv => \@argv );
    return ( $status, $out, $err );
}

# --- TKT-508: --attach on add, and the per-item attach/ref sub-verbs -------
{
    my $file_a = File::Spec->catfile( $tmp, 'a.txt' );
    my $file_b = File::Spec->catfile( $tmp, 'b.txt' );
    open my $fa, '>', $file_a or die $!; print {$fa} 'A'; close $fa;
    open my $fb, '>', $file_b or die $!; print {$fb} 'B'; close $fb;

    my $attached = $tira->tasklist_add(
        project => $root, text => 'has files', session => 'attach', attach => [ $file_a, $file_b ],
    );
    is( scalar @{ $attached->{attachments} }, 2, 'tasklist.add --attach stores both files' );

    my $file_c = File::Spec->catfile( $tmp, 'c.txt' );
    open my $fc, '>', $file_c or die $!; print {$fc} 'C'; close $fc;
    my $more = $tira->tasklist_task_attach_add(
        project => $root, id => $attached->{id}, files => [$file_c], session => 'attach',
    );
    is( scalar @{ $more->{attachments} }, 3, 'task.attach.add adds a third attachment to an existing item' );

    my $fewer = $tira->tasklist_task_attach_discard(
        project => $root, id => $attached->{id}, files => ['a.txt'], session => 'attach',
    );
    is( scalar @{ $fewer->{attachments} }, 2, 'task.attach.discard removes one by name' );
    ok( !( grep { $_->{original_filename} eq 'a.txt' } @{ $fewer->{attachments} } ),
        'and a.txt specifically is gone' );

    my $card_x = $tira->create_record( project => $root, type => 'ticket', title => 'X' );
    my $card_y = $tira->create_record( project => $root, type => 'ticket', title => 'Y' );
    my $linked = $tira->tasklist_task_ref_link(
        project => $root, id => $attached->{id}, refs => [ $card_x->{ref}, $card_y->{ref} ], session => 'attach',
    );
    is( scalar @{ $linked->{refs} }, 2, 'task.ref.link adds both refs' );

    my $unlinked = $tira->tasklist_task_ref_unlink(
        project => $root, id => $attached->{id}, refs => [ $card_x->{ref} ], session => 'attach',
    );
    is_deeply( $unlinked->{refs}, [ $card_y->{ref} ], 'task.ref.unlink removes just the one named' );

    eval { $tira->tasklist_task_attach_add( project => $root, id => 'TSK-999', files => [$file_a] ) };
    like( $@, qr/TSK-999/, 'attach.add on an id that does not exist is refused, naming it' );

    my ( $status, $out ) = cli(
        'tasklist.task.ref.link', '--id', $attached->{id}, '--ref', $card_x->{ref}, '--session', 'attach', '-o', 'json',
    );
    is( $status, 0, 'tasklist.task.ref.link dispatches' );
    ok( ( grep { $_ eq $card_x->{ref} } @{ decode_json($out)->{refs} } ), 'and adds the ref via the CLI too' );

    # Found adversarially: a pre-existing global guard (TKT-338/389) collapsed
    # --file down to a single value for every command except attachment.add,
    # silently breaking multiple --file on these two new commands even though
    # the engine methods themselves accepted an arrayref fine. Only a CLI-level
    # call with two --file flags exercises the option-parsing layer that bug
    # lived in - the direct-method tests above never would.
    my $file_d = File::Spec->catfile( $tmp, 'd.txt' );
    open my $fd, '>', $file_d or die $!; print {$fd} 'D'; close $fd;
    ( $status, $out ) = cli(
        'tasklist.task.attach.add', '--id', $attached->{id}, '--file', $file_c, '--file', $file_d,
        '--session', 'attach', '-o', 'json',
    );
    is( $status, 0, 'tasklist.task.attach.add with two --file flags dispatches' );
    is( scalar @{ decode_json($out)->{attachments} }, 3,
        'and both files land (c.txt already there from earlier, d.txt newly added)' );
}

done_testing();

__END__

=head1 NAME

t/1046-a-file-that-followed-an-item.t - the per-item attachment/ref subverbs

=head1 DESCRIPTION

Split out of t/390-a-list-that-does-not-need-a-ticket.t (TKT-1046), the
same week TKT-1041/1042/1043/1044/1045 lifted five other files' own
separable concerns: --attach on tasklist.add, tasklist.task.attach.add,
tasklist.task.attach.discard, tasklist.task.ref.link and
tasklist.task.ref.unlink, plus their CLI dispatch, are a self-contained
concern independent of the tasklist-reads-without-a-card contract the rest
of t/390 proves.

=head1 SEE ALSO

L<t/390-a-list-that-does-not-need-a-ticket.t>

=cut

