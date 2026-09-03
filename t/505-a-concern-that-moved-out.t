#!/usr/bin/env perl
# The attachment concern, lifted out of the engine.
#
# TKT-746, EPC-007. lib/Tira.pm holds every command, rule and renderer in one
# file, so reading it to change one command means reading all of it. Three
# concerns have already been lifted - Tira::Toon, Tira::Tasklist, Tira::Render -
# and Tira::Job was written into its own module from the start for the same
# reason. This is the next one.
#
# MEASURED BEFORE THIS FILE WAS WRITTEN, at commit 51a22aa:
#
#     lib/Tira.pm                14,583 lines
#     the attachment concern     12 subs, ~457 lines, 3.1% of the file
#
#       _store_attachment_file    3468  ~34      attachment_get           4030  ~19
#       attachment_add            3802  ~13      attachment_remove        4049  ~18
#       attachment_add_content    3815  ~76      _attachment_content_type 4067  ~51
#       attachment_detach         3891  ~62      _attachment_head         4118  ~36
#       attachment_discard        3996  ~34      _record_attachments      4207  ~18
#       attachment_list           4225  ~78      _attachment_path        12512  ~18
#
# THE NUMBER IS MEASURED, NOT COPIED, and on this card that is the point rather
# than a nicety. Four places in the tree state this file's size - the card's own
# title says 14,621, README.md 14,177, SKILLS.md 14,256, lib/Tira/Job.pm 14,177
# - and all four are wrong. That is TKT-876. A count carried forward instead of
# taken is exactly how they got that way, so this file states what it measured
# and when.
#
# WHY ATTACHMENTS STAND ALONE. It is a complete named subsystem - store a file,
# sniff its type, read its head, attach it to a record, list, fetch, detach,
# discard - with private helpers already prefixed _attachment_*, and nothing
# outside it reaches into those helpers.
#
# WHAT IT NEEDS FROM Tira.pm, and why that is not a blocker: nine helpers,
# reached through $self - _atomic_write, _canonical_path, _load_yaml,
# _replace_record, _require_person, _slurp, _with_project_lock, _write_yaml.
# That is exactly how Tira::Job already works: the lifted module takes $self and
# calls back through it, so the helpers stay where they are and only the concern
# moves.
#
# WRITTEN RED. There is no lib/Tira/Attachment.pm.
#
# WHAT THIS FILE DOES NOT ASSERT, because something else already does it better:
#
#   - that the new module loads standing alone, and that every function it calls
#     resolves where it now sits. t/431 does that, and it WALKS lib/ rather than
#     naming modules, so it covers this one the moment it exists. Writing a
#     second version here would duplicate a general guard with a specific one,
#     which is how the specific one gets left behind.
#   - that behaviour did not change. The whole existing suite asserts that; a
#     lift is proved by the tests that passed before passing after, unchanged.
#   - a line count for lib/Tira.pm. Asserting a number here would create a FIFTH
#     claim to go stale, which is the defect this card sits next to.

use strict;
use warnings;

use Test::More;

use lib 'lib';
use lib 't/lib';
use Tira;

# t/486 stops tests reaching for lib/Tira.pm by name to find engine BEHAVIOUR,
# because behaviour moves between modules and a test that names a file goes
# stale the moment it does - which is this card's whole subject. This file is
# the sanctioned other case: what it asserts IS the composition of that one
# file. Whether a name in it is a forwarder or a body is not a fact about the
# engine's behaviour, and there is nowhere else to ask it.
my $engine = do {
    open my $fh, '<:raw', 'lib/Tira.pm' or die "lib/Tira.pm: $!";  # t/486 marker: about this file, not its code
    local $/;
    <$fh>;
};

# non-empty is the whole claim: every assertion below reads the engine's text,
# and an unreadable file would fail them all for the wrong reason.
like( $engine, qr/\S/, 'the engine source is there to be read' );

# --- the concern has somewhere of its own to live ----------------------------

ok( -f 'lib/Tira/Attachment.pm',
    'the attachment concern has its own module' );

# --- and the engine no longer holds its bodies -------------------------------
#
# A forwarder is one line and ends on the same line it starts. A body is not.
# Matching on that shape rather than on line counts keeps this true however the
# module is formatted later.

my @public = qw(
  attachment_add attachment_add_content attachment_detach
  attachment_discard attachment_get attachment_remove attachment_list
);

for my $name (@public) {
    my ($line) = $engine =~ /^(sub \Q$name\E\b[^\n]*)$/m;
    ok( defined $line, "the engine still answers to $name" )
      or next;
    like( $line, qr/\}\s*\z/,
        "and $name is a forwarder, not a body - the engine keeps the name and "
          . 'the module keeps the work' );
    like( $line, qr/require\s+Tira::Attachment/,
        "and $name loads the module AT THE CALL SITE, so a command that never "
          . 'touches an attachment never compiles it' );
}

# --- the private helpers went with it ----------------------------------------
#
# Leaving these behind would be the worst outcome: the module would call back
# into the engine for its own internals, and the concern would be split across
# two files rather than moved out of one.
#
# THE SPLIT BETWEEN THESE TWO LISTS WAS MEASURED, not guessed, and the first
# version of this file had it wrong. It demanded that all five private helpers
# vanish from the engine. Two of them have callers OUTSIDE the attachment
# concern:
#
#   _store_attachment_file  <- question_attach (3507), question_voice (3544)
#   _attachment_path        <- _backfill_added_at (2159)
#
# Questions attach files through the attachment store, so those calls are
# legitimate rather than a tangle to unpick here. The helpers still MOVE - they
# are attachment code - but the engine keeps the name as a forwarder, which is
# what this card means by "nothing that called it breaks". Demanding they vanish
# would have forced either a broken engine or the concern staying put.

for my $name (qw(_attachment_head _record_attachments)) {
    unlike( $engine, qr/^sub \Q$name\E\b/m,
        "$name went with the concern it belongs to, and nothing outside it "
          . 'ever called it' );
}

# THE SPLIT WAS MEASURED THREE TIMES AND WRONG TWICE, which is the honest
# record. First it demanded all five private helpers vanish; then two came back
# as forwarders because question_attach, question_voice and _backfill_added_at
# call them. Both of those searches looked inside lib/Tira.pm ONLY.
#
# _attachment_content_type is here because the third search finally looked at
# the whole tree: lib/Tira/CLI.pm and t/423 call it as Tira::_attachment_content_type,
# fully qualified across a file boundary. Nothing inside lib/Tira.pm calls it at
# all, so two searches in a row said it was free to leave, and the suite caught
# it - "Undefined subroutine &Tira::_attachment_content_type called at
# lib/Tira/CLI.pm line 919".
#
# The lesson is in the search, not the helper: a private name is private to a
# PACKAGE, not to a file, and Perl will let any module reach it by its full name.
for my $name (qw(_store_attachment_file _attachment_path _attachment_content_type)) {
    my ($line) = $engine =~ /^(sub \Q$name\E\b[^\n]*)$/m;
    ok( defined $line, "the engine still answers to $name" )
      or next;
    like( $line, qr/require\s+Tira::Attachment/,
        "$name moved but kept its name in the engine - the question concern "
          . 'calls it, and a lift must not break its callers' );
}

# --- the module is not loaded until it is needed ------------------------------
#
# The card asks for require at the CALL SITE rather than at the top of the file,
# and that is the whole benefit: the engine gets smaller to load, not just
# smaller to read.

unlike( $engine, qr/^use\s+Tira::Attachment/m,
    'the engine does not load the module at compile time' );

done_testing();

__END__

=head1 NAME

505-a-concern-that-moved-out.t - the attachment concern, lifted out of the engine

=head1 WHY

TKT-746. C<lib/Tira.pm> was 14,583 lines at commit 51a22aa and the attachment
concern was 12 subs and about 457 lines of it - a complete subsystem whose only
coupling to the engine is nine helpers reached through C<$self>, which is the
shape L<Tira::Job> already uses.

=head1 WHAT IS ASSERTED

That the concern MOVED: the module exists, the engine keeps the public names as
one-line forwarders that C<require> it at the call site, and the private
C<_attachment_*> helpers went with it rather than being left behind for the
module to call back into.

=head1 WHAT IS DELIBERATELY LEFT TO OTHER FILES

F<t/431> already resolves every function every module under C<lib/> calls, and
it walks the directory rather than naming modules - so it covers this one
automatically, and duplicating it here is how the general guard gets left
behind. Behaviour is proved by the existing suite passing unchanged, which is
what a lift means. And no line count is asserted here: four places in the tree
already state this file's size and all four are wrong (TKT-876), so a fifth
would be a liability rather than a check.

=cut
