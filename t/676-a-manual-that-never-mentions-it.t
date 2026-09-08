#!/usr/bin/env perl
# TKT-676. SKILLS.md - the manual an agent actually reads for workflows -
# never named tira.conversation.add or tira.conversation.list. Zero
# occurrences; they were documented only in docs/commands.md, the argument
# reference. The one mention SKILLS.md did make, the police rule
# conversation-not-folded, actively misleads: the rule reads COMMENTS, not
# conversation records, and its own name implies a link that does not exist.
#
# WRITTEN RED.

use strict;
use warnings;

use File::Spec;
use Test::More;

my $skills_path = File::Spec->catfile( 'SKILLS.md' );
open my $fh, '<:raw:encoding(UTF-8)', $skills_path or die "Cannot read SKILLS.md: $!\n";
local $/;
my $skills = <$fh>;
close $fh;

like( $skills, qr/tira\.conversation\.add/, 'SKILLS.md names tira.conversation.add' );
like( $skills, qr/tira\.conversation\.list/, 'SKILLS.md names tira.conversation.list' );
like( $skills, qr/--heard/, 'SKILLS.md names the --heard argument' );
like( $skills, qr/conversation record/i, 'SKILLS.md says what a conversation record is' );

# The disambiguation: wherever conversation-not-folded is named, or nearby,
# something must say the rule reads comments, not conversation records.
my @mentions = $skills =~ /(.{0,400}conversation-not-folded.{0,400})/gs;
ok( scalar @mentions, 'conversation-not-folded is named somewhere in SKILLS.md' );
ok( ( grep { /reads comments/i || /not conversation records/i } @mentions, $skills ),
    'somewhere near the rule name, or in the conversation-record section itself, it is plain the rule reads comments' );

done_testing();

__END__

=head1 NAME

676-a-manual-that-never-mentions-it.t - SKILLS.md documents the
conversation commands and disambiguates them from conversation-not-folded

=head1 DESCRIPTION

TKT-676. C<tira.conversation.add>/C<tira.conversation.list> are given a
section beside comments in SKILLS.md, since the distinction between the
two is the whole point and was previously explained only in
C<docs/commands.md>. The police rule C<conversation-not-folded>, which
reads comments rather than conversation records despite the shared word,
is disambiguated in the same place.

=cut
