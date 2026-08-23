#!/usr/bin/env perl
# Every release bumps .env's VERSION= and lib/Tira.pm's our $VERSION by
# hand, and the two have to agree - t/03-metadata.t only checks that after
# the fact. Measured this session alone: six version bumps, and two earlier
# releases each shipped with exactly one of the two hand-edits missed,
# caught only by the pre-push gate's clean-worktree run. tools/bump-version
# writes both together; this proves it against a throwaway fixture rather
# than the real project files, since Changes and t/03-metadata.t's own
# literals stay hand-written - deliberately out of the script's scope - and
# running it against the real tree would leave those disagreeing on
# purpose, mid test-run. TKT-436.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use Test::More;

my $real_root = File::Spec->rel2abs( File::Spec->catdir( dirname($0), File::Spec->updir ) );
my $script    = File::Spec->catfile( $real_root, 'tools', 'bump-version' );
ok( -x $script, 'tools/bump-version exists and is executable' ) or die "cannot find $script";

# Purpose: a throwaway project layout the script can run against, with only
#          the two files and the relative path (tools/bump-version) it needs.
sub fixture {
    my (%files) = @_;
    my $dir = tempdir( CLEANUP => 1 );
    mkdir File::Spec->catdir( $dir, 'tools' );
    mkdir File::Spec->catdir( $dir, 'lib' );
    copy( $script, File::Spec->catfile( $dir, 'tools', 'bump-version' ) ) or die $!;
    chmod 0755, File::Spec->catfile( $dir, 'tools', 'bump-version' );

    open my $env, '>', File::Spec->catfile( $dir, '.env' ) or die $!;
    print {$env} "VERSION=$files{env}\n";
    close $env;

    open my $module, '>', File::Spec->catfile( $dir, 'lib', 'Tira.pm' ) or die $!;
    print {$module} "package Tira;\nuse strict;\nour \$VERSION = '$files{module}';\n1;\n";
    close $module;

    return $dir;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die $!;
    local $/;
    return <$fh>;
}

# --- a normal bump updates both files, leaving everything else untouched --------

{
    my $dir = fixture( env => '1.00', module => '1.00' );
    my $out = `cd '$dir' && ./tools/bump-version 1.01 2>&1`;
    is( $? >> 8, 0, 'bump-version exits 0 on a clean bump' ) or diag($out);

    my $env_text = read_file("$dir/.env");
    like( $env_text, qr/^VERSION=1\.01$/m, '.env is updated to the new version' );

    my $module_text = read_file("$dir/lib/Tira.pm");
    like( $module_text, qr/our \$VERSION = '1\.01';/, "lib/Tira.pm's \$VERSION is updated too" );
    like( $module_text, qr/^package Tira;/m, 'everything else in the module is untouched' );
}

# --- refuses when .env and lib/Tira.pm already disagree, rather than picking one -

{
    my $dir = fixture( env => '1.00', module => '1.01' );
    my $out = `cd '$dir' && ./tools/bump-version 1.02 2>&1`;
    isnt( $? >> 8, 0, 'refuses when the two files already disagree' );
    like( $out, qr/already disagree/, 'and says so' );

    is( read_file("$dir/.env"), "VERSION=1.00\n", 'and .env is untouched, not guessed at' );
}

# --- refuses a version already in place, rather than a silent no-op -------------

{
    my $dir = fixture( env => '1.00', module => '1.00' );
    my $out = `cd '$dir' && ./tools/bump-version 1.00 2>&1`;
    isnt( $? >> 8, 0, 'refuses bumping to the version already in place' );
    like( $out, qr/already at 1\.00/, 'and says so' );
}

# --- refuses a version that does not look like one ------------------------------

{
    my $dir = fixture( env => '1.00', module => '1.00' );
    my $out = `cd '$dir' && ./tools/bump-version not-a-version 2>&1`;
    isnt( $? >> 8, 0, 'refuses a malformed version' );
    is( read_file("$dir/.env"), "VERSION=1.00\n", 'and neither file is touched' );
}

# --- refuses with no argument at all ---------------------------------------------

{
    my $dir = fixture( env => '1.00', module => '1.00' );
    my $out = `cd '$dir' && ./tools/bump-version 2>&1`;
    isnt( $? >> 8, 0, 'refuses with no version given' );
    like( $out, qr/Usage:/, 'and names how to call it' );
}

done_testing;

__END__

=head1 NAME

329-a-bump-that-tries-to-be-one-command.t - tools/bump-version writes .env and lib/Tira.pm's $VERSION together

=head1 DESCRIPTION

C<tools/bump-version NEW_VERSION> writes C<.env>'s C<VERSION=> line and
C<lib/Tira.pm>'s C<our $VERSION> line together, refusing rather than
guessing when the two already disagree, when the target version is already
in place, or when the version does not parse. C<Changes> and
C<t/03-metadata.t>'s own version literals stay hand-written on purpose -
tested here against a throwaway fixture, not the real project tree, since
running it for real would leave those two deliberately out of sync with
the rest of the bump. TKT-436.

=cut
