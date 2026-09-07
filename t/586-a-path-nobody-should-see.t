#!/usr/bin/env perl
# TKT-988, his live report from zenandi: "never expose where the ticket json
# file. check all the violation message. I found it shouldn't do that: VIO-1171
# its history could not be read: Cannot read JSON
# '/home/mv/.tira/zenandi/.tira/ticket/documenting/ZSD-334.json': No such file
# or directory."
#
# THE SOURCE OF THE LEAK. lib/Tira.pm:13371, _slurp dies as
# "Cannot read JSON '$path': $!" with the board's own absolute path embedded.
# That $@ propagates unscrubbed into whichever caller reports it - the trailing
# "at FILE line N" Perl noise is stripped everywhere it is captured, but the
# path sits in the MIDDLE of the message and none of that cleanup touches it.
#
# THREE CONFIRMED CAPTURE POINTS, found by checking every violation message
# rather than only the one he quoted:
#   _police_history      lib/Tira.pm:7194   card-unreadable / card-damaged
#   _jobs_or_report       lib/Tira.pm:10998  job-due / monitor-dead / monitor-output
#   police_pass           lib/Tira.pm:11086  the whole-pass bridge line AND the
#                                            pass result's own error field
#
# THIS PROJECT ALREADY PROMISES NOT TO DO THIS. README.md: Tira resolves
# project aliases "without printing the private target directory." A die
# message written by ordinary file-handling code has no way to know that
# promise exists, which is why the first read failure on any board breaks it.
#
# WHAT MUST SURVIVE. The OS-level reason - "No such file or directory",
# "Permission denied" - is the part a reader can act on, and TKT-988's own
# scope excludes the corruption-detail path entirely: a card read past a bad
# byte (card-damaged) names an offset and a byte count, never a path, and nfree
# rewriting that message would be exactly the "fixing something that already
# worked" mistake this suite has been caught making before.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use lib 'lib';
use lib 't/lib';
use Suite ();
use Tira;
use Tira::CLI::Police;

sub board {
    my $tmp  = tempdir( CLEANUP => 1 );
    my $tira = Tira->new( clock => sub {'2026-09-07T01:00:00Z'} );
    my $root = File::Spec->catdir( $tmp, 'proj' );
    $tira->project_new(
        name => 'No Path', dir => $root, members => ['claude'],
        columns    => ['backlog, done'],
        sow_prefix => 'NPS', epic_prefix => 'NPE', ticket_prefix => 'NPT',
    );
    mkdir File::Spec->catdir( $root, '.git' );
    return ( $tira, $root, File::Spec->catdir( $tmp, 'store' ) );
}

# Every path this whole test must never see, checked once and reused, so a
# check that happens to match a shorter substring of the real path cannot pass
# by accident.
sub assert_no_path {
    my ( $text, $root, $label ) = @_;
    # non-empty is the whole claim: the two denials below would pass on an
    # empty string exactly as readily as on clean text.
    like( $text // '', qr/\S/, "$label is there to be checked" )
      or return;
    unlike( $text // '', qr/\Q$root\E/, "$label does not contain the board's real path" );
    unlike( $text // '', qr{/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+}, "$label carries no path shape at all" );
}

# --- a card whose record file vanished after being cached --------------------
#
# The whole card, reproduced the way it happens: a ref resolves to a path, the
# file is then removed (racing another writer, or a corrupted board), and the
# NEXT read of it is what dies with the path embedded.

{
    my ( $tira, $root, $store ) = board();
    my $card = $tira->create_record( project => $root, type => 'ticket', title => 'x' );
    my ($path) = $tira->_record_data( project => $root, ref => $card->{ref} );

    # HIS EXACT SCENARIO, reproduced rather than approximated. A ref resolved
    # to a path once already this pass (TKT-978's per-pass cache) and the file
    # vanishes before a LATER read of that same ref - not "the file never
    # existed", which resolves through a fresh board walk and answers the safe
    # "Record 'X' not found" instead. A fresh Tira object doing a fresh walk on
    # a genuinely-missing file cannot reproduce this; only a cache primed
    # earlier in the pass and then invalidated can, and calling
    # _police_history outside police_pass entirely is what makes both states
    # reachable without racing a real board.
    my @unreadable;
    my $entries = $tira->_police_path_cache( sub {
        $tira->_record_data( project => $root, ref => $card->{ref} );    # primes the cache
        unlink $path or die "could not remove the fixture file: $!";
        return $tira->_police_history( $root, $card->{ref}, \@unreadable );
    } );

    ok( !defined $entries, 'the read genuinely failed, so there is something to check the wording of' );
    my ($found) = grep { ( $_->{ref} // '' ) eq $card->{ref} } @unreadable;
    ok( $found, 'and it was recorded as unreadable' ) or diag('nothing was pushed to @unreadable at all');

    my $reason = $found ? $found->{reason} : undef;
    assert_no_path( $reason, $root, 'the unreadable reason' );
    like( $reason // '', qr/No such file or directory/,
        'and the OS-level reason still survives redaction, so the finding stays actionable' );
}

# --- a corrupt jobs record --------------------------------------------------
#
# The second confirmed leak point, and its actual failure shape is different
# from the first: Cpanel::JSON::XS's own parse error carries Perl's "at FILE
# line N" trailer naming THIS ENGINE'S OWN installed module (lib/Tira/Job.pm),
# not the board's data file. Still not something a bridge viewer should see -
# it discloses server install layout - and the same redaction that strips a
# quoted board path also has to strip this trailer, which is why one shared
# helper is right rather than three bespoke ones.

{
    my ( $tira, $root, $store ) = board();
    $tira->policy_add( project => $root, rule => 'job-due', action => 'bridge-reminder' );
    $tira->job_add( project => $root, schedule => '* * * * *', message => 'x' );

    my $jobs_path = File::Spec->catfile( $root, '.tira', 'jobs.json' );
    open my $fh, '>', $jobs_path or die "could not corrupt the fixture: $!";
    print {$fh} '{not json';
    close $fh;

    my $pass = $tira->police_pass( project => $root, store => $store,
        world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );

    my ($violation) = grep { ( $_->{rule} // '' ) eq 'job-due' } @{ $pass->{violations} || [] };
    ok( $violation, 'the corrupt jobs record produces a finding' )
      or diag('no job-due violation was raised at all');

    my $detail = $violation ? $violation->{detail} : undef;
    unlike( $detail // '', qr/\bat\s+\S+\.pm\s+line\s+\d+/,
        "the jobs record's violation detail carries no Perl file-and-line trailer, which is what "
          . 'named lib/Tira/Job.pm before this was fixed' );
    like( $detail // '', qr/expected/,
        'and the parse error itself - the part a reader can act on - still survives' );
}

# --- the whole pass failing to read the board -------------------------------
#
# The third confirmed leak point, and it reaches TWO surfaces from one
# capture: the bridge's own terminal line, and the pass result's error field -
# both asserted, because a caller reading result->{error} programmatically is
# exactly as exposed as one reading the bridge.

{
    my ( $tira, $root, $store ) = board();
    $tira->policy_add( project => $root, rule => 'orphan-card', action => 'bridge-reminder' );

    my $ticket_dir = File::Spec->catdir( $root, '.tira', 'ticket' );
    chmod 0000, $ticket_dir or die "could not lock the fixture directory: $!";

    my $pass = eval {
        $tira->police_pass( project => $root, store => $store,
            world => Tira::CLI::Police::police_world( tira => $tira, project => $root ) );
    };
    chmod 0755, $ticket_dir;    # restored unconditionally, so tempdir cleanup can still remove it

    SKIP: {
        skip 'this environment does not enforce directory permissions (likely running as root)', 4
          if !defined $pass || !defined $pass->{error};

        assert_no_path( $pass->{error}, $root, "the pass result's error field" );

        my ($terminal_line) = grep { /could not finish this pass/ } @{ $pass->{terminal} || [] };
        assert_no_path( $terminal_line, $root, "the bridge's terminal line" );
    }
}

# --- the corruption-detail path is untouched --------------------------------
#
# The regression that matters most in the other direction: card-damaged names
# a byte count and an offset, never a path, and this card must not rewrite
# working behaviour while fixing a broken one.

{
    my $engine = Suite::engine_source();
    # non-empty is the whole claim: the check below would pass on an
    # unreadable file's emptiness alone.
    like( $engine, qr/\S/, 'the engine source is there to be read' );

    my ($sub) = $engine =~ /(sub\s+_police_history\s*\{\n.*?\n\})/s;
    # Two fragments checked separately rather than one pattern spanning them:
    # in the SOURCE the ternary branches ('byte that is' / 'bytes that are')
    # and " not valid UTF-8" are separate quoted string literals joined by a
    # concatenation operator, not one contiguous run of English words the way
    # they read once Perl has evaluated them.
    like( $sub // '', qr/bytes that are/,
        '_police_history was found, and still carries the corruption-detail wording - asserted '
          . 'by content so a match on the wrong sub could not satisfy the check below' );
    like( $sub // '', qr/not valid UTF-8/, 'and the rest of that sentence is still there too' );
    # Scoped to the corruption branch specifically - a check spanning the whole
    # sub would find _redact_path in the OTHER branch of the same function and
    # wrongly call that a shared routing, rather than the two branches staying
    # separate.
    my ($corruption_branch) = ( $sub // '' ) =~ /(push\s+\@\{\$unreadable\},\s*\{\s*ref\s*=>.*?repaired.*?\n\s*\})/s;
    # non-empty is the whole claim here: the unlike() below would pass on an
    # extraction that caught nothing just as readily as on one that caught
    # the right text.
    like( $corruption_branch // '', qr/\S/, 'the corruption-report push was found on its own' );
    unlike( $corruption_branch // '', qr/_redact_path/,
        'and it is not routed through path redaction, because it names no path to begin with - '
          . 'only the read-failure branch needs it' );
}

done_testing();

__END__

=head1 NAME

586-a-path-nobody-should-see.t - the board's own filesystem path never reaches a violation

=head1 DESCRIPTION

TKT-988. C<_slurp> dies with the board's absolute path embedded, and that
message reaches a bridge-visible violation unscrubbed in three places:
C<_police_history> (card-unreadable/card-damaged), C<_jobs_or_report>
(job-due/monitor-dead/monitor-output), and C<police_pass>'s own board-read
failure, which reaches both the bridge's terminal line and the pass result's
C<error> field from one capture.

This holds the fix: none of the three ever contains a path, in either shape a
test could miss (the real path, or ANY path-like string), while the OS-level
reason a reader can act on survives. The card-damaged corruption path, which
never carried a filesystem path to begin with, is asserted unchanged.

=cut
