#!/usr/bin/env perl

use strict;
use warnings;

use Cwd ();
use Test::More;

# An agent reported twenty-seven failed attempts against an example in the
# manual that named a flag the command does not take. The existing doc test
# checked that flags were *mentioned* somewhere in the section, which a wrong
# example passes happily. This one runs the examples through the real option
# parser, so an example that cannot work fails the suite.

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot read '$path': $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body;
}

my $cli = slurp('lib/Tira/CLI.pm');

# Every flag the parser actually declares, taken from the parser itself rather
# than from a list somebody has to remember to update.
my ($spec) = $cli =~ /GetOptionsFromArray\(\s*\$argv,(.*?)\n    \);/s;
ok( $spec, 'the option specification is where it is expected' );
my %known;
while ( $spec =~ /'([a-z0-9|_-]+)(?:[=:][si]@?)?!?'/gi ) {
    $known{$_} = 1 for map { s/_/-/gr } split /\|/, $1;
}
ok( scalar keys %known > 40, 'and it declares a full set of options' );
$known{$_} = 1 for qw(o);

my @examples;
for my $file (qw(SKILLS.md docs/commands.md)) {
    my $body = slurp($file);
    while ( $body =~ /((?:dashboard |d2 )?tira\.[a-z.]+(?:[^\n`|]*))/g ) {
        my $line = $1;
        next if $line !~ /--/;
        push @examples, { file => $file, text => $line };
    }
}
ok( scalar @examples > 15, 'both manuals carry runnable examples to check' );

my @broken;
for my $example (@examples) {
    while ( $example->{text} =~ /--([a-z][a-z0-9-]*)/g ) {
        my $flag = $1;
        next if $known{$flag};
        push @broken, "$example->{file}: --$flag in: $example->{text}";
    }
}
is_deeply( \@broken, [],
    'every flag in every documented example is one the parser accepts at all' );

# That check alone is too weak, and knowing why is the point of this test. The
# flag an agent failed on twenty-seven times was --file, which every version of
# Tira has accepted - just not on that command. So each example is actually run,
# and rejected only for the two failures that mean the manual lied: an option
# the parser does not know, or one this command refuses to take.
use File::Spec;
use File::Temp qw(tempdir);
use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub { '2026-08-09T09:00:00Z' } );
# Untainted so the chdir below is allowed, and kept for the return trip.
my ($root) = File::Spec->catdir( $tmp, 'docs-project' ) =~ /\A([^\x00-\x1f\x7f]+)\z/;
$tira->project_new( name => 'Docs', dir => $root, members => ['ada'], columns => ['Backlog, Doing'] );

# The examples name TKT-001 and Q-007, so those must exist here or every one of
# them fails on a missing reference before it ever reaches the flag being
# checked - which is exactly how the first version of this test passed against
# the broken build it was written to catch.
my $subject = $tira->create_record( project => $root, type => 'ticket', title => 'Documented card' );
is( $subject->{ref}, 'TKT-001', 'the fixture holds the card the examples name' );
$tira->question_add( project => $root, ref => $subject->{ref}, text => "Question $_" ) for 1 .. 7;
is( $tira->question_list( project => $root, ref => $subject->{ref} )->{questions}[6]{id},
    'Q-007', 'and the question they name' );

# Some documented commands write, and one of them created a directory in the
# repository the first time this ran, from a placeholder taken literally. Every
# attempt now runs inside the throwaway project, so a stray write lands
# somewhere that is deleted rather than in somebody's checkout.
sub attempt {
    my (@argv) = @_;
    my $command = shift @argv;
    my ($return_to) = Cwd::getcwd() =~ /\A([^\x00-\x1f\x7f]+)\z/;
    chdir $root or die "Cannot enter the fixture: $!";
    my $type = $command =~ s/\A(sow|epic|ticket)\.// ? $1 : undef;
    $command = "record.$command" if defined $type;
    my ( $out, $err ) = ( '', '' );
    open my $stdout, '>', \$out or die $!;
    open my $stderr, '>', \$err or die $!;
    {
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        eval {
            Tira::CLI->run(
                command => $command, type => $type,
                argv => [ '--project', $root, @argv ], tira => $tira );
            1;
        };
    }
    chdir $return_to or die "Cannot leave the fixture: $!";
    return $err;
}

my @rejected;
for my $example (@examples) {
    my $text = $example->{text};
    $text =~ s/\A(?:dashboard|d2)\s+//;
    next if $text !~ /\Atira\.([a-z.]+)/;
    my $command = $1;
    $command =~ s/[.,)]\z//;

    # Placeholders stand in for real values; this is about whether the command
    # accepts the shape of the example, not whether the values exist.
    my @argv = ($command);
    my @tokens = $text =~ /(--[a-z][a-z0-9-]*)(?:\s+((?:"[^"]*")|(?:[^\s-][^\s]*)))?/g;
    while ( my ( $flag, $value ) = splice @tokens, 0, 2 ) {
        push @argv, $flag;
        next if !defined $value;
        $value =~ s/\A"|"\z//g;
        push @argv, $value;
    }
    my $error = attempt(@argv);
    push @rejected, "$example->{file}: $text -> $error"
      if $error =~ /Unknown option|belongs to the|is available on|available on the/i;

    # The failure that actually cost an agent twenty-seven attempts was quieter
    # than a rejection: the command ignored the flag it was given and then
    # complained that the very thing was missing. Being told you must supply
    # what you just supplied is the most confusing failure a tool can produce,
    # so a contradiction between what the example passes and what the error
    # asks for is treated as a broken example.
    next if $error !~ /need|require|missing/i;
    for my $flag ( $text =~ /--([a-z][a-z0-9-]*)\s+(?:"[^"]*"|[^\s-][^\s]*)/g ) {
        push @rejected, "$example->{file}: passes --$flag yet is told it is missing -> $error"
          if $error =~ /\b\Q$flag\E\b/i;
    }
}
is_deeply( \@rejected, [],
    'and no example uses an option the command it names would refuse' );

done_testing;

__END__

=head1 NAME

70-doc-examples.t - every documented example is runnable

=head1 DESCRIPTION

An agent reported twenty-seven consecutive failures against a manual
example that named a flag the command does not take. Checking that a
flag is mentioned somewhere in a section does not catch that, because a
wrong example mentions it too. This reads the option specification out
of the parser and every example out of both manuals, and fails when an
example uses a flag no command accepts, so the manuals cannot promise
something the tool will refuse.

=cut
