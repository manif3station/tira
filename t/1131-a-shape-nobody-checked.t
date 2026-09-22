#!/usr/bin/env perl
# TKT-1131: tira.doctor's damage scan only ever looked for invalid UTF-8
# bytes - never for a record whose evidence/attachments/gate_passing_log
# field is a scalar or other non-array-of-hashes value where every reader
# expects an array of hash records. That exact corruption happened live on
# TKT-1028's production record this session (fixed at the write path by
# TKT-1130's record_update guard); doctor did not detect it, and would not
# have known how to fix it if it had. Recovery meant reading the raw JSON
# by hand and resetting the field to [].
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub {'2026-09-19T00:00:00Z'} );
$tira->project_new( name => 'Proj', dir => $root, members => ['claude'] );

my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card', author => 'claude',
    description => 'd', problem_or_feature => 'p', solution_needed => 's',
);
my $ref = $ticket->{ref};

sub record_path {
    my ($ref) = @_;
    my $record = $tira->record_show( project => $root, ref => $ref );
    my $glob = File::Spec->catfile( $root, '.tira', 'ticket', '*', "$ref.json" );
    my ($path) = glob $glob;
    return $path;
}

my $path = record_path($ref);
ok( -f $path, 'the record file exists where doctor will look for it' );

# --- corrupt it directly on disk, exactly the shape TKT-1028 hit -----------

sub corrupt_field {
    my ( $path, $field, $value ) = @_;
    open my $fh, '<:raw', $path or die "Cannot read $path: $!";
    local $/;
    my $bytes = <$fh>;
    close $fh;
    my $data = Tira::json_decode($bytes);
    $data->{$field} = $value;
    require JSON::PP;
    my $json = JSON::PP->new->canonical->pretty->utf8->encode($data);
    open my $out, '>:raw', $path or die "Cannot write $path: $!";
    print {$out} $json;
    close $out;
    return;
}

corrupt_field( $path, 'evidence', 'a plain string, not an array' );

eval { $tira->record_show( project => $root, ref => $ref ) };
like( $@, qr/ARRAY ref/, 'the corrupted card really does crash on read right now - the TKT-1028 incident, reproduced' );

# --- doctor finds it, exactly the way it already finds byte damage ---------

my $found = $tira->doctor( project => $root );
my ($report) = grep { $_->{path} eq $path && ( $_->{field} // '' ) eq 'evidence' } @{ $found->{damaged} };
ok( $report, 'doctor reports the shape corruption, not just byte corruption' );
like( $report->{detail}, qr/array/i, 'saying what shape was expected' );

# --- and changes nothing until asked ----------------------------------------

eval { $tira->record_show( project => $root, ref => $ref ) };
like( $@, qr/ARRAY ref/, 'reporting is not repairing - the card still crashes on read' );
is( scalar @{ $found->{repaired} }, 0, 'nothing in repaired[] yet either' );

# --- when asked, it repairs by resetting the field to [] --------------------

my $fixed = $tira->doctor( project => $root, repair => 1 );
my ($fix_report) = grep { $_->{path} eq $path && ( $_->{field} // '' ) eq 'evidence' } @{ $fixed->{repaired} };
ok( $fix_report, 'doctor --repair reports the fix' );

my $after = $tira->record_show( project => $root, ref => $ref );
is_deeply( $after->{evidence}, [], 'and the field is now a real, empty array - readable again' );

# --- the full field/shape matrix - all three fields, each corruption shape -
# (Codex review pass: the corrupting-scalar case above only exercised
# 'evidence'; the stated contract covers attachments/gate_passing_log too,
# and a JSON null, and an array of scalars, not just a bare scalar.)

for my $field (qw(evidence attachments gate_passing_log)) {
    for my $case (
        [ scalar_value => 'a plain string, not an array' ],
        [ null_value   => undef ],
        [ array_of_scalars => ['not a hashref'] ],
    ) {
        my ( $label, $value ) = @$case;
        my $card = $tira->create_record(
            project => $root, type => 'ticket', title => "A $field/$label card", author => 'claude',
            description => 'd', problem_or_feature => 'p', solution_needed => 's',
        );
        my $card_path = record_path( $card->{ref} );
        corrupt_field( $card_path, $field, $value );

        my $scan = $tira->doctor( project => $root );
        my ($found_report) = grep { $_->{path} eq $card_path && ( $_->{field} // '' ) eq $field }
          @{ $scan->{damaged} };
        ok( $found_report, "doctor reports $field/$label as damaged" );

        my $repaired_scan = $tira->doctor( project => $root, repair => 1 );
        my ($fix) = grep { $_->{path} eq $card_path && ( $_->{field} // '' ) eq $field }
          @{ $repaired_scan->{repaired} };
        ok( $fix, "doctor --repair fixes $field/$label" );

        my $card_after = $tira->record_show( project => $root, ref => $card->{ref} );
        is_deeply( $card_after->{$field}, [], "and $field/$label is now a real, empty array" );
    }
}

# --- a null field is corruption too, not a legitimate "no value" -----------
# (undef reads as an empty list on record_show, but crashes evidence_add's
# own "@{$record->{evidence}} + 1" the same way a string does.)

my $second = $tira->create_record(
    project => $root, type => 'ticket', title => 'A null-evidence card', author => 'claude',
    description => 'd', problem_or_feature => 'p', solution_needed => 's',
);
corrupt_field( record_path( $second->{ref} ), 'evidence', undef );

# evidence_add used to crash here ("Can't use an undefined value as an
# ARRAY reference") - TKT-1082's max-id-scan rewrite changed its loop to
# `for my $existing (@{ $record->{evidence} })`, and a foreach over a
# dereferenced undef is a silent empty list in Perl, not a die. That
# incidentally makes evidence_add treat a null field the same way
# checklist_add's own TKT-642 precedent already treats one (`@{ $record->
# {checklist} // [] }`) - consistent with the established pattern, not a
# regression to guard against. doctor's own detection below (the actual
# point of this file, per its own header) is unaffected either way.
eval { $tira->evidence_add( project => $root, ref => $second->{ref}, author => 'claude', summary => 'x' ) };
ok( !$@, 'evidence_add no longer crashes on a null evidence field - TKT-1082 made it consistent with checklist_add' )
  or diag("died: $@");

# doctor's own detection needs a SEPARATE still-null record: evidence_add's
# successful write above replaced $second's null field with a real array as
# a side effect, so scanning $second again would prove nothing about
# doctor's own null-detection - only that evidence_add fixed what it touched.
my $third = $tira->create_record(
    project => $root, type => 'ticket', title => 'Another null-evidence card', author => 'claude',
    description => 'd', problem_or_feature => 'p', solution_needed => 's',
);
corrupt_field( record_path( $third->{ref} ), 'evidence', undef );

my $null_scan = $tira->doctor( project => $root );
my ($null_report) = grep { $_->{path} eq record_path( $third->{ref} ) && ( $_->{field} // '' ) eq 'evidence' }
  @{ $null_scan->{damaged} };
like( $null_report->{detail}, qr/null/i, 'saying it was null, not silently treating null as fine' );

# --- a genuinely clean record is untouched and unreported -------------------

my $other = $tira->create_record(
    project => $root, type => 'ticket', title => 'A clean card', author => 'claude',
    description => 'd', problem_or_feature => 'p', solution_needed => 's',
);
$tira->evidence_add( project => $root, ref => $other->{ref}, author => 'claude', summary => 'Ran the suite' );
my $clean_scan = $tira->doctor( project => $root );
my $clean_path = record_path( $other->{ref} );
my @flagged_clean = grep { $_->{path} eq $clean_path } @{ $clean_scan->{damaged} };
is( scalar @flagged_clean, 0, 'a record with a real evidence entry is never reported as damaged' );

done_testing();

__END__

=head1 NAME

1131-a-shape-nobody-checked.t - tira.doctor detects a structurally-corrupted
evidence/attachments/gate_passing_log field

=head1 DESCRIPTION

tira.doctor's damage scan (TKT-192) only ever checked for invalid UTF-8
bytes. TKT-1131 extends it to also check that evidence/attachments/
gate_passing_log, when present on a ticket/epic/sow record, is an ARRAY ref
of HASH refs - the same shape TKT-1130's record_update now enforces on
write. A record already in this corrupted state (from before TKT-1130
shipped, or written directly rather than through the engine) is reported
in the same C<damaged> list byte-corruption already used, and C<--repair>
resets the offending field to C<[]> - there is no way to recover the
intended array content from a corrupted scalar.

=cut
