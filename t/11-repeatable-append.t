#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'repeatable' );
my $tira = Tira->new( clock => sub { '2026-08-05T16:00:00Z' } );
$tira->create_project( name => 'Repeatable fields', dir => $root );

my %field = (
    key_details => 'key_details', deliverables => 'deliverables',
    acceptance => 'acceptance_criteria', test_steps => 'test_steps',
    bdd => 'bdd', atdd => 'atdd',
);

for my $type (qw(sow epic ticket)) {
    my $record = $tira->create_record(
        project => $root, type => $type, title => "Append $type",
        ( map { $_ => ["old-$_"] } keys %field ),
        scope_in => ['old-in'], scope_out => ['old-out'],
    );
    $record = $tira->record_update(
        project => $root, ref => $record->{ref},
        ( map { $_ => [ "new-a-$_", "new-b-$_" ] } keys %field ),
        scope_in => [ 'new-a-in', 'new-b-in' ], scope_out => [ 'new-a-out', 'new-b-out' ],
    );
    for my $argument ( sort keys %field ) {
        is_deeply(
            $record->{ $field{$argument} },
            [ "old-$argument", "new-a-$argument", "new-b-$argument" ],
            "$type $argument appends without data loss",
        );
    }
    is_deeply( $record->{scope}{included}, [qw(old-in new-a-in new-b-in)], "$type included scope appends" );
    is_deeply( $record->{scope}{excluded}, [qw(old-out new-a-out new-b-out)], "$type excluded scope appends" );
}

my $ticket = $tira->create_record(
    project => $root, type => 'ticket', title => 'Replacement controls',
    ( map { $_ => ["old-$_"] } keys %field ),
);
$ticket = $tira->record_update(
    project => $root, ref => $ticket->{ref},
    key_details => ['replacement-key'], deliverables => ['replacement-deliverable'],
    acceptance => ['replacement-acceptance'], test_steps => ['replacement-step'],
    bdd => ['replacement-bdd'], atdd => ['replacement-atdd'],
);

local $ENV{TIRA_HOME} = $root;
my ( $stdout, $stderr ) = ('', '');
{
    open my $out, '>', \$stdout or die $!;
    open my $err, '>', \$stderr or die $!;
    local *STDOUT = $out;
    local *STDERR = $err;
    is( Tira::CLI->run(
        command => 'record.update', type => 'ticket',
        argv => [ '--ref', $ticket->{ref}, '--key-detail', 'cli-a', '--key-detail', 'cli-b', '-o', 'json' ],
    ), 0, 'CLI repeated update succeeds' );
}
is( $stderr, '', 'CLI repeated update has no stderr' );
like( $stdout, qr/"old-key_details".*"replacement-key".*"cli-a".*"cli-b"/s,
    'CLI appends repeated values in order without dropping existing content' );

$ticket = $tira->record_update(
    project => $root, ref => $ticket->{ref},
    key_details_replace => ['set-key'], deliverables_replace => ['set-deliverable'],
    acceptance_replace => ['set-acceptance'], test_steps_replace => ['set-step'],
    bdd_replace => ['set-bdd'], atdd_replace => ['set-atdd'],
);
for my $argument ( sort keys %field ) {
    my $replacement = $argument eq 'acceptance' ? 'set-acceptance'
      : $argument eq 'test_steps' ? 'set-step'
      : $argument eq 'deliverables' ? 'set-deliverable'
      : $argument eq 'key_details' ? 'set-key'
      : "set-$argument";
    is_deeply( $ticket->{ $field{$argument} }, [$replacement], "$argument explicit set replaces wholesale" );
}

done_testing;

__END__

=head1 NAME

11-repeatable-append.t - Repeatable record update data-loss regression

=head1 DESCRIPTION

Proves append-safe updates for all accumulating fields and scopes across SOWs,
epics, and tickets, including repeated CLI arguments.

=cut
