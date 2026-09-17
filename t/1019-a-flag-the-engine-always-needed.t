#!/usr/bin/env perl

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite qw(engine_source cli_source);

# TKT-1019, follow-up to TKT-712. Ten engine methods die unconditionally
# without an author - eight via Tira::_require_author (record_update,
# comment_update, evidence_add, gate_add, checklist_add, checklist_update,
# required_item_add, required_item_update) or their own inline check
# (column_remove, record_move) - and TIRA_AUTHOR lets a caller satisfy that
# without ever typing --author, so a usage line naming it in brackets is
# correct, not a lie. What is NOT correct is a usage line naming no --author
# at all: a reader has no way to learn the requirement exists.
#
# TKT-712 fixed five of these (checklist.add, checklist.update,
# required-action.add, comment.update, TYPE.update) for a live incident;
# TKT-712's own key_details claimed TYPE.update was one of the five fixed,
# but SKILLS.md's own tira.TYPE.update line (the record-verb catalogue,
# ~line 766) never named --author - only the vague catch-all
# "[record field arguments]" - so the claim was wrong. tira.TYPE.move
# carries the same gap: record_move's own inline die requires it, and the
# usage line names nothing.
#
# This is a source-level check, not a text-search-against-SKILLS.md one:
# %RECORD_USAGE in lib/Tira/CLI/Usage.pm is the single hash both the typed
# and untyped _usage() branches read (TKT-1005 extended the untyped branch
# to read it too), so the fix belongs there, and this test reads that hash
# directly rather than SKILLS.md's own prose - a documentation catalogue is
# a second true source no better than the first if a test just diffs one
# against the other.

# Maps each unconditional-author engine method to the documented usage line
# a reader actually sees: the two record verbs (update, move) answer through
# %RECORD_USAGE (TKT-1005), the rest through their own literal SKILLS.md
# line. Checking each against the wrong source would either miss a real gap
# (comment.update's --author is not in %RECORD_USAGE at all) or invent one
# (record_update's --author is not a literal SKILLS.md line since 5.153,
# only the %RECORD_USAGE entry SKILLS.md's catalogue quotes verbatim).
my %usage_source_for = (
    record_update       => [ record_usage => 'update' ],
    record_move         => [ record_usage => 'move' ],
    comment_update      => [ skills_line  => 'tira.comment.update' ],
    evidence_add        => [ skills_line  => 'tira.evidence.add' ],
    gate_add            => [ skills_line  => 'tira.gate.add' ],
    checklist_add       => [ skills_line  => 'tira.checklist.add' ],
    checklist_update    => [ skills_line  => 'tira.checklist.update' ],
    required_item_add   => [ skills_line  => 'tira.required-action.add' ],
    required_item_update => [ skills_line => 'tira.required-action.update' ],
    column_remove       => [ skills_line  => 'tira.column.remove' ],
);

my $source = engine_source();

# Bounded to each sub's own body (up to the next top-level 'sub ' or EOF) so
# a later sub's own _require_author call cannot be mistaken for an earlier
# one's - Codex review caught column_remove matching record_update's call
# this way in the first draft.
my %uses_inline_check = map { $_ => 1 } qw(record_move column_remove);

my @unconditional_author_subs;
for my $method ( sort keys %usage_source_for ) {
    my ($body) = $source =~ /sub \Q$method\E \{(.*?)(?=\nsub \w+ \{|\z)/s;
    next if !defined $body;
    my $requires_author =
        $uses_inline_check{$method}
      ? $body =~ /needs to say who is making it/
      : $body =~ /_require_author\(\%args\)/;
    push @unconditional_author_subs, $method if $requires_author;
}

is_deeply( [ sort @unconditional_author_subs ], [ sort keys %usage_source_for ],
    'the eight _require_author callers plus the two inline-check methods are exactly the unconditional-author set - an eleventh appearing here means this list is stale' );

my $cli_source     = cli_source('Usage.pm');
my ($record_usage_block) = $cli_source =~ /my \%RECORD_USAGE = \((.*?)\n\);/s;
ok( $record_usage_block, 'found %RECORD_USAGE to check the record verbs against' );

my $skills_text = do {
    local $/;
    open my $fh, '<', 'SKILLS.md' or die $!;
    <$fh>;
};

for my $method ( sort keys %usage_source_for ) {
    my ( $kind, $key ) = @{ $usage_source_for{$method} };
    my $line;
    if ( $kind eq 'record_usage' ) {
        ($line) = $record_usage_block =~ /^\s*\Q$key\E\s*=>\s*'([^']*)'/m;
        ok( defined $line, "\%RECORD_USAGE has an entry for $key" );
    }
    else {
        ($line) = $skills_text =~ /^\Q$key\E (.*)$/m;
        ok( defined $line, "SKILLS.md has a usage line for $key" );
    }
    like( $line // '', qr/--author/,
        "the usage line for $key names --author, which $method requires unconditionally" );
}

done_testing;

__END__

=head1 NAME

1019-a-flag-the-engine-always-needed.t - every unconditional --author requirement is named in its own usage line

=head1 DESCRIPTION

Eight engine methods refuse without an author via C<Tira::_require_author>,
and C<record_move>/C<column_remove> carry the identical requirement as
their own inline check - ten in total. C<TIRA_AUTHOR> lets a caller
satisfy any of them without typing C<--author>, so naming it in brackets
is correct - but C<record_update> and C<required_item_update> had a usage
line that named it not at all. This asserts every one of the ten is named
in its real documented source (%RECORD_USAGE for the two record verbs,
SKILLS.md's own line for the rest), so a future
method gaining the same requirement and no usage-line update fails here.

=cut
