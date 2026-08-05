#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir tempfile);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-05T02:00:00+0100' } );
my $root = File::Spec->catdir( $tmp, 'edges' );
$tira->create_project( name => 'Edges', dir => $root );
$tira->person_add( project => $root, id => 'ada', name => 'Ada' );

my $sow1 = $tira->create_record( project => $root, type => 'sow', title => 'SOW 1' );
my $sow2 = $tira->create_record( project => $root, type => 'sow', title => 'SOW 2' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Epic' );
my $ticket1 = $tira->create_record( project => $root, type => 'ticket', title => 'Ticket 1', assignees => ['ada'] );
my $ticket2 = $tira->create_record( project => $root, type => 'ticket', title => 'Ticket 2' );

is( scalar @{ $tira->record_list( project => $root, type => 'ticket', assignee => 'ada' ) }, 1, 'assignee filter selects matching record' );
eval { $tira->person_remove( project => $root, id => 'ada' ) };
like( $@, qr/still assigned/, 'assigned person cannot be removed' );

$tira->link_type_add( project => $root, outward => 'implements', inward => 'is-implemented-by' );
$tira->link_add( project => $root, from => $ticket1->{ref}, type => 'implements', to => $ticket2->{ref} );
eval { $tira->link_type_remove( project => $root, outward => 'implements' ) };
like( $@, qr/still in use/, 'used custom link type cannot be removed' );

eval { $tira->hierarchy_link( project => $root, parent => $sow1->{ref}, child => $ticket1->{ref} ) };
like( $@, qr/Hierarchy requires/, 'invalid cross-level hierarchy is rejected' );
$tira->hierarchy_link( project => $root, parent => $sow1->{ref}, child => $epic->{ref} );
$tira->hierarchy_link( project => $root, parent => $sow1->{ref}, child => $epic->{ref} );
$tira->hierarchy_link( project => $root, parent => $sow2->{ref}, child => $epic->{ref} );
is_deeply( $tira->record_show( project => $root, ref => $sow1->{ref} )->{linkage}{epic_refs}, [], 'reparenting clears old reciprocal link' );
is( $tira->hierarchy_show( project => $root, ref => $sow2->{ref} )->{children}[0]{ref}, $epic->{ref}, 'nonrecursive hierarchy lists immediate child' );

my $ticket3 = $tira->create_record( project => $root, type => 'ticket', title => 'Ticket 3' );
$tira->subitem_link( project => $root, parent => $ticket1->{ref}, child => $ticket3->{ref} );
$tira->subitem_link( project => $root, parent => $ticket1->{ref}, child => $ticket3->{ref} );
$tira->link_add( project => $root, from => $ticket1->{ref}, type => 'blocks', to => $ticket3->{ref} );
$tira->link_add( project => $root, from => $ticket1->{ref}, type => 'blocks', to => $ticket3->{ref} );
is( scalar @{ $tira->link_list( project => $root, ref => $ticket1->{ref}, type => 'blocks' ) }, 1, 'typed link add is idempotent' );
$tira->assignment_add( project => $root, ref => $ticket1->{ref}, person => 'ada' );
is_deeply( $tira->assignment_list( project => $root, ref => $ticket1->{ref} ), ['ada'], 'assignment add is idempotent' );

$tira->comment_add( project => $root, ref => $ticket1->{ref}, author => 'ada', text => 'one' );
is( $tira->comment_add( project => $root, ref => $ticket1->{ref}, author => 'ada', text => 'two' )->{id}, 'CMT-002', 'comment IDs increase' );

my $missing_dir = File::Spec->catdir( $root, '.tira', 'sow', 'discard' );
rmdir $missing_dir or die "Cannot remove empty test discard: $!";
my $rogue = File::Spec->catdir( $root, '.tira', 'sow', 'rogue' );
mkdir $rogue or die "Cannot create test drift: $!";
my $validation = $tira->project_validate( project => $root );
is( scalar @{ $validation->{issues} }, 2, 'validation reports missing and unconfigured directories' );
$tira->column_sync( project => $root, type => 'sow', apply => 1 );
ok( -d $missing_dir, 'sync recreates a protected missing directory' );

my ( $fh1, $file1 ) = tempfile( DIR => $tmp, SUFFIX => '.dat' );
print {$fh1} 'same-content';
close $fh1;
my ( $fh2, $file2 ) = tempfile( DIR => $tmp, SUFFIX => '.bin' );
print {$fh2} 'same-content';
close $fh2;
my $attachment = $tira->attachment_add( project => $root, ref => $ticket1->{ref}, file => $file1 );
is( $tira->attachment_get( project => $root, sha => $attachment->{sha} )->{content}, 'same-content', 'attachment lookup can infer one extension' );
$tira->attachment_add( project => $root, ref => $ticket2->{ref}, file => $file2 );
eval { $tira->attachment_get( project => $root, sha => $attachment->{sha} ) };
like( $@, qr/multiple extensions/, 'ambiguous attachment extension is rejected' );
eval { $tira->attachment_get( project => $root, sha => ( '0' x 64 ), extension => 'dat' ) };
like( $@, qr/not found/, 'unknown attachment content is rejected' );
eval { $tira->link_add( project => $root, from => $ticket1->{ref}, type => 'unknown', to => $ticket2->{ref} ) };
like( $@, qr/Unknown link type/, 'unknown typed relationship is rejected' );

{
    package Local::PairFailure;
    our @ISA = ('Tira');
    sub fail_second { $_[0]{pair_writes} = 0 }
    sub _write_json {
        my ( $self, @args ) = @_;
        die "Injected pair failure\n" if exists $self->{pair_writes} && ++$self->{pair_writes} == 2;
        return $self->SUPER::_write_json(@args);
    }
}
my $pair_failure = Local::PairFailure->new;
$pair_failure->fail_second;
eval { $pair_failure->link_add( project => $root, from => $ticket1->{ref}, type => 'relates-to', to => $ticket2->{ref} ) };
like( $@, qr/Injected pair failure/, 'multi-record write failure is returned' );
is_deeply( $tira->link_list( project => $root, ref => $ticket1->{ref}, type => 'relates-to' ), [], 'first record is rolled back after second write fails' );
is_deeply( $tira->link_list( project => $root, ref => $ticket2->{ref}, type => 'relates-to' ), [], 'second record remains unchanged after rollback' );

{
    package Local::YamlFailure;
    our @ISA = ('Tira');
    sub fail_yaml { $_[0]{fail_yaml} = 1 }
    sub _write_yaml {
        my ( $self, @args ) = @_;
        die "Injected column config failure\n" if delete $self->{fail_yaml};
        return $self->SUPER::_write_yaml(@args);
    }
}
my $yaml_failure = Local::YamlFailure->new;
$yaml_failure->fail_yaml;
eval { $yaml_failure->column_add( project => $root, type => 'ticket', name => 'failed-add' ) };
like( $@, qr/Injected column/, 'column add config failure is returned' );
ok( !-d File::Spec->catdir( $root, '.tira', 'ticket', 'failed-add' ), 'failed column add removes its directory' );
$yaml_failure->column_add( project => $root, type => 'ticket', name => 'rollback' );
$yaml_failure->record_move( project => $root, ref => $ticket2->{ref}, column => 'rollback' );
$yaml_failure->fail_yaml;
eval { $yaml_failure->column_remove( project => $root, type => 'ticket', name => 'rollback' ) };
like( $@, qr/Injected column/, 'column remove config failure is returned' );
is( $tira->record_show( project => $root, ref => $ticket2->{ref} )->{column}, 'rollback', 'failed column removal restores moved records' );
$yaml_failure->fail_yaml;
eval { $yaml_failure->column_rename( project => $root, type => 'ticket', name => 'rollback', new_name => 'renamed' ) };
like( $@, qr/Injected column/, 'column rename config failure is returned' );
ok( -d File::Spec->catdir( $root, '.tira', 'ticket', 'rollback' ), 'failed rename restores original directory' );

my ( $out, $err ) = ( '', '' );
my $stdin_text = '["stdin scenario"]';
open my $stdout, '>', \$out or die $!;
open my $stderr, '>', \$err or die $!;
open my $stdin, '<', \$stdin_text or die $!;
{
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    local *STDIN = $stdin;
    is(
        Tira::CLI->run(
            command => 'record.update', type => 'ticket',
            argv => [ '--ref', $ticket2->{ref}, '--set-bdd', '-', '--project', $root, '-o', 'json' ],
        ),
        0,
        'JSON-array replacement accepts stdin',
    );
}
like( $out, qr/stdin scenario/, 'stdin replacement reaches record output' );

( $out, $err ) = ( '', '' );
open $stdout, '>', \$out or die $!;
open $stderr, '>', \$err or die $!;
{
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    is(
        Tira::CLI->run(
            command => 'record.update', type => 'ticket',
            argv => [ '--ref', $ticket2->{ref}, '--bdd', 'append', '--set-bdd', $file1, '--project', $root ],
        ),
        2,
        'append and replacement options conflict',
    );
}
like( $err, qr/Cannot combine/, 'replacement conflict is structured' );

done_testing;

__END__

=head1 NAME

08-edge-contracts.t - Tira idempotency, drift, and failure contracts

=head1 DESCRIPTION

Proves guarded and idempotent branches required by the full command contract.

=cut
