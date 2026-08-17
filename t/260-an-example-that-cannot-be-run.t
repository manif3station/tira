#!/usr/bin/env perl
# A documented command that the tool refuses says so on the line itself.
#
# Reported by zen-framework, measured on their board: tira.usage shows
#
#     d2 tira.ticket.move --ref TKT-001 --column implement --sdlc-gate G9
#
# and running that shape exits 2 with nothing moved. They are careful about
# what they are asking for: the refusal is right, the exit code is right, the
# message names the fix, and they are not asking for any of it to change. The
# defect is that the documentation shows a command the tool rejects, so anyone
# following it writes a command that cannot work.
#
# The block does explain itself - the refusal is printed underneath each
# command - but an indented line under a command reads as that command's
# OUTPUT, which is how a successful example is usually laid out. A reader
# scanning for a shape to copy, human or otherwise, takes the first line.
#
# So the marker goes on the line being copied. tools/docs-examples-run cannot
# catch this: it sets these aside for carrying TKT-001, a shape a reader must
# replace, so a documented command that can never work is never executed.

use strict;
use warnings;

use Test::More;

my $doc = do {
    open my $fh, '<:encoding(UTF-8)', 'docs/commands.md' or die "docs/commands.md: $!";
    local $/;
    <$fh>;
};

# --- the blocks that show a refusal ---------------------------------------------

my @blocks = $doc =~ /```\n(.*?)```/gs;
my @refusals = grep { /does not act on|is available on the/ } @blocks;

cmp_ok( scalar @refusals, '>=', 2,
    'the reference shows commands the tool refuses, which is worth showing' );

# --- and every command in them says so, on the line itself -----------------------
#
# The line a reader copies is the command, so that is where it has to be said.
# The explanation underneath is the reason, not the warning.

{
    my @unmarked;
    for my $block (@refusals) {
        for my $line ( split /\n/, $block ) {
            next if $line !~ /\A\S/;          # the indented lines are the reasons
            next if $line !~ /\bd2 tira\./;
            push @unmarked, $line if $line !~ /#\s*refused/;
        }
    }

    is_deeply( \@unmarked, [],
        'every command shown only to be refused is marked refused on its own line' );
}

# --- and the marker survives being copied ---------------------------------------
#
# A reader who copies the whole line gets a comment, which the shell drops. A
# marker that had to be deleted before the line would run would be one more
# thing to get wrong.

{
    my ($example) = $doc =~ /^(d2 tira\.\S+[^\n]*#\s*refused[^\n]*)$/m;
    ok( $example, 'a marked example is there to look at' ) or diag 'none found';
    like( $example // '', qr/\A\S+\s/, 'and it is still a command a shell would parse' );
    unlike( $example // '', qr/#\s*refused.*d2 /,
        'with the marker at the end, so nothing after it is lost' );
}

# --- while a working example is not marked ---------------------------------------
#
# The marker has to mean something. If everything carried it, it would say
# nothing, and this is the assertion that keeps it honest.

{
    my $marked_everywhere = () = $doc =~ /#\s*refused/g;
    my $marked_in_refusals = 0;
    for my $block (@refusals) {
        $marked_in_refusals += () = $block =~ /#\s*refused/g;
    }

    is( $marked_everywhere, $marked_in_refusals,
        'nothing outside a refusal block carries the marker, so it still means something' );

    my @elsewhere = grep { /\bd2 tira\./ && !/#\s*refused/ }
      map { split /\n/, $_ } grep { !/does not act on|is available on the/ } @blocks;
    cmp_ok( scalar @elsewhere, '>', 0,
        'and the reference does show commands that work, unmarked' );
}

done_testing;

__END__

=head1 NAME

260-an-example-that-cannot-be-run.t - a documented command the tool refuses

=head1 DESCRIPTION

C<tira.usage> showed C<d2 tira.ticket.move --ref TKT-001 --column implement
--sdlc-gate G9>, which exits 2 and moves nothing. The refusal is right; the
documentation showing the shape without saying so on the line is not.

C<tools/docs-examples-run> cannot catch it - these examples are set aside for
carrying C<TKT-001>, a shape a reader must replace - so the marker is asserted
here instead.

=cut
