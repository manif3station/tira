#!/usr/bin/env perl

# TKT-1117. record_list(refs_only=>1) with no column/assignee/parent/text/
# where filter still walks every matching file and slurps+JSON-decodes it,
# just to read the one field (ref) the filename already names -
# "TKT-042.json" IS "TKT-042". Found by the 2-hourly improvement hunt while
# TKT-905/TKT-1116 work was in progress on this same board.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use Tira;

my $tmp  = tempdir( CLEANUP => 1 );
my $root = File::Spec->catdir( $tmp, 'proj' );
my $tira = Tira->new( clock => sub { '2026-09-21T00:00:00Z' } );
$tira->project_new( name => 'RefsOnly', dir => $root, members => ['claude'] );

my @refs;
for ( 1 .. 12 ) {
    my $card = $tira->create_record( project => $root, type => 'ticket', title => "Card $_" );
    push @refs, $card->{ref};
}

my $slurp_calls = 0;
{
    no warnings 'redefine';
    local *Tira::_slurp = sub {
        $slurp_calls++;
        my ( $self, $path ) = @_;
        open my $fh, '<:raw', $path or die "Cannot read JSON '$path': $!\n";
        my $content = do { local $/; <$fh> };
        close $fh or die "Cannot close JSON '$path': $!\n";
        return $content;
    };

    my $listed = $tira->record_list( project => $root, type => 'ticket', refs_only => 1 );
    is_deeply( [ sort @{$listed} ], [ sort @refs ], 'refs_only still returns every ref, correctly' );
}

is( $slurp_calls, 0,
    'an unfiltered refs_only call never reads a single file\'s content - the filename already names the ref, '
      . "got $slurp_calls slurp(s) for 12 cards" );

# --- adding any filter still needs the content, and still works ------------

my $filtered_slurps = 0;
{
    no warnings 'redefine';
    local *Tira::_slurp = sub {
        $filtered_slurps++;
        my ( $self, $path ) = @_;
        open my $fh, '<:raw', $path or die "Cannot read JSON '$path': $!\n";
        my $content = do { local $/; <$fh> };
        close $fh or die "Cannot close JSON '$path': $!\n";
        return $content;
    };
    my $listed = $tira->record_list( project => $root, type => 'ticket', refs_only => 1, column => 'backlog' );
    is_deeply( [ sort @{$listed} ], [ sort @refs ], 'refs_only with a --column filter still returns the right refs' );
}
cmp_ok( $filtered_slurps, '>', 0,
    'and DOES read content when a filter needs it - this is a short-circuit for the unfiltered case only, not a removal of correctness' );

# --- --since ALSO needs content - Codex review caught this as the first ----
# version's real gap: _changed_since reads the record itself (its own
# last_updated, comments...), which no filename can answer.

my $since_slurps = 0;
{
    no warnings 'redefine';
    local *Tira::_slurp = sub {
        $since_slurps++;
        my ( $self, $path ) = @_;
        open my $fh, '<:raw', $path or die "Cannot read JSON '$path': $!\n";
        my $content = do { local $/; <$fh> };
        close $fh or die "Cannot close JSON '$path': $!\n";
        return $content;
    };
    my $listed = $tira->record_list(
        project => $root, type => 'ticket', refs_only => 1, since => '2026-09-20T00:00:00Z' );
    is_deeply( [ sort @{$listed} ], [ sort @refs ],
        'refs_only with --since still returns the right refs (all of them, created after the threshold)' );
}
cmp_ok( $since_slurps, '>', 0,
    'and --since ALSO takes the slow path - the fast path is scoped to the genuinely filename-answerable case only' );

# Codex review: the check above proves --since is not IGNORED (still reads
# content), but every card here was created at the same fixed clock
# instant, so nothing above actually proves a stale ref gets EXCLUDED - a
# threshold AFTER every card's own last_updated does.
my $listed_future = $tira->record_list(
    project => $root, type => 'ticket', refs_only => 1, since => '2026-09-22T00:00:00Z' );
is_deeply( $listed_future, [],
    '--since actually excludes: a threshold after every card\'s own last_updated returns none of them, not all of them' );

# --- an observable behavior change, made explicit rather than left to be --
# found by surprise - Codex review's own second finding.
#
# The slow path dies on genuinely corrupt JSON (via _json_from_content) and
# would return a card's OWN embedded ref if it ever disagreed with its
# filename. The fast path reads neither: an unfiltered refs_only call now
# answers from the filename alone, corrupt or not, agreeing or not. Both
# scenarios are deliberately out of scope to "fix" here - a filename and
# its own content disagreeing, or a card file that will not parse, are
# board-integrity questions a plain refs_only lookup was never positioned
# to catch (t/988's own reasoning already treats a read failure as a fact
# about the FILE, not the record) - but the change is real and is pinned
# here rather than left to be discovered by accident.

{
    my $extra = $tira->create_record( project => $root, type => 'ticket', title => 'Corrupt-on-purpose' );
    my $path = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', "$extra->{ref}.json" );
    open my $fh, '>', $path or die $!;
    print {$fh} 'not valid json at all';
    close $fh;

    my $listed = $tira->record_list( project => $root, type => 'ticket', refs_only => 1 );
    ok( ( grep { $_ eq $extra->{ref} } @{$listed} ),
        'a corrupt record file still answers refs_only with its FILENAME - the fast path never reads content to notice the corruption' );

    eval { $tira->record_list( project => $root, type => 'ticket' ) };
    # non-empty is the whole claim - only that it died, not its exact wording
    like( $@, qr/\S/,
        'while a FULL (non-refs_only) list still dies on the same corrupt file - only the fast path is unaffected by it, not the record engine generally' );

    unlink $path;
}

# Codex review: the corrupt-JSON case above proves the fast path never
# READS content, but not the other half of the same claim - that a
# filename and its own embedded ref disagreeing resolves differently
# between the two paths. Proved directly: copy one real card's own valid
# JSON (embedded ref intact) onto a SECOND filename.

{
    my $original = $tira->create_record( project => $root, type => 'ticket', title => 'The real owner of this content' );
    my $original_path = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', "$original->{ref}.json" );
    my $renamed_path   = File::Spec->catfile( $root, '.tira', 'ticket', 'backlog', 'TKT-999999.json' );
    open my $in,  '<:raw', $original_path or die $!;
    open my $out, '>:raw', $renamed_path  or die $!;
    print {$out} do { local $/; <$in> };
    close $in;
    close $out;

    my $listed = $tira->record_list( project => $root, type => 'ticket', refs_only => 1 );
    ok( ( grep { $_ eq 'TKT-999999' } @{$listed} ),
        'refs_only answers with the FILENAME (TKT-999999), not the embedded ref, for a file placed under a different name' );
    ok( !( grep { $_ eq $original->{ref} } grep { $_ eq 'TKT-999999' } @{$listed} ),
        'sanity: the two are genuinely different strings, this is not an accidental match' );

    # The slow path indexes what it finds by filename too (TKT-988), so a
    # mismatched file is a genuine duplicate-ref case there, not silently
    # resolved either way - out of scope for this ticket to change, only to
    # observe correctly. What matters here is narrower, and proved above:
    # the FAST path's answer for this file is its filename.

    unlink $renamed_path;
}

done_testing;

__END__

=head1 NAME

1143-a-name-already-on-the-envelope.t - record_list(refs_only=>1) with no
filter never reads a card's content

=head1 DESCRIPTION

TKT-1117. C<record_list>'s find() walk slurped and JSON-decoded every
matching file unconditionally, even for C<refs_only =E<gt> 1> with no
column/assignee/parent/text/where filter - the one field being asked for
(the ref) is already named by the filename ("TKT-042.json" IS "TKT-042"),
so no content read was ever necessary for that specific call shape.
Proved by counting real calls to C<Tira::_slurp> via a monkey-patched
wrapper: the unfiltered case must make zero, while a filtered call (which
genuinely needs to inspect content to decide inclusion) is unaffected.

=cut
