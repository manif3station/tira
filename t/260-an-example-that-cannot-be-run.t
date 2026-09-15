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
#
# TKT-749. A fence line TOGGLES fenced/not-fenced, the same line-based
# approach t/433/t/876/t/1098 already use for exactly this reason - it does
# not care whether a fence carries a language tag, so a ```text opener pairs
# correctly with the next fence regardless of what follows the backticks.
# The earlier version matched literal /```\n(.*?)```/gs, which required an
# OPENER to have nothing after its backticks - a tagged opener never matched
# as one, so the regex skipped straight to that block's own CLOSING fence and
# used it as the next opener instead, inverting every pairing after it. Found
# live: adding a ```text block anywhere before the refusal examples took the
# refusal-block count this file checks from a real number to a wrong one, and
# the failure that produced ('0' >= '2') named nothing about fencing at all.
#
# AN UNPAIRED FENCE IS A REFUSAL WITH A REASON, not a silent drop of
# whatever was still open at end of file - the document itself is what is
# malformed then, and the message says which line opened the fence that
# never closed, not merely that a downstream count came out wrong.
#
# THE CLOSER HAS TO MATCH THE OPENER'S OWN CHARACTER. Codex review found
# the first version toggled on EITHER ``` or ~~~ with no memory of which
# one opened the block - so ``` ... ~~~ ... ``` ... ~~~ (four markers, an
# even count) silently paired a backtick opener with a tilde "closer" as
# two clean blocks, which is not what either Markdown or a person reading
# the document means by a fence. Reproduced directly: the un-tracked
# version returned 2 blocks for exactly that text, both wrong. Not a live
# bug today - docs/commands.md carries no ~~~ fence - but the "unpaired
# fence" diagnostic this file claims to give is only honest once a
# mismatched closer is refused the same way an unclosed one already is.
sub _fenced_blocks {
    my ($text) = @_;
    my ( @blocks, @current, $fenced, $opened_at, $opener );
    my $line_number = 0;
    for my $line ( split /\n/, $text, -1 ) {
        $line_number++;
        if ( $line =~ /^ {0,3}(```|~~~)/ ) {
            my $marker = $1;
            if ($fenced) {
                die "docs/commands.md line $line_number closes the fence "
                  . "opened at line $opened_at with $marker instead of $opener\n"
                  if $marker ne $opener;
                push @blocks, join( "\n", @current );
            }
            else {
                $opened_at = $line_number;
                $opener    = $marker;
            }
            @current = ();
            $fenced  = !$fenced;
            next;
        }
        push @current, $line if $fenced;
    }
    die "docs/commands.md line $opened_at opens a fence that is never closed\n"
      if $fenced;
    return @blocks;
}

my @blocks = _fenced_blocks($doc);
my @refusals = grep { /does not act on|is available on the/ } @blocks;

cmp_ok( scalar @refusals, '>=', 2,
    'the reference shows commands the tool refuses, which is worth showing' );

# --- a tagged opener does not invert pairing for what comes after it -------------
#
# Proved directly on a small, controlled document rather than on
# docs/commands.md itself - the live file is long enough that a single
# inserted tag does not reliably invert the real refusal count, which is
# exactly why this defect went unnoticed for as long as it did. Confirmed
# genuinely red against the PRE-FIX regex before this fix landed: replacing
# _fenced_blocks's body with the old /```\n(.*?)```/gs found 0 blocks in
# this fixture, not 2 - the tagged opener's own closing fence was read as an
# opener instead, and the real refusal text ended up as the ungrouped gap
# between two consumed delimiters rather than inside any captured block.

my $tagged_first = <<'TAGGED';
```text
a tagged block with no refusal wording in it at all
```

```
this command does not act on the board
```
TAGGED

my @tagged_blocks = _fenced_blocks($tagged_first);
is( scalar @tagged_blocks, 2,
    'a ```text opener is still recognised as an opener, so the fence after it '
      . 'pairs correctly instead of eating the real content as a gap' );
ok( ( grep { /does not act on/ } @tagged_blocks ),
    'and the refusal wording inside that correctly-paired block is still found' );

# An unpaired fence names itself rather than surfacing as a silent drop or an
# unrelated count mismatch three assertions later.
eval { _fenced_blocks("```\nnever closed\n") };
like( $@, qr/line 1 opens a fence that is never closed/,
    'an unpaired fence is refused by line number, not silently dropped' );

# A ``` opener cannot be closed by a ~~~ line, even though both are fence
# markers - an even count of mismatched markers used to pair cleanly with no
# memory of which character opened which block, found by Codex review.
eval {
    _fenced_blocks(
        "```\nreal content that never actually closed\n~~~\nmore\n```\n~~~\n"
    );
};
like( $@, qr/line 3 closes the fence opened at line 1 with ~~~ instead of ```/,
    'a mismatched closer is refused by name, not silently accepted as a pair' );

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
