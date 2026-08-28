#!/usr/bin/env perl

# --dry-run is accepted by every command and honoured by two.
#
# One global @spec parses every option for every command, so 'dry-run' at
# lib/Tira/CLI.pm:386 is available everywhere. Line 2680 then deletes it from
# %args along with the other CLI-only keys before dispatch - a correct guard,
# stopping presentation options leaking into the engine. Only bulk_import and
# replace_records read it.
#
# So tira.import --dry-run previews and writes nothing, tira.replace --dry-run
# previews and writes nothing, and tira.ticket.create --dry-run CREATES THE
# CARD. The word is not foreign to the vocabulary; it is honoured in one place
# and swallowed in another.
#
# Measured, not imagined. Probe commands were run against the board to discover
# which options ticket.create accepts, all but one of them carrying --dry-run in
# the belief that it prevented a write. They left eight live junk cards -
# TKT-617 through TKT-624 - every one discarded afterwards. The one probe that
# was refused was refused correctly: --affects-versions, with a did-you-mean
# pointing at --affects-version, which is TKT-298's unknown-option handling
# working, and it wrote nothing. The flag said the write would not happen and
# the write happened, eight times.
#
# Reproduced afterwards in a container against a board created inside it:
#
#   tickets before: 0
#   --- record.create --type ticket --title DRYRUN-PROBE --dry-run ---
#   column: backlog
#   ref: "PBT-001"
#   tickets after: 1
#   --- contrast: an option nothing knows ---
#   error: "Unknown option: not-a-flag"
#   tickets at end: 1
#
# The contrast is the whole argument. An option the parser does not know is
# refused by name and writes nothing. --dry-run walks past that guard precisely
# BECAUSE it is known - globally - while being unimplemented here.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;
use Tira::CLI;

my $tmp  = tempdir( CLEANUP => 1 );
my $tira = Tira->new( clock => sub {'2026-08-28T03:35:00Z'} );

my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name          => 'Dry runs', dir         => $root,
    members       => ['ada'],    columns     => ['backlog, done'],
    sow_prefix    => 'DRS',      epic_prefix => 'DRE',
    ticket_prefix => 'DRT',      author      => 'ada',
);

sub count_of {
    my ($type) = @_;
    my $list = eval { $tira->record_list( project => $root, type => $type ) } // [];
    return scalar @{$list};
}

sub run_cli {
    my (@argv) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    my $code = eval {
        Tira::CLI->run( command => 'record.create', tira => $tira, argv => \@argv );
    };
    select $old;
    return ( $code, ( $stdout // '' ) . ( $said // '' ) );
}

# --- the control: an option nothing knows is refused and writes nothing ------
#
# Without this the assertions below could pass on a board where creation is
# broken for some unrelated reason, which would prove nothing about --dry-run.

my $before_unknown = count_of('ticket');
my ( undef, $unknown_said ) = run_cli(
    '--type', 'ticket', '--title', 'Refused for a flag nobody knows',
    '--not-a-flag', 'x', '--author', 'ada', '-o', 'toon',
);
like( $unknown_said, qr/Unknown option: not-a-flag/,
    'an option the parser does not know is refused by name' );
is( count_of('ticket'), $before_unknown,
    'and nothing is written - which is what --dry-run should also do' );

# --- the fault: a flag whose entire meaning is DO NOT WRITE ------------------

my $before_dry = count_of('ticket');
my ( undef, $dry_said ) = run_cli(
    '--type', 'ticket', '--title', 'DRYRUN-PROBE',
    '--dry-run', '--author', 'ada', '-o', 'toon',
);
is( count_of('ticket'), $before_dry,
    'creating a ticket with --dry-run writes no ticket' );
like( $dry_said, qr/dry-run/,
    'and the caller is told what happened to the flag, rather than being shown a card that looks created' );

# --- the same for the sibling verbs that share the parser --------------------
#
# The card asks for this explicitly. They are one dispatch branch, so a fix that
# only reached tickets would be an accident of where it was written.

for my $type (qw(epic sow)) {
    my $before = count_of($type);
    run_cli( '--type', $type, '--title', "A $type nobody asked for",
        '--dry-run', '--author', 'ada', '-o', 'toon' );
    is( count_of($type), $before, "creating a $type with --dry-run writes no $type either" );
}

# --- the verbs that CHANGE a record, not only the ones that make one ----------
#
# The card's second acceptance criterion says "create and update verbs", and its
# deliverable says "every verb that shares the fault". A fix covering only create
# would be reading the first as "create" and the second as "some".

my $victim = $tira->create_record(
    project => $root, type => 'ticket', title => 'A card to change', author => 'ada',
);

sub run_verb {
    my ( $command, @argv ) = @_;
    local $ENV{TIRA_HOME} = $root;
    open my $out, '>', \my $stdout or die $!;
    open my $eh,  '>', \my $said   or die $!;
    local *STDERR = $eh;
    my $old = select $out;
    eval { Tira::CLI->run( command => $command, tira => $tira, argv => \@argv ) };
    select $old;
    return ( $stdout // '' ) . ( $said // '' );
}

my $update_said = run_verb( 'record.update', '--type', 'ticket', '--ref', $victim->{ref},
    '--title', 'CHANGED BY A DRY RUN', '--dry-run', '--author', 'ada', '-o', 'toon' );
like( $update_said, qr/does not act on --dry-run/,
    'updating with --dry-run is refused by name' );
my $unchanged = $tira->record_show( project => $root, type => 'ticket', ref => $victim->{ref} );
is( $unchanged->{title}, 'A card to change',
    'and the title is untouched - the criterion says create AND update' );

my $move_said = run_verb( 'record.move', '--type', 'ticket', '--ref', $victim->{ref},
    '--column', 'done', '--dry-run', '--author', 'ada', '-o', 'toon' );
like( $move_said, qr/does not act on --dry-run/, 'moving with --dry-run is refused by name' );
my $unmoved = $tira->record_show( project => $root, type => 'ticket', ref => $victim->{ref} );
is( $unmoved->{column}, 'backlog', 'and the card did not move' );

# A verb that is not a record verb at all. This is the assertion that separates
# an allow-list from a list of the four offenders someone happened to test: it
# was never named in the fix, and it must be refused anyway.

my $before_comments = scalar @{ $tira->record_show(
    project => $root, type => 'ticket', ref => $victim->{ref} )->{comments} // [] };
my $comment_said = run_verb( 'comment.add', '--type', 'ticket', '--ref', $victim->{ref},
    '--text', 'a comment nobody wanted', '--dry-run', '--author', 'ada', '-o', 'toon' );
like( $comment_said, qr/does not act on --dry-run/,
    'a verb the fix never named is refused too - the guard is an allow-list, not a list of offenders' );
my $after_comments = scalar @{ $tira->record_show(
    project => $root, type => 'ticket', ref => $victim->{ref} )->{comments} // [] };
is( $after_comments, $before_comments, 'and it wrote no comment' );

# Without this the assertion above would pass just as well on a board where
# comment.add is broken for some unrelated reason, which would prove nothing
# about the flag.
run_verb( 'comment.add', '--type', 'ticket', '--ref', $victim->{ref},
    '--text', 'a comment that should land', '--author', 'ada', '-o', 'toon' );
my $real_comments = scalar @{ $tira->record_show(
    project => $root, type => 'ticket', ref => $victim->{ref} )->{comments} // [] };
is( $real_comments, $before_comments + 1,
    'while the same command without the flag does write one - so the refusal is the flag, not a broken verb' );

# --- and the commands that honour it keep honouring it -----------------------
#
# --dry-run is not being removed from the vocabulary. tira.import and
# tira.replace preview with it and must go on doing so, or this fix would trade
# one surprise for a worse one.

my $kept = $tira->create_record(
    project => $root, type => 'ticket', title => 'A real card, to replace text in', author => 'ada',
);
$tira->record_update(
    project => $root, type => 'ticket', ref => $kept->{ref}, author => 'ada',
    description => 'the description says Jira in it',
);
# Through the CLI, not through the engine. Calling replace_records directly
# would prove the ENGINE still honours dry_run while saying nothing about
# whether the new allow-list lets the command reach it - the assertion would
# pass just as well if 'replace' had been misspelled in the guard.

my $replace_said = run_verb( 'replace', '--type', 'ticket', '--pattern', 'Jira',
    '--with', 'Tira', '--field', 'description', '--dry-run', '--author', 'ada', '-o', 'toon' );
like( $replace_said, qr/\bdry_run:\s*1\b/,
    'tira.replace --dry-run reports the flag back as honoured, so it reached replace_records through the CLI' );
like( $replace_said, qr/\bchanged_records:\s*1\b/,
    'and it previewed the one change it would have made' );
unlike( $replace_said, qr/does not act on --dry-run/,
    'and was not refused - it is one of the two commands the allow-list names' );
my $after = $tira->record_show( project => $root, type => 'ticket', ref => $kept->{ref} );
like( $after->{description}, qr/Jira/,
    'and a previewed replacement changed nothing - the flag still means what it means where it is read' );

# The same for import, which had no CLI assertion at all: a typo in the other
# half of the allow-list would have gone unnoticed.

my $changes_file = File::Spec->catfile( $tmp, 'changes.json' );
open my $cfh, '>', $changes_file or die $!;
print {$cfh} qq({"$kept->{ref}":{"description":"rewritten by an import"}});
close $cfh;
my $import_said = run_verb( 'import', '--type', 'ticket', '--file', $changes_file,
    '--dry-run', '--author', 'ada', '-o', 'toon' );
like( $import_said, qr/\bdry_run:\s*1\b/,
    'tira.import --dry-run reports the flag back as honoured too' );
like( $import_said, qr/rewritten by an import/,
    'and the preview shows the text it would have written' );
unlike( $import_said, qr/does not act on --dry-run/,
    'and was not refused either - the other half of the allow-list' );
my $after_import = $tira->record_show( project => $root, type => 'ticket', ref => $kept->{ref} );
like( $after_import->{description}, qr/Jira/,
    'and the import previewed rather than writing' );

done_testing();

__END__

=head1 NAME

t/413-a-flag-that-says-do-not-write-and-writes.t - C<--dry-run> must not create
a record on a command that does not implement it

=head1 DESCRIPTION

One global C<@spec> parses every option for every command, so C<--dry-run> is
accepted everywhere and read by C<bulk_import> and C<replace_records> alone.
C<tira.ticket.create --dry-run> therefore creates the card.

It cost eight junk cards on the live board - TKT-617 through TKT-624 - written
by probes that all carried the flag believing it prevented a write.

The control matters as much as the fault: an option the parser does not know is
refused by name and writes nothing. C<--dry-run> gets past that guard precisely
because it IS known, globally, while being unimplemented here. The last two
assertions hold the fix to not overcorrecting: the two commands that honour the
flag must go on honouring it.

=cut
