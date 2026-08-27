#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;
use YAML::XS ();

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-05T13:30:00Z' } );
my $root = File::Spec->catdir( $tmp, 'metadata' );
$tira->create_project( name => 'Metadata', dir => $root );

my $ada = $tira->person_add( project => $root, id => 'ada', name => 'Ada Lovelace' );
ok( $ada->{active}, 'new person is active' );
$tira->person_add( project => $root, id => 'grace', name => 'Grace Hopper' );

for my $type (qw(sow epic ticket)) {
    my $record = $tira->create_record( project => $root, type => $type, title => "Metadata $type" );
    is( $record->{assignee}, undef, "$type assignee defaults null" );
    is( $record->{reporter}, undef, "$type reporter defaults null" );
    is_deeply( $record->{labels}, [], "$type labels default empty" );
    is( $record->{due_date}, undef, "$type due date defaults null" );
    is( $record->{start_date}, undef, "$type start date defaults null" );
    is( $record->{priority}, undef, "$type priority defaults null" );
    is( $record->{fix_version}, undef, "$type fix version defaults null" );
    is_deeply( $record->{affects_versions}, [], "$type affected versions default empty" );
    is( $record->{parent}, undef, "$type parent defaults null" );
}

my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Fully described',
    assignee => 'ada', reporter => 'grace', labels => [ 'Security', 'security', 'API' ],
    due_date => '2026-09-01T17:00:00+01:00', start_date => '2026-08-06T09:00:00Z',
    sdlc_gate => 'Threat model approved', lifecycle => 'Delivery', priority => 5,
    fix_version => '3.0.0', affects_versions => [ '2.0.0', '2.1.0' ],
);
is( $ticket->{assignee}, 'ada', 'create stores one assignee ID' );
is( $ticket->{reporter}, 'grace', 'create stores one reporter ID' );
is_deeply( $ticket->{labels}, [ 'Security', 'API' ], 'labels deduplicate case-insensitively' );
is( $ticket->{priority}, 5, 'priority is stored as JSON number' );

$ticket = $tira->record_update( author => 'ada',
    project => $root, ref => $ticket->{ref}, labels => [ 'api', 'Backend' ],
    affects_versions => ['2.2.0'], lifecycle => 'Maintenance',
);
is_deeply( $ticket->{labels}, [ 'Security', 'API', 'Backend' ], 'update appends unique labels case-insensitively' );
is_deeply( $ticket->{affects_versions}, [ '2.0.0', '2.1.0', '2.2.0' ], 'update appends affected versions' );
$ticket = $tira->record_update( author => 'ada',
    project => $root, ref => $ticket->{ref}, labels_replace => ['Release'],
    affects_versions_replace => [], assignee => '', reporter => '', priority => '', fix_version => '',
);
is_deeply( $ticket->{labels}, ['Release'], 'replacement replaces labels' );
is_deeply( $ticket->{affects_versions}, [], 'replacement clears affected versions' );
is( $ticket->{assignee}, undef, 'empty assignee clears it' );
is( $ticket->{reporter}, undef, 'empty reporter clears it' );
is( $ticket->{priority}, undef, 'empty priority clears it' );
is( $ticket->{fix_version}, undef, 'empty fix version clears it' );

for my $case (
    [ priority => 0, qr/Priority/ ], [ priority => 6, qr/Priority/ ],
    [ due_date => '2026-09-01', qr/ISO 8601/ ],
    [ start_date => '2026-08-06T09:00:00', qr/ISO 8601/ ],
) {
    my ( $field, $value, $error ) = @{$case};
    eval { $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, $field => $value ) };
    like( $@, $error, "invalid $field is rejected" );
}

$tira->person_deactivate( project => $root, id => 'ada' );
ok( !$tira->person_list( project => $root )->[0]{active}, 'person can be deactivated' );
eval { $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, assignee => 'ada' ) };
like( $@, qr/inactive/, 'inactive person cannot receive a new assignment' );
$tira->person_activate( project => $root, id => 'ada' );
$ticket = $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, assignee => 'ada', reporter => 'grace' );
is( $ticket->{assignee}, 'ada', 'reactivated person can be assigned' );
eval { $tira->person_remove( project => $root, id => 'ada' ) };
like( $@, qr/historical reference/, 'historically referenced person cannot be removed' );

my $sow = $tira->create_record( project => $root, type => 'sow', title => 'SOW parent' );
my $epic = $tira->create_record( project => $root, type => 'epic', title => 'Epic parent' );
my $master = $tira->create_record( project => $root, type => 'ticket', title => 'Master ticket' );
my $child = $tira->create_record( project => $root, type => 'ticket', title => 'Child ticket' );
$tira->hierarchy_link( project => $root, parent => $sow->{ref}, child => $epic->{ref} );
is( $tira->record_show( project => $root, ref => $epic->{ref} )->{parent}, $sow->{ref}, 'epic parent is its SOW' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $master->{ref} );
is( $tira->record_show( project => $root, ref => $master->{ref} )->{parent}, $epic->{ref}, 'ticket parent is its epic' );
$tira->hierarchy_link( project => $root, parent => $epic->{ref}, child => $child->{ref} );
$tira->subitem_link( project => $root, parent => $master->{ref}, child => $child->{ref} );
is( $tira->record_show( project => $root, ref => $child->{ref} )->{parent}, $master->{ref}, 'same-type parent takes immediate-parent precedence' );
is( scalar @{ $tira->record_list( project => $root, type => 'ticket', parent => $master->{ref} ) }, 1, 'parent filter uses the immediate parent' );
$tira->subitem_unlink( project => $root, parent => $master->{ref}, child => $child->{ref} );
is( $tira->record_show( project => $root, ref => $child->{ref} )->{parent}, $epic->{ref}, 'unlink restores hierarchy parent' );

my $human = $tira->format_output(
    $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, priority => 5 ),
    output => 'human', project => $root,
);
like( $human, qr/Assignee: Ada Lovelace/, 'human output resolves assignee name' );
like( $human, qr/Reporter: Grace Hopper/, 'human output resolves reporter name' );
like( $human, qr/Priority: Very High/, 'human output renders priority label' );

my $legacy = $tira->create_record( project => $root, type => 'ticket', title => 'Legacy record' );
my $legacy_path = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', "$legacy->{ref}.json" );
open my $legacy_in, '<:raw', $legacy_path or die $!;
my $legacy_data = decode_json( do { local $/; <$legacy_in> } );
close $legacy_in;
delete @{$legacy_data}{qw(assignee reporter labels due_date start_date sdlc_gate lifecycle priority fix_version affects_versions parent checklist)};
$legacy_data->{assignees} = ['ada'];
open my $legacy_out, '>:raw', $legacy_path or die $!;
print {$legacy_out} Cpanel::JSON::XS->new->canonical->pretty->encode($legacy_data);
close $legacy_out;
my $migrated = $tira->record_show( project => $root, ref => $legacy->{ref} );
is( $migrated->{assignee}, 'ada', 'legacy assignee array migrates to singular assignee' );
is_deeply( $migrated->{labels}, [], 'legacy record receives metadata defaults' );
is_deeply( $migrated->{checklist}, [], 'legacy record receives empty checklist default' );

$legacy_data->{comments} = [{
    id => 'CMT-001', author => 'ada', format => 'markdown', body => 'Cost £523',
    attachments => [], created_at => '2026-08-05T13:30:00Z', last_updated => '2026-08-05T13:30:00Z',
}];
my $legacy_bytes = Cpanel::JSON::XS->new->canonical->pretty->utf8->encode($legacy_data);
$legacy_bytes =~ s/\xC2\xA3/\xA3/ or die 'Could not create legacy pound-byte fixture';
open $legacy_out, '>:raw', $legacy_path or die $!;
print {$legacy_out} $legacy_bytes;
close $legacy_out;
$migrated = $tira->record_show( project => $root, ref => $legacy->{ref} );
is( $migrated->{comments}[0]{body}, 'Cost £523', 'legacy isolated pound byte is repaired without data loss' );
$tira->record_update( author => 'ada', project => $root, ref => $legacy->{ref}, title => 'Legacy repaired' );
open $legacy_in, '<:raw', $legacy_path or die $!;
my $repaired_bytes = do { local $/; <$legacy_in> };
close $legacy_in;
is( decode_json($repaired_bytes)->{comments}[0]{body}, 'Cost £523', 'next mutation persists repaired valid UTF-8 JSON' );
like( $repaired_bytes, qr/\xC2\xA3/, 'repaired JSON contains canonical UTF-8 pound bytes' );

my $yaml = Tira::Yaml->new;
my $project_path = File::Spec->catfile( $root, '.tira', 'project.yml' );
my $project_data = read_yaml($project_path);
delete $project_data->{people}[1]{active};
write_yaml( $project_path, $yaml->dump_string($project_data) );
ok( $tira->project_show( project => $root )->{people}[1]{active}, 'legacy person reads as active' );
$tira->person_update( project => $root, id => 'grace', email => 'grace@example.test' );
ok( $tira->project_show( project => $root )->{people}[1]{active}, 'legacy person active default persists on mutation' );

# Optimistic concurrency — expect is a compare-and-swap under the lock
$ticket = $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, title => 'Concurrency base' );
eval {
    $tira->record_update( author => 'ada',
        project => $root, ref => $ticket->{ref},
        title => 'Second writer', expect => { title => 'Stale title' },
    );
};
like( $@, qr/\AConflict: title changed while you were editing/, 'a stale base is rejected as a conflict' );
is( $tira->record_show( project => $root, ref => $ticket->{ref} )->{title},
    'Concurrency base', 'a conflicted update writes nothing' );
$ticket = $tira->record_update( author => 'ada',
    project => $root, ref => $ticket->{ref},
    title => 'Second writer', expect => { title => 'Concurrency base' },
);
is( $ticket->{title}, 'Second writer', 'a matching base applies the update' );
$ticket = $tira->record_update( author => 'ada',
    project => $root, ref => $ticket->{ref}, fix_version => '4.0.0', expect => { fix_version => undef },
);
is( $ticket->{fix_version}, '4.0.0', 'a null base matches a still-empty field' );
eval {
    $tira->record_update( author => 'ada',
        project => $root, ref => $ticket->{ref}, fix_version => '5.0.0', expect => { fix_version => undef },
    );
};
like( $@, qr/\AConflict: fix_version changed/, 'a null base conflicts once the field has a value' );
$ticket = $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, priority => 3 );
$ticket = $tira->record_update( author => 'ada', project => $root, ref => $ticket->{ref}, priority => 4, expect => { priority => 3 } );
is( $ticket->{priority}, 4, 'numeric bases compare by value' );

# the YAML reader's load_file left the handle open, and on Windows an open handle
# makes a file impossible to replace - so a test that reads a config and then
# asks Tira to write it fails there and nowhere else. Reading it as a string
# closes the file when this says so.
sub read_yaml {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $yaml->load_string($body);
}

# dump_file leaves the handle open in the same way load_file does, and a test
# that writes a file Tira then replaces fails on Windows for that alone.
sub write_yaml {
    my ( $path, $body ) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write '$path': $!";
    print {$fh} $body;
    close $fh;
    return 1;
}

# --- TKT-572: a value Tira printed is a value Tira takes back ----------------
#
# Every timestamp Tira writes carries a basic-format offset - created_at and
# last_updated read 2026-08-19T09:00:00+0100 - and _valid_datetime required
# the extended form with a colon. So copying a stamp out of a card and
# pasting it back was refused, with "must be an ISO 8601 date-time with
# timezone" about a value that already was one. Both spellings are valid
# ISO 8601; the tool disagreed with itself about which.
#
# It disagreed with itself literally, in one file: _epoch_of_datetime accepts
# [+-]\d{2}:?\d{2} and says so in its own comment - "Accepts Z, +-HH:MM, and
# the +-HHMM the default clock writes". Somebody diagnosed this exactly and
# fixed one validator, leaving the other. These assertions hold both.

{
    # This file's own clock writes Z, which _valid_datetime always accepted -
    # so reading created_at here would have proved nothing, and the first
    # version of this block did exactly that and passed green against the
    # unfixed code. The bug needs the offset form the DEFAULT clock writes, so
    # the board for this case gets a clock that writes one.
    my $offset_tira = Tira->new( clock => sub {'2026-08-19T09:00:00+0100'} );
    my $offset_root = File::Spec->catdir( $tmp, 'offsets' );
    $offset_tira->create_project( name => 'Offsets', dir => $offset_root );
    $offset_tira->person_add( project => $offset_root, id => 'ada', name => 'Ada' );

    my $card = $offset_tira->create_record(
        project => $offset_root, type => 'ticket', title => 'Round-trips its own stamps' );
    my $stamp = $offset_tira->record_show(
        project => $offset_root, ref => $card->{ref} )->{created_at};

    like( $stamp, qr/[+-]\d{4}\z/,
        'the clock writes a basic-format offset, which is what this case is about' );

    # Read back rather than written as a literal: whatever the clock actually
    # writes is what has to be accepted, so this cannot drift if the stamp
    # format changes.
    for my $field (qw(start_date due_date)) {
        my $set = eval {
            $offset_tira->record_update(
                author => 'ada', project => $offset_root, ref => $card->{ref}, $field => $stamp );
        };
        ok( $set, "$field accepts the timestamp Tira itself wrote ($stamp)" );
        is( $set->{$field}, $stamp, "and stores it unchanged" ) if $set;
    }

    # The extended form keeps working - this widens what is accepted, it does
    # not trade one spelling for the other.
    ( my $extended = $stamp ) =~ s/([+-]\d{2})(\d{2})\z/$1:$2/;
    my $ext = eval {
        $offset_tira->record_update(
            author => 'ada', project => $offset_root, ref => $card->{ref}, start_date => $extended );
    };
    ok( $ext, "the extended offset form is still accepted ($extended)" );

    # And Z, which is what the default clock writes when no offset applies.
    my $zulu = eval {
        $offset_tira->record_update(
            author => 'ada', project => $offset_root, ref => $card->{ref},
            start_date => '2026-08-06T09:00:00Z' );
    };
    ok( $zulu, 'and Z' );

    # Still refused: no offset at all. Widening the accepted set must not turn
    # the check off - a stamp without a zone is genuinely ambiguous, which is
    # what the field exists to prevent.
    ok( !eval {
        $offset_tira->record_update(
            author => 'ada', project => $offset_root, ref => $card->{ref},
            start_date => '2026-08-06T09:00:00' ); 1 },
        'a date-time with no offset at all is still refused' );

    # The two validators must agree on the same string, which is the condition
    # that failed and the one worth holding.
    ok( defined Tira::_epoch_of_datetime( $stamp, 'Threshold' ),
        'the sibling validator accepts that stamp too - the two now agree' );
}

done_testing;

__END__

=head1 NAME

09-record-metadata.t - record metadata and inactive-person acceptance

=head1 DESCRIPTION

Defines the symmetric SOW, epic, and ticket metadata contract, immediate-parent
semantics, human rendering, validation, and historical person behavior.

=cut
