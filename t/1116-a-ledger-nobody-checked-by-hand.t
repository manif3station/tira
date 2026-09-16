#!/usr/bin/env perl
# TKT-905. %OPTION_READ_BY's own reader lists (lib/Tira/CLI/Options.pm) were
# hand-walked once, on TKT-748, and never checked again - the walk that found
# history.list/search/replace missing from the `fields` entry, and question.ask
# /question.update silently dropping --status, was done by eye and is now
# frozen in a comment. A hand-walk nothing repeats is a walk that can go stale
# the moment a new reader is added and nobody happens to re-derive it.
#
# THE MECHANISM, traced this session: skills/{sow,epic,ticket}/cli/{create,
# update,move,...} are byte-identical copies of one generic dispatcher script
# that derives the real dispatched $command - for a single-segment type
# directory it becomes "record.$action" (record.create, record.update,
# record.move), never a type-prefixed form. lib/Tira/CLI.pm's own %method
# hash gives a direct command->sub map for most of the rest (checklist.*,
# comment.*, gate.*, evidence.*, required-action.*, attachment.*, search).
# A handful of literal $command eq '...' branches cover the remainder
# (history.list, replace, project.mode).
#
# SCOPE: this derives the ENGINE-side readers only (lib/ excluding
# lib/Tira/CLI), per this ticket's own KD2 recipe - a sub named in the
# engine that reads args{OPTION}, mapped back to the command(s) that reach
# it. sort/all_sessions/unlinked/mode were first assumed to be CLI-layer-
# only and skipped in an earlier draft - Codex review caught that
# assumption as wrong: tasklist_list itself (lib/Tira/Tasklist.pm) reads
# args{sort}/args{all_sessions}/args{unlinked} directly, search
# (lib/Tira.pm) reads args{all_sessions} too, and project_mode
# (lib/Tira.pm) reads args{mode} - all genuine engine reads this
# derivation was built to catch, not a real gap. A CLI-side walk (options
# read directly off $option->{FLAG} inside the dispatch chain itself,
# never reaching an engine args{} at all - e.g. how question_verbs
# constructs %question before calling the engine) remains real, separate
# further work: it has no sub-per-command boundary the way this file's own
# engine walk does, so it is not forced into a fragile derivation here.

use strict;
use warnings;

use Test::More;
use lib 't/lib';
use Suite qw(engine_source cli_source);

# The command -> engine-sub map, derived the same two ways the CLI itself
# dispatches: lib/Tira/CLI.pm's own %method hash (read out by name, the same
# table t/03-metadata.t and t/410 already parse), plus the handful of
# literal $command eq '...' branches %method does not cover. Read through
# Suite's own cli_source() rather than opening lib/Tira/CLI.pm by name -
# t/486's own rule, walking rather than naming, so a future lift of the
# %method table (the same shape TKT-837 already did once for this file's
# sibling tables) does not silently break this test's own claim.
my $cli = cli_source();

my ($method_block) = $cli =~ /my \%method\s*=\s*\((.*?)\n    \);/s;
ok( $method_block, 'found the %method table to read command->sub pairs from' );

my %command_to_sub;
while ( $method_block =~ /'([a-z][a-z0-9.\-]*)'\s*=>\s*'([a-z_][a-z0-9_]*)'/g ) {
    $command_to_sub{$1} = $2;
}
cmp_ok( scalar keys %command_to_sub, '>', 20,
    'the %method table produced a real number of command->sub pairs' );

# The literal branches %method does not cover, each confirmed this session by
# reading its own dispatch line in lib/Tira/CLI.pm or lib/Tira/CLI/Records.pm
# (question_verbs/tasklist's own individual $command eq '...' branches):
@command_to_sub{
    qw(record.create record.update record.move record.list
       history.list replace project.mode project.new onboard
       question.ask question.list question.answer question.update
       question.discard question.withdraw question.mark
       tasklist.list tasklist.add tasklist.update tasklist.unshift tasklist.slice)
} = qw(create_record record_update record_move record_list
       history_list replace_records project_mode project_mode project_mode
       question_add question_list question_answer question_update
       question_discard question_withdraw question_mark
       tasklist_list tasklist_add tasklist_update tasklist_unshift tasklist_slice);

# attachment.add is %method's own entry, but it dispatches to attachment_add,
# which never reads $args{comment} itself - it forwards the whole %args to
# attachment_add_content (a second, real reader), which is what actually
# reads it. Codex review caught this: the automatic derivation keys a
# command to the ONE sub %method names, so a forwarder whose own reads are a
# strict subset of the sub it calls is invisible to it. Overriding the one
# entry that forwards rather than teaching the walk to trace arbitrary call
# graphs - project_mode (above) has the same shape, called directly rather
# than forwarded to, so it needed no override.
$command_to_sub{'attachment.add'} = 'attachment_add_content';

# Reversed: which command(s) reach a given engine sub. More than one command
# can share a sub (create_record is reached by every type's own create verb
# through the same 'record.create' dispatch, since ticket/epic/sow all
# normalise to it - captured here as the single command 'record.create'
# rather than three, since that is the literal $command value every one of
# them actually dispatches as).
my %sub_to_commands;
while ( my ( $command, $sub ) = each %command_to_sub ) {
    push @{ $sub_to_commands{$sub} }, $command;
}

# --- the engine walk ---------------------------------------------------------
#
# For each .pm file outside lib/Tira/CLI, track the enclosing `sub NAME {`
# while scanning line by line, skipping POD blocks (=head1 ... =cut) so a
# match inside prose - TKT-748's own _replace_file false positive - is not
# mistaken for a real read. A private helper (name starts with `_`) is
# excluded from the derived reader set - TKT-748's OTHER false positive,
# _proof_entries_for, is called BY a real public reader, which is the one
# already accounted for.
my @engine_files;
{
    require File::Find;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
              return if !/\.pm\z/;
              return if $File::Find::name =~ m{\blib/Tira/CLI\b};
              push @engine_files, $File::Find::name;
          } },
        'lib' );
}
cmp_ok( scalar @engine_files, '>=', 4, 'the engine was walked - ' . scalar(@engine_files) . ' modules' );

my %option_readers;    # option name => { sub_name => 1, ... }

for my $file (@engine_files) {
    open my $fh, '<', $file or die "$file: $!";
    my $current_sub;
    my $depth = 0;
    my $in_pod = 0;
    while ( my $line = <$fh> ) {
        if ( $line =~ /\A=\w/ ) { $in_pod = 1; next }
        if ( $line =~ /\A=cut/ ) { $in_pod = 0; next }
        next if $in_pod;

        # Brace-depth tracked per line so a one-line forwarder
        # ("sub foo { ...; return Other::foo(@_) }", this file's own
        # attachment_*/gate_*-style lifts) closes before the next line,
        # rather than leaking its name onto every line until the next
        # "sub " - the false positive that made attachment_detach look
        # like it read --comment, when the real read is in a different
        # module entirely (Tira::Attachment, walked separately).
        if ( !$depth && $line =~ /\Asub\s+([A-Za-z_][A-Za-z0-9_]*)/ ) {
            $current_sub = $1;
        }
        my $opens  = () = $line =~ /\{/g;
        my $closes = () = $line =~ /\}/g;
        my $was_open = $depth > 0 || defined $current_sub;
        $depth += $opens - $closes;
        $depth = 0 if $depth < 0;    # a stray closing brace outside any sub
        my $closed_this_line = $was_open && $depth == 0;

        # The cleanup below must run even when this sub is skipped as
        # private - Codex review caught the earlier draft's `next` (before
        # this point) leaving a private sub's name attributed to every
        # later line until the next "sub " declaration overwrote it.
        if ( defined $current_sub && $current_sub !~ /\A_/ ) {
            while ( $line =~ /\$args\s*\{\s*([a-z_][a-z0-9_]*)\s*\}/g ) {
                $option_readers{$1}{$current_sub} = 1;
            }
        }
        $current_sub = undef if $closed_this_line;
    }
}

# --- the comparison -----------------------------------------------------------
#
# %OPTION_READ_BY is a lexical (`my`) hash in lib/Tira/CLI/Options.pm with no
# public accessor - read out of its own source the same way the %method
# table above is, via the same cli_source() (walking rather than naming
# lib/Tira/CLI/Options.pm, t/486's rule again).
my ($table_block) = $cli =~ /my \%OPTION_READ_BY = \((.*?)\n\);/s;
ok( $table_block, 'found the %OPTION_READ_BY table to read entries from' );

my %OPTION_READ_BY;
while ( $table_block =~ /\n    ([a-z_]+) => \{(.*?)\n    \},/gs ) {
    my ( $name, $body ) = ( $1, $2 );
    my ( $pattern, $x_flag ) = $body =~ /commands\s*=>\s*qr\/(.*?)\/(x?)\s*[,\n]/s;
    next if !defined $pattern;
    my $regex = $x_flag ? qr/$pattern/x : qr/$pattern/;

    # The engine reads $args{FLAG}, not $args{HASH_KEY} - they agree for
    # most entries but not all ('fields' the hash key, 'field' the flag
    # and the real args key comment_list's own unrelated --fields field-
    # selection option would otherwise be mistaken for a read of this
    # entry, since both happen to be spelled the same word pluralised).
    my ($flag) = $body =~ /flag\s*=>\s*'([a-z0-9_-]+)'/;
    next if !defined $flag;
    ( my $args_key = $flag ) =~ tr/-/_/;
    $OPTION_READ_BY{$name} = { commands => $regex, args_key => $args_key };
}
# Exact, not a floor: a '>=' here would still pass if the /x-flagged
# entries (text, status) silently dropped out of parsing again, the same
# regression Codex review caught once already (10 parsed instead of the
# real 12).
is( scalar keys %OPTION_READ_BY, 12,
    'parsed all 12 %OPTION_READ_BY entries, not a silently-shrunk subset' );

my @mismatches;
for my $name ( sort keys %OPTION_READ_BY ) {
    my $entry = $OPTION_READ_BY{$name};
    my $regex = $entry->{commands};
    my %seen_commands;
    for my $sub ( sort keys %{ $option_readers{ $entry->{args_key} } // {} } ) {
        for my $command ( @{ $sub_to_commands{$sub} // [] } ) {
            $seen_commands{$command} = $sub;
        }
    }
    my @uncovered = sort grep { !/$regex/ } keys %seen_commands;
    if (@uncovered) {
        push @mismatches,
          "$name: declared commands => $regex does not match "
          . join( ', ', map { "$_ (via $seen_commands{$_})" } @uncovered )
          . ' - a genuine engine reader this entry does not exempt';
    }
}

is_deeply( \@mismatches, [],
    'every engine reader of a %OPTION_READ_BY option is covered by that entry\'s own declared commands' )
  or diag( join( "\n", @mismatches ) );

done_testing;

__END__

=head1 NAME

1116-a-ledger-nobody-checked-by-hand.t - %OPTION_READ_BY's declared readers, derived rather than trusted

=head1 WHY

TKT-905: %OPTION_READ_BY's reader lists were hand-walked once (TKT-748) and
frozen as a comment nothing repeats. This test derives the engine-side half
of that walk mechanically - the command->sub map from lib/Tira/CLI.pm's own
%method table plus its literal dispatch branches, and the reader set from a
line-scan of every engine module tracking sub boundaries and skipping POD -
and fails naming any option whose declared `commands` regex does not cover
every command whose engine sub genuinely reads it.

=head1 SCOPE

Engine-side only, per this ticket's own KD2 split: a sub in lib/ (outside
lib/Tira/CLI) that reads C<$args{OPTION}>, mapped back to the command(s)
that reach it. All 12 %OPTION_READ_BY entries are covered by this
derivation, including sort/all_sessions/unlinked/mode - an earlier draft
wrongly assumed those four were CLI-layer-only and skipped them, which
Codex review caught: tasklist_list, search and project_mode all read them
as ordinary engine args{} reads. A genuinely CLI-layer-only read (an
option taken directly off $option->{FLAG} inside the dispatch chain
itself, never reaching an engine args{} at all - e.g. how question_verbs
constructs %question before calling the engine) has no sub-per-command
boundary this file's own engine walk can key on, and remains real,
separate further work rather than a fragile derivation forced in here.

=cut
