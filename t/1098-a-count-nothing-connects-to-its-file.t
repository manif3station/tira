#!/usr/bin/env perl

# TKT-724. t/876 solved this for one file (lib/Tira.pm) after that
# figure went stale three times in one card, self-found by eye each
# time. Every other "lib/<path> is N lines" claim in SKILLS.md,
# README.md and Changes was still held by nothing - only correct as
# long as nobody touched the file it described.
#
# Generalises t/876's own pattern (itself modeled on t/430's threshold
# check and t/03-metadata's shipped-name check) from one hard-coded file
# to any lib/<path> a claim names, and extends the walk from markdown
# documents to Perl module headers too - t/876's own "WHAT IS NOT
# ASSERTED" list already named this as the wider fault, not fixed there
# because fixing the class is not the same work as the refactor that
# exposed it.
#
# SCOPE, deliberately narrower than every "N lines" sentence in this
# codebase: only a claim of the shape "lib/<path> is N lines" - the
# file's own CURRENT TOTAL line count, present tense. Checked against
# the real corpus (grep) before writing this: every module-header "N
# lines" sentence today names a SUBSET instead - "249 lines of bodies",
# "575 lines of subs", "187 lines" for one sub, one command's own body -
# a genuinely different, not mechanically wc-l-comparable measurement,
# and none of today's module headers make a resolvable whole-file claim
# at all. That is a real, checked absence, not a gap in this test: the
# guard still exists to catch the day one is written.  A count with no
# file to measure against ("four guards on the move path") has no file
# name in it at all, so it never matches this pattern in the first
# place - t/428 covers that family properly, and it is out of scope
# here by construction, not by exclusion list.
#
# WRITTEN RED against the sub reading real claims from the fixture, not
# against the real corpus - the same as t/876's own control test. Looked
# hard for a second real drift first: SKILLS.md's "lib/Tira/Tasklist.pm
# - the shared to-do queue, 692 lines" and its sibling for Render.pm
# looked like candidates, but are lift-moment measurements ("at TKT-832,
# 5.24") the same way README's own "was 15,264 lines" is - correctly
# historical, not a live claim, and this regex correctly does not match
# either (no "is N lines" verb-object shape).
#
# CODEX REVIEW found a genuine, currently-stale second real claim this
# draft's own 40-character proximity window missed: README.md's own
# "`lib/Tira/CLI.pm` was 6,048 lines with every command body in it, and
# is 2,939 now" - the file is 2,485 lines. Fixed two things: the file
# association is now nearest-preceding-in-paragraph rather than a fixed
# window (see _live_claims_in below), and the stale prose itself was
# corrected to restate "lines" explicitly rather than the elliptical
# "is N now", which this guard - deliberately - does not try to parse.

use strict;
use warnings;

use File::Find ();
use File::Spec ();
use Test::More;

# --- what counts as a live claim, generalised from t/876's own regex -------
#
# CODEX REVIEW: a fixed proximity window between the file name and "is N
# lines" missed a real, live claim - README.md's own "`lib/Tira/CLI.pm`
# was 6,048 lines with every command body in it, and is 2,939 now" names
# the file, then states the past figure, THEN the live one, more than 40
# characters later. Rather than widen the window (which risks crossing
# into a NEXT file's own claim in a paragraph naming several, as this
# same paragraph does), each "is N lines" match is paired with the
# NEAREST PRECEDING file mention anywhere earlier in the same paragraph
# - correct here because a paragraph names a file once before describing
# its size, never restates it mid-description the way "was X ... is Y"
# does for the SAME file.
#
# Also tracks which original line each match started on (not just the
# paragraph's first line) - CODEX REVIEW again: reporting only the
# paragraph's start line made an unresolvable-claim diagnostic name the
# wrong line for any claim after the first in a multi-line paragraph.

sub _live_claims_in {
    my ($text) = @_;
    my ( @claims, $fenced, @paragraph, @paragraph_lines );

    my $flush = sub {
        return if !@paragraph;
        my $joined = join ' ', @paragraph;

        # Map a character offset in $joined back to the source line it
        # came from, accounting for the single space _joining_ lines.
        my @offsets;
        my $running = 0;
        for my $i ( 0 .. $#paragraph ) {
            push @offsets, $running;
            $running += length( $paragraph[$i] ) + 1;
        }
        my $line_for = sub {
            my ($offset) = @_;
            my $line = $paragraph_lines[0];
            for my $i ( 0 .. $#offsets ) {
                $line = $paragraph_lines[$i] if $offsets[$i] <= $offset;
            }
            return $line;
        };

        my @files;
        while ( $joined =~ /\b(lib\/[\w\/.-]+?\.pm)\b/g ) {
            push @files, { file => $1, pos => pos($joined) };
        }
        while ( $joined =~ /\bis\b(?:\s+now)?\s+([\d,]+)\s+lines\b/g ) {
            my $match_start = pos($joined) - length($&);
            my ($nearest) = sort { $b->{pos} <=> $a->{pos} }
              grep { $_->{pos} <= $match_start } @files;
            next if !$nearest;
            push @claims, { line => $line_for->($match_start), file => $nearest->{file}, claimed => $1 };
        }
        @paragraph      = ();
        @paragraph_lines = ();
    };

    my $line_number = 0;
    for my $line ( split /\n/, $text, -1 ) {
        $line_number++;
        if ( $line =~ /^ {0,3}(?:```|~~~)/ ) { $flush->(); $fenced = !$fenced; next }
        if ($fenced)                         { next }
        if ( $line !~ /\S/ )                 { $flush->(); next }
        if ( $line =~ /^ {0,3}(?:[-*+]|\d+[.)])\s/ ) { $flush->() }
        push @paragraph, $line;
        push @paragraph_lines, $line_number;
    }
    $flush->();
    return \@claims;
}

# Perl comments read as continuous prose the same way a markdown
# paragraph does, but a bare "#" strip is enough - the matcher above
# already treats each accumulated line as free text, and code lines
# (which do not start with #) simply never accumulate into a paragraph
# a claim could hide inside.
sub _live_claims_in_perl {
    my ($text) = @_;
    my $prose = join "\n", map { /^\s*#\s?(.*)/ ? $1 : '' } split /\n/, $text, -1;
    return _live_claims_in($prose);
}

# --- the control: names two different files, one wrong, one right, one ----
# unresolvable, one past-tense, one a comparison -----------------------------

my $fixture = <<'FIXTURE';
lib/Tira.pm was 15,264 lines before the first lift.

lib/Tira.pm is 14,164 lines after four lifts, down from 15,264.

`lib/Tira.pm` is
14,164 lines so far, measured at the fourth lift.

lib/Tira/Widget.pm was 6,048 lines with everything in it, and is
2,939 lines now, split across several smaller modules.

lib/Tira/Nowhere.pm is 40 lines, a file this test made up to prove an
unresolvable claim is reported rather than passed silently.

lib/../../etc/Escape.pm is 999 lines, a claim that would escape lib/
if it were ever trusted rather than refused.
FIXTURE

my $fixture_claims = _live_claims_in($fixture);
is_deeply(
    [ map { [ $_->{file}, $_->{claimed} ] } @{$fixture_claims} ],
    [   [ 'lib/Tira.pm',         '14,164' ],
        [ 'lib/Tira.pm',         '14,164' ],
        [ 'lib/Tira/Widget.pm',  '2,939' ],
        [ 'lib/Tira/Nowhere.pm', '40' ],
        [ 'lib/../../etc/Escape.pm', '999' ],
    ],
    'the two live lib/Tira.pm claims are found, the "was X... is Y now" shape names the '
      . 'right file even though the number is on the next line, and so are the unresolvable '
      . 'and the escaping ones - neither the past-tense claim nor the comparison is' );

{
    my ($unresolvable) = grep { $_->{file} eq 'lib/Tira/Nowhere.pm' } @{$fixture_claims};
    ok( !-f $unresolvable->{file}, 'sanity: the made-up file genuinely does not exist' );
}

{
    my ($escaping) = grep { $_->{file} =~ /Escape/ } @{$fixture_claims};
    ok( $escaping->{file} =~ m{(?:^|/)\.\.(?:/|\z)}, 'sanity: the escaping claim is genuinely detected as escaping' );
}

# --- every prose document that might carry a live claim ---------------------

my @documents;
File::Find::find(
    {   no_chdir  => 1,
        # CODEX REVIEW: filtering cover_db/node_modules/.git only in
        # wanted() still descends INTO them first - pruned here instead,
        # so a real .git or a stray cover_db is never walked at all.
        preprocess => sub {
            return @_ if $File::Find::dir !~ m{(?:^|/)(?:cover_db|node_modules|\.git)\z};
            return ();
        },
        wanted   => sub {
            # Changes carries no extension at all - a plain /\.md\z/ walk
            # (t/876's own) silently never reached it, though the
            # acceptance criteria name it explicitly. Matched by basename
            # instead of guessing at more un-extensioned files.
            return if !/\.md\z/ && $File::Find::name !~ m{(?:^|/)Changes\z};
            push @documents, $File::Find::name;
        },
    },
    '.'
);
cmp_ok( scalar @documents, '>=', 3, 'the documents were walked' );
ok( ( grep { m{(?:^|/)Changes\z} } @documents ), 'Changes itself is among them, despite carrying no extension' );

my @modules;
File::Find::find(
    { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm\z/ } },
    'lib' );
cmp_ok( scalar @modules, '>=', 4, 'the module headers were walked - ' . scalar(@modules) . ' modules' );

my @claims;
for my $document ( sort @documents ) {
    open my $fh, '<', $document or die "$document: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    push @claims, map { { %{$_}, in => $document } } @{ _live_claims_in($text) };
}
for my $module ( sort @modules ) {
    open my $fh, '<', $module or die "$module: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    push @claims, map { { %{$_}, in => $module } } @{ _live_claims_in_perl($text) };
}

cmp_ok( scalar @claims, '>=', 1,
    'at least one live claim exists - '
      . join( ', ', map { "$_->{in}:$_->{line} names $_->{file} as $_->{claimed}" } @claims ) );

# CODEX REVIEW: the claim pattern's own character class allows '..', so
# a claim reading "lib/../../etc/passwd is N lines" would resolve
# outside lib/ entirely rather than naming a real module - refused as
# unresolvable rather than ever handed to -f.
my ( @checked, @unresolvable );
for my $claim (@claims) {
    if ( $claim->{file} =~ m{(?:^|/)\.\.(?:/|\z)} ) { push @unresolvable, $claim }
    elsif ( -f $claim->{file} )                     { push @checked, $claim }
    else                                             { push @unresolvable, $claim }
}

is_deeply( \@unresolvable, [],
    'every claim resolves to a real file under lib/ - none of today\'s real claims name one that is missing' )
  or diag( join( "\n", map { "  $_->{in}:$_->{line} names $_->{file}, which does not exist" } @unresolvable ) );

for my $claim (@checked) {
    my $real = do {
        open my $fh, '<', $claim->{file} or die "$claim->{file}: $!";
        my $n = 0;
        $n++ while <$fh>;
        close $fh;
        $n;
    };
    ( my $formatted = reverse $real ) =~ s/(\d{3})(?=\d)/$1,/g;
    $formatted = reverse $formatted;
    is( $claim->{claimed}, $formatted,
        "$claim->{in}:$claim->{line} - '$claim->{file} is $claim->{claimed} lines' "
          . "matches the real, measured count ($formatted)" );
}

done_testing;

__END__

=head1 NAME

1098-a-count-nothing-connects-to-its-file.t - every "lib/<path> is N lines" claim, anywhere, matches the real file

=head1 DESCRIPTION

TKT-724. A factual claim naming a file under C<lib/> and a present-tense
line count is held to that file's real, measured C<wc -l> - generalised
from t/876's single hard-coded C<lib/Tira.pm> case to any such claim, in
SKILLS.md, README.md, Changes, and every module's own header. A claim
naming a file that does not exist - or one that escapes C<lib/> via
C<..> - is reported explicitly rather than silently passed or resolved
outside the tree. Codex review found a genuine, currently-stale real
claim this guard's first draft missed (README.md's own
C<lib/Tira/CLI.pm> figure, corrected alongside it) - not fabricated for
the test.

=head1 WHAT IS NOT ASSERTED

A past-tense claim narrating history, a "down from" comparison, or a
"N lines of <subset>" claim - none of which name the file's own current
total, the same distinction t/876 already draws. A count with no file
name in it at all ("four guards on the move path") never matches this
pattern by construction; t/428 covers that family.

=cut
