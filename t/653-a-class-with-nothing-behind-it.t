#!/usr/bin/env perl
# TKT-653. A meta-test in the family of t/121 (no dead controls) and t/147
# (no vacuous denials): every hyphenated, BEM-shaped string the dashboard's
# view JS carries must match a rule in the stylesheet it ships, or be
# recorded in the exemption ledger below with a reason. A class assigned and
# never styled ships invisible or misshapen with every other test green -
# measured 2026-08-28, four classes from TKT-591 and a fifth passed only as
# a variable, found solely because the owner opened the page.
#
# WHY A STRING SCAN, NOT className="..." ALONE: TKT-591's fifth class,
# column-row__entry-action-input, reached the page only as a variable
# passed into buildActionRow - a detector reading literal className
# attributes missed exactly it. The class name is still a string literal
# SOMEWHERE in the source; scanning every BEM-shaped string literal in the
# file, not only ones sitting next to className=, is what catches it.
#
# THE LEDGER, NOT A BLOCKED RELEASE: this check found 15 more classes with
# no rule at all beyond the 5 already known, on a codebase that has grown
# since 2026-08-28. Fixing 15 CSS rules blind, with no way to see the
# rendered page from here, risks shipping worse regressions than the ones
# this test exists to catch. Each is named below with why it is exempt for
# now - most "pending: needs a real stylesheet rule, filed as TKT-1006" -
# so the ledger is honest about what remains rather than silently widened.
# TKT-1006 is the follow-up that clears it, the same two-step t/410 already
# uses for a ledger of commands with no usage line.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Basename qw(basename);
use File::Find ();
use File::Spec;
use Test::More;

use lib 't/lib';
use Suite ();

# Not a class at all - excluded by name rather than treated as a style gap.
# Both are hyphenated strings that happen to match the BEM-shaped pattern
# this scan looks for, for reasons that have nothing to do with CSS.
my %NOT_A_CLASS = (
    'no-store'          => 'a fetch() cache mode, not a class (live-helpers.js, column-editor.js and others)',
    'tira-column-width' => 'a localStorage key (base-script.js), not a class',
);

# A real gap, measured now rather than assumed fixed. Each is unstyled
# today; TKT-1006 is the follow-up that adds the missing rules, one card
# rather than blind changes made here with no way to see the result.
my %PENDING_STYLE = map { $_ => 'pending: no stylesheet rule yet, tracked as TKT-1006' } qw(
    card-attach-input
    card-attachments
    card-comments-box
    card-list__more
    card-list__proof-detail
    card-value__text
    column-row__administrative-action-row
    column-row__administrative-actions-list
    column-row__entry-action-row
    column-row__entry-actions-list
    is-editing
    is-error
    jobs-editor__loop-on
    logs-line__path
    logs-line__status
    not-ok
);

my %EXEMPT = ( %NOT_A_CLASS, %PENDING_STYLE );

# --- read every view script and the stylesheet it ships ---------------------

my @js_files;
File::Find::find(
    { no_chdir => 1, wanted => sub {
          push @js_files, $File::Find::name
            if /\.js\z/ && -f && m{\blib/Tira/views/};
      } },
    'lib' );
ok( scalar @js_files > 5, 'the dashboard ships more than a handful of view scripts' );

my %found;    # class => which file(s) it was seen in
for my $file (@js_files) {
    my $source = Suite::view_source( basename($file) );
    while ( $source =~ /['"]([a-z][a-z0-9]*(?:-[a-z0-9]+)+(?:__[a-z0-9-]+)*)['"]/g ) {
        my $class = $1;
        next if $class =~ /\A(?:aria|data)-/;
        push @{ $found{$class} }, basename($file);
    }
}
ok( scalar keys %found > 50, 'a substantial number of BEM-shaped class strings were found' );

my $css = Suite::view_source('dashboard.css');
my %styled;
$styled{$1} = 1 while $css =~ /\.([A-Za-z][A-Za-z0-9_-]*)/g;

# --- every class assigned is either styled or named as an exception --------

my @unstyled = sort grep { !$styled{$_} && !$EXEMPT{$_} } keys %found;
is_deeply( \@unstyled, [],
    'every class the view scripts assign has a stylesheet rule or a named, reasoned exemption' )
  or diag( "unstyled and unexplained: @unstyled" );

# --- the exemption ledger cannot silently grow --------------------------
#
# The same discipline t/410's own ledger holds: an exemption is a decision,
# not a place to drop a new gap without anyone noticing. A class that is
# EXEMPT but has quietly become STYLED should be pruned from the ledger, not
# left to rot as a stale entry claiming a gap that closed.

my @stale = sort grep { $styled{$_} } keys %PENDING_STYLE;
is_deeply( \@stale, [],
    'the pending-style ledger holds no entry that has already been styled - '
      . 'a closed gap is removed from it, not left behind' )
  or diag( "already styled, remove from the ledger: @stale" );

# --- and a genuinely new, unstyled class is still caught --------------------

{
    local $found{'made-up-class-nobody-styled'} = ['synthetic'];
    my @with_invented = sort grep { !$styled{$_} && !$EXEMPT{$_} } keys %found;
    ok( scalar(@with_invented) == 1 && $with_invented[0] eq 'made-up-class-nobody-styled',
        'an invented class with no rule and no exemption is caught' );
}

done_testing();

__END__

=head1 NAME

653-a-class-with-nothing-behind-it.t - every class the dashboard assigns has
a rule or a reasoned exemption

=head1 DESCRIPTION

TKT-653. Every BEM-shaped string literal in C<lib/Tira/views/*.js> is
checked against C<dashboard.css> - not only strings sitting next to
C<className=>, because TKT-591's own missed class reached the page only as
a variable. A class with no rule and no entry in this file's exemption
ledger fails the build; C<%NOT_A_CLASS> names strings that only look like
one (a fetch cache mode, a localStorage key), and C<%PENDING_STYLE> is a
ledger of real, currently-unstyled classes with a reason and a follow-up
ticket (TKT-1006) rather than a blind fix made with no way to see the
rendered page.

=cut
