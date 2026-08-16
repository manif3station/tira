#!/usr/bin/env perl
# One way to say which board, not three.
#
# The owner's instruction, in his words: "fix that no more --project. all use
# TIRA_HOME=alias so TIRA_HOME always d2 paths alias and no command need
# --project anymore. All rely on environment variable either from .env or from
# %ENV ... So now will be only 1 way not 3."
#
# There were three: a flag, the environment, and discovery from the working
# directory. Three ways to say one thing is three behaviours to keep in
# agreement, and they had already stopped agreeing - the dashboard replaces the
# environment value from the working directory when that directory belongs to a
# project, so a value passed in was discarded rather than preferred. That cost
# an hour the night before this was written: a test believed it was measuring a
# board with one card in it and was measuring one with two hundred and thirty
# five, and it timed out rather than failing, which is the least useful way to
# be wrong.
#
# The internal name stays. The engine is told which board it is working on and
# always was; what goes is the flag on the command surface an agent types.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'board' );

my $tira = Tira->new( clock => sub {'2026-08-16T01:00:00Z'} );
$tira->project_new(
    name => 'One Way', dir => $root, members => ['claude'],
    columns => ['backlog, done'],
    sow_prefix => 'OWS', epic_prefix => 'OWE', ticket_prefix => 'OWT',
);
$tira->create_record( project => $root, type => 'ticket', title => 'On the board' );

sub run {
    my (@argv) = @_;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    my $status;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = Tira::CLI->run( command => 'record.list', type => 'ticket',
            tira => $tira, argv => \@argv );
    }
    return ( $status, $out, $err );
}

# --- the one way -----------------------------------------------------------

{
    local $ENV{TIRA_HOME} = $root;
    my ( $status, $out ) = run( '-o', 'json' );
    is( $status, 0, 'a board named in the environment is the board worked on' );
    like( $out, qr/OWT-001/, 'and the command answers about that board' );
}

# --- and not the other ------------------------------------------------------
#
# Asserted as a refusal rather than as an absence. A flag that is merely
# ignored looks identical to a flag that works until somebody checks what it
# did, which is how a caller ends up writing to a board it did not mean.

{
    local $ENV{TIRA_HOME} = $root;
    my ( $status, $out, $err ) = run( '--project', $root, '-o', 'json' );
    isnt( $status, 0, 'the flag is refused rather than ignored' );

    # non-empty is the whole claim: a precondition for the assertion below,
    # which would pass against a command that said nothing at all.
    like( $out . $err, qr/\S/, 'and says something about it' );
    like( $out . $err, qr/Unknown option|Invalid command-line/i,
        'naming it as an option the command does not have' );
}

# --- there is no second spelling of it -------------------------------------
#
# The parser is the thing that decides, so it is read directly. A test that
# only drove one command would pass while another kept its own copy.

{
    open my $source, '<', 'lib/Tira/CLI.pm' or die "CLI.pm: $!";
    my $text = do { local $/; <$source> };
    close $source;

    my @declared = $text =~ /'(project(?:=s)?)'\s*=>\s*\\\$option\{project\}/g;
    is_deeply( \@declared, [], 'no command declares a board-selecting option' );
}

done_testing;

__END__

=head1 NAME

220-one-way-to-say-which-board.t - one way, not three

=head1 DESCRIPTION

A board is named in the environment, by a name the machine resolves. The flag
that used to do it is refused rather than ignored, because a flag that is
ignored looks identical to one that works until somebody checks what it wrote.

Creating a board is not covered here and is not a selector: C<project.create>
takes the directory the board is about to be made in, which is where it goes
rather than which one to work on.

=cut
