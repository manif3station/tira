#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP ();
use Test::More;

use lib 'lib';
use Tira;

my $tmp = tempdir( CLEANUP => 1 );
my $now = '2026-08-11T09:00:00Z';
my $tira = Tira->new( clock => sub {$now} );
sub at { $now = $_[0]; return $now }

my $root = File::Spec->catdir( $tmp, 'project' );
$tira->project_new(
    name => 'Logged', dir => $root, members => [ 'michael', 'claude' ],
    columns => ['backlog, implement, done'],
    sow_prefix => 'LGS', epic_prefix => 'LGE', ticket_prefix => 'LGT',
);

my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Something happens to it' );

sub log_for {
    return $tira->work_log( project => $root, ref => $card->{ref} );
}

sub kinds {
    return map { $_->{kind} } @{ log_for() };
}

# --- everything that happens to a card ------------------------------------

# His words: every event that changes a card - moved column to column, changed
# description, changed an answer, answered a question, added a comment.
at('2026-08-11T09:10:00Z');
$tira->record_move( project => $root, ref => $card->{ref}, column => 'implement', author => 'michael' );

at('2026-08-11T09:20:00Z');
$tira->record_update( project => $root, ref => $card->{ref}, description => 'now explained' );

at('2026-08-11T09:30:00Z');
$tira->comment_add( project => $root, ref => $card->{ref}, author => 'claude', text => 'starting on this' );

at('2026-08-11T09:40:00Z');
my $question = $tira->question_add( project => $root, ref => $card->{ref},
    author => 'claude', text => 'which way round?' );

at('2026-08-11T09:50:00Z');
$tira->question_answer( project => $root, ref => $card->{ref}, id => $question->{id}, text => 'that way' );

at('2026-08-11T10:00:00Z');
$tira->question_mark( project => $root, ref => $card->{ref}, id => $question->{id}, mark => 'ok' );

my %seen = map { $_ => 1 } kinds();
for my $kind (qw(created moved changed commented asked answered marked)) {
    ok( $seen{$kind}, "$kind is in the work log" );
}

# --- in the order it happened ---------------------------------------------

my @entries = @{ log_for() };
is_deeply( [ map { $_->{at} } @entries ], [ sort map { $_->{at} } @entries ],
    'the log reads forwards, as what happened and when' );

# --- and it says who, where the board knows -------------------------------

my ($move) = grep { $_->{kind} eq 'moved' } @entries;
is( $move->{who}, 'michael', 'a move says who moved it' );
like( $move->{detail}, qr/backlog.*implement/, 'and from where to where' );

my ($comment) = grep { $_->{kind} eq 'commented' } @entries;
is( $comment->{who}, 'claude', 'a comment says who left it' );

# A change made with nobody named says nobody, rather than inventing one.
at('2026-08-11T10:10:00Z');
$tira->record_update( project => $root, ref => $card->{ref}, title => 'Renamed by a script' );
my ($anonymous) = grep { $_->{kind} eq 'changed' && ( $_->{detail} // '' ) =~ /title/ } @{ log_for() };
is( $anonymous->{who}, undef, 'and a change with nobody named claims nobody' );

# --- the agent cannot write it --------------------------------------------

# An agent that has to remember to log keeps a fictional log, so it never
# writes one. Adding a comment IS the entry; changing a title logs itself.
ok( !Tira->can('work_log_add'), 'there is no command to add an entry' );
ok( !Tira->can('work_log_update'), 'nor to change one' );
ok( !Tira->can('work_log_remove'), 'nor to remove one' );

# --- one implementation, both ways in -------------------------------------

# The command line and the browser are wrappers around the same subroutines,
# so the log is built where the change happens rather than where it was asked
# for. Anything else covers one path and misses the other.
{
    my $other = $tira->create_record( project => $root, type => 'ticket', title => 'Touched twice' );
    at('2026-08-11T11:00:00Z');
    $tira->comment_add( project => $root, ref => $other->{ref}, author => 'michael', text => 'from a terminal' );

    my @theirs = @{ $tira->work_log( project => $root, ref => $other->{ref} ) };
    my ($from_cli) = grep { $_->{kind} eq 'commented' } @theirs;
    ok( $from_cli, 'a comment made through the engine is logged' );

    # The browser reaches the very same subroutine, so there is nothing
    # separate to test - which is the point, and is asserted rather than
    # assumed by checking the engine is what records it.
    is( $from_cli->{who}, 'michael', 'with whoever made it' );
}

# --- what reading a real card's log showed --------------------------------

# None of the following came from a test. They came from reading an actual
# card's log and finding it unreadable: sixty entries, a comment reported
# twice, and runs of identical lines saying nothing.
{
    my $noisy = $tira->create_record( project => $root, type => 'ticket', title => 'Busy card' );

    at('2026-08-11T12:00:00Z');
    $tira->comment_add( project => $root, ref => $noisy->{ref},
        author => 'claude', text => 'something worth saying' );

    my @entries = @{ $tira->work_log( project => $root, ref => $noisy->{ref} ) };
    is( scalar( grep { $_->{kind} eq 'commented' } @entries ), 1,
        'a comment is one event' );
    is( scalar( grep { ( $_->{detail} // '' ) =~ /comments changed/ } @entries ), 0,
        'and is not also reported as a field write, which read as two things happening' );

    my ($said) = grep { $_->{kind} eq 'commented' } @entries;
    like( $said->{detail}, qr/something worth saying/,
        'and carries what was said - the field is body, and reading text gave an empty line' );

    # Twenty identical lines is one thing happening twenty times, and says less
    # than one line that says so.
    at('2026-08-11T12:10:00Z');
    $tira->checklist_add( project => $root, ref => $noisy->{ref}, item => "step $_", status => 'pending' )
      for 1 .. 5;

    my @after = @{ $tira->work_log( project => $root, ref => $noisy->{ref} ) };
    my ($run) = grep { ( $_->{detail} // '' ) =~ /checklist/ } @after;
    ok( $run, 'the checklist writes are there' );
    is( $run->{times}, 5, 'collapsed into one entry that says how many times' );
    is( scalar( grep { ( $_->{detail} // '' ) =~ /checklist/ } @after ), 1,
        'rather than five lines saying the same thing' );

    ok( $run->{until}, 'and says when the run ended as well as when it started' );
}

# --- the route the browser asks --------------------------------------------

# The section fetches this when somebody expands it, so it is driven here the
# way the browser drives it rather than through the engine - the provider is
# where a mistake would show up as an empty section nobody could explain.
{
    require Tira::CLI;
    my %providers = Tira::CLI::browser_providers( tira => $tira, project => $root );
    ok( ref $providers{work_log} eq 'CODE', 'the browser is given a work log provider' );

    my $answered = JSON::PP->new->decode( $providers{work_log}->( { ref => $card->{ref} } ) );
    ok( scalar @{$answered}, 'and it answers with what happened' );
    is( $answered->[0]{kind}, 'created', 'starting at the beginning' );

    ok( !eval { $providers{work_log}->( {} ); 1 },
        'asking about no card is refused rather than answered with everything' );
}

# --- who did it, from the command line ------------------------------------

# Michael moved a card back himself and it was the only entry on that card that
# said who: every one of mine said nobody. The browser has always known, because
# there is a login in front of it; the command line never said, so the log knew
# what happened and never who - which is most of what a work log is for.
{
    require Tira::CLI;

    sub run_cli {
        my (@argv) = @_;
        my ( $out, $err ) = ( '', '' );
        open my $so, '>', \$out or die $!;
        open my $se, '>', \$err or die $!;
        my $status = do {
            local *STDOUT = $so;
            local *STDERR = $se;
            Tira::CLI->run( command => shift(@argv), tira => $tira,
                argv => [ '--project', $root, @argv ] );
        };
        return ( $status, $out, $err );
    }

    sub last_move {
        my ($ref) = @_;
        my @moves = grep { $_->{kind} eq 'moved' }
          @{ $tira->work_log( project => $root, ref => $ref ) };
        return $moves[-1];
    }

    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Who moved it' );

    at('2026-08-11T13:00:00Z');
    run_cli( 'record.move', '--type', 'ticket', '--ref', $card->{ref},
        '--column', 'implement', '--author', 'michael', '-o', 'json' );
    is( last_move( $card->{ref} )->{who}, 'michael',
        'a move named on the command line is recorded against that person' );

    # Said once in the environment rather than remembered on every command.
    at('2026-08-11T13:10:00Z');
    {
        local $ENV{TIRA_AUTHOR} = 'claude';
        run_cli( 'record.move', '--type', 'ticket', '--ref', $card->{ref},
            '--column', 'done', '-o', 'json' );
    }
    is( last_move( $card->{ref} )->{who}, 'claude',
        'and one nobody named is recorded against whoever the environment says is running it' );

    at('2026-08-11T13:20:00Z');
    {
        local $ENV{TIRA_AUTHOR} = 'claude';
        run_cli( 'record.move', '--type', 'ticket', '--ref', $card->{ref},
            '--column', 'backlog', '--author', 'michael', '-o', 'json' );
    }
    is( last_move( $card->{ref} )->{who}, 'michael',
        'somebody who says who they are beats the environment' );

    # And with neither, it says nobody rather than inventing one.
    at('2026-08-11T13:30:00Z');
    {
        local $ENV{TIRA_AUTHOR};
        delete $ENV{TIRA_AUTHOR};
        run_cli( 'record.move', '--type', 'ticket', '--ref', $card->{ref},
            '--column', 'implement', '-o', 'json' );
    }
    is( last_move( $card->{ref} )->{who}, undef,
        'and with nobody named anywhere it claims nobody' );

    # An edit is a change to the card exactly as a move is.
    at('2026-08-11T13:40:00Z');
    {
        local $ENV{TIRA_AUTHOR} = 'claude';
        run_cli( 'record.update', '--type', 'ticket', '--ref', $card->{ref},
            '--description', 'now it says something', '-o', 'json' );
    }
    my ($edit) = grep { $_->{kind} eq 'changed' && ( $_->{detail} // '' ) =~ /description/ }
      @{ $tira->work_log( project => $root, ref => $card->{ref} ) };
    is( $edit->{who}, 'claude', 'an edit says who made it too' );
}

# --- what the browser draws -----------------------------------------------

# Two faults he could see and no assertion could. The log fetched once when it
# was expanded and never again, so a log opened before a move showed the card as
# it was when it was opened for as long as the dialog stayed open. And an entry
# with nobody named had its name cell left out rather than left blank, so the
# detail slid into the name column and the row read as though it were broken.
{
    require Tira::CLI;
    my @calls;
    my ( $out, $err ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    {
        local *STDOUT = $so;
        local *STDERR = $se;
        Tira::CLI->run(
            command => 'dashboard.ticket', tira => $tira,
            argv => [ '--project', $root, '-o', 'browser' ],
            browser_server => sub { push @calls, {@_}; return 1 },
        );
    }
    my $html = $calls[0]{render}->();

    like( $html, qr/card-worklog__who",entry\.who\|\|dash/,
        'an entry with nobody named still gets its name cell, so the row keeps its columns' );
    like( $html, qr/worklogRefresh=\(\)=>\{if\(loaded&&!body\.hidden\)readLog\(\)\}/,
        'an open work log is re-read rather than left as it was when it was opened' );
    like( $html, qr/if\(worklogOpen\)\{/,
        'and it stays open when the card behind it is redrawn' );
    like( $html, qr/if\(!open\|\|loaded\)return/,
        'while a log nobody has opened still fetches nothing' );
}

# --- a card nothing has happened to ---------------------------------------

my $untouched = $tira->create_record( project => $root, type => 'ticket', title => 'Just made' );
my $quiet = $tira->work_log( project => $root, ref => $untouched->{ref} );
is( scalar @{$quiet}, 1, 'a new card has one entry: that it was created' );
is( $quiet->[0]{kind}, 'created', 'saying so' );

done_testing;

__END__

=head1 NAME

93-work-log.t - what actually happened to a card

=head1 DESCRIPTION

The owner looked at the board late one night, saw cards apparently started in
the afternoon and still open, and could not tell whether the work took that
long, whether the agent had forgotten to move the card, or whether nothing had
happened at all. His words: I have no idea what the real history is, whether
the agent is being lazy or incompetent.

So every event that changes a card is recorded on it - moved, edited,
commented, asked, answered, marked - built where the change happens rather than
where it was asked for. The command line and the browser are wrappers around
the same subroutines, and logging at either wrapper would cover one path and
miss the other.

The agent never writes an entry, and there is no command that lets it. Adding a
comment IS the entry; changing a title logs itself. An agent that has to
remember to log keeps a log worth nothing, which is the whole problem being
solved.

=cut
