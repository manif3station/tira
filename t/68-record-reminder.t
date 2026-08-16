#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );

sub cli {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira, type => 'ticket' );
    return ( $status, $out );
}

my $root = File::Spec->catdir( $tmp, 'proj' );

# The board every command here works on, named the one way there is.
# TKT-250.
$ENV{TIRA_HOME} = $root;
$tira->project_new( name => 'Remind', dir => $root, members => ['michael'], columns => ['Backlog, Doing'],
    sow_prefix => 'RMS', epic_prefix => 'RME', ticket_prefix => 'RMT' );

# The record itself must stay exactly what is stored: an agent has to be able
# to trust that what it holds is what is on disk. The advice is computed from
# it and attached where agents are spoken to, not baked into the data.
my $bare = $tira->create_record( project => $root, type => 'ticket', title => 'Only a title' );
is( $bare->{reminder}, undef, 'the stored record carries no advice of its own' );
my $bare_reminder = $tira->record_reminder($bare);
like( $bare_reminder, qr/\Amissing: description,reporter,gate,questions\(if unclear\)/,
    'a ticket created with only a title is told everything it still owes, at once' );
like( $bare_reminder, qr/\Qtira.ticket.update --ref $bare->{ref} --description TEXT --reporter NAME\E/,
    'the two fields that share a command share one, references filled in' );
like( $bare_reminder, qr/\Qtira.gate.add --ref $bare->{ref}\E/, 'the gate has its own' );
like( $bare_reminder, qr/\Qtira.question.ask --ref $bare->{ref}\E/,
    'and asking is offered, because guessing at something unclear is the expensive mistake' );
unlike( $bare_reminder, qr/\n/, 'all of it on one line' );

# Created complete, told nothing.
my $full = $tira->create_record(
    project => $root, type => 'ticket', title => 'Done properly',
    description => 'What it is and why.', reporter => 'michael' );
like( $tira->record_reminder($full), qr/\Amissing: gate,questions/,
    'a ticket with a description and a reporter is only reminded of the rest' );
unlike( $tira->record_reminder($full), qr/--description|--reporter/,
    'and not offered fixes it does not need' );

# Each is settled independently.
$tira->record_update( project => $root, type => 'ticket', ref => $bare->{ref},
    description => 'Now described.', reporter => 'michael' );
$tira->gate_add( project => $root, type => 'ticket', ref => $bare->{ref},
    gate => 'Review', result => 'pass' );
my $asked = $tira->question_add( project => $root, ref => $bare->{ref}, text => 'One thing?' );
my $settled = $tira->record_show( project => $root, type => 'ticket', ref => $bare->{ref} );
is( $tira->record_reminder($settled), undef,
    'once it has all four it owes nothing and says nothing' );

# A question that was set aside does not count as having asked.
$tira->question_discard( project => $root, id => $asked->{id} );
my $aside = $tira->record_show( project => $root, type => 'ticket', ref => $bare->{ref} );
like( $tira->record_reminder($aside), qr/questions\(if unclear\)/,
    'a question set aside leaves the card back where it was on that point' );

# The reporter rule is the owner when he asked, and the agent itself when it
# found the thing - which is why the reminder names the field rather than
# guessing a value.
like( $bare_reminder, qr/--reporter NAME/, 'the reporter is named as something to supply' );

# Every board, since a SOW with no description is no better than a ticket.
my $sow = $tira->create_record( project => $root, type => 'sow', title => 'A statement' );
like( $tira->record_reminder($sow), qr/\Qtira.sow.update --ref $sow->{ref}\E/,
    'the fix names the board the record actually lives on' );

# Through the command line, which is where an agent meets it.
my ( $status, $out ) = cli( 'record.create', '--title', 'From the CLI', '-o', 'json' );
is( $status, 0, 'the CLI creates a ticket' );
like( decode_json($out)->{reminder}, qr/missing: description,reporter/,
    'and hands back the same reminder' );

done_testing;

__END__

=head1 NAME

68-record-reminder.t - what a newly created record still owes

=head1 DESCRIPTION

A ticket that is only a title cannot be picked up by anybody who did
not write it. Proves a new record is told, in one terse line, that it
has no description, no reporter, no gate and no question - the four the
owner chose, which are about who owns the work and how it will be
judged rather than how it is written. Fields sharing a command share
one, the fix names the board the record actually lives on, and a record
that owes nothing says nothing.

=cut
