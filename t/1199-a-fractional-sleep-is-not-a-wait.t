#!/usr/bin/env perl

use strict;
use warnings;

use File::Find;
use Test::More;

# TKT-1199. Perl's built-in sleep takes whole seconds, so 'sleep 0.1' is
# 'sleep 0': a loop meant to wait up to two seconds for a process to be reaped
# spins through its twenty turns almost instantly. t/1053 did exactly that, and
# with 791 files running in parallel the reap had not happened yet when the loop
# gave up. t/1014 and t/1053 also slept a fixed second and then assumed the
# feeder had started its child by then, which a loaded host does not promise.
#
# Both are read from source rather than timed: a timing test for a timing bug
# would itself be a coin toss, which is the thing being removed.

my @files;
find( sub { push @files, $File::Find::name if -f $_ && /\.t\z/ }, 't' );

# The built-in is fine once Time::HiRes replaces it, so a file importing sleep
# from there is not held to this, and Time::HiRes::sleep(...) called by its
# full name never matches, nor does another language's time.sleep(0.1) in a
# heredoc (the lookbehind skips a name after a colon or a dot), while the explicit
# CORE::sleep spelling is still the whole-second built-in and is flagged.
sub code_of {
    my ($path) = @_;
    open my $in, '<', $path or die "Cannot read $path: $!";
    my @code;
    while ( my $line = <$in> ) {
        last if $line =~ /\A__END__/;
        next if $line =~ /\A\s*#/;
        push @code, $line;
    }
    close $in;
    return join '', @code;
}

my $fractional_sleep = qr/(?:(?<![\w'":.])|(?<=CORE::))sleep\s*\(?\s*\d*\.\d+/;

# The pattern first, on lines it must and must not match: a guard that misses
# the explicit CORE:: spelling would pass while the truncation came back.
for my $line ( 'sleep 0.1;', 'sleep(0.5);', 'sleep .5;', '    sleep 0.05 if $x;', 'CORE::sleep 0.1;', 'CORE::sleep(0.1);' ) {
    like( $line, $fractional_sleep, "flags: $line" );
}
for my $line ( 'sleep 1;', 'sleep(2);', 'Time::HiRes::sleep(0.1);', 'time.sleep(0.1)', "command => 'sleep 47'" ) {
    unlike( $line, $fractional_sleep, "leaves alone: $line" );
}

my @fractional;
for my $path ( sort @files ) {
    next if $path =~ m{1199-a-fractional-sleep};
    my $code = code_of($path);
    next if $code =~ /use\s+Time::HiRes[^;]*\bsleep\b/;
    push @fractional, $path if $code =~ $fractional_sleep;
}
is_deeply( \@fractional, [], 'no test waits with a fractional built-in sleep, which Perl truncates to sleep 0' );

# The start waits: a bare 'sleep N;' followed straight away by the read that
# assumes the process has started.
for my $name ( '1014-a-signal-that-outran-the-reap.t', '1053-a-reap-nobody-was-positioned-for.t' ) {
    my $code = code_of("t/$name");
    unlike(
        $code,
        qr/^sleep\s+\d+;\s*\n\s*(?:my\s+\@tree\s*=\s*tree_of|ok\(\s*stat_of)/m,
        "$name polls for the feeder to start instead of sleeping a fixed second and hoping"
    );
}

done_testing;

__END__

=head1 NAME

1199-a-fractional-sleep-is-not-a-wait.t - no test waits with a truncated sleep or a fixed guess

=head1 DESCRIPTION

TKT-1199. C<sleep 0.1> is C<sleep 0> in Perl, so t/1053's twenty-turn reap wait
gave the SIGCHLD handler almost no time, and both t/1053 and t/1014 slept a
fixed second before reading a process that a loaded host may not have started.
Both failed only inside the parallel gate run. This walks every file under
C<t/> for a fractional built-in C<sleep> that is not replaced by
C<Time::HiRes>, and checks that the two files' start waits are no longer a
bare C<sleep> followed by the read. It is read from source, not timed, because
a timing test for a timing bug would be as unreliable as the thing it replaces.

=cut
