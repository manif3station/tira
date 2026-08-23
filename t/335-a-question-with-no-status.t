#!/usr/bin/env perl
# question.list computes a question's status (new/answered/discarded) through
# _question_view. tira.<type>.show's embedded questions - dispatched as
# record.show - spread the stored entry as-is, which carries no status key at
# all, so a discarded question and a live one were distinguishable only by
# discarded_at, invisible to a caller filtering on status the documented
# way. Measured: the same three questions from ticket.show and question.list
# in the same minute disagreed about whether status was even present.
#
# Fixed at the CLI dispatch boundary rather than inside the engine's own
# record_show: record_show is reused internally as a fetch-then-mutate
# primitive (question_update reads a record through it, then writes the same
# structure back) - view-computed fields leaking into that path would get
# written into storage. TKT-322.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-23T09:00:00Z'} );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Statused', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'QSS', epic_prefix => 'QSE', ticket_prefix => 'QST',
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
        Tira::CLI->run( command => 'record.show', tira => $tira,
            argv => [ '--ref', $card->{ref}, '-o', 'json' ] );
    };
    is( $status, 0, 'record.show dispatches cleanly' );

    require Cpanel::JSON::XS;
    my $shown = Cpanel::JSON::XS::decode_json($out);
    my %by_id = map { $_->{id} => $_ } @{ $shown->{questions} };

    is( $by_id{ $live->{id} }{status}, 'new', 'dispatched record.show: live question carries status new' );
    is( $by_id{ $answered->{id} }{status}, 'answered', 'dispatched record.show: answered question carries its status' );
    is( $by_id{ $discarded->{id} }{status}, 'discarded', 'dispatched record.show: discarded question carries its status' );

    my $listed = $tira->question_list( project => $root, ref => $card->{ref} );
    my %listed_status = map { $_->{id} => $_->{status} } @{ $listed->{questions} };
    my %shown_status  = map { $_->{id} => $_->{status} } @{ $shown->{questions} };
    is_deeply( \%shown_status, \%listed_status,
        'ticket.show and question.list agree about every question\'s status' );
}

# --- and record.show with --refs (record_show_many) agrees too --------------------

{
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME}   = $root;
        local $ENV{TIRA_AUTHOR} = 'claude';
        Tira::CLI->run( command => 'record.show', tira => $tira,
            argv => [ '--refs', $card->{ref}, '-o', 'json' ] );
    };
    is( $status, 0, 'record.show --refs dispatches cleanly' );

    require Cpanel::JSON::XS;
    my $result = Cpanel::JSON::XS::decode_json($out);
    my %by_id = map { $_->{id} => $_ } @{ $result->{records}{ $card->{ref} }{questions} };
    is( $by_id{ $discarded->{id} }{status}, 'discarded',
        'record.show --refs (record_show_many) carries status too' );
}

done_testing;

__END__

=head1 NAME

335-a-question-with-no-status.t - ticket.show's embedded questions carry status

=head1 DESCRIPTION

C<question.list> computes a question's C<status> (new/answered/discarded)
through C<_question_view>. C<record.show> - what C<ticket.show> and the
sibling C<sow.show>/C<epic.show> dispatch to - returned the stored question
entry as-is, which carries no C<status> key, so a discarded question and a
live one were distinguishable only by C<discarded_at>: invisible to a
caller filtering on the documented field.

Fixed at the C<Tira::CLI> dispatch boundary for C<record.show> and
C<record.show>'s C<--refs> (batch) form, rather than inside the engine's
own C<record_show>: C<record_show> is reused internally by roughly forty
call sites as a fetch-then-mutate primitive (C<question_update> reads a
record through it, mutates the returned structure, and writes it straight
back) - view-computed fields leaking into that path would get written into
storage. TKT-322.

=cut
