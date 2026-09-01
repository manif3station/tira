#!/usr/bin/env perl
# A priority scale says which end is urgent.
#
# He asked why a card he had raised as urgent was showing as "1 Low". The answer
# is that Tira's scale runs the other way from the one everybody says out loud:
# 5 is Very High here, and P1 means most urgent almost everywhere else.
#
# Nothing anywhere said so. The validator refuses anything outside 1 to 5 and
# stops there. tira.usage does not mention priority. The command reference does
# not mention it. The only place the direction is written down is a JavaScript
# label map inside a minified string in the dashboard, and a sort beside it.
#
# So it was gettable wrong in silence, and it was got wrong: every card raised
# with --priority 1 meaning "top" was recorded as Low and sorted to the bottom
# of the column he was reading. He corrected two of them through the dashboard
# without saying anything -
#
#     TKT-177  set to 1 at 17:31:47, changed to 5 at 17:33:04
#     TKT-166  set to 2 at 12:57:07, changed to 5 at 13:13:04
#
# - and the agent never noticed, because nothing would have told it.
#
# The direction itself is not the fault and is not changed here. Either
# convention is defensible; only one is implemented, and the fault is that it
# was implemented in three places and stated in none.
#
# TKT-171 depends on this. It adds a rule reporting work taken out of priority
# order, and its first draft was written with the scale inverted - a guard that
# would have enforced exactly the wrong order while looking like a guard.

use strict;
use warnings;

use File::Find ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

# --- the reader who has only the command line -------------------------------------
#
# The refusal is where somebody who typed a wrong priority meets the scale, so
# it is the one place that reaches a reader who is not reading documentation.

my $tmp = tempdir( CLEANUP => 1 );
my $tira = Tira->new;
my $root = File::Spec->catdir( $tmp, 'proj' );
$tira->project_new(
    name => 'Ordering', dir => $root, members => ['michael'],
    columns => ['backlog, done'],
    sow_prefix => 'ORS', epic_prefix => 'ORE', ticket_prefix => 'ORT',
);

ok( !eval {
        $tira->create_record( project => $root, type => 'ticket',
            title => 'Out of range', priority => 9 );
        1;
    },
    'a priority outside the scale is refused' );

my $refusal = $@;
like( $refusal, qr/1 to 5/, 'and the refusal gives the range' );
like( $refusal, qr/\b5\b[^\n]*\b(?:urgent|highest|most)\b|\b(?:urgent|highest|most)\b[^\n]*\b5\b/i,
    'and says which end of it is urgent, which is the whole of this card' );

# --- the copies agree ------------------------------------------------------------------
#
# The direction lives in a label map the browser reads, a second label map the
# human and markdown renderers print, a sort, and the refusal. Four copies of
# one decision is what let this drift unnoticed; they cannot be reduced to one
# - a browser cannot read a Perl string and a refusal cannot be a JavaScript
# object - so instead they are checked against each other.
#
# They were not. This file said that sentence from the day it was written and
# read exactly one of the two label maps: the browser's. The renderers' table
# was covered by luck, because t/09 pins one card's output to 'Priority: Very
# High', so 5 was held and 1 through 4 were not - swapping Low and Medium Low
# in one copy passed the whole suite, and the result would be a board reading
# one way in the browser and another on the command line, about the one field a
# reader can already get exactly backwards.
#
# A claim in a header that describes something other than what the file does is
# the fault this file exists to catch, one level up. TKT-207.

# WALKED, NOT NAMED. This read 'lib/Tira.pm' by name and broke the moment
# TKT-834 lifted the renderers into lib/Tira/Render.pm - the third time a
# test in this suite has asserted where code lives while claiming to assert
# something else, and the third time the test was the thing that was wrong
# (t/64, t/144, t/244 and t/289 all did it before, and TKT-703 patched this
# very file by naming a second location rather than by walking). The label
# map has to agree with the dashboard's wherever either one sits, so the
# Perl half is now found by reading every module under lib/. Same reasoning
# as t/429 and t/431, which walk for exactly this reason.
my $source = '';
{
    my @modules;
    File::Find::find(
        { no_chdir => 1, wanted => sub { push @modules, $File::Find::name if /\.pm\z/ } },
        'lib' );
    cmp_ok( scalar @modules, '>=', 4,
        'lib/ was walked for the Perl half - ' . scalar(@modules) . ' modules' );
    for my $module ( sort @modules ) {
        open my $fh, '<:raw', $module or die "$module: $!";
        local $/;
        $source .= <$fh>;
    }
}

# TKT-703 moved the dashboard's scripts out of lib/Tira.pm into
# lib/Tira/views, so the JS half of this comparison is read from there - and
# TKT-834 later moved the Perl half into lib/Tira/Render.pm, which is why the
# block above walks lib/ instead of naming a file. The point of the test is
# unchanged and is the reason it must follow the code: the two label maps have
# to agree, and they live in different files, which is exactly when they drift.
# Every script, not a named one, for the same reason: the labels and the sort
# comparator sit in different files and a test that had to know which would
# break on the next move without anything actually being wrong.
my $views = File::Spec->catdir( 'lib', 'Tira', 'views' );
opendir my $dh, $views or die "$views: $!";
my @scripts = sort grep { /\.js\z/ } readdir $dh;
closedir $dh;
my $script = '';
for my $name (@scripts) {
    open my $fh, '<:encoding(UTF-8)', File::Spec->catfile( $views, $name )
      or die "$name: $!";
    local $/;
    $script .= <$fh>;
    close $fh;
}
ok( $script,
    'the dashboard scripts were read - '
      . scalar(@scripts) . ' files, ' . length($script) . ' bytes' );

my ($labels) = $script =~ /const priorityLabels=\{([^}]*)\}/;
ok( $labels, 'the dashboard still labels the scale' );

my %label = $labels =~ /(\d+):"([^"]+)"/g;
is( scalar keys %label, 5, 'with a word for each of the five' );

like( $label{5}, qr/high/i, 'and five is the high end' );
like( $label{1}, qr/low/i,  'while one is the low end' );

# The other label map: what the human and markdown renderers print. Read from
# the same source and compared key for key, because a difference in any one of
# the five is a board that says two different things about the same card.
my ($rendered) = $source =~ /my %priority = \(([^)]*)\)/;
ok( $rendered, 'the renderers still label the scale too' );

my %printed = $rendered =~ /(\d+)\s*=>\s*'([^']+)'/g;
is( scalar keys %printed, scalar keys %label,
    'with a word for each of the same five' );
is_deeply( \%printed, \%label,
    'and the two copies say exactly the same thing, key for key' );

# The sort has to agree with the labels, or the column reads top-first by one
# rule and bottom-first by the other.
like( $script, qr/mode==="priority"\?\(Number\(b\.dataset\.priority\|\|0\)-Number\(a\.dataset\.priority\|\|0\)/,
    'and the board sorts the high end first, which is what the labels promise' );

# --- and the documents say the same thing ---------------------------------------------
#
# A reader who never triggers the refusal and never opens the dashboard still
# has to be able to get this right.

for my $document ( 'SKILLS.md', 'docs/commands.md' ) {
    open my $fh, '<:raw', $document or die "$document: $!";
    my $text = do { local $/; <$fh> };
    close $fh;
    like( $text, qr/priority/i, "$document mentions priority at all" );
    like( $text, qr/5[^\n]{0,80}(?:most urgent|highest)|(?:most urgent|highest)[^\n]{0,80}5/i,
        "$document says which end is urgent" );
}

# --- while the scale itself is unchanged ------------------------------------------------
#
# Nothing here renumbers anybody's cards or moves the urgent end. A board that
# upgrades must find its priorities meaning exactly what they meant before.

{
    my $made = $tira->create_record( project => $root, type => 'ticket',
        title => 'Still five', priority => 5 );
    is( $made->{priority}, 5, 'five is still five' );

    my $low = $tira->create_record( project => $root, type => 'ticket',
        title => 'Still one', priority => 1 );
    is( $low->{priority}, 1, 'and one is still one' );

    ok( !eval {
            $tira->create_record( project => $root, type => 'ticket',
                title => 'Zero', priority => 0 );
            1;
        },
        'and the range is unchanged' );
}

done_testing;

__END__

=head1 NAME

177-which-end-is-urgent.t - the priority scale says which end is urgent

=head1 DESCRIPTION

Tira's priority runs 1 to 5 with B<5 the most urgent>, which is the opposite of
the P1 convention most trackers use. Nothing said so: the validator gave only
the range, neither document mentioned priority, and the direction existed only
in a JavaScript label map and a sort inside the dashboard.

It was got wrong in silence for a whole session, and corrected twice by hand
without anybody saying why. The refusal now states the direction, both documents
state it, and both label maps and the sort are checked against each other - four
copies of one decision that cannot be reduced to one, so they are held together
instead.

The direction itself is not changed and no card is renumbered.

=cut
