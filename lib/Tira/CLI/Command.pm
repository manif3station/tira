package Tira::CLI::Command;

# TKT-660. Whether a bare command name this skill dispatches at all is real,
# and the nearest known names when it is not - split out of
# Tira::CLI::Usage to keep that file at the 500-line limit rather than
# growing it past it.
#
# Every bare command name this skill dispatches, read from its own source -
# TKT-660's solution_needed names this as the list t/410 already assembles
# for its usage-line ledger. $command dispatches two ways in lib/Tira/CLI.pm:
# an exact 'eq' (or a %method key) and a regex alternation
# (C<$command =~ /\Alogin\.(register|check|status|logout)\z/> and two dozen
# more like it) - t/410's own ledger reads only the first shape, fine for
# what IT checks (whether a command HAS a usage line, not whether it
# dispatches at all). Refusing on that shape alone here would have refused
# --help for login.status and every other regex-dispatched command as
# unknown - caught by this ticket's own t/1086 the first time it ran
# against a real implementation, naming login.status. So the regex objects
# themselves are extracted and tested directly against $command, rather
# than re-deriving every concrete name an alternation can produce.

use strict;
use warnings;

use File::Find ();
use File::Spec ();
use Tira ();
use Tira::CLI::Usage ();

# Cached after the first call - the command surface does not change within
# a process, and every --help call reads this to answer a name that might
# be a typo.
my ( %KNOWN_COMMAND, @KNOWN_COMMAND_PATTERN );

sub _ensure_known_commands {
    return if %KNOWN_COMMAND || @KNOWN_COMMAND_PATTERN;
    my @modules;
    File::Find::find(
        { no_chdir => 1, wanted => sub {
              return if !/\.pm\z/;
              return if $File::Find::name !~ m{\blib/Tira/CLI(?:\.pm|/)};
              push @modules, $File::Find::name;
          } },
        File::Spec->catdir( Tira::CLI::Usage::_skill_root(), 'lib' ) );
    for my $module (@modules) {
        open my $fh, '<:raw', $module or next;
        local $/;
        my $source = <$fh>;
        close $fh;

        # Codex review: a $command =~ /PATTERN/ inside a comment or POD block
        # is not dispatch - this module's own DESCRIPTION names the shape it
        # looks for using exactly that text, and was compiling its own
        # documentation into a bogus known pattern until this strip. POD runs
        # from a line starting '=word' to the line starting '=cut'; every
        # other '#'-led line is a full-line comment, the only comment shape
        # this file and lib/Tira/CLI.pm use before a dispatch regex.
        $source =~ s/^=\w+.*?\n=cut\b[^\n]*\n/\n/gms;
        $source =~ s/^[ \t]*#.*$//gm;

        # _finish's own $command =~ /\Awarning\./ is not dispatch - it
        # silences the warnings banner for an ALREADY-dispatched warning.*
        # command, after the real dispatch (run()'s help branch, or
        # _invoke's eq/%method/regex chain) has already decided what $command
        # is. Reading it as a fourth dispatch shape would have accepted
        # 'tira.warning.nonesuch --help' as real, the exact false-negative
        # this module exists to prevent (Codex review) - and it is broader
        # than the three real warning.* commands (list/add/clear), so unlike
        # every other $command =~ match in this file, dropping it cannot
        # lose a real command: an anchored \Awarning\. only ever needed those
        # three, and they are already known via the plain 'eq' dispatch each
        # one uses inside _invoke. Removed by name rather than by sub
        # location, since run()'s own help branch (this ticket's own fix)
        # dispatches job.help/policies outside _invoke and must stay read.
        if ( $module =~ m{/CLI\.pm\z} ) {
            $source =~ s/^sub _finish \{.*?^\}\n//ms;
        }

        # [a-z0-9_.-], not t/410's own [a-z0-9.-]: that narrower class
        # truncates 'dev.found.bug_or_improvement' at the underscore into
        # 'dev.found.bug', harmless in a ledger keyed by string but not
        # here - a caller asking --help for the real command would find
        # the truncated name absent from this set and be refused as
        # unknown, the exact bug this fix exists to remove.
        $KNOWN_COMMAND{$1} = 1 while $source =~ /\$command\s+eq\s+'([a-z][a-z0-9_.\-]*)'/g;
        my ($table) = $source =~ /my \%method\s*=\s*\((.*?)\n    \);/s;
        # Same character class as the 'eq' extractor above (Codex review
        # caught the two disagreeing) - a %method key with an underscore
        # would otherwise vanish from this set and its real command would
        # be refused as unknown.
        $KNOWN_COMMAND{$1} = 1 while defined($table) && $table =~ /'([a-z][a-z0-9_.\-]*)'\s*=>/g;
        # The trailing modifier letters (none exist in this file today, but
        # a future /i would silently change what a pattern matches if
        # dropped here) travel with the pattern into qr//.
        while ( $source =~ m{\$command\s*=~\s*/(.*?)/([a-z]*)}g ) {
            my ( $pattern, $modifiers ) = ( $1, $2 );
            my $regex = eval { qr/(?$modifiers:$pattern)/ };
            push @KNOWN_COMMAND_PATTERN, $regex if $regex;
        }
    }
}

sub known_command {
    my ($command) = @_;
    _ensure_known_commands();
    return 1 if exists $KNOWN_COMMAND{$command};
    return 1 if grep { $command =~ $_ } @KNOWN_COMMAND_PATTERN;
    return 0;
}

# The same near-match shape the unknown-option refusal already gives an
# unrecognised flag. Suggestions come from the literal-name set only - a
# regex-alternation command has no single string to offer back, so a typo
# near one of those is refused without a suggestion rather than a guess.
sub nearest_commands {
    my ($bad) = @_;
    _ensure_known_commands();
    my %distance = map { $_ => Tira::_edit_distance( $bad, $_ ) } keys %KNOWN_COMMAND;
    my @close = grep { $distance{$_} <= 3 } keys %distance;
    my @near = sort { $distance{$a} <=> $distance{$b} || $a cmp $b } @close;
    return [ @near[ 0 .. ( $#near > 2 ? 2 : $#near ) ] ] if @near;
    return [];
}

1;

__END__

=head1 NAME

Tira::CLI::Command - whether a bare command name is real, and its nearest match

=head1 DESCRIPTION

Answers the question C<--help> never used to ask: is this command name one
the skill actually dispatches? C<known_command> reads C<lib/Tira/CLI.pm>'s
own source for every C<$command eq '...'>, every C<%method> table key, and
every C<$command =~ /PATTERN/> dispatch regex, testing the last group's
regex objects directly against the name rather than trying to expand every
alternation into concrete strings - the DIRECT test cannot miss a shape it
does not fully understand the way a generator could.

C<nearest_commands> offers the closest known literal names within a small
edit distance, the same shape C<Tira::CLI::Usage>'s unknown-option message
already gives - both built on C<Tira::_edit_distance>, the engine's own
Levenshtein implementation (TKT-1004; this module's copy and
C<Tira::CLI::Usage>'s were byte-for-byte identical from the day each was
introduced until this ticket removed the duplicate).

=cut
