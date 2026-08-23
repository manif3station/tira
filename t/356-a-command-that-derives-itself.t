#!/usr/bin/env perl
# 119 command dispatchers sit outside the coverage gate (it names three
# modules by hand) and are not thin - roughly 4,900 lines of executable Perl
# nothing proves. Two refusals in the shared body - "Cannot locate Tira
# skill root" and "Unsafe Tira skill root" - are exercised by no test
# anywhere in this project, and skills/checklist/cli/{add,list,update}
# hardcode their command as 'checklist.' . basename($0) instead of deriving
# it the way the other 116 dispatchers do, agreeing with them today only
# because the checklist skill happens to sit at one nesting level. TKT-395.

use strict;
use warnings;

use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs('.');

# --- every dispatcher, found the same way t/03-metadata.t finds them --------

my @dispatchers;
find( { no_chdir => 1, wanted => sub {
    return if !-f $File::Find::name || !-x $File::Find::name;
    return if $File::Find::name !~ m{(?:\A|/)cli/[^/]+\z};
    push @dispatchers, $File::Find::name;
} }, qw(cli skills) );

cmp_ok( scalar @dispatchers, '>=', 100, 'enough dispatchers exist to make this worth checking' );

# --- the refusal nothing exercises: no skill root above the dispatcher ------

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $stray = File::Spec->catdir( $tmp, 'cli' );
    make_path($stray);
    my $copy = File::Spec->catfile( $stray, 'backup' );
    copy( File::Spec->catfile( $root, 'cli', 'backup' ), $copy ) or die "copy failed: $!";
    chmod 0755, $copy;

    my $said = qx(perl "$copy" 2>&1);
    my $status = $? >> 8;

    is( $status, 2, 'a dispatcher with no Tira skill root above it exits 2' );
    like( $said, qr/Cannot locate Tira skill root/, 'and says so, not something else' );
}

# --- the refusal nothing exercises: a control character in the found root ---

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $tainted = File::Spec->catdir( $tmp, "root\x01ctrl" );
    make_path( File::Spec->catdir( $tainted, 'lib', 'Tira' ) );
    make_path( File::Spec->catdir( $tainted, 'cli' ) );
    open my $fh, '>', File::Spec->catfile( $tainted, 'lib', 'Tira', 'CLI.pm' ) or die $!;
    print {$fh} "1;\n";
    close $fh;
    my $copy = File::Spec->catfile( $tainted, 'cli', 'backup' );
    copy( File::Spec->catfile( $root, 'cli', 'backup' ), $copy ) or die "copy failed: $!";
    chmod 0755, $copy;

    my $said = qx(perl "$copy" 2>&1);
    my $status = $? >> 8;

    is( $status, 2, 'a dispatcher whose located root contains a control character exits 2' );
    like( $said, qr/Unsafe Tira skill root/, 'and says so, not something else' );
}

# --- one rule for deriving a command, not two ------------------------------
#
# A dispatcher directly in cli/ is legitimately named by a literal matching
# its own basename - it can never be nested, so there is nothing to derive.
# A dispatcher under skills/.../cli/ must derive through the path, the same
# way skills/card/cli/holes and the other 115 do - never a literal string
# with a dot in it glued to basename($0), which is exactly the shape
# skills/checklist/cli/{add,list,update} used to have.

my @hardcoded;
for my $file (@dispatchers) {
    next if $file !~ m{\Askills/}; # a bare cli/NAME file is not nested, and exempt
    open my $fh, '<', $file or die "$file: $!";
    my $body = do { local $/; <$fh> };
    close $fh;
    push @hardcoded, $file if $body =~ /=\s*'[\w-]+\.[\w.]*'\s*\.\s*basename/;
}
is_deeply( \@hardcoded, [],
    'no nested dispatcher hardcodes a dotted prefix instead of deriving it from its path' );

# --- break it: a hardcoded prefix is exactly what the check above catches ---

{
    my $tmp = tempdir( CLEANUP => 1 );
    my $fake = File::Spec->catfile( $tmp, 'planted' );
    open my $fh, '>', $fake or die $!;
    print {$fh} "my \$command = 'card.checklist.' . basename(\$0);\n";
    close $fh;
    open my $rfh, '<', $fake or die $!;
    my $body = do { local $/; <$rfh> };
    close $rfh;
    ok( $body =~ /=\s*'[\w-]+\.[\w.]*'\s*\.\s*basename/,
        'the pattern this check looks for really does match a planted hardcoded prefix' );
}

done_testing;

__END__

=head1 NAME

356-a-command-that-derives-itself.t - dispatcher refusals proved, one derivation rule

=head1 DESCRIPTION

Runs a copied dispatcher under two conditions the shared body refuses -
no locatable skill root, and a root whose path contains a control
character - and asserts both exit 2 with their own message, proving code
that guards every one of the project's commands rather than assuming it.
Also asserts no dispatcher nested under C<skills/> hardcodes a dotted
command prefix instead of deriving it from its own path, the gap
C<skills/checklist/cli/{add,list,update}> used to have.

=cut
