#!/usr/bin/env perl
# TKT-648. tira.export's embedded questions carry no 'status' key at all -
# the same gap TKT-322 already fixed for record.show (t/335), but never
# applied to export_records. Measured live: 151 questions across 49 cards,
# 0 carrying 'status'. A consumer filtering on the documented field sees
# zero discarded questions instead of the real count, silently, at exit 0.
#
# Fixed the same way TKT-322 was: at the Tira::CLI dispatch boundary for
# the 'export' command, not inside export_records itself - the engine
# method stays a plain read, and the view-computed status is layered on
# only for the CLI-facing answer.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-09-22T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Exported', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'XSS', epic_prefix => 'XSE', ticket_prefix => 'XST',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Carries questions' );
my $live = $tira->question_add( project => $root, ref => $card->{ref},
    text => 'Still open?', reason => 'r', options => [ 'y', 'n' ] );
my $answered = $tira->question_add( project => $root, ref => $card->{ref},
    text => 'Answer me', reason => 'r', options => [ 'y', 'n' ] );
$tira->question_answer( project => $root, ref => $card->{ref},
    id => $answered->{id}, text => 'y', author => 'claude' );
my $discarded = $tira->question_add( project => $root, ref => $card->{ref},
    text => 'Never mind', reason => 'r', options => [ 'y', 'n' ] );
$tira->question_discard( project => $root, ref => $card->{ref}, id => $discarded->{id} );

# --- proved through the real dispatch path, the way an agent actually calls it ----

{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME}   = $root;
        local $ENV{TIRA_AUTHOR} = 'claude';
        Tira::CLI->run( command => 'export', tira => $tira, argv => [ '-o', 'json' ] );
    };
    is( $status, 0, 'export dispatches cleanly' );

    require Cpanel::JSON::XS;
    my $result = Cpanel::JSON::XS::decode_json($out);
    my ($record) = grep { $_->{ref} eq $card->{ref} } @{ $result->{records} };
    ok( defined $record, 'the card is present in the export' );
    my %by_id = map { $_->{id} => $_ } @{ $record->{questions} };

    is( $by_id{ $live->{id} }{status}, 'new', 'export: live question carries status new' );
    is( $by_id{ $answered->{id} }{status}, 'answered', 'export: answered question carries its status' );
    is( $by_id{ $discarded->{id} }{status}, 'discarded', 'export: discarded question carries its status' );

    # A consumer filtering on the documented field is the whole point of
    # this card - prove the count, not just the presence of the key.
    my @discarded_ones = grep { ( $_->{status} // '' ) eq 'discarded' } @{ $record->{questions} };
    is( scalar @discarded_ones, 1, 'filtering export by status:discarded finds the real count' );
}

# --- and export agrees with question.list about the same questions ----------

{
    my $listed = $tira->question_list( project => $root, ref => $card->{ref} );
    my %listed_status = map { $_->{id} => $_->{status} } @{ $listed->{questions} };

    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    local *STDOUT = $so;
    local *STDERR = $se;
    local $ENV{TIRA_HOME}   = $root;
    local $ENV{TIRA_AUTHOR} = 'claude';
    Tira::CLI->run( command => 'export', tira => $tira, argv => [ '-o', 'json' ] );
    close $so;

    require Cpanel::JSON::XS;
    my $result = Cpanel::JSON::XS::decode_json($out);
    my ($record) = grep { $_->{ref} eq $card->{ref} } @{ $result->{records} };
    my %exported_status = map { $_->{id} => $_->{status} } @{ $record->{questions} };
    is_deeply( \%exported_status, \%listed_status,
        'export and question.list agree about every question\'s status' );
}

# --- the engine method itself is untouched - the fix is at the CLI boundary -

{
    my $raw = $tira->export_records( project => $root );
    my ($record) = grep { $_->{ref} eq $card->{ref} } @{ $raw->{records} };
    ok( !( grep { exists $_->{status} } @{ $record->{questions} } ),
        'the bare engine method (export_records) still returns no status - '
          . 'the view is layered on only at the CLI dispatch boundary, '
          . 'matching TKT-322\'s own precedent for record.show' );
}

done_testing;

__END__

=head1 NAME

1156-a-count-that-was-secretly-zero.t - tira.export's embedded questions
carry status

=head1 DESCRIPTION

TKT-648. C<tira.export -o json> embedded each record's raw C<questions>
array, which carries no C<status> key - C<status> is computed only by
C<_question_view>, applied at the C<Tira::CLI> dispatch boundary for
C<record.show> since TKT-322 but never extended to C<export>. Measured
live: 151 questions across 49 cards, 0 carrying C<status> - a consumer
filtering on the documented field silently saw zero discarded questions
instead of the real sixteen. Fixed the same way, and for the same reason:
C<export_records> itself is left alone since nothing reuses it as a
fetch-then-mutate primitive the way C<record_show> is, but the fix still
lives at the CLI boundary rather than the engine, for consistency with
TKT-322's own precedent and to keep the pattern in one place.

=cut
