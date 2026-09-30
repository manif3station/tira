#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

# TKT-1201. The project standard for a refusal, set by TKT-268, is that it
# names the option that supplies the thing left out: checklist.add says
# "supply it with --item", question.ask says --text, evidence.add says --ref.
# Four commands were missed. Run with only --author they answered

#     comment.add             A comment needs some text
#     tasklist.add            Task text is required
#     tasklist.update         Task id is required
#     required-action.update  Required item or status is required
#
# each correct, each a refusal that wrote nothing, and each naming a thing
# rather than the option to type. The translation lives in %SUPPLIED_BY in
# lib/Tira/CLI/Usage.pm, where these four were simply absent.
#
# What is held here: each of the four names its option, each still refuses and
# writes nothing, and a call that does supply the value is unchanged.

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-09-30T03:40:00Z' } );
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Named', dir => $root, members => ['claude'],
    columns => ['backlog, implement, done'],
    sow_prefix => 'NMS', epic_prefix => 'NME', ticket_prefix => 'NMT',
);
my $card = $tira->create_record( project => $root, type => 'ticket',
    title => 'A card that a refused call must not touch', priority => 3 );

sub run {
    my ( $command, @argv ) = @_;
    my ( $out, $err, @warned ) = ( '', '' );
    open my $so, '>', \$out or die $!;
    open my $se, '>', \$err or die $!;
    my $status = do {
        local $SIG{__WARN__} = sub { push @warned, @_ };
        local *STDOUT = $so;
        local *STDERR = $se;
        local $ENV{TIRA_HOME} = $root;
        Tira::CLI->run( command => $command, tira => $tira, argv => [ '--author', 'claude', @argv ] );
    };
    return ( $status, $out . $err, \@warned );
}

sub snapshot {
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    my $tasks = eval { $tira->tasklist_list( project => $root, all_sessions => 1 ) } || [];
    return join '|', ( map { scalar @{ $shown->{$_} || [] } } qw(comments checklist required_items) ),
      scalar( @{$tasks} );
}

# command, arguments, the option the refusal must name
my @cases = (
    [ 'comment.add',            [ '--ref', $card->{ref} ],           '--text' ],
    [ 'tasklist.add',           [],                                  '--text' ],
    [ 'tasklist.update',        [],                                  '--id' ],
    [ 'tasklist.remove',        [],                                  '--id' ],
    [ 'required-action.update', [ '--ref', $card->{ref} ],           '--item' ],
);

my $before = snapshot();
for my $case (@cases) {
    my ( $command, $argv, $option ) = @$case;
    my ( $status, $said, $warned ) = run( $command, @$argv );

    isnt( $status, 0, "$command with the value left out is still refused" );
    # non-empty is the whole claim for this one: the assertions after it name the
    # option, and would pass vacuously against a command that said nothing.
    like( $said, qr/\S/, "$command says something about it" );
    like( $said, qr/\Q$option\E\b/, "$command names $option, the option that supplies it" );
    is_deeply( $warned, [], "$command emits no Perl warning at all" );
    unlike( $said, qr/uninitialized/, "$command prints no uninitialized-value text" );
}
is( snapshot(), $before, 'no refused call wrote anything to the card' );

# --- a call that does supply the value is unchanged -----------------------------

{
    my ( $status, $said ) = run( 'comment.add', '--ref', $card->{ref}, '--text', 'a real comment' );
    is( $status, 0, 'comment.add with --text still succeeds' );
    unlike( $said, qr/error/i, 'and says nothing about an error' );
    my $shown = $tira->record_show( project => $root, type => 'ticket', ref => $card->{ref} );
    is( scalar @{ $shown->{comments} || [] }, 1, 'and the comment was written' );
}

# --- and the snapshot can see a task, so 'nothing was written' means something --

{
    my $was = snapshot();
    my ( $status ) = run( 'tasklist.add', '--text', 'a real task' );
    is( $status, 0, 'tasklist.add with --text still succeeds' );
    isnt( snapshot(), $was, 'and the snapshot notices the new task, so it can catch a refused call that wrote one' );
}

done_testing;

__END__

=head1 NAME

1201-a-missing-value-that-names-its-option.t - comment.add, tasklist.* and required-action.update say which option to supply

=head1 DESCRIPTION

TKT-1201. C<comment.add>, C<tasklist.add>, C<tasklist.update> and
C<required-action.update> refused a missing value in words that named a thing
rather than the option to type, unlike C<checklist.add>, C<question.ask> and
C<evidence.add>. This file holds that each of the four names its option, still
exits non-zero, prints no Perl warning and writes nothing, and that a call which
supplies the value behaves as before.

=cut
