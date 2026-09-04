#!/usr/bin/env perl
# The messages the code prints are a surface too.
#
# The board's real location is kept from the agent working a project, so it
# cannot go round the CLI and edit the board's files directly. The suite
# enforces that in several places - SKILLS.md, three help surfaces, the
# question reference - and every one of them reads a document or a help screen.
# None reads the modules.
#
# So the decision is enforced on every surface a reader might be handed except
# the one the code itself produces, and that is where it drifted. Two guards
# added in the release before this one die with the selector spelled out, in a
# guard whose own comment says it says nothing about what it was given. It does
# not quote the value, which was the part I thought about. It names the flag,
# which tells a reader that a flag pointing at a board exists at all - and a
# reader who learns that goes looking for the board.
#
# Found by breaking the resolution deliberately and reading what came back,
# which is the only way any of these messages get read.

use strict;
use warnings;

use File::Find;
use Test::More;

use lib 't/lib';
use Suite ();
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $text;
}

my @modules;
find( sub { push @modules, $File::Find::name if -f && /\.pm\z/ }, 'lib' );
@modules = sort @modules;
ok( scalar @modules, 'there are modules to read' );

# What a message may not contain. The value itself is already covered where it
# matters; this is about the names, which are what a reader would act on.
my $selector = qr/--project\b|TIRA_HOME/;

my @naming;
for my $path (@modules) {
    my $source = slurp($path);
    my $line   = 0;
    for my $text ( split /\n/, $source ) {
        $line++;

        # Comments explain why the rule exists and have to be able to say what
        # they are talking about. Only what gets printed is in question.
        next if $text =~ /\A\s*#/;
        next if $text !~ /\b(?:die|croak|warn)\b/;
        next if $text !~ $selector;
        push @naming, "$path:$line";
    }
}

# The diag is a separate statement. Written as a postfix for on the assertion
# it read as one thing and ran as another: the whole assertion once per fault,
# so a suite with three faults reported three failures of one test and the plan
# moved with the bug. Caught by running it red, which is the only reason to.
diag("names the selector: $_") for @naming;
is_deeply( \@naming, [],
    'no message the code prints names how a board is selected' );

# --- and the guard that started this, by hand ------------------------------
#
# Asserted on the module rather than through a call, because both of these are
# floors under a mistake already made once: the CLI resolves before it serves,
# so reaching them at all means something upstream is wrong.

# The engine rather than the dashboard module by name, since TKT-921: what the
# claim needs is "a refusal the code prints", and which file prints it is the
# thing that keeps moving. Wider than it was, and the wider version is the one
# the assertion above already makes over every file that can carry a message.
my $web = Suite::engine_source();
my @refusals = $web =~ /die\s+"([^"]*)"/g;
ok( scalar @refusals, 'the engine refuses things' );
unlike( join( ' ', @refusals ), $selector,
    'and none of those refusals names the selector' );

# It still has to say something a reader can act on. A message emptied of
# everything useful passes the check above and helps nobody, which would be the
# obvious wrong way to make this pass.
my ($serving) = grep { /Serving a board/ } @refusals;
ok( $serving, 'the refusal for serving without a board is still there' );
like( $serving, qr/\S/, 'non-empty is the whole claim: it still says something' );

done_testing;

__END__

=head1 NAME

215-what-a-refusal-may-name.t - the messages the code prints are a surface too

=head1 DESCRIPTION

The board's location is kept from the agent working a project. That is enforced
on SKILLS.md, on help text and on the question reference, all of which are
documents. Nothing read the modules, and the decision drifted there: two guards
died with the selector spelled out.

This reads every module and asks the same question of anything it prints. The
guard that started it is also asserted by hand, along with the fact that it
still says something - a message emptied of content would pass a check for what
it must not contain, and help nobody.

=cut
