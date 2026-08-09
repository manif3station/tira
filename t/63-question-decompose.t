#!/usr/bin/env perl

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tick = '2026-08-09T09:00:00Z';
my $tira = Tira->new( clock => sub {$tick} );

sub cli {
    my (@argv) = @_;
    my $command = shift @argv;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    local *STDOUT = $stdout;
    local *STDERR = $stderr;
    my $status = Tira::CLI->run( command => $command, argv => \@argv, tira => $tira );
    return ( $status, $out );
}

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new( name => 'Decompose', dir => $root, columns => ['Backlog, Doing'],
    sow_prefix => 'DCS', epic_prefix => 'DCE', ticket_prefix => 'DCT' );
my $card = $tira->create_record( project => $root, type => 'ticket', title => 'Importer' );

# A question from before any of this existed: everything crammed into the text,
# because that was the only field there was.
my $crammed = $tira->question_add(
    project => $root, ref => $card->{ref},
    text => 'Which store should this write to? Both are configured and the runbook '
      . 'names neither, so it could be staging, live, or block until told.',
);
ok( !defined $crammed->{reason}, 'a version-one question has no reason of its own' );
is_deeply( $crammed->{options}, [], 'and no options' );

# Taken apart in one command.
my $split = $tira->question_update(
    project => $root, id => $crammed->{id},
    text => 'Which store should this write to?',
    reason => 'Both are configured and the runbook names neither.',
    options => [ 'Staging', 'Live', 'Block until told' ],
);
is( $split->{text}, 'Which store should this write to?', 'the question is now just the question' );
is( $split->{reason}, 'Both are configured and the runbook names neither.', 'the reason is its own field' );
is_deeply( $split->{options}, [ 'Staging', 'Live', 'Block until told' ], 'and so are the choices' );
is( $split->{id}, $crammed->{id}, 'it keeps its reference, so anybody quoting it is not stranded' );
is( $split->{asked_at}, '2026-08-09T09:00:00Z', 'and when it was asked, because that has not changed' );

# Or one piece at a time, which is how an agent that works it out gradually goes.
my $second = $tira->question_add( project => $root, ref => $card->{ref},
    text => 'Everything crammed in here again' );
$tick = '2026-08-09T10:00:00Z';
my $step = $tira->question_update( project => $root, id => $second->{id}, reason => 'Only the reason.' );
is( $step->{reason}, 'Only the reason.', 'a reason can be set on its own' );
is( $step->{text}, 'Everything crammed in here again', 'and the text is left exactly as it was' );
is_deeply( $step->{options}, [], 'with no options invented' );

$step = $tira->question_update( project => $root, id => $second->{id}, options => [ 'One', 'Two' ] );
is_deeply( $step->{options}, [ 'One', 'Two' ], 'options can be set on their own' );
is( $step->{reason}, 'Only the reason.', 'without disturbing the reason already there' );
is( $step->{text}, 'Everything crammed in here again', 'or the text' );

$step = $tira->question_update( project => $root, id => $second->{id}, text => 'Just the question now?' );
is( $step->{text}, 'Just the question now?', 'and the text can be set on its own' );
is( $step->{reason}, 'Only the reason.', 'leaving the reason' );
is_deeply( $step->{options}, [ 'One', 'Two' ], 'and the options alone' );

# An agent that decides its reason was wrong must be able to take it back.
$step = $tira->question_update( project => $root, id => $second->{id}, reason => '' );
ok( !defined $step->{reason}, 'an empty reason clears it' );
is_deeply( $step->{options}, [ 'One', 'Two' ], 'without touching the options' );
$step = $tira->question_update( project => $root, id => $second->{id}, options => [] );
is_deeply( $step->{options}, [], 'and empty options clear them' );
is( $step->{text}, 'Just the question now?', 'still leaving the question itself' );

# Nothing named is a mistake worth saying out loud.
eval { $tira->question_update( project => $root, id => $second->{id} ) };
like( $@, qr/text, a reason, options, or a voice note/,
    'an update that changes nothing is refused, naming everything it could have changed' );
eval { $tira->question_update( project => $root, id => $second->{id}, text => '  ' ) };
like( $@, qr/needs some text/, 'and a question cannot be blanked' );

# Answering is unaffected by any of it.
$tira->question_answer( project => $root, id => $second->{id}, text => 'One.' );
is( $tira->question_list( project => $root, ref => $card->{ref} )->{questions}[1]{status},
    'answered', 'a decomposed question still answers normally' );

# The command line, in both shapes.
my ( $status, $out ) = cli( 'question.update', '--project', $root, '--id', $crammed->{id},
    '--reason', 'Reworded from the CLI', '-o', 'json' );
is( $status, 0, 'the CLI updates one piece' );
is( decode_json($out)->{reason}, 'Reworded from the CLI', 'and it lands' );
is( decode_json($out)->{text}, 'Which store should this write to?', 'leaving the rest alone' );

( $status, $out ) = cli( 'question.update', '--project', $root, '--id', $crammed->{id},
    '--text', 'All three at once?', '--reason', 'Because we can',
    '--option', 'Yes', '--option', 'No', '-o', 'json' );
is( $status, 0, 'and all three at once' );
my $all = decode_json($out);
is( $all->{text}, 'All three at once?', 'the text' );
is( $all->{reason}, 'Because we can', 'the reason' );
is_deeply( $all->{options}, [ 'Yes', 'No' ], 'and the choices' );

( $status, $out ) = cli( 'question.update', '--project', $root, '--id', $crammed->{id}, '-o', 'json' );
is( $status, 2, 'an update naming nothing exits 2' );

done_testing;

__END__

=head1 NAME

63-question-decompose.t - DD-482 taking a crammed question apart

=head1 DESCRIPTION

Every question asked before reason and options existed has all three
crammed into its text, because that was the only field there was. Those
questions are exactly the ones that most need choices, so an agent has
to be able to revisit one and split it into its three pieces, in a
single command or one at a time. Proves that only what is named
changes, that an explicitly empty value clears a piece while an absent
one leaves it alone, and that the question keeps its reference and the
time it was asked so nobody quoting it is stranded.

=cut
