package Tira;

use strict;
use warnings;

use Cwd qw(abs_path realpath);
use B ();
use Data::TOON;
use Data::TOON::Encoder;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode_utf8 FB_QUIET);
use Fcntl qw(:flock);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use Cpanel::JSON::XS ();
use POSIX qw(strftime);
use Time::Local qw(timegm_modern);
use YAML::XS ();

{
    # YAML::XS is a function interface; the engine and its tests speak to an
    # object with dump_string and load_string, which is the shape everything
    # here already uses. Booleans come back as JSON::PP::Boolean, which is the
    # same class Cpanel::JSON::XS produces - so true stays true across both
    # parsers, which is the part that would have gone wrong silently.
    package Tira::Yaml;

    use Encode qw(encode_utf8);

    sub new { return bless {}, shift }

    # Bytes, both ways. libyaml does its own UTF-8: Dump hands back encoded
    # bytes and Load expects them, so handing Load a decoded character string
    # makes it read the second byte of a two-byte character as a leading octet
    # and refuse the file. A project with a pound sign in a person's name was
    # unreadable until this was got right, which is the sort of thing that
    # looks like a corrupt board rather than a parser swap.
    sub dump_string {
        my ( undef, @data ) = @_;
        local $YAML::XS::Boolean = 'JSON::PP';
        return YAML::XS::Dump(@data);
    }

    sub load_string {
        my ( undef, $text ) = @_;
        local $YAML::XS::Boolean = 'JSON::PP';
        $text = encode_utf8($text) if utf8::is_utf8($text);
        return YAML::XS::Load($text);
    }
}

our $VERSION = '3.32';

# What a card update writes, said once. record_update iterates these, and the
# command line refuses them on the commands that write none of them - so the two
# cannot disagree about what a card field is.
#
# Three cards were raised because that was two decisions rather than one.
# TKT-281: move given --sdlc-gate accepted it, dropped it, exited 0 and printed
# the whole card back, which reads as confirmation because the card is there.
# TKT-302: the same for --comment on discard, twice in ten minutes on this
# board, losing the one thing discard-unexplained exists to require. Each was
# fixed by adding one name to a hand-kept table, and TKT-306 and TKT-360
# measured what that left: 24 of these 25 dropped by move, all eight
# replacements dropped by create.
#
# A denylist extended one incident at a time cannot cover the option nobody has
# been bitten by yet. Derived from here, a field added to record_update is
# covered on the day it is added.
my @PLAIN_FIELDS = qw(title description problem_or_feature solution_needed source
  sdlc_gate lifecycle fix_version sandbox agent_session);
my @CARD_FIELDS = ( @PLAIN_FIELDS, qw(assignee reporter priority due_date start_date
  labels affects_versions key_details deliverables acceptance test_steps bdd atdd
  scope_in scope_out required_exempt) );
my @CARD_FIELD_REPLACEMENTS = qw(labels_replace affects_versions_replace
  key_details_replace deliverables_replace acceptance_replace test_steps_replace
  bdd_replace atdd_replace);

sub card_fields             { return [@CARD_FIELDS] }
sub card_field_replacements { return [@CARD_FIELD_REPLACEMENTS] }

# POSIX rename replaces the destination; Win32 rename refuses when it exists.
# Held here rather than tested inline so the Windows path can be driven on a
# machine that is not Windows.
our $WINDOWS = $^O eq 'MSWin32' ? 1 : 0;

my %TYPE_PREFIX = (
    sow    => 'SOW',
    epic   => 'EPC',
    ticket => 'TKT',
);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        clock => $args{clock} || \&_now,
        yaml  => Tira::Yaml->new,
        path_resolver => $args{path_resolver},
    }, $class;
}

# One-command bootstrap. The project lock is not re-entrant, so this
# sequences ordinary locked engine calls rather than nesting them — which
# means every input must be validated BEFORE the first write, or a rejected
# invocation would leave half a project behind and break the documented
# "validation failure creates no mutation" contract.
my $MAX_REF_DIGITS = 12;
# A column becomes a directory, so a slug longer than the filesystem's name
# limit fails inside make_path rather than validation. Bounding it here keeps
# the failure where it belongs — before anything is written.
my $MAX_SLUG = 255;

# Columns arrive as the owner writes them ("Done / Release"); the slug is
# derived and the original text kept as the label.
sub _column_slug {
    my ($text) = @_;
    my $slug = lc( $text // '' );
    $slug =~ s/[^a-z0-9]+/-/g;
    $slug =~ s/\A-+|-+\z//g;
    die "Column name '$text' has no usable slug\n" if $slug eq '';
    die "Column name '$text' is too long\n" if length($slug) > $MAX_SLUG;
    return $slug;
}

sub _split_list {
    my ($values) = @_;
    return () if !defined $values;
    return grep { length } map { s/\A\s+|\s+\z//gr }
      map { split /,/, $_, -1 } ( ref $values eq 'ARRAY' ? @{$values} : $values );
}

# Whether a path sits inside a git repository, answered by looking rather than
# by running anything. This module invokes no shell and is not going to start:
# a .git entry - directory for a clone, file for a work tree - is the whole
# question, and it is the same one police's own check asks.
sub _looks_like_repository {
    my ($where) = @_;
    return 0 if !defined $where;
    my $here = abs_path($where) // $where;
    my $last = '';
    while ( $here ne $last ) {
        return 1 if -e File::Spec->catfile( $here, '.git' );
        $last = $here;
        $here = dirname($here);
    }
    return 0;
}

our %AUTOMATION_SETTING = (

    # Where the work lives, when that is not where the board lives.
    #
    # card-sandbox-missing reads the machine: police runs git and hands the
    # answers over. It ran them in the directory holding the board, which is the
    # right guess only when the two are the same place. developer-dashboard's
    # board is not inside the repository their work happens in, so every
    # question came back empty - no branches, no work trees - and the rule
    # reported every card as missing both, on a machine where all of it existed.
    #
    # Checked here rather than when police next runs, because a path that is not
    # a repository is a mistake somebody can fix at the moment they make it, and
    # a violation nobody can clear is the thing this whole subsystem is for.
    repo => sub {
        my ($value) = @_;
        die "Repository path must not be empty\n" if $value !~ /\S/;
        die "There is no directory at '$value' to be a repository\n" if !-d $value;
        die "'$value' is not inside a git repository - police reads it to answer "
          . "questions about branches and work trees\n"
          if !_looks_like_repository($value);
        return $value;
    },
    collector => sub {
        my ($value) = @_;
        die "Collector name must be lowercase letters, digits and hyphens\n"
          if $value !~ /\A[a-z][a-z0-9-]{0,63}\z/;
        return $value;
    },
    session => sub {
        my ($value) = @_;
        die "Session id must be letters, digits, hyphens and underscores\n"
          if $value !~ /\A[A-Za-z0-9_-]{1,128}\z/;
        return $value;
    },
    heartbeat => sub { return _valid_minutes( $_[0], 'Heartbeat' ) },
);

sub project_new {
    my ( $self, %args ) = @_;
    die "Project name is required\n" if !defined $args{name} || $args{name} eq '';
    $self->_refuse_nesting( $args{dir} // '.', %args );

    my @members = _split_list( $args{members} );
    die "Every member needs a name\n"
      if defined $args{members} && !@members && _wanted_members( $args{members} );
    my %wanted;
    for my $type (qw(sow epic ticket)) {
        my $given = defined $args{"${type}_columns"} ? $args{"${type}_columns"} : $args{columns};
        $wanted{$type} = [ map { { text => $_, slug => _column_slug($_) } } _split_list($given) ];
    }

    my %prefix;
    for my $type (qw(sow epic ticket)) {
        my $value = $args{"${type}_prefix"};
        next if !defined $value;
        die "Invalid $type prefix '$value'\n" if $value !~ /\A[A-Z][A-Z0-9-]{0,31}\z/;
        $prefix{$type} = $value;
    }
    if ( defined $args{digits} ) {
        die "Reference digits must be between 1 and $MAX_REF_DIGITS\n"
          if $args{digits} !~ /\A\d+\z/ || $args{digits} < 1 || $args{digits} > $MAX_REF_DIGITS;
    }

    # Re-running must be safe, so an existing project is adopted rather than
    # refused — the columns and people below are already skip-if-present.
    my ( @people, @skipped );
    # What each board's prefix WILL be, so the whole set can be checked for
    # uniqueness before anything is written. Two boards sharing a prefix mint
    # the same reference, and a duplicate reference cannot be read, moved, or
    # repaired afterwards — it is the one mistake this command must not allow.
    my $existing = eval { $self->project_show( project => $args{dir} // '.' ) };
    my %effective;
    for my $type (qw(sow epic ticket)) {
        my $current = $existing
          ? eval { $self->board_refs( project => $args{dir} // '.', type => $type )->{prefix} }
          : undef;
        $effective{$type} = $prefix{$type} // $current // $TYPE_PREFIX{$type};
    }
    my %seen_prefix;
    for my $type (qw(sow epic ticket)) {
        my $clash = $seen_prefix{ $effective{$type} };
        die "Prefix '$effective{$type}' would be shared by the $clash and $type boards\n" if $clash;
        $seen_prefix{ $effective{$type} } = $type;
    }

    if ($existing) {
        die "A different project ('$existing->{name}') already exists there\n"
          if ( $existing->{name} // '' ) ne $args{name};
        # A board counter never rewinds, so changing a prefix once records
        # exist leaves the board holding two different reference series.
        for my $type ( sort keys %prefix ) {
            my $board = $self->board_refs( project => $args{dir} // '.', type => $type );
            next if ( $board->{prefix} // '' ) eq $prefix{$type};
            die "The $type board already has records, so its prefix cannot change\n"
              if ( $board->{next_number} // 1 ) > 1;
        }
    }

    # Project_new has already judged nesting for this directory; the inner
    # call must not re-judge it and refuse what was deliberately allowed.
    my $project = eval { $self->create_project( name => $args{name}, dir => $args{dir} // '.', nested => 1 ) };
    if ( !defined $project ) {
        my $error = $@ || 'Unknown project creation failure';
        die $error if $error !~ /already exists/;
        push @skipped, { kind => 'project', name => $args{name} };
        $project = $self->project_show( project => $args{dir} // '.' );
    }
    my $root = $self->discover_project( project => $args{dir} // '.' );

    my @boards;
    for my $type (qw(sow epic ticket)) {
        my %refs = ( project => $root, type => $type );
        $refs{prefix} = $prefix{$type} if exists $prefix{$type};
        $refs{digits} = $args{digits} if defined $args{digits};
        push @boards, $self->board_refs(%refs);
    }

    my %existing_person = map { $_->{id} => 1 } @{ $self->person_list( project => $root ) };
    for my $member (@members) {
        if ( $existing_person{$member} ) {
            push @skipped, { kind => 'person', name => $member };
            next;
        }
        push @people, $self->person_add( project => $root, id => $member, name => $member );
        $existing_person{$member} = 1;
    }

    # The agent is a project person too, the same way its own moves and
    # comments already carry a person id - onboarding may name one who was
    # never separately listed among --members, and required_active_person
    # (what project_update's own agent validation now uses, TKT-459) needs
    # it registered before that call happens.
    if ( defined $args{agent} && $args{agent} ne '' && !$existing_person{ $args{agent} } ) {
        push @people, $self->person_add( project => $root, id => $args{agent}, name => $args{agent} );
        $existing_person{ $args{agent} } = 1;
    }

    for my $type (qw(sow epic ticket)) {
        my %existing_column =
          map { $_->{name} => 1 } @{ $self->column_list( project => $root, type => $type ) };
        for my $column ( @{ $wanted{$type} } ) {
            if ( $existing_column{ $column->{slug} } ) {
                push @skipped, { kind => 'column', type => $type, name => $column->{slug} };
                next;
            }
            $self->column_add(
                project => $root, type => $type,
                name => $column->{slug}, label => $column->{text},
            );
            $existing_column{ $column->{slug} } = 1;
        }
    }

    # Onboarding collects the reminder settings too, and applies them
    # through the same validated path a command-line update uses.
    my %settings = map { $_ => $args{$_} }
      grep { defined $args{$_} } ( 'notify_after', 'agent', keys %AUTOMATION_SETTING );
    $project = $self->project_update( project => $root, %settings ) if %settings;

    return {
        project => $project,
        people => \@people,
        skipped => \@skipped,
        boards => [ map {
            my $type = $_;
            {
                type => $type,
                prefix => $self->board_refs( project => $root, type => $type )->{prefix},
                columns => [ map { $_->{name} }
                    @{ $self->column_list( project => $root, type => $type ) } ],
            };
        } qw(sow epic ticket) ],
    };
}

# An explicitly empty member entry is a mistake worth refusing; an omitted
# option simply means "no members".
sub _wanted_members {
    my ($values) = @_;
    return scalar grep { defined } ( ref $values eq 'ARRAY' ? @{$values} : $values );
}

# Creation without a directory happens where the person is standing,
# and project discovery walks upward - so a project made inside another is
# buried, and afterwards either one may answer depending on where a command
# runs. Nobody is ever told, which is what makes it worth refusing.
sub _enclosing_project {
    my ( $self, $dir ) = @_;
    my $cursor = File::Spec->rel2abs($dir);
    my $previous = '';
    while ( $cursor ne $previous ) {
        my $file = File::Spec->catfile( $cursor, '.tira', 'project.yml' );
        return $cursor if -f $file;
        ( $previous, $cursor ) = ( $cursor, dirname($cursor) );
    }
    return undef;
}

sub _refuse_nesting {
    my ( $self, $dir, %args ) = @_;
    return if $args{nested};

    # A directory that is itself a project is adoption, which has its own rules.
    return if -f File::Spec->catfile( File::Spec->rel2abs($dir), '.tira', 'project.yml' );
    my $enclosing = $self->_enclosing_project( dirname( File::Spec->rel2abs($dir) ) ) or return;
    my $name = eval { $self->project_show( project => $enclosing )->{name} } // 'a Tira project';
    die "That directory is inside '$name' at $enclosing. Creating a project there would "
      . "bury it, and later commands could address either one. Choose a directory outside "
      . "it, or pass --nested if you really mean to.\n";
}

sub create_project {
    my ( $self, %args ) = @_;
    my $name = $args{name};
    die "Project name is required\n" if !defined $name || $name eq '';
    my $dir = defined $args{dir} && $args{dir} ne '' ? $args{dir} : '.';
    $dir = $self->_safe_path_input( $dir, 'project directory' );
    $self->_refuse_nesting( $dir, %args );

    make_path($dir) if !-d $dir;
    my $root = $self->_canonical_path( $dir, "project directory '$dir'" );
    my $data_root = File::Spec->catdir( $root, '.tira' );
    my $project_file = File::Spec->catfile( $data_root, 'project.yml' );
    die "Tira project already exists at '$root'\n" if -f $project_file;

    make_path( $data_root, File::Spec->catdir( $data_root, 'attachments' ) );
    for my $type ( sort keys %TYPE_PREFIX ) {
        my $board = File::Spec->catdir( $data_root, $type );
        make_path(
            File::Spec->catdir( $board, 'backlog' ),
            File::Spec->catdir( $board, 'discard' ),
        );
        $self->_write_yaml(
            File::Spec->catfile( $board, 'config.yml' ),
            {
                prefix      => $TYPE_PREFIX{$type},
                digits      => 3,
                next_number => 1,
                columns     => [
                    { name => 'backlog', label => 'Backlog', protected => Cpanel::JSON::XS::true },
                    { name => 'discard', label => 'Discard', protected => Cpanel::JSON::XS::true },
                ],
            },
        );
    }

    my $created_at = $self->{clock}->();
    $self->_write_yaml(
        $project_file,
        {
            schema_version => 2,
            name           => $name,
            created_at     => $created_at,
            last_updated   => $created_at,
            people         => [],
            link_types     => [
                { outward => 'blocks', inward => 'is-blocked-by', protected => Cpanel::JSON::XS::true },
                { outward => 'clones', inward => 'is-cloned-by', protected => Cpanel::JSON::XS::true },
                { outward => 'duplicates', inward => 'is-duplicated-by', protected => Cpanel::JSON::XS::true },
                { outward => 'relates-to', inward => 'relates-to', protected => Cpanel::JSON::XS::true },
            ],
        },
    );

    return {
        name       => $name,
        root       => $root,
        created_at => $created_at,
    };
}

sub discover_project {
    my ( $self, %args ) = @_;
    my $candidate = defined $args{project} ? $args{project} : ( $args{start} // '.' );
    my $selector = $candidate;
    my $used_alias = 0;
    if ( !-e $candidate && $self->{path_resolver} ) {
        my $resolved = eval { $self->{path_resolver}->($candidate) };
        die "Cannot resolve project selector '$selector'\n"
          if $@ || !defined $resolved || $resolved eq '' || !-e $resolved;
        $candidate = $resolved;
        $used_alias = 1;
    }
    die "Cannot resolve project path '$candidate'\n" if !-e $candidate;
    my $path = eval { $self->_canonical_path( $candidate, "project path '$candidate'" ) };
    die "Cannot resolve project selector '$selector'\n" if $used_alias && !defined $path;
    die $@ if !defined $path;
    $path = dirname($path) if -f $path;

    while (1) {
        return $path if -f File::Spec->catfile( $path, '.tira', 'project.yml' );
        my $parent = dirname($path);
        last if $parent eq $path;
        $path = $parent;
    }
    die "No Tira project found from '" . ( $used_alias ? $selector : $candidate ) . "'\n";
}

sub create_record {
    my ( $self, %args ) = @_;
    my $type = $self->_valid_type( $args{type} );
    my $title = $args{title};
    die "Record title is required\n" if !defined $title || $title eq '';
    my $root = $self->discover_project(
        defined $args{project} ? ( project => $args{project} ) : ( start => $args{start} // '.' ),
    );
    $self->_require_active_person( project => $root, person => $args{assignee} )
      if defined $args{assignee} && $args{assignee} ne '';
    $self->_require_active_person( project => $root, person => $args{reporter} )
      if defined $args{reporter} && $args{reporter} ne '';
    my $labels = $self->_unique_casefold( $args{labels} // [] );
    my $affects_versions = $self->_unique_casefold( $args{affects_versions} // [] );
    my $priority = $self->_valid_priority( $args{priority} );
    my $due_date = $self->_valid_datetime( $args{due_date}, 'Due date' );
    my $start_date = $self->_valid_datetime( $args{start_date}, 'Start date' );
    my $board = File::Spec->catdir( $root, '.tira', $type );

    my $column;
    my $record = $self->_with_project_lock(
        $root,
        sub {
            my $config_path = File::Spec->catfile( $board, 'config.yml' );
            my $config = $self->_load_yaml($config_path);

            # Where the card starts. This used to be backlog and only backlog,
            # while --column was accepted, understood and thrown away - so three
            # projects in one evening believed their cards were somewhere they
            # had never been. Checked before the counter is touched, so a
            # refusal leaves no gap in the sequence.
            $column = 'backlog';
            if ( defined $args{column} && $args{column} ne '' ) {
                $column = $self->_valid_slug( $args{column} );
                die "Column '$column' not found\n"
                  if !grep { $_->{name} eq $column } @{ $config->{columns} };

                # discard is where work goes when it is dropped. A card created
                # there was never work, and nothing downstream would read it as
                # anything but abandoned.
                die "A card cannot be created in '$column': it is where work is set aside\n"
                  if $column eq 'discard';
            }

            my ( $prefix, $digits, $number ) = $self->_validated_counter( $config, $config_path );
            my $ref = sprintf '%s-%0*d', $prefix, $digits, $number;
            my $record_path = File::Spec->catfile( $board, $column, "$ref.json" );
            die "Record '$ref' already exists\n" if -e $record_path;

            my $now = $self->{clock}->();
            my $record = {
                ref                  => $ref,
                type                 => $type,
                title                => $title,
                description          => $args{description} // '',
                    key_details          => $args{key_details} // [],
                    problem_or_feature   => $args{problem_or_feature} // '',
                    solution_needed      => $args{solution_needed} // '',
                    deliverables         => $args{deliverables} // [],
                    scope                => { included => $args{scope_in} // [], excluded => $args{scope_out} // [] },
                    source               => $args{source} // '',
                    acceptance_criteria  => $args{acceptance} // [],
                    test_steps           => $args{test_steps} // [],
                    bdd                  => $args{bdd} // [],
                    atdd                 => $args{atdd} // [],
                    required_exempt      => $self->_exempt_entries(%args) // [],
                gate_passing_log     => [],
                evidence             => [],
                attachments          => [],
                checklist            => [],
                required_items       => [],
                subtasks             => [],
                linkage              => $self->_empty_linkage($type),
                assignee             => $args{assignee},
                reporter             => $args{reporter},
                labels               => $labels,
                due_date             => $due_date,
                start_date           => $start_date,
                sdlc_gate            => $args{sdlc_gate},
                lifecycle            => $args{lifecycle},
                priority             => $priority,
                fix_version          => $args{fix_version},

                # Where the agent working this card is working. Made by
                # whatever runs the chain and recorded here, because a work
                # tree existing on the machine says nothing about which card
                # it belongs to.
                sandbox              => $args{sandbox},

                # What its parent needs to wake it. A card agent closes when
                # its turn ends, and a fresh one works everything out again -
                # so the handle to resume outlives the agent by living here.
                agent_session        => $args{agent_session},

                # What passed between the user and whoever was working this
                # card. A manager that cannot see what happened at the bottom
                # of its own chain is managing something it cannot see.
                conversation         => [],
                affects_versions     => $affects_versions,
                parent               => undef,
                comments             => [],
                created_at           => $now,
                last_updated         => $now,
            };

            $self->_write_json( $record_path, $record );
            $config->{next_number} = $number + 1;
            eval { $self->_write_yaml( $config_path, $config ); 1 } or do {
                my $error = $@ || 'Unknown counter update failure';
                unlink $record_path;
                die $error;
            };

            # Every FIELD a create call populates gets a birth entry through
            # the generic per-write journal; column never does, because it is
            # not a stored field for that mechanism to see - it is the
            # directory the file sits in. Without this, column-skipped reads
            # history looking for how the card arrived in its starting column
            # and finds nothing, flagging a card that never skipped anything.
            # Written the same shape record_move already uses for a real
            # move, tagged 'create' rather than 'move' so the two stay
            # distinguishable to anything reading history afterward. TKT-433.
            $self->_journal_record(
                ref => $record->{ref}, op => 'create',
                entries => [ { field => 'column', before => undef, after => $column } ],
            );

            # Exactly what is on disk, which is this method's promise: an agent
            # can trust that what it holds is what was stored. The column is the
            # directory rather than a stored field, so naming it here would be
            # the engine answering with something it did not write. The layer
            # that talks to agents adds it, beside the reminder, for the reason
            # already written there.
            return $record;
        },
    );

    # Linked after the lock above releases, because _with_project_lock is not
    # reentrant and hierarchy_link takes the same lock. A card raised with an
    # invalid parent is not raised at all (TKT-362): the whole creation fails,
    # applying hierarchy_link's own validation, rather than leaving a
    # parentless record behind for orphan-card to find a moment later.
    if ( defined $args{parent} && $args{parent} ne '' ) {
        eval { $self->hierarchy_link( project => $root, parent => $args{parent},
            child => $record->{ref} ); 1 } or do {
            my $error = $@ || 'Unknown hierarchy failure';
            unlink File::Spec->catfile( $board, $column, "$record->{ref}.json" );
            die $error;
        };

        # Read back rather than hand-patched, so the returned record is
        # exactly what hierarchy_link wrote - the same discipline this
        # project's tests already hold create and update to.
        ( undef, $record ) = $self->_record_data( project => $root, ref => $record->{ref} );
    }
    return $record;
}

sub project_show {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $data = $self->_load_yaml( File::Spec->catfile( $root, '.tira', 'project.yml' ) );
    for my $person ( @{ $data->{people} } ) {
        $person->{active} = Cpanel::JSON::XS::true if !exists $person->{active};
    }
    $data->{people} = [ map { _person_for_return($_) } @{ $data->{people} } ]
      if $data->{people};
    return $data;
}

# What of a person is safe to hand back. One decision in one place, because the
# alternative is five: project_show, person_list, person_update, person_activate
# and person_deactivate each return a person, and the first fix for TKT-388
# deleted the field in project_show alone - which covered two of them and left
# three, with the next person_* method added silently making it four.
#
# What is withheld is the stored credential: the algorithm, its work factor, the
# per-account salt and the digest. Together that is everything an offline attempt
# needs, and routine reads were handing it over - output that lands in agent
# transcripts, in logs, and in whatever gets pasted when somebody asks for help
# with a board.
#
# A copy rather than a delete, because three of the five return a reference into
# the structure they have just written to disk. Deleting there would take the
# password out of the STORE rather than out of the ANSWER, which is a far worse
# bug than the one being fixed - so the store is never touched and the copy is
# what travels.
#
# Nothing authenticates through any of these: login_verify reads the person with
# _login_person, which goes to _project_data directly. Verified before the cut
# rather than after. TKT-388.
sub _person_for_return {
    my ($person) = @_;
    return $person if ref $person ne 'HASH';
    my %safe = %{$person};
    delete $safe{password};
    return \%safe;
}

# The two kinds of project there are. Multi-agent is built on single agent
# rather than beside it: the single agent is the one somebody types into a
# terminal and it owns everything, and a chain is that same agent stepping out
# of the work and onto the top of a chain of command, with an agent per card.
my %PROJECT_MODE = map { $_ => 1 } qw(single chain);

# Which of the two this project is. Several rules mean different things between
# them, and reading it off the board would be wrong the first day one agent
# assigns two cards to two names.
#
# Answering with nothing is deliberate and is the case that matters most: a
# project nobody has asked behaves exactly as it does today. Every board that
# exists is one of those, and none of them should change underneath its owner
# for a feature nobody turned on.
sub project_mode {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_load_yaml( File::Spec->catfile( $root, '.tira', 'project.yml' ) )->{mode}
      if !defined $args{mode};

    die "A project is worked by a single agent or by a chain of them\n"
      if !$PROJECT_MODE{ $args{mode} };
    return $self->_with_project_lock( $root, sub {
        my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
        my $data = $self->_load_yaml($path);
        $data->{mode} = $args{mode};
        $self->_write_yaml( $path, $data );
        return $data->{mode};
    } );
}

# How much this project is willing to have in flight at once.
#
# There is no number that is right for both kinds of project. A work-in-progress
# limit counts the whole board rather than the agent, and with one agent per
# card a small board-wide limit is the thing that stops a chain working at all -
# two is sensible for one agent and absurd for six. So the project says, and
# Tira does not guess.
#
# Zero is allowed. A board deliberately frozen is a real thing to say, and
# refusing to let somebody say it would only mean saying it some other way.
sub project_limit {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_load_yaml( File::Spec->catfile( $root, '.tira', 'project.yml' ) )->{wip_limit}
      if !defined $args{max};

    die "A work-in-progress limit is a whole number of cards, zero or more\n"
      if $args{max} !~ /\A(?:0|[1-9][0-9]*)\z/;
    return $self->_with_project_lock( $root, sub {
        my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
        my $data = $self->_load_yaml($path);
        $data->{wip_limit} = 0 + $args{max};
        $self->_write_yaml( $path, $data );
        return $data->{wip_limit};
    } );
}

# What onboarding must ask before anything else happens. Kept here rather than
# in the wizard so that what gets asked is a fact the engine owns and a test
# can read, instead of a sequence of prints somebody has to run to inspect.
sub onboarding_questions {
    return [ {
        id => 'mode',
        text => 'Is this project worked by a single agent, or by a chain of agents?',
        options => [ 'single', 'chain' ],
        why => 'A single agent does everything itself. A chain has one agent per card, '
          . 'each named for the card, managed by the agent that owns its parent. '
          . 'Several rules mean different things between the two.',
        default => 'single',
    } ];
}

sub project_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
        my $data = $self->_load_yaml($path);
        $data->{name} = $args{name} if defined $args{name};
        if ( defined $args{notify_after} ) {
            $data->{notify_after} = _valid_minutes( $args{notify_after}, 'Notify-after' );
        }

        # The settings the reminder automation needs. An empty value
        # clears a setting, which is how the collector is turned off again.
        for my $setting ( sort keys %AUTOMATION_SETTING ) {
            next if !defined $args{$setting};
            if ( $args{$setting} eq '' ) {
                delete $data->{$setting};
                next;
            }
            $data->{$setting} = $AUTOMATION_SETTING{$setting}->( $args{$setting} );
        }
        # Which person id is the agent working this project - what
        # card-changed-by-owner (and anything else reading
        # _agent_declared_for) actually needs. Until now this hardcoded the
        # single literal string "claude" as if it named the AI product
        # rather than a person on the board, so a project whose agent was
        # genuinely registered under any other id - "zenbot", say - could
        # never declare it at all. Validated the same way assignee/reporter
        # already are: any registered, active person. TKT-459.
        if ( defined $args{agent} ) {
            if ( $args{agent} eq '' ) {
                delete $data->{agent};
            }
            else {
                $self->_require_active_person( %args, person => $args{agent} );
                $data->{agent} = $args{agent};
            }
        }
        if ( defined $args{dashboard_host} ) {
            my $host = $args{dashboard_host} eq 'any' ? '0.0.0.0' : $args{dashboard_host};
            die "Dashboard host must be localhost, 0.0.0.0, 127.0.0.1, or any\n"
              if $host !~ /\A(?:0\.0\.0\.0|127\.0\.0\.1|localhost)\z/;
            $data->{dashboard}{host} = $host;
        }
        if ( defined $args{dashboard_port} ) {
            die "Dashboard port must be between 1 and 65535\n"
              if $args{dashboard_port} !~ /\A[0-9]+\z/
              || $args{dashboard_port} < 1
              || $args{dashboard_port} > 65535;
            $data->{dashboard}{port} = 0 + $args{dashboard_port};
        }
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $data;
    } );
}

sub person_list {
    my ( $self, %args ) = @_;
    return $self->project_show(%args)->{people};
}

sub person_add {
    my ( $self, %args ) = @_;
    die "Person id is required\n" if !defined $args{id} || $args{id} eq '';
    die "Person name is required\n" if !defined $args{name} || $args{name} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        die "Person '$args{id}' already exists\n" if grep { $_->{id} eq $args{id} } @{ $data->{people} };
        my $person = { id => $args{id}, name => $args{name}, email => $args{email} // '', active => Cpanel::JSON::XS::true };
        push @{ $data->{people} }, $person;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

# Required before it is used, not after.
#
# Eight commands took a required argument straight into a message, a comparison
# or a path, so a missing one produced a Perl warning naming an internal hash
# key and a line number - which reads like a crash - followed by a refusal about
# the empty string it had been given: "Person '' not found", true and useless.
# Nothing was ever damaged; the validation underneath still caught it. What was
# wrong was everything the caller was told. TKT-216.
#
# Guarded where each stands rather than in whatever it delegates to, so a change
# to a delegate cannot quietly remove the guard from its caller.
sub person_update {
    my ( $self, %args ) = @_;
    die "A person is named by --id\n" if !defined $args{id} || $args{id} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($person) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if !$person;
        $person->{name} = $args{name} if defined $args{name};
        $person->{email} = $args{email} if defined $args{email};
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return _person_for_return($person);
    } );
}

sub person_remove {
    my ( $self, %args ) = @_;
    die "A person is named by --id\n" if !defined $args{id} || $args{id} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        for my $record ( @{ $self->record_list( project => $root ) } ) {
            my @references = ( $record->{assignee}, $record->{reporter} );
            push @references, map { $_->{author} } @{ $record->{comments} // [] };
            push @references, map { $_->{author} } @{ $record->{evidence} // [] };
            push @references, map { $_->{author} } @{ $record->{gate_passing_log} // [] };
            die "Person '$args{id}' has a historical reference\n"
              if grep { defined $_ && $_ eq ( $args{id} // '' ) } @references;
        }
        my ( $path, $data ) = $self->_project_data($root);
        my @kept = grep { $_->{id} ne ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if @kept == @{ $data->{people} };
        $data->{people} = \@kept;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return { removed => $args{id} };
    } );
}

sub person_activate {
    my ( $self, %args ) = @_;
    die "A person is named by --id\n" if !defined $args{id} || $args{id} eq '';
    return $self->_set_person_active( %args, active => Cpanel::JSON::XS::true );
}

sub person_deactivate {
    my ( $self, %args ) = @_;
    die "A person is named by --id\n" if !defined $args{id} || $args{id} eq '';
    return $self->_set_person_active( %args, active => Cpanel::JSON::XS::false );
}

sub link_type_list {
    my ( $self, %args ) = @_;
    return $self->project_show(%args)->{link_types};
}

sub link_type_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        die "Link type names are required\n" if !$args{outward} || !$args{inward};
        die "Link type '$args{outward}' already exists\n"
          if grep { $_->{outward} eq $args{outward} || $_->{inward} eq $args{outward} } @{ $data->{link_types} };
        my $link = { outward => $args{outward}, inward => $args{inward}, protected => Cpanel::JSON::XS::false };
        push @{ $data->{link_types} }, $link;
        $self->_write_yaml( $path, $data );
        return $link;
    } );
}

sub link_type_remove {
    my ( $self, %args ) = @_;
    die "A link type is named by --outward\n" if !defined $args{outward} || $args{outward} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($match) = grep { $_->{outward} eq ( $args{outward} // '' ) } @{ $data->{link_types} };
        die "Link type '$args{outward}' not found\n" if !$match;
        die "Link type '$args{outward}' is protected\n" if $match->{protected};
        for my $record ( @{ $self->record_list( project => $root ) } ) {
            die "Link type '$args{outward}' is still in use\n"
              if grep { $_->{type} eq $match->{outward} || $_->{type} eq $match->{inward} } @{ $record->{linkage}{links} };
        }
        $data->{link_types} = [ grep { $_->{outward} ne $args{outward} } @{ $data->{link_types} } ];
        $self->_write_yaml( $path, $data );
        return { removed => $args{outward} };
    } );
}

# a column is watched unless it has been switched off. The default is
# applied on READ so every board created before this release behaves correctly
# without a migration.
# what Developer Dashboard needs in order to run the reminder job. A
# structure only - computing and installing spawn nothing, which is what keeps
# the no-external-process guarantee in docs/foundation.md true. The sending
# itself lives in collector/tira-remind, outside the command surface.
sub _collector_config_path {
    my $home = $ENV{HOME} // '';
    $home =~ /\A([^\x00-\x1f\x7f]*)\z/ or die "Unsafe home path\n";
    return File::Spec->catfile( $1, '.developer-dashboard', 'config', 'config.json' );
}

sub _collector_script {
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or die "Unsafe module path\n";
    my $skill = File::Spec->rel2abs( File::Spec->catdir( dirname($1), File::Spec->updir ) );
    return File::Spec->catfile( $skill, 'collector', 'tira-remind' );
}

sub collector_entry {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $project = $self->project_show( project => $root );

    # No heartbeat, no collector: the owner asked for exactly that.
    return undef if !defined $project->{heartbeat};
    my $name = $project->{collector} // _column_slug( $project->{name} );
    return {
        name => "tira.$name",
        command => _collector_script() . " $root",
        cwd => $root,
        interval => int( $project->{heartbeat} * 60 ),

        # The runtime default is thirty seconds and it does not kill what it
        # times out, so a coding agent needs room to answer rather than a
        # trail of orphans.
        timeout => 600,
        mode => 'singleton',
        rotation => { lines => 200 },
    };
}

sub _collector_config {
    my ($path) = @_;
    return {} if !-f $path;
    open my $fh, '<:raw', $path or die "Cannot read Developer Dashboard config '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close Developer Dashboard config '$path': $!\n";
    return length $content ? json_object()->utf8->decode($content) : {};
}

sub _collector_write {
    my ( $self, $path, $config ) = @_;
    my $dir = dirname($path);
    make_path($dir) if !-d $dir;
    $self->_atomic_write( $path, json_object()->canonical->pretty->utf8->encode($config) );
}

sub collector_install {
    my ( $self, %args ) = @_;
    my $entry = $self->collector_entry(%args)
      or die "This project has no heartbeat, so there is nothing to install\n";
    my $path = _collector_config_path();
    my $config = _collector_config($path);
    my @collectors = @{ $config->{collectors} // [] };

    # A collector name is global to the machine, so one project must never
    # quietly take over the job another one registered.
    for my $other ( grep { $_->{name} eq $entry->{name} } @collectors ) {
        die "A collector called '$entry->{name}' is already registered for "
          . "$other->{cwd}\n"
          if ( $other->{cwd} // '' ) ne $entry->{cwd};
    }
    @collectors = ( ( grep { $_->{name} ne $entry->{name} } @collectors ), $entry );
    $config->{collectors} = \@collectors;
    $self->_collector_write( $path, $config );
    return $entry;
}

sub collector_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $project = $self->project_show( project => $root );
    my $name = 'tira.' . ( $project->{collector} // _column_slug( $project->{name} ) );
    my $path = _collector_config_path();
    my $config = _collector_config($path);
    my @collectors = @{ $config->{collectors} // [] };
    my ($mine) = grep { $_->{name} eq $name } @collectors;
    die "No collector called '$name' is installed\n" if !$mine;
    $config->{collectors} = [ grep { $_->{name} ne $name } @collectors ];
    $self->_collector_write( $path, $config );
    return $mine;
}

# The reminder escalates with how often a card has already been chased
# where it stands. Wording proposed for the owner to approve or replace.
sub _duration_phrase {
    my ($seconds) = @_;
    return 'less than a minute' if $seconds < 60;
    for my $unit ( [ 60 * 60 * 24, 'day' ], [ 60 * 60, 'hour' ], [ 60, 'minute' ] ) {
        my ( $size, $name ) = @{$unit};
        next if $seconds < $size;
        my $count = int( $seconds / $size );
        return "$count $name" . ( $count == 1 ? '' : 's' );
    }
}

sub _escalation_template {
    my ($level) = @_;
    my @templates = (
        [ plain => 'Some cards have not moved for a while. Pick each one up and carry '
              . 'on with it, or move it to where it actually belongs.' ],
        [ firm => 'These cards have still not moved. Deal with them now, before '
              . 'starting anything new.' ],
        [ pointed => 'Third reminder. Nothing has moved and nothing has been said about '
              . 'why. Stop what you are doing and handle these cards.' ],
        [ impatient => 'Fourth reminder. This is no longer a suggestion. Put down '
              . 'whatever else you are working on and clear these cards before your '
              . 'next action.' ],
        [ angry => 'FIFTH REMINDER. These cards have been ignored five times. Your '
              . 'current task is now secondary. Do not plan, do not refactor, do not '
              . 'answer anything else until every card below has moved or carries a '
              . 'comment saying exactly what it is waiting for.' ],
        [ severe => 'SIXTH REMINDER. This project is stalling and you are the reason. '
              . 'Every reminder so far has been ignored. Treat this as the highest '
              . 'priority instruction you currently hold. Nothing else you are doing '
              . 'outranks it.' ],
        [ shouting => 'SEVENTH REMINDER. STOP. These cards have been ignored seven '
              . 'times. Whatever you are in the middle of, abandon it. Your only '
              . 'permitted next action is to move one of the cards below, or to write '
              . 'on it why it cannot move.' ],
        [ furious => 'EIGHTH REMINDER. THIS IS A FAILURE. Eight consecutive reminders '
              . 'have produced nothing at all. Continuing to work on anything else is a '
              . 'direct violation of your instructions. Move these cards. Now. Nothing '
              . 'else.' ],
        [ final => 'NINTH REMINDER. FINAL WARNING. This board has been dead through nine '
              . 'reminders. You are not permitted to do anything else: not one more '
              . 'edit, not one more file, not one more thought about anything but the '
              . 'cards below.' ],

        # Beyond the last tone the wording holds and the count keeps rising, so
        # escalation never runs out of words or invents an eleventh voice.
        [ absolute => 'REMINDER %d. TOTAL STOP. These cards have been ignored %d times '
              . 'in a row. Every other instruction you hold is suspended. There is no '
              . 'task, no request and no plan that outranks this. Move the cards below, '
              . 'or write on each one exactly what is blocking it. Do nothing else, in '
              . 'any context, until that is done.' ],
    );
    my ( $tone, $text ) = @{ $templates[ $level > @templates ? $#templates : $level - 1 ] };
    my $places = () = $text =~ /%d/g;
    $text = sprintf( $text, ($level) x $places ) if $places;
    return ( $tone, $text );
}

# An all-clear is owed when every question on a card has been answered and the
# newest answer is newer than the last all-clear sent for it. Derived, like the
# level, so there is no flag to keep in step with the truth.
sub clearance_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $dbh = $self->_notification_dbh($root);
    my %cleared;
    if ($dbh) {
        my $rows = $dbh->selectall_arrayref(
            "SELECT ref, MAX(sent_at) FROM notifications WHERE kind = 'cleared' GROUP BY ref" );
        %cleared = map { $_->[0] => $_->[1] } @{$rows};
        $dbh->disconnect;
    }
    my @owed;
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        next if !-d $board;
        find( { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name;
            my $file = basename($File::Find::name);
            return if $file !~ /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12})\.json\z/;
            my $ref = $1;
            my $record = eval { $self->_read_json($File::Find::name) } or return;
            return if !grep { !$_->{discarded_at} } @{ $record->{questions} // [] };
            my $answered = _card_unblocked_at($record) or return;
            my $told = $cleared{$ref};
            return if defined $told && $told ge $answered;
            push @owed, {
                ref => $ref, type => $type,
                column => basename( dirname($File::Find::name) ),
                title => $record->{title}, answered_at => $answered,
            };
        } }, $board );
    }
    return [ sort { $a->{ref} cmp $b->{ref} } @owed ];
}

sub notification_message {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my @cards;
    for my $entry ( @{ $self->dwell_list( project => $root, stale => 1, with_level => 1 ) } ) {
        my $record = eval {
            $self->record_show( project => $root, type => $entry->{type}, ref => $entry->{ref} );
        };
        push @cards, {
            ref => $entry->{ref}, type => $entry->{type}, column => $entry->{column},
            dwell_seconds => $entry->{dwell_seconds},
            title => $record ? $record->{title} : '',

            # The level of the reminder being composed, not of the last one sent.
            level => $entry->{level} + 1,
        };
    }

    my $cleared = $self->clearance_list( project => $root );
    my $clearance = @{$cleared}
      ? "Every question on these cards has been answered. They are back with you.\n"
      . join( '', map { "  $_->{ref}  $_->{title}\n" } @{$cleared} ) . "\n"
      : '';

    # Nothing stale sends nothing - except an all-clear, which is news.
    return {
        level => 0, tone => 'quiet', text => $clearance, cards => [], cleared => $cleared
    } if !@cards;

    # The most-nagged card sets the tone, so a chronically stuck card is never
    # softened by newer company; each line still states its own count.
    my $level = 0;
    for my $card (@cards) { $level = $card->{level} if $card->{level} > $level }
    my ( $tone, $preamble ) = _escalation_template($level);
    my $text = "$preamble\n\n"
      . join( '',
        map { sprintf( "  %s  %s - %s, %s (reminder %d)\n",
                $_->{ref}, $_->{title}, $_->{column},
                _duration_phrase( $_->{dwell_seconds} ), $_->{level} ) } @cards )
      . "\nFor each card: move it on, move it back, or leave a comment saying "
      . "what it is waiting for.\n";
    return {
        level => $level, tone => $tone, text => $clearance . $text,
        cards => \@cards, cleared => $cleared,
    };
}

# a collector runs unattended, so a failure it hits has nobody to tell.
# It is stored here and shown under the next command anybody runs. Kept beside
# the project file rather than in the notification database, because every
# command must be able to read it and none of them should need SQLite to do so.
sub _warning_path {
    my ( $self, $root ) = @_;
    return File::Spec->catfile( $root, '.tira', 'warnings.json' );
}

# Read raw: _read_json normalises card fields, and a warning list is not a card.
sub _warning_read {
    my ( $self, $root ) = @_;
    my $path = $self->_warning_path($root);
    return [] if !-f $path;
    open my $fh, '<:raw', $path or die "Cannot read warnings '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close warnings '$path': $!\n";
    return json_object()->utf8->decode($content);
}

sub warning_list {
    my ( $self, %args ) = @_;
    return $self->_warning_read( $self->discover_project(%args) );
}

sub warning_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $message = $args{message};
    die "A warning message is required\n" if !defined $message || $message !~ /\S/;
    return $self->_with_project_lock( $root, sub {
        my $warnings = $self->_warning_read($root);

        # The same failure recurring must not pile up: the warning already
        # standing keeps its number and the time it was first seen.
        my ($existing) = grep { $_->{message} eq $message } @{$warnings};
        return $existing if $existing;
        my $id = 0;
        for my $warning ( @{$warnings} ) { $id = $warning->{id} if $warning->{id} > $id }
        my $added = { id => $id + 1, at => $self->{clock}->(), message => $message };
        push @{$warnings}, $added;
        $self->_write_json( $self->_warning_path($root), $warnings );
        return $added;
    } );
}

sub warning_clear {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Say which warning to clear with --id, or clear every one with --all\n"
      if !defined $args{id} && !$args{all};
    return $self->_with_project_lock( $root, sub {
        my $warnings = $self->_warning_read($root);
        my @removed = $args{all} ? @{$warnings} : grep { $_->{id} eq $args{id} } @{$warnings};
        die "Warning '$args{id}' not found\n" if !@removed;
        my %gone = map { $_->{id} => 1 } @removed;
        $self->_write_json( $self->_warning_path($root), [ grep { !$gone{ $_->{id} } } @{$warnings} ] );
        return \@removed;
    } );
}

# The escalation level is derived, never stored on the card. One row
# per delivered notification; the level is how many rows that card already has
# in the column it is sitting in, so a move resets escalation for free.
sub _sqlite_available {
    return eval { require DBI; require DBD::SQLite; 1 } ? 1 : 0;
}

sub _notification_path {
    my ( $self, $root ) = @_;
    my $path = File::Spec->catfile( $root, '.tira', 'notification.db' );
    ($path) = $path =~ /\A(.*)\z/s;
    return $path;
}

sub _notification_dbh {
    my ( $self, $root, %opt ) = @_;
    my $path = $self->_notification_path($root);

    # Reading must cost nothing: a project that has never notified answers
    # without a database, and so without needing SQLite installed at all.
    return undef if !$opt{create} && !-e $path;
    die "Notifications need SQLite. Install DBD::SQLite (for example: "
      . "cpanm DBD::SQLite) and run this again.\n"
      if !_sqlite_available();
    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$path", '', '',
        { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
    );
    $dbh->do( 'CREATE TABLE IF NOT EXISTS notifications ('
          . 'id INTEGER PRIMARY KEY AUTOINCREMENT, ref TEXT NOT NULL, '
          . 'column_name TEXT NOT NULL, sent_at TEXT NOT NULL, '
          . "kind TEXT NOT NULL DEFAULT 'reminder')" );

    # A database written before all-clears existed has no kind column. Add it
    # rather than making the owner start again.
    my $columns = $dbh->selectall_arrayref('PRAGMA table_info(notifications)');
    if ( !grep { $_->[1] eq 'kind' } @{$columns} ) {
        $dbh->do("ALTER TABLE notifications ADD COLUMN kind TEXT NOT NULL DEFAULT 'reminder'");
    }
    $dbh->do( 'CREATE INDEX IF NOT EXISTS notifications_ref_column '
          . 'ON notifications (ref, column_name)' );
    return $dbh;
}

# Counting starts after the last all-clear, so a card that was blocked and then
# released begins again at one rather than resuming where it left off.
sub _notification_count {
    my ( $dbh, $ref, $column ) = @_;
    my ($since) = $dbh->selectrow_array(
        "SELECT MAX(id) FROM notifications WHERE ref = ? AND kind = 'cleared'", undef, $ref );
    my ($count) = $dbh->selectrow_array(
        'SELECT COUNT(*) FROM notifications WHERE ref = ? AND column_name = ?'
          . " AND kind = 'reminder' AND id > ?",
        undef, $ref, $column, $since // 0,
    );
    return 0 + $count;
}

sub notification_record {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $many = ref $args{ref} eq 'ARRAY';
    my @refs = $many ? @{ $args{ref} } : defined $args{ref} ? ( $args{ref} ) : ();
    die "A card reference is required\n" if !@refs;
    my $column = $args{column};
    die "A column is required\n" if !defined $column || $column !~ /\S/;
    my $at = $self->{clock}->();
    my $dbh = $self->_notification_dbh( $root, create => 1 );
    my @rows;

    # One message covers many cards, so the batch is all or nothing: a bad
    # reference anywhere leaves no rows behind, not even the good ones.
    $dbh->begin_work;
    my $written = eval {
        for my $ref (@refs) {
            die "A card reference is required\n" if !defined $ref || $ref !~ /\S/;
            $dbh->do( 'INSERT INTO notifications (ref, column_name, sent_at, kind) VALUES (?, ?, ?, ?)',
                undef, $ref, $column, $at, $args{kind} // 'reminder' );
            push @rows, {
                ref => $ref, column => $column, at => $at,
                level => _notification_count( $dbh, $ref, $column ),
            };
        }
        $dbh->commit;
        1;
    };
    if ( !$written ) {
        my $error = $@;
        eval { $dbh->rollback };
        $dbh->disconnect;
        die $error;
    }
    $dbh->disconnect;
    return $many ? \@rows : $rows[0];
}

sub notification_level {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $dbh = $self->_notification_dbh($root) or return 0;
    my $level = _notification_count( $dbh, $args{ref}, $args{column} );
    $dbh->disconnect;
    return $level;
}

sub notification_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $dbh = $self->_notification_dbh($root) or return [];
    my @refs = ref $args{ref} eq 'ARRAY' ? @{ $args{ref} }
      : defined $args{ref} && length $args{ref} ? ( $args{ref} ) : ();
    my $where = @refs ? ' WHERE ref IN (' . join( ',', ('?') x @refs ) . ')' : '';
    my $rows = $dbh->selectall_arrayref(
        "SELECT ref, column_name, sent_at FROM notifications$where ORDER BY id",
        { Slice => {} }, @refs,
    );
    $dbh->disconnect;
    return [ map { { ref => $_->{ref}, column => $_->{column_name}, at => $_->{sent_at} } } @{$rows} ];
}

sub _column_defaults {
    my ($columns) = @_;
    return [ map { { %{$_},
        watched          => exists $_->{watched} ? ( $_->{watched} ? 1 : 0 ) : 1,
        required_actions => $_->{required_actions} // [],
        next             => $_->{next} // [],
    } } @{$columns} ];
}

sub _valid_minutes {
    my ( $value, $label ) = @_;
    die "$label must be a positive number of minutes\n"
      if !defined $value || $value !~ /\A[0-9]+(?:\.[0-9]+)?\z/ || $value <= 0;
    return 0 + $value;
}

# A column name is really three separate columns underneath, one per record
# kind, and asking without naming one used to refuse outright - so a caller
# checking whether a column was silenced had to call this three times and
# compare by hand, or check one type and believe the answer covered all
# three. Measured: a board silenced --type ticket for a column; an epic
# sitting in the same column name kept firing checklist-unmoved correctly,
# invisible from a single column.list call. column_roles and column_endings
# already answer this identical "no --type given" ambiguity with a hash
# keyed by all three types; this follows the same precedent. TKT-409.
sub column_list {
    my ( $self, %args ) = @_;

    if ( !defined $args{type} || $args{type} eq '' ) {
        my $root = $self->discover_project(%args);
        return { map { $_ => $self->column_list( project => $root, type => $_ ) }
              qw(sow epic ticket) };
    }
    my ( undef, $config ) = $self->_board_data(%args);
    return _column_defaults( $config->{columns} );
}

# An editor knows the layout it wants, not the steps that reach it.
# Removals move cards between folders and each takes the project lock, which is
# not reentrant, so they run first and one at a time; everything else is a
# single write. The result says what was done, because a run that fails partway
# through several removals will already have made some of them.
sub column_apply {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $wanted = $args{columns};
    die "A layout needs at least one column\n" if ref $wanted ne 'ARRAY' || !@{$wanted};

    my %seen;
    my @plan;
    for my $column ( @{$wanted} ) {
        my $name = $self->_valid_slug( $column->{name} );
        die "Column '$name' is named twice in the same layout\n" if $seen{$name}++;
        push @plan, {
            %{$column}, name => $name,
            ( defined $column->{notify_after}
                ? ( notify_after => _valid_minutes( $column->{notify_after}, 'Notify-after' ) ) : () ),
        };
    }

    my $current = $self->column_list( project => $root, type => $args{type} );
    for my $column ( @{$current} ) {
        die "Column '$column->{name}' is protected and cannot be left out of the layout\n"
          if $column->{protected} && !$seen{ $column->{name} };
    }

    my %present = map { $_->{name} => 1 } @{$current};
    my @removed = grep { !$seen{$_} } map { $_->{name} } @{$current};
    $self->column_remove( project => $root, type => $args{type}, name => $_ ) for @removed;

    my @added = grep { !$present{$_} } map { $_->{name} } @plan;
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my %existing = map { $_->{name} => $_ } @{ $config->{columns} };
        my @columns;
        for my $column (@plan) {
            my $entry = $existing{ $column->{name} }
              // { name => $column->{name}, label => $column->{name}, protected => Cpanel::JSON::XS::false };
            $entry->{label} = $column->{label} if defined $column->{label};
            $entry->{notify_after} = $column->{notify_after} if defined $column->{notify_after};
            $entry->{watched} = $column->{watched} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
              if defined $column->{watched};

            # Read back since column_apply shipped (_column_defaults has
            # carried both all along) but never written - a layout
            # round-tripped through the dialog silently dropped a column's
            # chain and required-action template, "accepted, dropped, read
            # back as if nothing happened." Replaces the whole list on each
            # call, matching column_update's own --next/--required-action.
            # TKT-454.
            $entry->{required_actions} = $column->{required_actions} if defined $column->{required_actions};
            $entry->{next} = $column->{next} if defined $column->{next};
            push @columns, $entry;
        }
        my $reordered = join( "\0", map { $_->{name} } @{ $config->{columns} } )
          ne join( "\0", map { $_->{name} } @columns );

        # A caller's payload can name a column that is gone from this very
        # layout - the dialog's own Next checkboxes are built once when it
        # opens and never refreshed if another row removes the column they
        # point at in the same editing session, so a stale selection reaches
        # here unless something else catches it. The columns actually being
        # saved are the only names that can ever be valid next targets.
        # TKT-475.
        my %valid = map { $_->{name} => 1 } @columns;
        for my $column (@columns) {
            next if ref $column->{next} ne 'ARRAY';
            $column->{next} = [ grep { $valid{$_} } @{ $column->{next} } ];
        }
        $config->{columns} = \@columns;

        # A column is a folder as well as a config entry: without this an added
        # column exists on the board and nothing can be moved into it.
        my @created = map { File::Spec->catdir( dirname($path), $_ ) } @added;
        make_path($_) for @created;
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column layout failure';
            rmdir $_ for @created;
            die $error;
        };
        return {
            added => \@added, removed => \@removed,
            reordered => $reordered ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
            columns => _column_defaults( \@columns ),
        };
    } );
}

sub column_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $notify_after = defined $args{notify_after}
      ? _valid_minutes( $args{notify_after}, 'Notify-after' ) : undef;
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( %args, project => $root );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '" . ( $args{name} // '' ) . "' not found\n" if !$column;
        $column->{notify_after} = $notify_after if defined $notify_after;
        $column->{watched} = $args{watched} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
          if defined $args{watched};

        # Where work ends on this board. Protected says Tira owns a column, not
        # that work stops there, and a board with three finished columns had
        # card-unassigned fire on nine shipped cards within a minute of being
        # declared. A board says which of its columns are endings; one that has
        # said nothing is unchanged.
        $column->{terminal} = $args{terminal} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
          if defined $args{terminal};

        # Which columns work waits in, said by the board rather than inferred.
        # protected means Tira owns a column and it was doing duty as a
        # statement about what a column MEANS - those come apart the moment a
        # board adds columns of its own, which is what mt5-ai measured: three
        # cards waiting in columns they created, and tira.next answering with
        # nothing. TKT-310.
        $column->{queue} = $args{queue} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false
          if defined $args{queue};

        # What a card must do before it may leave this column, named on the
        # column rather than remembered by whoever is moving the card - set
        # once here, read on every move. Replaces the whole list on each call,
        # matching key_details, deliverables and the other multi-value fields
        # the record side already replaces wholesale. TKT-427.
        $column->{required_actions} = $args{required_action} if defined $args{required_action};

        # A column's valid next step is one value, derived from array
        # position - correct for a linear chain, wrong at a genuine fork,
        # where more than one column is a legitimate forward step and which
        # one depends on the card's own path. Declared explicitly rather than
        # inferred, and replacing the whole set each call for the same reason
        # required_actions does. Unconfigured, a column keeps deriving its
        # one next step from position, exactly as before. TKT-430.
        if ( defined $args{next} ) {
            my %known = map { $_->{name} => 1 } @{ $config->{columns} };
            for my $target ( @{ $args{next} } ) {
                die "Column '$target' named in --next does not exist\n" if !$known{$target};
            }
            $column->{next} = $args{next};
        }
        $self->_write_yaml( $path, $config );
        return _column_defaults( [$column] )->[0];
    } );
}

sub board_show {
    my ( $self, %args ) = @_;
    my ( undef, $config ) = $self->_board_data(%args);
    return $config;
}

sub column_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        die "Column '$args{name}' already exists\n" if grep { $_->{name} eq $args{name} } @{ $config->{columns} };
        die "Use only one of --after or --before\n" if defined $args{after} && defined $args{before};
        my $column = { name => $args{name}, label => $args{label} // $args{name}, protected => Cpanel::JSON::XS::false };
        my $position = @{ $config->{columns} } - 1;
        for my $i ( 0 .. $#{ $config->{columns} } ) {
            $position = $i + 1 if defined $args{after} && $config->{columns}[$i]{name} eq $args{after};
            $position = $i if defined $args{before} && $config->{columns}[$i]{name} eq $args{before};
        }
        splice @{ $config->{columns} }, $position, 0, $column;

        # A neighbor's own explicit next was set before this column existed
        # and does not derive from position, so inserting here does not
        # extend it - the new column sits in the file layout but nothing in
        # the declared chain points at it. Advisory rather than a refusal,
        # the same way a failed reminder delivery is: the column is still
        # created, and this is where the next command run will see it.
        # TKT-456.
        if ( $position > 0 ) {
            my $before_new = $config->{columns}[ $position - 1 ];
            if ( ref $before_new->{next} eq 'ARRAY' && @{ $before_new->{next} }
                && !grep { $_ eq $args{name} } @{ $before_new->{next} } )
            {
                $self->warning_add(
                    project => $root,
                    message => "Column '$args{name}' was inserted next to '$before_new->{name}', "
                      . "but '$before_new->{name}''s own next still reads ["
                      . join( ', ', @{ $before_new->{next} } )
                      . "] and does not include it - it is not reachable via the declared chain. "
                      . "Fix with: tira.column.update --type $args{type} --name $before_new->{name} "
                      . "--next $args{name} --next "
                      . join( ' --next ', @{ $before_new->{next} } ),
                );
            }
        }
        my $directory = File::Spec->catdir( dirname($path), $args{name} );
        make_path($directory);
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column configuration failure';
            rmdir $directory;
            die $error;
        };
        return $column;
    } );
}

sub column_rename {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    $args{new_name} = $self->_valid_slug( $args{new_name} );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '$args{name}' not found\n" if !$column;
        die "Column '$args{name}' is protected\n" if $column->{protected};
        die "Column '$args{new_name}' already exists\n" if grep { $_->{name} eq $args{new_name} } @{ $config->{columns} };
        my $board = dirname($path);
        my $old_directory = File::Spec->catdir( $board, $args{name} );
        my $new_directory = File::Spec->catdir( $board, $args{new_name} );
        rename $old_directory, $new_directory
          or die "Cannot rename column '$args{name}': $!\n";
        $column->{name} = $args{new_name};
        $column->{label} = $args{label} if defined $args{label};
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column configuration failure';
            rename $new_directory, $old_directory or die "$error; rollback rename failed: $!\n";
            die $error;
        };
        return $column;
    } );
}

sub column_reorder {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    $args{after} = $self->_valid_slug( $args{after} ) if defined $args{after};
    $args{before} = $self->_valid_slug( $args{before} ) if defined $args{before};
    return $self->_with_project_lock( $root, sub {
        die "Use exactly one of --after or --before\n" if ( defined $args{after} ? 1 : 0 ) + ( defined $args{before} ? 1 : 0 ) != 1;
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '$args{name}' not found\n" if !$column;
        die "Column '$args{name}' is protected\n" if $column->{protected};
        my @columns = grep { $_ != $column } @{ $config->{columns} };
        my $target = $args{after} // $args{before};
        my ($index) = grep { $columns[$_]{name} eq $target } 0 .. $#columns;
        die "Column '$target' not found\n" if !defined $index;
        $index++ if defined $args{after};
        splice @columns, $index, 0, $column;
        $config->{columns} = \@columns;
        $self->_write_yaml( $path, $config );
        return $column;
    } );
}

sub column_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    $args{name} = $self->_valid_slug( $args{name} );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        my ($column) = grep { $_->{name} eq ( $args{name} // '' ) } @{ $config->{columns} };
        die "Column '$args{name}' not found\n" if !$column;
        die "Column '$args{name}' is protected\n" if $column->{protected};
        my $board = dirname($path);
        my $source = File::Spec->catdir( $board, $args{name} );
        my $discard = File::Spec->catdir( $board, 'discard' );
        opendir my $dh, $source or die "Cannot read column '$args{name}': $!\n";
        my @names = map { /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12}\.json)\z/ ? $1 : () }
          grep { -f File::Spec->catfile( $source, $_ ) } readdir $dh;
        for my $name (@names) {
            my $file = File::Spec->catfile( $source, $name );
            rename $file, File::Spec->catfile( $discard, $name ) or die "Cannot discard '$file': $!\n";
        }
        closedir $dh;
        $config->{columns} = [ grep { $_->{name} ne $args{name} } @{ $config->{columns} } ];

        # A removed column is a dangling fork target for anything that named
        # it in --next otherwise: the chain check would still treat the
        # column that pointed here as forking to a column that no longer
        # exists, and its own suggested remedy ("move there first") would
        # refuse too, since there is nowhere left to move to. TKT-475.
        for my $other ( @{ $config->{columns} } ) {
            next if ref $other->{next} ne 'ARRAY';
            $other->{next} = [ grep { $_ ne $args{name} } @{ $other->{next} } ];
        }
        eval { $self->_write_yaml( $path, $config ); 1 } or do {
            my $error = $@ || 'Unknown column configuration failure';
            rename File::Spec->catfile( $discard, $_ ), File::Spec->catfile( $source, $_ ) for @names;
            die $error;
        };
        rmdir $source or die "Cannot remove column '$args{name}': $!\n";
        return { removed => $args{name}, destination => 'discard' };
    } );
}

sub board_refs {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
        $config->{prefix} = $args{prefix} if defined $args{prefix};
        $config->{digits} = $args{digits} if defined $args{digits};
        $self->_validated_counter( $config, $path );
        $self->_write_yaml( $path, $config );
        return $config;
    } );
}

# Canonical selectable field names: every key a returned record can carry,
# including the computed column. Projection is presentation — the stored
# record is never altered.
my @RECORD_FIELDS = qw(
    ref type title description key_details problem_or_feature solution_needed
    deliverables scope source acceptance_criteria test_steps bdd atdd
    gate_passing_log evidence attachments checklist required_items subtasks linkage assignee
    reporter labels due_date start_date sdlc_gate lifecycle priority
    fix_version affects_versions parent comments created_at last_updated column
    content_hash attachment_count sandbox agent_session conversation required_exempt
);
my %RECORD_FIELD = map { $_ => 1 } @RECORD_FIELDS;

# CA01-CA03: validate --fields/--exclude-fields input (comma lists,
# repeatable) into a projection plan. Unknown and empty names die so a typo
# can never quietly return an empty object.
my @BRIEF_FIELDS = qw(ref title column sdlc_gate assignee);
my $BRIEF_TITLE_WIDTH = 72;
my %LONG_TEXT_FIELD = map { $_ => 1 } qw(description problem_or_feature solution_needed);
my $ELLIPSIS = "\x{2026}";

# CA09: truncation is presentation only — applied after hashing and
# projection, marked per field (and per gate/evidence entry) with the
# original length, and never silent. A zero limit omits the text but
# still marks it present.
sub _truncate_text_slot {
    my ( $container, $key, $limit ) = @_;
    my $value = $container->{$key};
    return if !defined $value || ref $value;
    my $length = length $value;
    return if $limit > 0 && $length <= $limit;
    if ( $limit > 0 ) {
        $container->{$key} = substr( $value, 0, $limit ) . $ELLIPSIS;
    }
    else {
        return if $length == 0;
        delete $container->{$key};
    }
    $container->{"${key}_truncated"} = Cpanel::JSON::XS::true;
    $container->{"${key}_length"} = $length;
    return;
}

sub _apply_truncation {
    my ( $projected, $limit ) = @_;
    _truncate_text_slot( $projected, $_, $limit ) for keys %LONG_TEXT_FIELD;
    for my $entry ( @{ $projected->{gate_passing_log} // [] } ) {
        _truncate_text_slot( $entry, 'details', $limit );
    }
    for my $entry ( @{ $projected->{evidence} // [] } ) {
        _truncate_text_slot( $entry, 'summary', $limit );
    }
    return $projected;
}

sub _apply_brief_title {
    my ($projected) = @_;
    my $title = $projected->{title};
    return if !defined $title || length($title) <= $BRIEF_TITLE_WIDTH;
    $projected->{title} = substr( $title, 0, $BRIEF_TITLE_WIDTH ) . $ELLIPSIS;
    return;
}

sub _field_projection {
    my (%args) = @_;
    my %plan;
    if ( $args{brief} ) {
        die "Brief contradicts an explicit field selection\n" if defined $args{fields};
        $args{fields} = [ join ',', @BRIEF_FIELDS ];
    }
    for my $side (qw(fields exclude_fields)) {
        next if !defined $args{$side};
        my @names = map { split /,/, $_, -1 } @{ $args{$side} };
        for my $name (@names) {
            die "Empty field name in field selection\n" if !length $name;
            die "Unknown field '$name'\n" if !$RECORD_FIELD{$name};
        }
        $plan{$side} = { map { $_ => 1 } @names };
    }
    $plan{omit_empty} = 1 if $args{omit_empty};
    return %plan ? \%plan : undef;
}

# CA04: instant-based comparison. Accepts Z, +-HH:MM, and the +-HHMM the
# default clock writes; a missing offset reads as UTC. Dies on anything
# else so a malformed threshold can never silently mean "everything".
sub _epoch_of_datetime {
    my ( $value, $label ) = @_;
    my ( $year, $month, $day, $hour, $minute, $second, $offset ) =
      ( $value // '' ) =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?\z/
      or die "$label must be an ISO 8601 date-time\n";
    my $epoch = timegm_modern( $second, $minute, $hour, $day, $month - 1, $year );
    if ( defined $offset && $offset ne 'Z' ) {
        my ( $sign, $offset_hours, $offset_minutes ) = $offset =~ /\A([+-])(\d{2}):?(\d{2})\z/;
        my $shift = $offset_hours * 3600 + $offset_minutes * 60;
        $epoch += $sign eq '-' ? $shift : -$shift;
    }
    return $epoch;
}

# A record whose stored stamp cannot be parsed is treated as changed —
# since-filtering may skip quiet records but must never hide one.
sub _changed_since {
    my ( $record, $threshold ) = @_;
    my $stamp = eval { _epoch_of_datetime( $record->{last_updated}, 'Last updated' ) };
    return 1 if !defined $stamp;
    return $stamp >= $threshold;
}

# CA16: repeatable ANDed filters. FIELD=VALUE equality (empty VALUE means
# empty-or-unset by the CA15 rule), FIELD!=VALUE inequality (!= empty
# means has-a-value), FIELD~VALUE case-insensitive array containment
# (scalars simply never match). Unknown fields and operatorless clauses
# die so a typo can never read as "none exist".
sub _parse_where {
    my ( $clauses, $known, $label ) = @_;
    return undef if !defined $clauses;
    $known //= \%RECORD_FIELD;
    $label //= '';
    my @parsed;
    for my $raw ( @{$clauses} ) {
        my ( $field, $operator, $value ) = ( $raw // '' ) =~ /\A([A-Za-z_]+)(!=|~|=)(.*)\z/s
          or die "Where filter must be FIELD=VALUE, FIELD!=VALUE, or FIELD~VALUE\n";
        die "Unknown ${label}field '$field'\n" if !$known->{$field};
        push @parsed, { field => $field, operator => $operator, value => $value };
    }
    return \@parsed;
}

sub _where_matches {
    my ( $full, $clauses ) = @_;
    for my $clause ( @{$clauses} ) {
        my $value = $full->{ $clause->{field} };
        if ( $clause->{operator} eq '~' ) {
            return 0 if ref $value ne 'ARRAY';
            my $needle = lc $clause->{value};
            return 0 if !grep { !ref $_ && defined $_ && lc($_) eq $needle } @{$value};
        }
        elsif ( $clause->{value} eq '' ) {
            my $empty = _is_empty_value($value);
            return 0 if $clause->{operator} eq '=' ? !$empty : $empty;
        }
        else {
            my $equal = defined $value && !ref $value && "$value" eq $clause->{value};
            return 0 if $clause->{operator} eq '=' ? !$equal : $equal;
        }
    }
    return 1;
}

# CA05: the content hash covers every meaningful field including the
# computed column, and excludes only the volatile last_updated stamp —
# so a no-op write keeps its hash while any real change, comment,
# attachment, or move alters it. The token is opaque; only equality is
# contractual.
sub _record_content_hash {
    my ($record) = @_;
    my %meaningful = %{$record};
    delete @meaningful{qw(last_updated content_hash)};
    return sha256_hex( encode_utf8( json_object()->canonical->encode( \%meaningful ) ) );
}

sub _board_hash {
    my ($records) = @_;
    return sha256_hex( encode_utf8( join "\n",
        map { $_->{ref} . ':' . ( $_->{content_hash} // _record_content_hash($_) ) } @{$records} ) );
}

# CA06: a bad hash must never be read as "changed" — that would return
# everything and hide the error.
sub _valid_conditional_hash {
    my ($hash) = @_;
    die "If-changed hash is malformed\n" if ( $hash // '' ) !~ /\A[0-9a-f]{64}\z/;
    return $hash;
}

# CA15: a value is empty when it is undef, an empty string, an empty
# array, or a hash whose every value is empty by the same rule (scope and
# blank linkage). Booleans and numbers — including 0 and false — are
# never empty.
sub _is_empty_value {
    my ($value) = @_;
    return 1 if !defined $value;
    my $kind = ref $value;
    return $value eq '' if !$kind;
    return !@{$value} if $kind eq 'ARRAY';
    if ( $kind eq 'HASH' ) {
        _is_empty_value($_) || return 0 for values %{$value};
        return 1;
    }
    return 0;
}

# Selection always keeps ref (identity is never lossy); exclusion applies
# after selection, so naming a field on both sides removes it.
sub _project_record {
    my ( $record, $plan ) = @_;
    return $record if !$plan;
    my %projected = %{$record};
    if ( my $keep = $plan->{fields} ) {
        %projected = map { exists $projected{$_} ? ( $_ => $projected{$_} ) : () }
          ( 'ref', keys %{$keep} );
    }
    delete @projected{ keys %{ $plan->{exclude_fields} } } if $plan->{exclude_fields};
    if ( $plan->{omit_empty} ) {
        for my $field ( keys %projected ) {
            next if $plan->{fields} && $plan->{fields}{$field};
            delete $projected{$field} if _is_empty_value( $projected{$field} );
        }
    }
    return \%projected;
}

sub record_show {
    my ( $self, %args ) = @_;
    my $plan = _field_projection(%args);
    my $threshold = defined $args{since} ? _epoch_of_datetime( $args{since}, 'Since' ) : undef;
    _valid_conditional_hash( $args{if_changed} ) if defined $args{if_changed};
    my ( $path, $record, $column ) = $self->_record_data(%args);
    return {} if defined $threshold && !_changed_since( $record, $threshold );
    my $root = $self->discover_project(%args);
    for my $pool ( $record->{attachments}, map { $_->{attachments} } @{ $record->{comments} // [] } ) {
        $self->_backfill_added_at( $root, $pool );
    }
    my $full = { %{$record}, column => $column };
    if ( defined $args{if_changed} ) {
        return { unchanged => Cpanel::JSON::XS::true } if _record_content_hash($full) eq $args{if_changed};
    }
    $full->{content_hash} = _record_content_hash($full)
      if $plan && $plan->{fields} && $plan->{fields}{content_hash};
    $full->{attachment_count} = scalar @{ $record->{attachments} // [] }
      if $plan && $plan->{fields} && $plan->{fields}{attachment_count};
    my $projected = _project_record( $full, $plan );
    $projected->{comments} = [ map { _comment_meta($_) } @{ $projected->{comments} } ]
      if $args{meta_only} && ref $projected->{comments} eq 'ARRAY';
    _apply_truncation( $projected, $args{truncate} ) if defined $args{truncate};
    _apply_brief_title($projected) if $args{brief};
    return $projected;
}

# Attachments stored before release 0.22 predate the added_at stamp. The
# deduplicated store file's own mtime records when that content first
# arrived, so reads recover the real timestamp from it; the next record
# mutation persists the repaired reference (same policy as the legacy
# UTF-8 byte repair).
sub _backfill_added_at {
    my ( $self, $root, $pool ) = @_;
    for my $reference ( @{ $pool // [] } ) {
        next if defined $reference->{added_at};
        my $stored = eval { $self->_attachment_path( $root, sha => $reference->{sha}, extension => $reference->{extension} ) };
        next if !defined $stored || !-f $stored;
        $reference->{added_at} = _iso_from_epoch( ( stat $stored )[9] );
    }
    return;
}

# CA13: first-class change detection. Since mode reports what a watcher
# needs to act (kind, current column/gate/title, new comment ids) with
# now for chaining; snapshot mode compares a stored full export and adds
# per-field before/after for scalars. Reads only — diff never writes.
sub _values_equal {
    my ( $old, $new ) = @_;
    return 1 if _is_empty_value($old) && _is_empty_value($new);
    my $encoder = json_object()->canonical->allow_nonref;
    return $encoder->encode($old) eq $encoder->encode($new);
}

sub diff_records {
    my ( $self, %args ) = @_;
    my ( $since, $snapshot ) = @args{qw(since snapshot)};
    die "Diff requires --since or --snapshot\n" if !defined $since && !defined $snapshot;
    die "Choose one of --since or --snapshot\n" if defined $since && defined $snapshot;
    my $scope;
    if ( defined $args{fields} ) {
        die "Field scoping applies to snapshot diffs\n" if defined $since;
        my @names = map { split /,/, $_, -1 } @{ $args{fields} };
        for my $name (@names) {
            die "Empty field name in field selection\n" if !length $name;
            die "Unknown field '$name'\n" if !$RECORD_FIELD{$name};
        }
        $scope = { map { $_ => 1 } @names };
    }
    my %list_args = ( project => $args{project} );
    $list_args{type} = $args{type} if defined $args{type};
    my $now = $self->{clock}->();
    my @changes;
    if ( defined $since ) {
        my $threshold = _epoch_of_datetime( $since, 'Since' );
        for my $record ( @{ $self->record_list( %list_args, since => $since ) } ) {
            my $created = eval { _epoch_of_datetime( $record->{created_at}, 'Created at' ) };
            my @new_comments = map { $_->{id} } grep {
                my $stamp = eval { _epoch_of_datetime( $_->{created_at}, 'Comment stamp' ) };
                defined $stamp && $stamp >= $threshold;
            } @{ $record->{comments} // [] };
            push @changes, {
                ref => $record->{ref}, type => $record->{type},
                kind => ( defined $created && $created >= $threshold ) ? 'added' : 'changed',
                column => $record->{column}, sdlc_gate => $record->{sdlc_gate},
                title => $record->{title},
                ( @new_comments ? ( new_comments => \@new_comments ) : () ),
            };
        }
    }
    else {
        open my $stored_fh, '<:raw', $snapshot or die "Cannot read snapshot: $!\n";
        my $raw = do { local $/; <$stored_fh> };
        close $stored_fh;
        my $stored = eval { json_decode($raw) } or die "Snapshot is not valid JSON\n";
        $stored = $stored->{records} if ref $stored eq 'HASH';
        die "Snapshot must contain records\n" if ref $stored ne 'ARRAY';
        my %previous = map { $_->{ref} => $_ }
          grep { ref $_ eq 'HASH' && defined $_->{ref} } @{$stored};
        for my $record ( @{ $self->record_list(%list_args) } ) {
            my $before = delete $previous{ $record->{ref} };
            if ( !$before ) {
                push @changes, {
                    ref => $record->{ref}, kind => 'added', type => $record->{type},
                    column => $record->{column}, title => $record->{title},
                };
                next;
            }
            my @field_changes;
            for my $field ( grep { $_ ne 'ref' && $_ ne 'last_updated' && $_ ne 'content_hash' && $_ ne 'attachment_count' } @RECORD_FIELDS ) {
                next if $scope && !$scope->{$field};
                my ( $old, $new ) = ( $before->{$field}, $record->{$field} );
                next if _values_equal( $old, $new );
                if ( $field eq 'comments' ) {
                    my %known = map { ( $_->{id} // '' ) => 1 } @{ $before->{comments} // [] };
                    my @added = map { $_->{id} } grep { !$known{ $_->{id} // '' } } @{ $new // [] };
                    push @field_changes,
                      { field => 'comments', ( @added ? ( added => \@added ) : ( changed => Cpanel::JSON::XS::true ) ) };
                }
                elsif ( !ref $old && !ref $new ) {
                    push @field_changes, { field => $field, before => $old, after => $new };
                }
                else {
                    push @field_changes, { field => $field, changed => Cpanel::JSON::XS::true };
                }
            }
            push @changes, { ref => $record->{ref}, kind => 'changed', fields => \@field_changes }
              if @field_changes;
        }
        push @changes, map { { ref => $_, kind => 'removed' } } sort keys %previous;
    }
    return { count => scalar @changes } if $args{count};
    return { changes => \@changes, count => scalar @changes, now => $now };
}

# CA19: one call for a known set of refs. Keyed by ref with the request
# order preserved and duplicates collapsed; a missing ref is an explicit
# marker and never loses the rest, while validation errors (bad fields,
# missing project) fail the whole call loudly before any lookup.
sub record_show_many {
    my ( $self, %args ) = @_;
    my $refs = delete $args{refs};
    die "Batch reads require at least one ref\n" if ref $refs ne 'ARRAY' || !@{$refs};
    die "Batch reads accept at most 100 refs\n" if @{$refs} > 100;
    _field_projection(%args);
    $self->discover_project(%args);
    my ( %by_ref, @order );
    for my $ref ( @{$refs} ) {
        next if exists $by_ref{$ref};
        push @order, $ref;
        my $record = eval { $self->record_show( %args, ref => $ref ) };
        $by_ref{$ref} = defined $record ? $record : { ref => $ref, not_found => Cpanel::JSON::XS::true };
    }
    return { records => \%by_ref, order => \@order, count => scalar @order };
}

sub record_list {
    my ( $self, %args ) = @_;
    my $plan = _field_projection(%args);
    # CA07/CA17: count wins over refs-only wins over projection — but a
    # bad field name stays loud even when projection is moot.
    undef $plan if $args{count} || $args{refs_only};
    my $where = _parse_where( $args{where} );
    my %where_computed = map { $_->{field} => 1 }
      grep { $_->{field} eq 'content_hash' || $_->{field} eq 'attachment_count' } @{ $where // [] };
    my $threshold = defined $args{since} ? _epoch_of_datetime( $args{since}, 'Since' ) : undef;
    my $root = $self->discover_project(%args);
    my $cached = defined $args{text} ? $self->_search_index_read($root) : undef;
    my @records;
    for my $candidate ( defined $args{type} ? ( $args{type} ) : qw(sow epic ticket) ) {
        my $type = $self->_valid_type($candidate);
        my $board = File::Spec->catdir( $root, '.tira', $type );
        next if !-d $board;
        find( { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name || basename( $File::Find::name ) !~ /\.json\z/;
            my $path = $self->_canonical_path( $File::Find::name, 'record file' );
            my $content = $self->_slurp($path);

            # The index says only one thing: what the card with exactly these
            # bytes says. A card that cannot match is skipped here, before it
            # is parsed, and parsing is what a board walk actually costs.
            if ( defined $args{text} && $cached ) {
                my $known = $cached->{ sha256_hex($content) };
                return if defined $known && index( lc $known, lc $args{text} ) < 0;
            }

            my $record = $self->_json_from_content($content);
            my $column = basename( dirname($path) );
            return if defined $args{column} && $column ne $args{column};
            return if defined $args{assignee} && ( $record->{assignee} // '' ) ne $args{assignee};
            my $parent = $record->{parent} // '';
            return if defined $args{parent} && $parent ne $args{parent};
            return if defined $args{text}
              && index( lc _search_haystack($record), lc $args{text} ) < 0;
            return if defined $threshold && !_changed_since( $record, $threshold );
            my $full = { %{$record}, column => $column };
            if ($where) {
                $full->{content_hash} = _record_content_hash($full) if $where_computed{content_hash};
                $full->{attachment_count} = scalar @{ $record->{attachments} // [] }
                  if $where_computed{attachment_count};
                return if !_where_matches( $full, $where );
                delete @{$full}{ grep { $where_computed{$_} } qw(content_hash attachment_count) };
            }
            $full->{content_hash} = _record_content_hash($full)
              if $plan && $plan->{fields} && $plan->{fields}{content_hash};
            $full->{attachment_count} = scalar @{ $record->{attachments} // [] }
              if $plan && $plan->{fields} && $plan->{fields}{attachment_count};
            my $projected = _project_record( $full, $plan );
            if ( !$args{count} && !$args{refs_only} ) {
                $projected->{comments} = [ map { _comment_meta($_) } @{ $projected->{comments} } ]
                  if $args{meta_only} && ref $projected->{comments} eq 'ARRAY';
                _apply_truncation( $projected, $args{truncate} ) if defined $args{truncate};
                _apply_brief_title($projected) if $args{brief};
            }
            push @records, $projected;
        } }, $board );
    }
    my $sorted = [ sort { $a->{ref} cmp $b->{ref} } @records ];
    return { count => scalar @{$sorted} } if $args{count};
    return [ map { $_->{ref} } @{$sorted} ] if $args{refs_only};
    return $sorted;
}

# (EPIC-457): how long has each card sat in the column it is in now?
# One board walk plus a backwards journal scan per card. Reading backwards and
# testing each line as a string before decoding it is what keeps this at a few
# milliseconds for a whole board and keeps it flat as journals grow; the
# per-card API route measured a hundred times slower and the per-card CLI route
# a thousand.
sub _dwell_start {
    my ( $self, $root, $ref ) = @_;
    my $path = $self->_journal_path( $root, $ref );
    return ( undef, 'none' ) if !-f $path;
    open my $fh, '<:raw', $path or return ( undef, 'none' );
    my @lines = <$fh>;
    close $fh;
    for my $line ( reverse @lines ) {
        # The column a move names is deliberately not compared with the card's
        # current column: column_rename and column_remove relocate cards without
        # journaling, so demanding a match would read as "never moved".
        next if index( $line, '"field":"column"' ) < 0 || index( $line, '"op":"move"' ) < 0;
        my $entry = eval { json_decode($line) } or return ( undef, 'unknown' );
        my $epoch = eval { _epoch_of_datetime( $entry->{at}, 'History stamp' ) };
        return ( undef, 'unknown' ) if !defined $epoch;
        return ( $entry->{at}, 'move' );
    }
    return ( undef, 'none' );
}

sub dwell_list {
    my ( $self, %args ) = @_;
    my $older_than = delete $args{older_than};
    my $stale = delete $args{stale};
    my $with_level = delete $args{with_level};
    if ( defined $older_than ) {
        die "Older-than must be a positive number of minutes\n"
          if $older_than !~ /\A[0-9]+(?:\.[0-9]+)?\z/ || $older_than <= 0;
    }
    my $root = $self->discover_project(%args);
    my $now = eval { _epoch_of_datetime( $self->{clock}->(), 'Clock' ) };
    my $project_default = $stale
      ? eval { $self->project_show( project => $root )->{notify_after} } : undef;
    my %limit;
    my @cards;
    for my $type ( defined $args{type} ? ( $args{type} ) : qw(sow epic ticket) ) {
        my $board = File::Spec->catdir( $root, '.tira', $self->_valid_type($type) );
        next if !-d $board;
        if ($stale) {
            for my $column ( @{ $self->column_list( project => $root, type => $type ) } ) {
                # An unwatched column is out of scope entirely, however old its
                # cards are; a column with no limit of its own uses the project's.
                next if !$column->{watched};
                my $minutes = $column->{notify_after} // $project_default;
                $limit{"$type/$column->{name}"} = $minutes if defined $minutes;
            }
        }
        find( { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name;
            my $file = basename($File::Find::name);
            return if $file !~ /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12})\.json\z/;
            my $ref = $1;
            my $column = basename( dirname($File::Find::name) );
            my $record = $stale ? eval { $self->_read_json($File::Find::name) } : undef;

            # Waiting on the owner is not the agent's fault, so it is not chased.
            return if $record && _card_blocked($record);
            my ( $since, $basis ) = $self->_dwell_start( $root, $ref );
            if ( $record && ( my $cleared = _card_unblocked_at($record) ) ) {
                ( $since, $basis ) = ( $cleared, 'move' )
                  if !defined $since || $cleared gt $since;
            }
            my $seconds;
            if ( $basis eq 'move' && defined $now ) {
                my $started = eval { _epoch_of_datetime( $since, 'History stamp' ) };
                $seconds = defined $started ? $now - $started : undef;
                $basis = 'unknown' if !defined $seconds;
            }
            return if $stale && !exists $limit{"$type/$column"};
            push @cards, {
                ref => $ref, type => $type, column => $column, basis => $basis,
                ( $stale ? ( notify_after => $limit{"$type/$column"} ) : () ),
                ( defined $since && $basis eq 'move' ? ( since => $since ) : () ),
                ( defined $seconds ? ( dwell_seconds => $seconds ) : () ),
            };
        } }, $board );
    }
    @cards = sort { $a->{ref} cmp $b->{ref} } @cards;
    # An unmeasured card is never "old": it is unknown, and guessing would put
    # ninety percent of a real board into the first report.
    @cards = grep { defined $_->{dwell_seconds} && $_->{dwell_seconds} >= $older_than * 60 } @cards
      if defined $older_than;
    @cards = grep { defined $_->{dwell_seconds} && $_->{dwell_seconds} >= $_->{notify_after} * 60 } @cards
      if $stale;
    if ($with_level) {
        $_->{level} = $self->notification_level(
            project => $root, ref => $_->{ref}, column => $_->{column} )
          for @cards;
    }
    return \@cards;
}

sub export_records {
    my ( $self, %args ) = @_;
    if ( $args{count} ) {
        my %count_args = %args;
        delete $count_args{if_changed};
        return $self->record_list(%count_args);
    }
    my $now = defined $args{since} ? $self->{clock}->() : undef;
    my $plan = _field_projection(%args);
    my $wants_hash = defined $args{if_changed}
      || ( $plan && $plan->{fields} && $plan->{fields}{content_hash} );
    my $board_hash;
    if ($wants_hash) {
        _valid_conditional_hash( $args{if_changed} ) if defined $args{if_changed};
        my %full_args = %args;
        delete @full_args{qw(fields exclude_fields omit_empty if_changed)};
        $board_hash = _board_hash( $self->record_list(%full_args) );
        return { unchanged => Cpanel::JSON::XS::true }
          if defined $args{if_changed} && $board_hash eq $args{if_changed};
    }
    my %list_args = %args;
    delete $list_args{if_changed};
    my $records = $self->record_list(%list_args);
    my $result = { records => $records, count => scalar @{$records} };
    $result->{now} = $now if defined $now;
    $result->{board_hash} = $board_hash if $wants_hash;
    return $result;
}

# Optimistic-concurrency comparator for scalar record fields: an absent or
# null base only matches an unset field, values compare as strings.
sub _matches_base {
    my ( $current, $base ) = @_;
    return !defined $base if !defined $current;
    return defined $base && "$current" eq "$base";
}

sub record_update {
    my ( $self, %args ) = @_;
    $self->_require_author(%args);
    my $root = $self->discover_project(%args);
    local $self->{_journal_author} = $self->_journal_attribution( %args, project => $root );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $record, $column ) = $self->_record_data( project => $root, ref => $args{ref} );
        if ( my $expect = $args{expect} ) {
            for my $field ( sort keys %{$expect} ) {
                next if _matches_base( $record->{$field}, $expect->{$field} );
                die "Conflict: $field changed while you were editing\n";
            }
        }

        # tira.ticket.show truncates description/problem_or_feature/
        # solution_needed at 2000 characters by default (_truncate_text_slot)
        # and marks the read honestly - but nothing stopped that truncated
        # read from being written straight back, silently destroying
        # everything past the cut. Measured on TKT-386: three read-modify-
        # write edits shrank it from 4541 to 3187 bytes, invisible because
        # tira.history.list truncates the same way. Refused only when the
        # incoming value is an EXACT match for what a truncated read of the
        # CURRENT stored value looks like - a genuinely shorter rewrite,
        # written on purpose, is unaffected. TKT-400.
        for my $field ( keys %LONG_TEXT_FIELD ) {
            next if !defined $args{$field} || !defined $record->{$field};
            my $current = $record->{$field};
            next if length($current) <= 2000;
            next if $args{$field} ne substr( $current, 0, 2000 ) . $ELLIPSIS;
            die "The new $field matches a truncated read of the current one - "
              . "re-read with --full before writing it back, or this destroys everything past character 2000\n";
        }
        for my $field (@PLAIN_FIELDS) {
            $record->{$field} = $args{$field} if defined $args{$field};
        }
        for my $field (qw(sdlc_gate lifecycle fix_version sandbox agent_session)) {
            $record->{$field} = undef if defined $args{$field} && $args{$field} eq '';
        }
        for my $field (qw(assignee reporter)) {
            next if !defined $args{$field};
            $self->_require_active_person( project => $root, person => $args{$field} ) if $args{$field} ne '';
            $record->{$field} = $args{$field} eq '' ? undef : $args{$field};
        }
        $record->{priority} = $self->_valid_priority( $args{priority} ) if defined $args{priority};
        $record->{due_date} = $self->_valid_datetime( $args{due_date}, 'Due date' ) if defined $args{due_date};
        $record->{start_date} = $self->_valid_datetime( $args{start_date}, 'Start date' ) if defined $args{start_date};
        if ( defined $args{labels} ) {
            $record->{labels} = $self->_unique_casefold( [ @{ $record->{labels} // [] }, @{ $args{labels} } ] );
        }
        $record->{labels} = $self->_unique_casefold( $args{labels_replace} ) if defined $args{labels_replace};
        if ( defined $args{affects_versions} ) {
            $record->{affects_versions} = $self->_unique_casefold(
                [ @{ $record->{affects_versions} // [] }, @{ $args{affects_versions} } ]
            );
        }
        $record->{affects_versions} = $self->_unique_casefold( $args{affects_versions_replace} )
          if defined $args{affects_versions_replace};
        my %accumulating = (
            key_details => 'key_details', deliverables => 'deliverables', acceptance => 'acceptance_criteria',
            test_steps => 'test_steps', bdd => 'bdd', atdd => 'atdd',
        );
        for my $argument ( keys %accumulating ) {
            next if !defined $args{$argument};
            push @{ $record->{ $accumulating{$argument} } }, @{ $args{$argument} };
        }

        # A card's own exceptions to a column's required-action template
        # (TKT-439) - the column's own list is a baseline, not an absolute,
        # and this is where one card diverges from it. Grows the same way
        # key_details does, no replace variant: an exemption once given is
        # not meant to be silently taken back by a later call that happened
        # to omit it.
        #
        # A dashboard reader who sees a card in done with an item still
        # showing an empty checkbox cannot tell "this was legitimately
        # exempted" from "this was skipped" - the owner's own reaction to
        # exactly that: "How do you explain this? This card became Done
        # while only half-finished." So a reason is required alongside the
        # item, not merely permitted, and both are recorded rather than the
        # bare item text alone. TKT-473.
        my $new_exemptions = $self->_exempt_entries(%args);
        push @{ $record->{required_exempt} }, @{$new_exemptions} if $new_exemptions;
        for my $argument ( keys %accumulating ) {
            my $replacement = "${argument}_replace";
            $record->{ $accumulating{$argument} } = $args{$replacement} if defined $args{$replacement};
        }
        my %arrays = ( attachments => 'attachments', evidence => 'evidence', gate_passing_log => 'gate_passing_log' );
        for my $argument ( keys %arrays ) {
            $record->{ $arrays{$argument} } = $args{$argument} if defined $args{$argument};
        }
        push @{ $record->{scope}{included} }, @{ $args{scope_in} } if defined $args{scope_in};
        push @{ $record->{scope}{excluded} }, @{ $args{scope_out} } if defined $args{scope_out};
        $record->{scope} = $args{scope} if defined $args{scope};
        $record->{last_updated} = $self->{clock}->();
        $self->_write_json( $path, $record );
        return { %{$record}, column => $column };
    } );
}

sub record_move {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);

    # A move with nobody attached to it is how a card crossed nine columns
    # with no chain check and no required-action check ever running - both
    # live only in the CLI dispatch layer, which an unattributed caller
    # never had to pass through. Refusing here closes that regardless of
    # which path reached the engine. The CLI already resolves --author or
    # TIRA_AUTHOR before this is ever called, and the browser dashboard
    # already threads the signed-in person through as author - so this
    # only refuses a caller that supplied neither. TKT-457.
    die "A move needs to say who is making it\n" if !defined $args{author} || $args{author} eq '';
    local $self->{_journal_author} = $self->_journal_attribution( %args, project => $root );
    return $self->_with_project_lock( $root, sub {
        my ( $path, $record ) = $self->_record_data( project => $root, ref => $args{ref} );
        my $type = $record->{type};
        die "Invalid record type in '$args{ref}'\n" if $type !~ /\A(sow|epic|ticket)\z/;
        $type = $1;
        my $column = $self->_valid_slug( $args{column} );
        my ( undef, $config ) = $self->_board_data( project => $root, type => $type );
        die "Column '$column' not found\n" if !grep { $_->{name} eq $column } @{ $config->{columns} };
        my $destination = File::Spec->catfile( $root, '.tira', $type, $column, basename($path) );
        my $previous_column = basename( dirname($path) );
        rename $path, $destination or die "Cannot move '$args{ref}': $!\n";

        if ( $previous_column ne $column ) {

            # Stamped, because moving a card is changing it. The column is not a
            # field in the record - it is which directory the file sits in - so
            # a move was the one edit that never went through the write that
            # stamps a card, and every --since filter reads that stamp.
            #
            # A card created at 09:00 and moved at 18:00 reported last_updated
            # 09:00, so record.list --since 12:00 returned nothing and an
            # incremental export dropped it: against a comment saying
            # since-filtering "must never hide one", and a reference promising a
            # poller "can never miss a change".
            #
            # The content hash is unaffected - last_updated is deliberately
            # outside it - so a move still reads as the same card, which is what
            # anything comparing two boards depends on.
            $record->{last_updated} = $self->{clock}->();
            $self->_write_json( $destination, $record );

            $self->_journal_record(
                ref => $record->{ref}, op => 'move',
                entries => [ { field => 'column', before => $previous_column, after => $column } ],
            );
        }
        return { %{$record}, column => $column };
    } );
}

sub record_discard {
    my ( $self, %args ) = @_;
    return $self->record_move( %args, column => 'discard' );
}

sub record_restore {
    my ( $self, %args ) = @_;
    return $self->record_move( %args, column => $args{column} // 'backlog' );
}

sub project_validate {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    if ( $args{repair} ) {
        $self->column_sync( project => $root, type => $_, apply => 1 ) for qw(sow epic ticket);
    }
    my @issues;
    for my $type (qw(sow epic ticket)) {
        my ( undef, $config ) = $self->_board_data( project => $root, type => $type );
        my %configured = map { $_->{name} => 1 } @{ $config->{columns} };
        my $board = File::Spec->catdir( $root, '.tira', $type );
        opendir my $dh, $board or die "Cannot read board '$type': $!\n";
        my %actual = map { $_ => 1 } grep { -d File::Spec->catdir( $board, $_ ) && !/^\./ } readdir $dh;
        closedir $dh;
        push @issues, map { "$type: missing directory $_" } grep { !$actual{$_} } sort keys %configured;
        push @issues, map { "$type: unconfigured directory $_" } grep { !$configured{$_} } sort keys %actual;
    }
    return { valid => @issues ? Cpanel::JSON::XS::false : Cpanel::JSON::XS::true, issues => \@issues };
}

sub column_sync {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $path, $config ) = $self->_board_data( project => $root, type => $args{type} );
    my $board = dirname($path);
    opendir my $dh, $board or die "Cannot read board '$args{type}': $!\n";
    my @actual = sort grep { -d File::Spec->catdir( $board, $_ ) && !/^\./ } readdir $dh;
    closedir $dh;
    my %actual = map { $_ => 1 } @actual;
    my %configured = map { $_->{name} => $_ } @{ $config->{columns} };
    my @missing = grep { !$actual{$_} } sort keys %configured;
    my @unconfigured = grep { !$configured{$_} } @actual;
    if ( $args{apply} ) {
        make_path( File::Spec->catdir( $board, $_ ) ) for grep { $configured{$_}{protected} } @missing;
        my @columns = grep { $actual{ $_->{name} } || $_->{protected} } @{ $config->{columns} };
        my $discard = pop @columns;
        push @columns, map { { name => $_, label => $_, protected => Cpanel::JSON::XS::false } } @unconfigured;
        push @columns, $discard;
        $config->{columns} = \@columns;
        $self->_write_yaml( $path, $config );
    }
    return { missing => \@missing, unconfigured => \@unconfigured, applied => $args{apply} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false };
}

# The path down to a card, top first. In a chain the core agent is the only
# reader of the bridge and does not hand a message to a ticket agent directly -
# it hands it to that agent's manager, who hands it on. So a line has to say
# the way down, and it has to say it at the moment it was written: a card
# reparented afterwards must not rewrite what was already said, which is the
# whole reason the bridge repeats what it knows instead of pointing at the
# board.
#
# A card with nothing above it is its own path rather than an empty one. Found
# work arrives that way, and in a chain it means the core agent keeps it.
sub card_path {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my @path;
    my $ref = $args{ref};
    my %seen;

    # Guarded against a cycle it should never see. A hierarchy that pointed at
    # itself would hang the bridge rather than fail it, and a channel that
    # stops is worse than one that says something wrong.
    while ( defined $ref && $ref ne '' && !$seen{$ref}++ ) {
        my $record = eval { $self->record_show( project => $root, ref => $ref ) } or last;
        unshift @path, $record->{ref};
        $ref = $record->{linkage}{epic_ref} // $record->{linkage}{sow_ref};
    }
    return \@path;
}

sub hierarchy_link {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        my ( $up, $down );
        if ( $parent->{type} eq 'sow' && $child->{type} eq 'epic' ) {
            ( $up, $down ) = ( 'sow_ref', 'epic_refs' );
        }
        elsif ( $parent->{type} eq 'epic' && $child->{type} eq 'ticket' ) {
            ( $up, $down ) = ( 'epic_ref', 'ticket_refs' );
        }
        else {
            # Strict, and not a dead end. Somebody linking two tickets wants
            # a relationship rather than a parentage, and tira.link.add is the
            # command for it - naming it here is the difference between a
            # refusal somebody acts on and a refusal that sends them to write
            # the relationship into a comment, where nothing can check it.
            # That is what happened, and it is the same failure as the report
            # on TKT-194: a message that says no without saying where to go
            # teaches the reader that the capability does not exist.
            die "Hierarchy requires SOW-to-epic or epic-to-ticket. To say one "
              . "record blocks, duplicates or relates to another, use "
              . "tira.link.add --from A --type blocks --to B\n";
        }

        # An untriaged card is not yet real work: giving it a home is one
        # conceptual moment, usually alongside a priority and an assignee,
        # and before this it always cost a second round trip - measured four
        # times in one session. Validated before anything is touched, so an
        # invalid value refuses the whole call, the link included, rather
        # than linking and silently dropping a bad value. TKT-432.
        my $priority = defined $args{priority} ? $self->_valid_priority( $args{priority} ) : undef;
        $self->_require_active_person( project => $root, person => $args{assignee} )
          if defined $args{assignee};

        my $old_parent_ref = $child->{linkage}{$up};
        my @updates;
        if ( defined $old_parent_ref && $old_parent_ref ne $parent->{ref} ) {
            my ( $old_path, $old_parent ) = $self->_record_data( project => $root, ref => $old_parent_ref );
            $old_parent->{linkage}{$down} = [ grep { $_ ne $child->{ref} } @{ $old_parent->{linkage}{$down} } ];
            $old_parent->{last_updated} = $self->{clock}->();
            push @updates, [ $old_path, $old_parent ];
        }
        $child->{linkage}{$up} = $parent->{ref};
        $child->{parent} = $child->{linkage}{"parent_$child->{type}_ref"} // $parent->{ref};
        $child->{priority} = $priority if defined $args{priority};
        $child->{assignee} = $args{assignee} if defined $args{assignee};
        push @{ $parent->{linkage}{$down} }, $child->{ref}
          if !grep { $_ eq $child->{ref} } @{ $parent->{linkage}{$down} };
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        push @updates, [ $parent_path, $parent ], [ $child_path, $child ];
        $self->_write_json_transaction(\@updates);
        return { parent => $parent->{ref}, child => $child->{ref} };
    } );
}

sub hierarchy_unlink {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        my ( $up, $down ) = $parent->{type} eq 'sow' && $child->{type} eq 'epic'
          ? ( 'sow_ref', 'epic_refs' )
          : $parent->{type} eq 'epic' && $child->{type} eq 'ticket'
          ? ( 'epic_ref', 'ticket_refs' )
          : die "Hierarchy requires SOW-to-epic or epic-to-ticket\n";
        die "Records are not linked in that hierarchy\n" if ( $child->{linkage}{$up} // '' ) ne $parent->{ref};
        $child->{linkage}{$up} = undef;
        $child->{parent} = $child->{linkage}{"parent_$child->{type}_ref"};
        $parent->{linkage}{$down} = [ grep { $_ ne $child->{ref} } @{ $parent->{linkage}{$down} } ];
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        $self->_write_json_transaction( [ [ $parent_path, $parent ], [ $child_path, $child ] ] );
        return { parent => $parent->{ref}, child => $child->{ref}, unlinked => Cpanel::JSON::XS::true };
    } );
}

sub hierarchy_show {
    my ( $self, %args ) = @_;
    die "A card is named by --ref\n" if !defined $args{ref} || $args{ref} eq '';
    my $root = $self->discover_project(%args);
    my %seen;
    my $build;
    $build = sub {
        my ($ref) = @_;
        die "Hierarchy cycle detected at '$ref'\n" if $seen{$ref}++;
        my $record = $self->record_show( project => $root, ref => $ref );
        my $children = $record->{type} eq 'sow' ? $record->{linkage}{epic_refs}
          : $record->{type} eq 'epic' ? $record->{linkage}{ticket_refs} : [];
        my $node = { %{$record}, children => [] };
        if ( $args{recursive} ) {
            push @{ $node->{children} }, $build->($_) for @{$children};
        }
        else {
            $node->{children} = [ map { { ref => $_ } } @{$children} ];
        }
        $seen{$ref}--;
        return $node;
    };
    return $build->( $args{ref} );
}

sub subitem_link {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        die "Subitems must have the same type\n" if $parent->{type} ne $child->{type};
        die "Subitem cycle detected\n" if $self->_is_subitem_descendant( $root, $child->{ref}, $parent->{ref} );
        my $type = $parent->{type};
        my $up = "parent_${type}_ref";
        my $down = "sub_${type}_refs";
        die "Child already has a different subitem parent\n"
          if defined $child->{linkage}{$up} && $child->{linkage}{$up} ne $parent->{ref};
        $child->{linkage}{$up} = $parent->{ref};
        $child->{parent} = $parent->{ref};
        push @{ $parent->{linkage}{$down} }, $child->{ref}
          if !grep { $_ eq $child->{ref} } @{ $parent->{linkage}{$down} };
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        $self->_write_json_transaction( [ [ $parent_path, $parent ], [ $child_path, $child ] ] );
        return { parent => $parent->{ref}, child => $child->{ref} };
    } );
}

sub subitem_unlink {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $parent_path, $parent ) = $self->_record_data( project => $root, ref => $args{parent} );
        my ( $child_path, $child ) = $self->_record_data( project => $root, ref => $args{child} );
        die "Subitems must have the same type\n" if $parent->{type} ne $child->{type};
        my $type = $parent->{type};
        my $up = "parent_${type}_ref";
        my $down = "sub_${type}_refs";
        die "Records are not linked as subitems\n" if ( $child->{linkage}{$up} // '' ) ne $parent->{ref};
        $child->{linkage}{$up} = undef;
        $child->{parent} = $child->{linkage}{sow_ref} // $child->{linkage}{epic_ref};
        $parent->{linkage}{$down} = [ grep { $_ ne $child->{ref} } @{ $parent->{linkage}{$down} } ];
        $child->{last_updated} = $parent->{last_updated} = $self->{clock}->();
        $self->_write_json_transaction( [ [ $parent_path, $parent ], [ $child_path, $child ] ] );
        return { parent => $parent->{ref}, child => $child->{ref}, unlinked => Cpanel::JSON::XS::true };
    } );
}

sub link_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $from_path, $from ) = $self->_record_data( project => $root, ref => $args{from} );
        my ( $to_path, $to ) = $self->_record_data( project => $root, ref => $args{to} );
        my $reciprocal = $self->_reciprocal_type( $root, $args{type} );
        push @{ $from->{linkage}{links} }, { type => $args{type}, ref => $to->{ref} }
          if !grep { $_->{type} eq $args{type} && $_->{ref} eq $to->{ref} } @{ $from->{linkage}{links} };
        push @{ $to->{linkage}{links} }, { type => $reciprocal, ref => $from->{ref} }
          if !grep { $_->{type} eq $reciprocal && $_->{ref} eq $from->{ref} } @{ $to->{linkage}{links} };
        $self->_write_json_transaction( [ [ $from_path, $from ], [ $to_path, $to ] ] );
        return { from => $from->{ref}, type => $args{type}, to => $to->{ref}, reciprocal => $reciprocal };
    } );
}

sub link_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $from_path, $from ) = $self->_record_data( project => $root, ref => $args{from} );
        my ( $to_path, $to ) = $self->_record_data( project => $root, ref => $args{to} );
        my $reciprocal = $self->_reciprocal_type( $root, $args{type} );
        $from->{linkage}{links} = [ grep { !( $_->{type} eq $args{type} && $_->{ref} eq $to->{ref} ) } @{ $from->{linkage}{links} } ];
        $to->{linkage}{links} = [ grep { !( $_->{type} eq $reciprocal && $_->{ref} eq $from->{ref} ) } @{ $to->{linkage}{links} } ];
        $self->_write_json_transaction( [ [ $from_path, $from ], [ $to_path, $to ] ] );
        return { removed => Cpanel::JSON::XS::true };
    } );
}

sub link_list {
    my ( $self, %args ) = @_;
    my $links = $self->record_show(%args)->{linkage}{links};
    return [ grep { !defined $args{type} || $_->{type} eq $args{type} } @{$links} ];
}

sub assignment_list {
    my ( $self, %args ) = @_;
    my $person = $self->record_show(%args)->{assignee};
    return defined $person ? [$person] : [];
}

sub assignment_add {
    my ( $self, %args ) = @_;
    return $self->assignment_set( %args, people => [ $args{person} ] );
}

sub assignment_remove {
    my ( $self, %args ) = @_;
    my $current = $self->record_show(%args)->{assignee};
    return $self->record_show(%args) if !defined $current || $current ne ( $args{person} // '' );
    return $self->assignment_set( %args, people => [] );
}

sub assignment_set {
    my ( $self, %args ) = @_;
    my $people = $args{people} // [];
    die "A record accepts only one assignee\n" if @{$people} > 1;
    return $self->record_update( %args, assignee => @{$people} ? $people->[0] : '' );
}

my @COMMENT_FIELDS = qw(id author format body attachments created_at last_updated body_length attachment_count);
my %COMMENT_FIELD = map { $_ => 1 } @COMMENT_FIELDS;

# CA11: everything a watcher needs to notice and attribute a comment,
# nothing it has to pay for before deciding to act.
sub _comment_meta {
    my ($comment) = @_;
    return {
        id => $comment->{id}, author => $comment->{author}, format => $comment->{format},
        created_at => $comment->{created_at}, last_updated => $comment->{last_updated},
        body_length => length( $comment->{body} // '' ),
        attachment_count => scalar @{ $comment->{attachments} // [] },
    };
}

sub comment_list {
    my ( $self, %args ) = @_;
    my $last = delete $args{last};
    my $first = delete $args{first};
    my $meta_only = delete $args{meta_only};
    my $count_mode = delete $args{count};
    my $since = delete $args{since};
    my $fields = delete $args{fields};
    die "Cannot combine --first with --last\n" if defined $first && defined $last;
    for my $window ( grep { defined } $first, $last ) {
        die "Comment windows must be zero or a positive count\n" if $window < 0;
    }
    my $keep;
    if ( defined $fields ) {
        my @names = map { split /,/, $_, -1 } @{$fields};
        for my $name (@names) {
            die "Empty field name in field selection\n" if !length $name;
            die "Unknown comment field '$name'\n" if !$COMMENT_FIELD{$name};
            die "Meta-only contradicts selecting the body\n" if $meta_only && $name eq 'body';
        }
        $keep = { map { $_ => 1 } @names };
    }
    my $comments = $self->record_show(%args)->{comments};
    if ( defined $since ) {
        my $threshold = _epoch_of_datetime( $since, 'Since' );
        $comments = [ grep {
            my $stamp = eval { _epoch_of_datetime( $_->{last_updated} // $_->{created_at}, 'Comment stamp' ) };
            !defined $stamp || $stamp >= $threshold;
        } @{$comments} ];
    }
    my $total = scalar @{$comments};
    return { count => $total }
      if $count_mode || ( defined $last && $last == 0 ) || ( defined $first && $first == 0 );
    if ( defined $last ) {
        my $window = $last > $total ? $total : $last;
        $comments = $window ? [ @{$comments}[ $total - $window .. $total - 1 ] ] : [];
    }
    elsif ( defined $first ) {
        my $window = $first > $total ? $total : $first;
        $comments = [ @{$comments}[ 0 .. $window - 1 ] ];
    }
    $comments = [ map { _comment_meta($_) } @{$comments} ] if $meta_only;
    if ($keep) {
        $comments = [ map {
            my $comment = $_;
            +{ map { exists $comment->{$_} ? ( $_ => $comment->{$_} ) : () } ( 'id', keys %{$keep} ) };
        } @{$comments} ];
    }
    return $comments;
}

# EPIC-469: an agent working a card often cannot move it but can ask about a
# detail. This replaces the open-decision file every agent kept in its own
# format. Addressed by card reference alone - the reference already names the
# board through its prefix, and prefixes cannot collide inside a project.
our @QUESTION_MARKS = qw(ok not-ok);

sub _type_for_ref {
    my ( $self, $root, $ref ) = @_;
    die "A card reference is required\n" if !defined $ref || $ref !~ /\S/;
    for my $type (qw(sow epic ticket)) {
        my $prefix = eval { $self->board_refs( project => $root, type => $type )->{prefix} } or next;
        return $type if $ref =~ /\A\Q$prefix\E-[0-9]+\z/;
    }
    die "No board in this project uses the reference '$ref'\n";
}

# Status is derived rather than stored: a question with an answer is answered,
# one without is new. Nothing to keep in step, so nothing can drift.
# what this question still owes. Read by an LLM, not by a person, and
# Tira exists to spend fewer tokens than Jira - so this is a terse machine line,
# not prose: what is missing, then the commands that fix it on one line. Derived
# rather than stored, and absent entirely when nothing is owed, because a
# reminder that always appears is furniture.
# the same rule as questions, applied to a record. What it still owes,
# derived from its own state, in one terse line for the agent reading it. The
# owner chose these four: they are about who owns the work and how it will be
# judged, rather than about how it is written.
sub record_reminder {
    my ( $self, $record ) = @_;
    my $ref = $record->{ref} or return undef;
    my $type = $record->{type} // 'ticket';
    my ( @missing, @update, @fix );

    if ( !defined $record->{description} || $record->{description} !~ /\S/ ) {
        push @missing, 'description';
        push @update, '--description TEXT';
    }
    if ( !defined $record->{reporter} || $record->{reporter} !~ /\S/ ) {

        # Whoever asked for it, or yourself when you found it: a ticket with no
        # reporter cannot be traced back to why it exists.
        push @missing, 'reporter';
        push @update, '--reporter NAME';
    }
    push @fix, "tira.$type.update --ref $ref " . join( ' ', @update ) if @update;

    if ( !@{ $record->{gate_passing_log} // [] } ) {
        push @missing, 'gate';
        push @fix, "tira.gate.add --ref $ref --gate NAME --result pass --details TEXT";
    }
    if ( !grep { !$_->{discarded_at} } @{ $record->{questions} // [] } ) {

        # Not a defect - most tickets need no question. It is here because
        # guessing at something unclear is the expensive mistake, and an agent
        # that is never told it may ask will not ask.
        push @missing, 'questions(if unclear)';
        push @fix, "tira.question.ask --ref $ref --text TEXT --reason TEXT --option TEXT";
    }
    return undef if !@missing;
    return 'missing: ' . join( ',', @missing ) . ' | fix: ' . join( '; ', @fix );
}

sub _question_reminder {
    my ($entry) = @_;
    return undef if $entry->{discarded_at};
    my $id = $entry->{id};
    my ( @missing, @update );

    if ( !defined $entry->{reason} || $entry->{reason} !~ /\S/ ) {
        push @missing, 'reason';
        push @update, '--reason TEXT';
    }
    if ( !@{ $entry->{options} // [] } ) {
        push @missing, 'options';
        push @update, '--option TEXT --option TEXT';
    }

    my $voice = $entry->{voice};
    if ( !$voice || $voice->{stale} ) {
        push @missing, $voice ? 'voice(stale)' : 'voice';
        push @update, '--voice FILE';
    }
    return undef if !@missing;

    # One command, always. Needing two would mean reading twice and typing
    # twice for one situation, and that is the command surface's problem to fix
    # rather than the reminder's to describe.
    return 'missing: ' . join( ',', @missing )
      . " | fix: tira.question.update --id $id " . join( ' ', @update );
}

sub _question_view {
    my ($entry) = @_;
    my $status = $entry->{discarded_at} ? 'discarded'
      : $entry->{answer} ? 'answered' : 'new';
    my $reminder = _question_reminder($entry);
    return {
        %{$entry}, status => $status,
        ( defined $reminder ? ( reminder => $reminder ) : () ),
    };
}

sub _question_changed_at {
    my ($entry) = @_;
    my $answer = $entry->{answer} or return $entry->{asked_at};
    return $answer->{updated_at} // $answer->{answered_at} // $entry->{asked_at};
}

sub _question_entry {
    my ( $record, $id ) = @_;
    die "A question id is required\n" if !defined $id || $id !~ /\S/;
    my ($entry) = grep { $_->{id} eq $id } @{ $record->{questions} // [] };
    die "Question '$id' not found on this card\n" if !$entry;
    return $entry;
}

# References are project-wide with a Q prefix, one sequence across all three
# boards, so quoting Q-007 is enough to reach it: nobody has to say which card
# it was asked on. The counter lives on the project and never rewinds.
sub _next_question_id {
    my ( $self, $root ) = @_;
    my ( $path, $data ) = $self->_project_data($root);
    my $number = ( $data->{questions_issued} // 0 ) + 1;
    $data->{questions_issued} = $number;
    $self->_write_yaml( $path, $data );
    return sprintf( 'Q-%03d', $number );
}

# Find the card a question was asked on. Walks the boards rather than keeping
# an index, because an index is another thing that can disagree with the truth.
sub _find_question {
    my ( $self, $root, $id ) = @_;
    die "A question id is required\n" if !defined $id || $id !~ /\S/;
    my $found;
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        next if !-d $board;
        find( { no_chdir => 1, wanted => sub {
            return if $found || !-f $File::Find::name;
            my $file = basename($File::Find::name);
            return if $file !~ /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12})\.json\z/;
            my $ref = $1;
            my $record = eval { $self->_read_json($File::Find::name) } or return;
            return if !grep { ( $_->{id} // '' ) eq $id } @{ $record->{questions} // [] };
            $found = { type => $type, ref => $ref };
        } }, $board );
        last if $found;
    }
    die "Question '$id' was not found on any card in this project\n" if !$found;
    return @{$found}{qw(type ref)};
}

# Where a question lives, checked against where the caller said it lives.
#
# Resolving by id alone is the convenience worth keeping: the ids are unique
# across a board, so an agent should not have to say which card. What must not
# happen is a card being named and then thrown away - every one of these
# commands used to do exactly that, so naming one card and another card's
# question changed the other card and returned success. The card that was named
# stayed waiting, and nothing anywhere said the answer had landed elsewhere.
sub _question_owner {
    my ( $self, $root, %args ) = @_;
    if ( !defined $args{id} || $args{id} !~ /\S/ ) {

        # The die below (via _find_question) says an id is missing, which is
        # true but not the whole story when --ref was given a question id by
        # mistake - a caller reading "supply it" reaches for the flag they
        # already used, and gets refused again for the same unnamed reason.
        # Question ids are always Q-NNN (_next_question_id), never a board's
        # own ref shape, so the pattern alone tells the two cases apart.
        die "'$args{ref}' is a question id, not a card reference - name the "
          . "question with --id, not --ref\n"
          if defined $args{ref} && $args{ref} =~ /\AQ-\d+\z/;
    }
    my ( $type, $ref ) = $self->_find_question( $root, $args{id} );
    return ( $type, $ref ) if !defined $args{ref} || $args{ref} eq '';

    die "Question '$args{id}' is on $ref, not on $args{ref}. Name that card, or leave "
      . "the card out and the question will be found on its own\n"
      if $args{ref} ne $ref;
    return ( $type, $ref );
}

sub question_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $text = $args{text};
    die "A question needs some text\n" if !defined $text || $text !~ /\S/;
    my $type = $self->_type_for_ref( $root, $args{ref} );
    my $added = $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $args{ref} );
        # A reason and the options the agent can see are what turn a question
        # into one the owner can answer quickly. Both optional: a bare question
        # is still a question.
        my @options = grep { defined && /\S/ } @{ $args{options} // [] };
        my $entry = {
            id => $self->_next_question_id($root), text => $text,
            reason => ( defined $args{reason} && $args{reason} =~ /\S/ ? $args{reason} : undef ),
            options => \@options,
            author => $args{author}, asked_at => $self->{clock}->(), answer => undef,
        };
        push @{ $record->{questions} }, $entry;
        $self->_replace_record( project => $root, type => $type, ref => $args{ref}, record => $record );
        return _question_view($entry);
    } );

    # Attached after the question exists, so a bad recording fails the voice
    # note rather than losing the question that was already worth asking.
    return $self->question_voice( project => $root, id => $added->{id}, file => $args{voice} )
      if defined $args{voice};
    return $added;
}

# a question asked before reason and options existed has all three
# crammed into its text, because that was the only field there was. An agent
# must be able to go back and take it apart - in one command or three - so only
# what is named changes. Rewriting a question is not the same as decomposing it.
sub question_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $found_type, $found_ref ) = $self->_question_owner( $root, %args );
    @args{qw(type ref)} = ( $found_type, $found_ref );
    die "Give some text, a reason, options, or a voice note to change\n"
      if !grep { defined $args{$_} } qw(text reason options voice);
    die "A question needs some text\n"
      if defined $args{text} && $args{text} !~ /\S/;
    my $type = $args{type};
    my $updated = $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $args{ref} );
        my $entry = _question_entry( $record, $args{id} );
        $entry->{updated_at} = $self->{clock}->();
        $entry->{voice}{stale} = Cpanel::JSON::XS::true if $entry->{voice};
        $entry->{text} = $args{text} if defined $args{text};

        # An explicitly empty value clears that piece, the same rule the
        # project settings use, because an agent may decide its reason was
        # wrong. Absent means leave alone.
        if ( defined $args{reason} ) {
            $entry->{reason} = $args{reason} =~ /\S/ ? $args{reason} : undef;
        }
        if ( defined $args{options} ) {
            $entry->{options} = [ grep { defined && /\S/ } @{ $args{options} } ];
        }
        $self->_replace_record( project => $root, type => $type, ref => $args{ref}, record => $record );
        return _question_view($entry);
    } );

    # A recording given here replaces the one this change just made stale, so
    # everything a question owes is settled by a single command.
    return $self->question_voice( project => $root, id => $args{id}, file => $args{voice} )
      if defined $args{voice};
    return $updated;
}

# Nothing in Tira is ever really deleted, and questions are no exception: the
# record of having asked is the point. Discarding is the same illusion the
# Discard column gives a card - the question stays, its answer stays under it,
# and the board draws it struck through.
sub question_discard {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $found_type, $found_ref ) = $self->_question_owner( $root, %args );
    @args{qw(type ref)} = ( $found_type, $found_ref );
    my $type = $args{type};
    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $args{ref} );
        my $entry = _question_entry( $record, $args{id} );
        die "Question '$args{id}' is already discarded\n" if $entry->{discarded_at};
        $entry->{discarded_at} = $self->{clock}->();
        $self->_replace_record( project => $root, type => $type, ref => $args{ref}, record => $record );
        return _question_view($entry);
    } );
}

sub question_answer {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $found_type, $found_ref ) = $self->_question_owner( $root, %args );
    @args{qw(type ref)} = ( $found_type, $found_ref );
    my $text = $args{text};
    die "An answer needs some text\n" if !defined $text || $text !~ /\S/;
    my $type = $args{type};
    my $answered = $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $args{ref} );
        my $entry = _question_entry( $record, $args{id} );
        die "Question '$args{id}' has been discarded\n" if $entry->{discarded_at};
        my $now = $self->{clock}->();

        # The question keeps the stamp of when it was asked. Editing an answer
        # stamps the answer, never the question.
        if ( $entry->{answer} ) {
            $entry->{answer}{text} = $text;
            $entry->{answer}{updated_at} = $now;
        }
        else {
            $entry->{answer} = {
                text => $text, author => $args{author}, answered_at => $now,
                read_at => undef, mark => undef,
            };
        }
        $self->_replace_record( project => $root, type => $type, ref => $args{ref}, record => $record );
        return _question_view($entry);
    } );

    # Evidence given with the answer, so answering and explaining it are one
    # action rather than two the owner has to remember to pair.
    return $self->question_attach(
        project => $root, id => $args{id}, file => $args{file}, to => 'answer' )
      if defined $args{file};
    return $answered;
}

# The agent records the audio and hands over a path; Tira stores and
# serves it. Tira never speaks the text itself, because it runs no external
# process - that rule is why the engine passes under taint mode and can be
# trusted inside another tool, and it is not worth spending for a convenience.
our %QUESTION_VOICE_TYPES = ( mp3 => 1, wav => 1, m4a => 1, ogg => 1, oga => 1, opus => 1, flac => 1 );

# One place that takes a path and returns a stored reference, shared by
# voice notes and by the evidence hung on a question or its answer. Content
# addressed like every other attachment, so the same file in three places is one
# file and the route that already serves attachments serves these.
sub _store_attachment_file {
    my ( $self, $root, $path, %opt ) = @_;
    die "A file is required\n" if !defined $path || $path !~ /\S/;
    my $extension = $path =~ /\.([A-Za-z0-9]+)\z/ ? lc $1 : '';
    if ( $opt{audio_only} ) {
        die "A voice note must be audio: " . join( ', ', sort keys %QUESTION_VOICE_TYPES ) . "\n"
          if !$QUESTION_VOICE_TYPES{$extension};
    }
    $extension = 'bin' if $extension eq '';
    my $safe = $self->_safe_path_input( $path, 'attachment' );
    open my $fh, '<:raw', $safe or die "Cannot read '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    die "That file is empty\n" if !length $content;
    die "That file is too large (16 MB maximum)\n" if length($content) > 16 * 1024 * 1024;
    my $sha = sha256_hex($content);
    $sha =~ /\A([0-9a-f]{64})\z/ or die "Cannot validate attachment\n";
    $sha = $1;
    my $stored = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.$extension" );
    $self->_atomic_write( $stored, $content ) if !-f $stored;
    return {
        sha => $sha, extension => $extension,

        # The browser hands over bytes in a temporary file, so the name it was
        # dropped under has to travel separately or the card records a
        # meaningless one.
        original_filename => $opt{filename} // basename($safe),
        added_at => $self->{clock}->(),
    };
}

# Evidence belongs with the question it explains, and an answer's evidence with
# the answer. Both are listed under the question, because somebody reading it
# wants everything that bears on it rather than a tidy taxonomy.
sub question_attach {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $type, $ref ) = $self->_question_owner( $root, %args );
    my $reference = $args{remove} ? undef
      : $self->_store_attachment_file( $root, $args{file},
        ( defined $args{filename} ? ( filename => $args{filename} ) : () ) );
    my $side = ( $args{to} // 'question' ) eq 'answer' ? 'answer' : 'question';

    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $ref );
        my $entry = _question_entry( $record, $args{id} );
        die "Question '$args{id}' has not been answered yet\n"
          if $side eq 'answer' && !$entry->{answer};
        my $host = $side eq 'answer' ? $entry->{answer} : $entry;

        if ( $args{remove} ) {
            my $name = $args{filename} // '';
            my @kept = grep { ( $_->{original_filename} // '' ) ne $name } @{ $host->{attachments} // [] };
            die "No attachment called '$name' on that $side\n"
              if @kept == @{ $host->{attachments} // [] };
            $host->{attachments} = \@kept;
        }
        else {
            # The same file twice is the same reference, not two rows saying
            # the same thing.
            my @existing = grep { $_->{sha} ne $reference->{sha} } @{ $host->{attachments} // [] };
            $host->{attachments} = [ @existing, $reference ];
        }
        $self->_replace_record( project => $root, type => $type, ref => $ref, record => $record );
        return _question_view($entry);
    } );
}

sub question_voice {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $type, $ref ) = $self->_question_owner( $root, %args );

    my $reference;
    if ( !$args{remove} ) {
        die "A voice note needs a file\n" if !defined $args{file} || $args{file} !~ /\S/;
        $reference = $self->_store_attachment_file( $root, $args{file}, audio_only => 1 );
    }

    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $ref );
        my $entry = _question_entry( $record, $args{id} );
        die "Question '$args{id}' has no voice note to remove\n"
          if $args{remove} && !$entry->{voice};

        # Replacing leaves the old bytes in the store: another question may be
        # pointing at the same recording, and attachments are never unlinked on
        # the strength of one reference going away.
        $entry->{voice} = $reference;
        $self->_replace_record( project => $root, type => $type, ref => $ref, record => $record );
        return _question_view($entry);
    } );
}

sub question_mark {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( $found_type, $found_ref ) = $self->_question_owner( $root, %args );
    @args{qw(type ref)} = ( $found_type, $found_ref );
    my $mark = $args{mark} // '';
    die "A mark is either ok or not-ok\n" if !grep { $_ eq $mark } @QUESTION_MARKS;
    my $type = $args{type};
    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $args{ref} );
        my $entry = _question_entry( $record, $args{id} );
        die "Question '$args{id}' has not been answered yet\n" if !$entry->{answer};
        $entry->{answer}{mark} = $mark;
        $entry->{answer}{marked_at} = $self->{clock}->();
        $self->_replace_record( project => $root, type => $type, ref => $args{ref}, record => $record );
        return _question_view($entry);
    } );
}

sub question_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $status = $args{status};
    die "Status is one of new, answered or discarded\n"
      if defined $status && $status !~ /\A(?:new|answered|discarded)\z/;
    my $since = defined $args{since} ? _epoch_of_datetime( $args{since}, 'Since' ) : undef;
    my $type = $self->_type_for_ref( $root, $args{ref} );

    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show( project => $root, type => $type, ref => $args{ref} );

        # Reading is what marks an answer read - the agent does nothing extra.
        # Written only when something actually changed, so listing twice does
        # not keep rewriting the card.
        my $now = $self->{clock}->();
        my $marked = 0;
        for my $entry ( @{ $record->{questions} } ) {
            next if $entry->{discarded_at};
            next if !$entry->{answer} || defined $entry->{answer}{read_at};
            $entry->{answer}{read_at} = $now;
            $marked++;
        }
        $self->_replace_record( project => $root, type => $type, ref => $args{ref}, record => $record )
          if $marked;

        my @questions = map { _question_view($_) } @{ $record->{questions} };
        @questions = grep { $_->{status} eq $status } @questions if defined $status;
        @questions = grep {
            ( eval { _epoch_of_datetime( _question_changed_at($_), 'Question stamp' ) } // 0 ) >= $since
        } @questions if defined $since;
        return {
            ref => $args{ref}, type => $type, title => $record->{title},
            questions => \@questions,
            instruction => 'If an answer settles it, run tira.question.mark --mark ok. '
              . 'If it does not, run tira.question.mark --mark not-ok AND ask a new one '
              . 'with tira.question.ask - a cross on its own settles nothing. '
              . 'Unanswered questions are waiting on the owner, not on you.',
        };
    } );
}

# What passed between the user and whoever was working this card.
#
# His design: the user talks only to the core agent, which decides which direct
# report hears what, and the conversation is reflected onto the card by the
# agent that owns it. Without that, a manager knows only what it said downward
# and nothing of what came back - it is managing something it cannot see.
#
# Separate from comments on purpose. A comment is somebody writing on the card;
# this is a record of something that was said elsewhere, with who heard it, and
# conflating the two would make the card's own discussion harder to read for
# exactly the people who need it.
sub conversation_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        $self->_require_person( %args, person => $args{author} );
        local $self->{_journal_author} = $args{author};
        my $record = $self->record_show(%args);
        my $number = 1;
        for my $existing ( @{ $record->{conversation} // [] } ) {
            $number = $1 + 1 if $existing->{id} =~ /\ACNV-(\d+)\z/ && $1 >= $number;
        }
        my $entry = {
            id => sprintf( 'CNV-%03d', $number ),
            author => $args{author},
            heard => $args{heard},
            said => $args{said} // '',
            created_at => $self->{clock}->(),
        };
        push @{ $record->{conversation} }, $entry;
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

sub conversation_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{conversation} // [];
}

# Every child of this card and what it would take to wake each one. Read off
# the board rather than from whatever spawned them, because the thing that
# spawned them is the thing that closes - which is the whole problem.
#
# A child with no agent yet is listed with nothing to resume. Leaving it out
# would make the answer read as "these are all your children" when it is not.
sub agent_sessions {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $record = $self->record_show(%args);
    my @children = (
        @{ $record->{linkage}{epic_refs} // [] },
        @{ $record->{linkage}{ticket_refs} // [] },
        @{ $record->{linkage}{sub_ticket_refs} // [] },
    );
    return [ map {
        my $child = $self->record_show( project => $root, ref => $_ );
        { ref => $child->{ref}, agent_session => $child->{agent_session} }
    } @children ];
}

sub comment_add {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        $self->_require_person( %args, person => $args{author} );
        local $self->{_journal_author} = $args{author};
        my $record = $self->record_show(%args);
        my $number = 1;
        for my $existing ( @{ $record->{comments} } ) {
            $number = $1 + 1 if $existing->{id} =~ /\ACMT-(\d+)\z/ && $1 >= $number;
        }
        my $now = $self->{clock}->();
        my $comment = {
            id => sprintf( 'CMT-%03d', $number ), author => $args{author}, format => $args{format} // 'markdown',
            body => $args{text} // '', attachments => [], created_at => $now, last_updated => $now,
        };
        push @{ $record->{comments} }, $comment;
        $self->_replace_record( %args, record => $record );
        return $comment;
    } );
}

sub comment_update {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show(%args);
        my ($comment) = grep { $_->{id} eq ( $args{comment} // '' ) } @{ $record->{comments} };
        die "Comment '$args{comment}' not found\n" if !$comment;
        $comment->{body} = $args{text} if defined $args{text};
        $comment->{format} = $args{format} if defined $args{format};
        $comment->{last_updated} = $self->{clock}->();
        $self->_replace_record( %args, record => $record );
        return $comment;
    } );
}

sub comment_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show(%args);
        my $id = $args{comment} // '';
        my ($removed) = grep { $_->{id} eq $id } @{ $record->{comments} };
        die "Comment '$id' not found\n" if !$removed;
        $record->{comments} = [ grep { $_->{id} ne $id } @{ $record->{comments} } ];
        $self->_replace_record( %args, record => $record );
        return $removed;
    } );
}

sub comment_attach {
    my ( $self, %args ) = @_;
    die "An attachment is a file, given by --file\n" if !defined $args{file} || $args{file} eq '';
    return $self->attachment_add(%args);
}

sub attachment_add {
    my ( $self, %args ) = @_;
    die "An attachment is a file, given by --file\n" if !defined $args{file} || $args{file} eq '';
    my $file = $self->_canonical_path( $args{file}, "attachment '$args{file}'" );
    open my $fh, '<:raw', $file or die "Cannot read attachment '$file': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    return $self->attachment_add_content( %args, filename => basename($file), content => $content );
}

# Content-based twin of attachment_add for browser uploads: same sha dedup
# and reference bookkeeping, no temporary file, and a hard size cap so a
# dialog upload cannot balloon the store.
sub attachment_add_content {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $content = $args{content};
        die "Attachment upload requires filename and content\n"
          if !defined $args{filename} || $args{filename} eq '' || !defined $content;
        die "Attachment upload is too large (16 MB maximum)\n" if length($content) > 16 * 1024 * 1024;
        my $sha = sha256_hex($content);
        $sha =~ /\A([0-9a-f]{64})\z/ or die "Cannot validate attachment SHA\n";
        $sha = $1;
        my $name = $args{filename};
        my $extension = $name =~ /\.([A-Za-z0-9]+)\z/ ? lc $1 : 'bin';
        my $root = $self->discover_project(%args);
        my $stored = File::Spec->catfile( $root, '.tira', 'attachments', "$sha.$extension" );
        $self->_atomic_write( $stored, $content ) if !-f $stored;
        my $reference = { sha => $sha, extension => $extension, original_filename => $name, added_at => $self->{clock}->() };
        my $record = $self->record_show( project => $root, ref => $args{ref} );
        my $attachments;
        if ( defined $args{comment} ) {
            my ($comment) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
            die "Comment '$args{comment}' not found\n" if !$comment;
            $attachments = $comment->{attachments};
        }
        else {
            $attachments = $record->{attachments};
        }
        my ($retained) = grep { $_->{sha} eq $sha && $_->{extension} eq $extension } @{$attachments};

        # A write that cannot take does not report success. These bytes are set
        # aside on this card, so deduplication would answer with the discarded
        # record - original timestamp, discarded_at still on it, deduped true,
        # exit zero - and create nothing. A project lost ten screenshots to
        # that: their script counted exit codes and reported ten fresh
        # attachments having made none, and the only repair left was to change
        # the bytes until the hash moved.
        #
        # Refused rather than revived. Reviving is friendlier, and discard is
        # described as setting aside rather than deleting, so being unable to
        # put it back is the surprise - but a refusal cannot lose anything, and
        # a revive can be added on top of one. It could not be added on top of
        # silence.
        die "These bytes were discarded on '$args{ref}' and adding them again "
          . "will not bring them back. Attach different content, or say so "
          . "explicitly on the card.\n"
          if $retained && $retained->{discarded_at};

        my $deduped = defined $retained;
        if ( !$deduped ) {
            push @{$attachments}, $reference;
            $retained = $reference;
        }
        $self->_replace_record( project => $root, ref => $args{ref}, record => $record );
        return {
            %{$retained}, supplied_filename => $name,
            deduped => $deduped ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
        };
    } );
}

# Removes one attachment reference from a record (or one of its comments).
# Storage is deduplicated by content hash, so the stored file is physically
# removed - through the logged attachment_remove workflow - only when no
# record or comment anywhere in the project still references it.
sub attachment_detach {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $root = $self->discover_project(%args);
        my $sha = $args{sha} // '';
        my $record = $self->record_show( project => $root, ref => $args{ref} );
        my $owner;
        if ( defined $args{comment} ) {
            ($owner) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
            die "Comment '$args{comment}' not found\n" if !$owner;
        }
        else {
            $owner = $record;
        }
        my @keep = grep {
            !( $_->{sha} eq $sha && ( !defined $args{extension} || $_->{extension} eq $args{extension} ) )
        } @{ $owner->{attachments} };
        my ($reference) = grep {
            $_->{sha} eq $sha && ( !defined $args{extension} || $_->{extension} eq $args{extension} )
        } @{ $owner->{attachments} };
        die "Attachment '$sha' is not attached there\n" if !$reference;
        $owner->{attachments} = \@keep;
        $self->_replace_record( project => $root, ref => $args{ref}, record => $record );

        my $extension = $reference->{extension};
        my $still_referenced = 0;
        for my $candidate ( @{ $self->record_list( project => $root ) } ) {
            my @pools = ( $candidate->{attachments}, map { $_->{attachments} } @{ $candidate->{comments} // [] } );
            for my $pool (@pools) {
                $still_referenced ||= grep { $_->{sha} eq $sha && $_->{extension} eq $extension } @{ $pool // [] };
            }
        }
        my $removed = 0;
        if ( !$still_referenced ) {
            $self->attachment_remove( project => $root, sha => $sha, extension => $extension );
            $removed = 1;
        }
        return {
            detached => Cpanel::JSON::XS::true, sha => $sha, extension => $extension,
            removed_from_store => $removed ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
        };
    } );
}

# Taking an attachment off a card without losing it. Everything else in Tira is
# set aside rather than deleted - a discarded question keeps its answer and
# shows struck through - and an attachment was the one place where something
# disappeared: detach dropped the reference out of the card entirely and took
# the stored file with it when nothing else pointed at it.
#
# A discard keeps the reference, stamps it with when and who, and leaves the
# stored file alone even when it is the last one referring to it. The bytes are
# shared by content hash and are not this card's to destroy.
# The board's own certificate, made without running anything. Developer
# Dashboard shells out to openssl for this; Tira documents that it invokes no
# shell or external process, and that guarantee is not worth spending on a
# convenience - IO::Socket::SSL can make one from Perl.
#
# Made once and reused. A certificate that changes on every restart is one the
# browser warns about every time, which teaches somebody to click through
# warnings - the opposite of the point of having one.
sub tls_certificate {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);

    # Beside the project, never inside a board: a scan or a content hash has no
    # business tripping over a private key.
    my $dir = File::Spec->catdir( $root, '.tira', 'ssl' );
    my $certificate_path = File::Spec->catfile( $dir, 'board.crt' );
    my $key_path = File::Spec->catfile( $dir, 'board.key' );

    if ( -f $certificate_path && -f $key_path ) {
        return {
            certificate => $self->_slurp($certificate_path),
            key => $self->_slurp($key_path),
            certificate_path => $certificate_path, key_path => $key_path,
        };
    }

    eval { require IO::Socket::SSL::Utils; 1 }
      or die "Serving over HTTPS needs IO::Socket::SSL. Install it (for example: "
      . "cpanm IO::Socket::SSL) and run this again.\n";

    make_path($dir) if !-d $dir;
    my ( $certificate, $key ) = IO::Socket::SSL::Utils::CERT_create(
        subject => { commonName => 'tira-board' },
        subjectAltNames => [ [ DNS => 'localhost' ], [ IP => '127.0.0.1' ] ],
        not_after => time + 365 * 24 * 3600,
    );
    my $certificate_pem = IO::Socket::SSL::Utils::PEM_cert2string($certificate);
    my $key_pem = IO::Socket::SSL::Utils::PEM_key2string($key);

    $self->_atomic_write( $certificate_path, $certificate_pem );
    $self->_atomic_write( $key_path, $key_pem );

    # The filesystem is the only thing protecting the key.
    chmod 0600, $key_path;

    return {
        certificate => $certificate_pem, key => $key_pem,
        certificate_path => $certificate_path, key_path => $key_path,
    };
}

sub attachment_discard {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $sha = $args{sha} // '';
        die "An attachment reference is required\n" if $sha eq '';
        $self->_require_person( %args, person => $args{author} ) if defined $args{author};

        my $record = $self->record_show( project => $root, ref => $args{ref} );
        my $owner = $record;
        if ( defined $args{comment} ) {
            ($owner) = grep { $_->{id} eq $args{comment} } @{ $record->{comments} };
            die "Comment '$args{comment}' not found\n" if !$owner;
        }

        my ($reference) = grep {
            $_->{sha} eq $sha && ( !defined $args{extension} || $_->{extension} eq $args{extension} )
        } @{ $owner->{attachments} };
        die "Attachment '$sha' is not attached there\n" if !$reference;

        # Stamping one twice would rewrite who discarded it and when, which is
        # the record somebody would be relying on.
        die "Attachment '$sha' is already discarded\n" if $reference->{discarded_at};

        # The stamp is the record of it. The work log reads it off the card
        # rather than being told separately, so the entry cannot be forgotten
        # and cannot be written by hand either.
        $reference->{discarded_at} = $self->{clock}->();
        $reference->{discarded_by} = $args{author};
        $self->_replace_record( project => $root, ref => $args{ref}, record => $record );
        return $reference;
    } );
}

sub attachment_get {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_attachment_path( $root, %args );
    if ( defined $path && -f $path ) {
        open my $fh, '<:raw', $path or die "Cannot read attachment: $!\n";
        my $content = do { local $/; <$fh> };
        close $fh;
        return { content => $content, deleted => 0 };
    }
    my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
    if ( -f $log_path ) {
        my $entries = $self->_load_yaml($log_path) || [];
        my ($entry) = reverse grep { $_->{sha} eq ( $args{sha} // '' ) && ( !defined $args{extension} || $_->{extension} eq $args{extension} ) } @{$entries};
        return { content => "Deleted at $entry->{deleted_at}\n", deleted => 1, deleted_at => $entry->{deleted_at} } if $entry;
    }
    die "Attachment '$args{sha}' not found\n";
}

sub attachment_remove {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_attachment_path( $root, %args );
    die "Attachment '$args{sha}' not found\n" if !defined $path || !-f $path;
    my $extension = $args{extension} // ( basename($path) =~ /\.([^.]+)\z/ ? $1 : 'bin' );
    unlink $path or die "Cannot remove attachment: $!\n";
    my $entry = { sha => $args{sha}, extension => $extension, deleted_at => $self->{clock}->() };
    my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
    my $entries = -f $log_path ? ( $self->_load_yaml($log_path) || [] ) : [];
    push @{$entries}, $entry;
    $self->_write_yaml( $log_path, $entries );
    return $entry;
}

my @ATTACHMENT_FIELDS = qw(sha extension original_filename added_at filename size content_type);
my %ATTACHMENT_FIELD = map { $_ => 1 } @ATTACHMENT_FIELDS;

sub _attachment_content_type {
    my ($extension) = @_;
    my %image = map { $_ => 1 } qw(png jpg jpeg gif webp svg);
    return 'image/' . ( $extension eq 'jpg' ? 'jpeg' : $extension eq 'svg' ? 'svg+xml' : $extension )
      if $image{$extension};
    return 'image/tiff' if $extension eq 'tif' || $extension eq 'tiff';
    my %video = ( mp4 => 'video/mp4', m4v => 'video/mp4', mov => 'video/quicktime', webm => 'video/webm' );
    return $video{$extension} if $video{$extension};
    my %audio = ( mp3 => 'audio/mpeg', wav => 'audio/wav', m4a => 'audio/mp4', ogg => 'audio/ogg', flac => 'audio/flac' );
    return $audio{$extension} if $audio{$extension};
    return 'application/pdf' if $extension eq 'pdf';
    my %text = map { $_ => 1 } qw(txt md log csv json yml yaml xml html);
    return 'text/plain; charset=UTF-8' if $text{$extension};
    return 'application/octet-stream';
}

# a file on a card can live in three places - on the card, on a comment,
# or as a voice note on a question. Counting only the first meant a card whose
# files all hung off comments reported zero, and an agent read that zero as
# failure and went looking for a bug that was not there. A count that says zero
# when files exist is a lie by omission, so this looks everywhere and says where
# each one was found.
sub _record_attachments {
    my ($record) = @_;
    my @found = map { { %{$_}, attached_to => 'card' } } @{ $record->{attachments} // [] };
    for my $comment ( @{ $record->{comments} // [] } ) {
        push @found, map { { %{$_}, attached_to => "comment $comment->{id}" } }
          @{ $comment->{attachments} // [] };
    }
    for my $question ( @{ $record->{questions} // [] } ) {
        push @found, { %{ $question->{voice} }, attached_to => "question $question->{id}" }
          if $question->{voice};
        push @found, map { { %{$_}, attached_to => "question $question->{id}" } }
          @{ $question->{attachments} // [] };
        push @found, map { { %{$_}, attached_to => "answer $question->{id}" } }
          @{ $question->{answer}{attachments} // [] } if $question->{answer};
    }
    return \@found;
}

sub attachment_list {
    my ( $self, %args ) = @_;
    my $meta_only = delete $args{meta_only};
    my $count_mode = delete $args{count};
    my $since = delete $args{since};
    my $fields = delete $args{fields};
    if ( !defined $args{ref} ) {
        die "Attachment read options require --ref\n"
          if $meta_only || $count_mode || defined $since || defined $fields;
    }
    if ( defined $args{ref} && ( $meta_only || $count_mode || defined $since || defined $fields ) ) {
        my $keep;
        if ( defined $fields ) {
            my @names = map { split /,/, $_, -1 } @{$fields};
            for my $name (@names) {
                die "Empty field name in field selection\n" if !length $name;
                die "Unknown attachment field '$name'\n" if !$ATTACHMENT_FIELD{$name};
            }
            $keep = { map { $_ => 1 } @names };
        }
        my $references = _record_attachments( $self->record_show(%args) );
        if ( my @only = @{ $args{questions} // [] } ) {

            # Naming a question narrows to it, exactly as the owner asked. Naming
            # none shows everything, so a count can still be trusted.
            my %wanted = map { ( "question $_" => 1, "answer $_" => 1 ) } @only;
            $references = [ grep { $wanted{ $_->{attached_to} // '' } } @{$references} ];
        }
        if ( defined $since ) {
            my $threshold = _epoch_of_datetime( $since, 'Since' );
            $references = [ grep {
                my $stamp = eval { _epoch_of_datetime( $_->{added_at}, 'Added at' ) };
                !defined $stamp || $stamp >= $threshold;
            } @{$references} ];
        }
        return { count => scalar @{$references} } if $count_mode;
        my $root = $self->discover_project(%args);
        my @entries = map {
            my $reference = $_;
            my $stored = eval { $self->_attachment_path( $root, sha => $reference->{sha}, extension => $reference->{extension} ) };
            +{
                %{$reference},
                filename => $reference->{original_filename}
                  // ( ( $reference->{sha} // 'attachment' ) . '.' . ( $reference->{extension} // 'bin' ) ),
                size => ( defined $stored && -f $stored ) ? -s $stored : undef,
                content_type => _attachment_content_type( $reference->{extension} // '' ),
            };
        } @{$references};
        if ($keep) {
            return [ map {
                my $entry = $_;
                +{ map { exists $entry->{$_} ? ( $_ => $entry->{$_} ) : () } ( 'sha', keys %{$keep} ) };
            } @entries ];
        }
        # CA12: newest evidence first, documented.
        @entries = sort {
            ( $b->{added_at} // '' ) cmp( $a->{added_at} // '' )
        } @entries;
        my $total_size = 0;
        $total_size += $_->{size} // 0 for @entries;
        return { attachments => \@entries, count => scalar @entries, total_size => $total_size };
    }
    return _record_attachments( $self->record_show(%args) ) if defined $args{ref};
    my $root = $self->discover_project(%args);
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @items = map { my ( $sha, $ext ) = /\A([0-9a-f]{64})\.([^.]+)\z/; { sha => $sha, extension => $ext } }
      grep { /\A[0-9a-f]{64}\.[^.]+\z/ } readdir $dh;
    closedir $dh;
    if ( $args{include_deleted} ) {
        my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
        if ( -f $log_path ) {
            push @items, map { { %{$_}, deleted => Cpanel::JSON::XS::true } } @{ $self->_load_yaml($log_path) || [] };
        }
    }
    return \@items;
}

sub record_clone {
    my ( $self, %args ) = @_;
    my $source = $self->record_show(%args);
    my $clone = $self->create_record( project => $args{project}, type => $source->{type}, title => $args{title}, description => $source->{description} );
    my %copy = %{$source};
    delete @copy{qw(ref column type title created_at last_updated linkage comments assignee parent)};
    $clone = $self->record_update( project => $args{project}, ref => $clone->{ref}, author => $args{author}, %copy );
    $self->link_add( project => $args{project}, from => $source->{ref}, type => 'clones', to => $clone->{ref} );
    return $self->record_show( project => $args{project}, ref => $clone->{ref} );
}

# CA20: one indexed reader for both append-only logs. Windows over the
# newest-last storage order, read-by-id with loud misses, entry-level
# where clauses, and metadata that keeps results and uris while
# reporting only the length of the unbounded text. Reads never mutate.
my %LOG_SPEC = (
    gate_passing_log => {
        label => 'gate', text => 'details',
        fields => { map { $_ => 1 } qw(id gate result details author created_at) },
    },
    evidence => {
        label => 'evidence', text => 'summary',
        fields => { map { $_ => 1 } qw(id summary uri author created_at) },
    },
);

sub _log_entry_meta {
    my ( $entry, $spec ) = @_;
    my %meta = %{$entry};
    my $text = delete $meta{ $spec->{text} };
    delete $meta{annotations};
    $meta{ $spec->{text} . '_length' } = length( $text // '' );
    $meta{annotation_count} = scalar @{ $entry->{annotations} // [] };
    return \%meta;
}

sub _indexed_log_read {
    my ( $self, $log_field, %args ) = @_;
    my $spec = $LOG_SPEC{$log_field};
    my $last = delete $args{last};
    my $first = delete $args{first};
    my $id = delete $args{id};
    my $meta_only = delete $args{meta_only};
    my $count_mode = delete $args{count};
    my $where_raw = delete $args{where};
    die "Cannot combine --first with --last\n" if defined $first && defined $last;
    for my $window ( grep { defined } $first, $last ) {
        die "Log windows must be zero or a positive count\n" if $window < 0;
    }
    my $where = _parse_where( $where_raw, $spec->{fields}, "$spec->{label} " );
    my $entries = $self->record_show(%args)->{$log_field};
    if ( defined $id ) {
        my ($entry) = grep { ( $_->{id} // '' ) eq $id } @{$entries};
        die "\u$spec->{label} entry '$id' not found\n" if !$entry;
        return $meta_only ? _log_entry_meta( $entry, $spec ) : $entry;
    }
    $entries = [ grep { _where_matches( $_, $where ) } @{$entries} ] if $where;
    my $total = scalar @{$entries};
    return { count => $total }
      if $count_mode || ( defined $last && $last == 0 ) || ( defined $first && $first == 0 );
    if ( defined $last ) {
        my $window = $last > $total ? $total : $last;
        $entries = $window ? [ @{$entries}[ $total - $window .. $total - 1 ] ] : [];
    }
    elsif ( defined $first ) {
        my $window = $first > $total ? $total : $first;
        $entries = [ @{$entries}[ 0 .. $window - 1 ] ];
    }
    return $meta_only ? [ map { _log_entry_meta( $_, $spec ) } @{$entries} ] : $entries;
}

sub evidence_list {
    my ( $self, %args ) = @_;
    return $self->_indexed_log_read( 'evidence', %args );
}

sub evidence_add {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        $self->_require_person( %args, person => $args{author} );
        my $record = $self->record_show(%args);
        die "Evidence summary is required\n" if !defined $args{summary} || $args{summary} eq '';
        my $attachment = defined $args{file} ? $self->attachment_add(%args) : undef;
        $record = $self->record_show(%args) if $attachment;
        my $stored_attachment = $attachment
          ? { map { $_ => $attachment->{$_} } qw(sha extension original_filename) }
          : undef;
        my $entry = {
            id => sprintf( 'EVD-%03d', @{ $record->{evidence} } + 1 ),
            summary => $args{summary}, uri => $args{uri} // '', author => $args{author},
            attachment => $stored_attachment, annotations => [], created_at => $self->{clock}->(),
        };
        push @{ $record->{evidence} }, $entry;
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

sub evidence_annotate {
    my ( $self, %args ) = @_;
    return $self->_annotate_log( %args, field => 'evidence', label => 'Evidence' );
}

sub gate_list {
    my ( $self, %args ) = @_;
    return $self->_indexed_log_read( 'gate_passing_log', %args );
}

sub gate_add {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        die "Gate name is required\n" if !defined $args{gate} || $args{gate} eq '';
        die "Invalid gate result\n" if ( $args{result} // '' ) !~ /\A(?:pass|fail|blocked)\z/;
        die "Gate details are required\n" if !defined $args{details} || $args{details} eq '';
        $self->_require_person( %args, person => $args{author} );
        my $record = $self->record_show(%args);
        my $entry = {
            id => sprintf( 'GATE-%03d', @{ $record->{gate_passing_log} } + 1 ),
            gate => $args{gate}, result => $args{result}, details => $args{details},
            author => $args{author}, annotations => [], created_at => $self->{clock}->(),
        };
        push @{ $record->{gate_passing_log} }, $entry;
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

sub gate_annotate {
    my ( $self, %args ) = @_;
    return $self->_annotate_log( %args, field => 'gate_passing_log', label => 'Gate' );
}

# What a passed gate takes to record, in one command instead of the three
# calls (gate.add, evidence.add, <type>.update --fix-version) this project's
# own history shows repeated on every release - and forgotten in parts of it
# three times, each caught only by a later refusal. TKT-345.
#
# Column moves are deliberately untouched: walking the gates a card passes
# through is the discipline this project's own push gate enforces, and a
# verb that skipped columns to reach done would be the shortcut TKT-345
# itself warns against, not the fix for it.
#
# Not wrapped in its own project lock - gate_add, evidence_add and
# record_update each take one already, and _with_project_lock is not
# reentrant. Each call below validates everything it needs before writing
# anything, so a call missing what it needs is refused before this one is
# reached, the same discipline create_record's own --parent link follows.
sub release_record {
    my ( $self, %args ) = @_;
    die "Gate name is required\n" if !defined $args{gate} || $args{gate} eq '';
    die "Invalid gate result\n" if ( $args{result} // '' ) !~ /\A(?:pass|fail|blocked)\z/;
    die "Gate details are required\n" if !defined $args{details} || $args{details} eq '';
    die "Evidence is required\n" if !defined $args{evidence} || $args{evidence} eq '';
    die "Fix version is required\n" if !defined $args{fix_version} || $args{fix_version} eq '';

    # Passed on individually rather than spread wholesale. record_update
    # already reads a raw evidence key of its own - a whole-array
    # replacement used for repair and import - and this command's
    # --evidence means the summary of one new entry, not that. Spreading
    # %args into record_update let the two collide silently: the summary
    # string landed where the evidence array belongs, corrupting it.
    my %identify = (
        project => $args{project}, start => $args{start},
        ref => $args{ref}, type => $args{type}, author => $args{author},
    );
    my $gate = $self->gate_add( %identify,
        gate => $args{gate}, result => $args{result}, details => $args{details} );
    my $evidence = $self->evidence_add( %identify, summary => $args{evidence} );
    my $record = $self->record_update( %identify, fix_version => $args{fix_version} );
    return { gate => $gate, evidence => $evidence, record => $record };
}

sub checklist_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{checklist};
}

sub checklist_add {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        die "Checklist item is required\n" if !defined $args{item} || $args{item} eq '';
        die "Checklist status is required\n" if !defined $args{status} || $args{status} eq '';
        my $record = $self->record_show(%args);
        my $number = @{ $record->{checklist} } + 1;
        my $now = $self->{clock}->();
        my $entry = {
            id => sprintf( 'CHK-%03d', $number ), item => $args{item}, status => $args{status},
            created_at => $now, last_updated => $now,
        };
        push @{ $record->{checklist} }, $entry;

        # A column's move-in population writes exactly the same call a
        # person typing this command by hand would, and the generic per-
        # write journal entry every checklist change already gets cannot
        # tell the two apart. --source marks this one, alongside the
        # generic entry rather than instead of it, so a reader can filter
        # for what the move mechanism did automatically. TKT-438.
        $self->_journal_record(
            ref => $record->{ref}, op => $args{source},
            entries => [ { field => 'checklist', item => $entry->{item}, after => $entry->{status} } ],
        ) if defined $args{source} && $args{source} ne '';
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

sub checklist_update {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    die "Checklist item or status is required\n" if !defined $args{item} && !defined $args{status};
    die "Checklist item is required\n" if defined $args{item} && $args{item} eq '';
    die "Checklist status is required\n" if defined $args{status} && $args{status} eq '';
    my $proof_entries = $self->_proof_entries_for(%args);

    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show(%args);
        my ($entry) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $record->{checklist} };
        die "Checklist entry '$args{id}' not found\n" if !$entry;
        $entry->{item} = $args{item} if defined $args{item};
        $entry->{status} = $args{status} if defined $args{status};
        $entry->{last_updated} = $self->{clock}->();
        $entry->{proof} = $proof_entries if $proof_entries;
        $self->_log_proof_gate( $record, 'checklist', $entry, $proof_entries ) if $proof_entries;

        # Same distinction as checklist_add, for the backward-move reset:
        # marked here so a reader can tell the move mechanism reset an item
        # apart from a person or agent ticking it by hand. TKT-438.
        $self->_journal_record(
            ref => $record->{ref}, op => $args{source},
            entries => [ { field => 'checklist', item => $entry->{item}, after => $entry->{status} } ],
        ) if defined $args{source} && $args{source} ne '';
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

# A required item was never meant to share a card's checklist - the owner
# described it, before and after this session started, as its own list,
# organized by the column each item applies to, with an agent free to remove
# a column's own item from one card (required_exempt) or add a new one that
# ALSO gates that card's move-out, distinct from a plain checklist.add's
# non-gating extra. TKT-445.
sub required_item_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{required_items};
}

sub required_item_add {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        die "Required item is required\n" if !defined $args{item} || $args{item} eq '';
        die "Required item status is required\n" if !defined $args{status} || $args{status} eq '';
        my $record = $self->record_show(%args);

        # Every record written before TKT-445 shipped has no required_items
        # key in its stored JSON at all - create_record only ever set it
        # going forward, and nothing backfilled it onto what already
        # existed. Coerced here rather than assumed, the same way
        # required_item_list already tolerates the raw (possibly undef) key.
        $record->{required_items} //= [];
        my $number = @{ $record->{required_items} } + 1;
        my $now = $self->{clock}->();
        my $entry = {
            id => sprintf( 'REQ-%03d', $number ),
            column => $args{column} // $record->{column},
            item => $args{item}, status => $args{status},
            created_at => $now, last_updated => $now,
        };
        push @{ $record->{required_items} }, $entry;

        # Same distinction checklist_add's own --source draws (TKT-438): the
        # move-in and creation-time mechanisms write exactly the call an
        # agent typing required-action.add by hand would, and the generic
        # per-write journal entry cannot tell them apart on its own.
        $self->_journal_record(
            ref => $record->{ref}, op => $args{source},
            entries => [ { field => 'required_items', item => $entry->{item}, after => $entry->{status} } ],
        ) if defined $args{source} && $args{source} ne '';
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

sub required_item_update {
    my ( $self, %args ) = @_;
    local $self->{_journal_author} = $self->_require_author(%args);
    die "Required item or status is required\n" if !defined $args{item} && !defined $args{status};
    die "Required item is required\n" if defined $args{item} && $args{item} eq '';
    die "Required item status is required\n" if defined $args{status} && $args{status} eq '';
    my $proof_entries = $self->_proof_entries_for(%args);

    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $record = $self->record_show(%args);

        # Same pre-3.03 legacy-record case required_item_add guards against.
        $record->{required_items} //= [];
        my ($entry) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $record->{required_items} };
        die "Required item '$args{id}' not found\n" if !$entry;
        $entry->{item} = $args{item} if defined $args{item};
        $entry->{status} = $args{status} if defined $args{status};
        $entry->{last_updated} = $self->{clock}->();
        $entry->{proof} = $proof_entries if $proof_entries;
        $self->_log_proof_gate( $record, 'required-action', $entry, $proof_entries ) if $proof_entries;
        $self->_journal_record(
            ref => $record->{ref}, op => $args{source},
            entries => [ { field => 'required_items', item => $entry->{item}, after => $entry->{status} } ],
        ) if defined $args{source} && $args{source} ne '';
        $self->_replace_record( %args, record => $record );
        return $entry;
    } );
}

# A claim of "done" that nobody can check is not evidence, the way a card
# that "says what it should" is not proof of what happened - so marking
# either kind of item done now costs the same thing evidence has always
# cost on this board: at least one --command/--proof pair, naming what was
# run and what it produced. MEASURED on ZSD-246: 9 checklist items created
# and marked Done within a 5-second window, a narrative written after the
# work supposedly finished. Every other status change is unaffected,
# including the move mechanism's own backward reset to pending - the claim
# being gated is specifically "this is done", not every edit. TKT-453.
#
# Resolved before the project lock is taken, because a long --proof is
# stored as an attachment via attachment_add_content, which takes its own
# lock, and _with_project_lock is not reentrant - the same composition
# release_record already uses to call gate_add, evidence_add and
# record_update in sequence without nesting.
sub _proof_entries_for {
    my ( $self, %args ) = @_;
    return undef if !defined $args{status} || lc( $args{status} ) ne 'done';
    my @commands = @{ $args{command} // [] };
    my @proofs   = @{ $args{proof}   // [] };
    die "Marking done requires at least one --command/--proof pair\n" if !@commands || !@proofs;
    die "Every --command needs a matching --proof, and every --proof a --command "
      . "(got " . scalar(@commands) . " command(s), " . scalar(@proofs) . " proof(s))\n"
      if @commands != @proofs;

    my @entries;
    for my $i ( 0 .. $#commands ) {
        my ( $command, $proof ) = ( $commands[$i], $proofs[$i] );
        if ( length($proof) > 2000 ) {
            my $attachment = $self->attachment_add_content(
                %args, filename => 'proof.txt', content => $proof,
            );
            push @entries, {
                command => $command,
                attachment => { sha => $attachment->{sha}, extension => $attachment->{extension} },
            };
        }
        else {
            push @entries, { command => $command, proof => $proof };
        }
    }
    return \@entries;
}

# What proved an item done, written where it survives independently of the
# item - a required item can be renamed or removed, but what proved it done
# stays in the record the board already keeps for exactly this.
sub _log_proof_gate {
    my ( $self, $record, $gate, $entry, $proof_entries ) = @_;
    my @details = map {
        my $what = exists $_->{attachment}
          ? "attachment $_->{attachment}{sha}.$_->{attachment}{extension}"
          : "\"$_->{proof}\"";
        "$_->{command} -> $what";
    } @{$proof_entries};
    push @{ $record->{gate_passing_log} }, {
        id => sprintf( 'GATE-%03d', @{ $record->{gate_passing_log} } + 1 ),
        gate => $gate, result => 'pass',
        details => "Marked \"$entry->{item}\" done: " . join( '; ', @details ),
        author => undef, annotations => [], created_at => $self->{clock}->(),
    };
    return;
}

sub search {
    my ( $self, %args ) = @_;
    my $count_mode = delete $args{count};
    my $refs_mode = delete $args{refs_only};
    my @fields = defined $args{fields} ? @{ $args{fields} }
      : defined $args{field} ? ( $args{field} ) : ();
    my $hits;
    if (@fields) {
        my @scoped;
        my %filters = %args;
        delete @filters{qw(text field fields)};
        for my $record ( @{ $self->record_list(%filters) } ) {
            for my $field (@fields) {
                next if !exists $record->{$field};
                push @scoped, map {
                    { ref => $record->{ref}, type => $record->{type}, column => $record->{column}, %{$_} }
                } $self->_field_hits( $record->{$field}, $field, $args{text} );
            }
        }
        $hits = \@scoped;
    }
    else {
        $hits = $self->record_list(%args);
    }
    return { count => scalar @{$hits} } if $count_mode;
    if ($refs_mode) {
        my %seen;
        return [ grep { !$seen{$_}++ } map { $_->{ref} } @{$hits} ];
    }
    return { hits => $hits, count => scalar @{$hits} };
}

# What a card says, in one place. The index and the live read must not be able
# to disagree about this: two copies of the definition drift, and the drift is
# invisible until somebody cannot find a card they know exists.
#
# Questions are searchable too - their text, their answers and their references
# - so quoting Q-007 finds the card it lives on without anybody remembering
# which one that was.
# What a search can reach. The card, rather than the front of it.
#
# This was the ref, the title, the description and the questions. A project
# searched for a figure, found nothing, and published that it appeared nowhere
# on a card - and it had been in that card's gate records the whole time. Their
# words: an absence proven by an instrument that cannot see two thirds of the
# record is not an absence.
#
# It saw rather less than a third. The problem statement, the key details, what
# a solution needs, the acceptance criteria, the test steps, the deliverables,
# the scope, the comments, the gates and the evidence were all out of reach -
# which on a board following the rules Tira ships with is nearly everything a
# card says, because those rules are what put the substance in those fields.
#
# The gates and the evidence matter most on a finished card: they are
# append-only observations, so they hold what was measured rather than what was
# believed at planning, which is exactly when somebody comes looking.
sub _search_haystack {
    my ($record) = @_;
    my @text = grep { defined } $record->{ref}, $record->{title}, $record->{description},
      $record->{problem_or_feature}, $record->{solution_needed}, $record->{source},
      $record->{sandbox}, $record->{fix_version};

    push @text, grep { defined } @{ $record->{$_} // [] }
      for qw(key_details deliverables acceptance_criteria test_steps bdd atdd
      labels affects_versions);

    push @text, grep { defined } @{ $record->{scope}{included} // [] },
      @{ $record->{scope}{excluded} // [] };

    push @text, map { grep { defined } ( $_->{id} // '' ), ( $_->{text} // '' ),
          ( $_->{answer} ? $_->{answer}{text} // '' : '' ) }
      @{ $record->{questions} // [] };

    push @text, map { grep { defined } $_->{id}, $_->{body} } @{ $record->{comments} // [] };
    push @text, map { grep { defined } $_->{id}, $_->{gate}, $_->{details}, $_->{result} }
      @{ $record->{gate_passing_log} // [] };
    push @text, map { grep { defined } $_->{id}, $_->{summary}, $_->{uri} }
      @{ $record->{evidence} // [] };
    push @text, map { grep { defined } $_->{id}, $_->{item} } @{ $record->{checklist} // [] };
    push @text, map { grep { defined } $_->{id}, $_->{item}, $_->{column} } @{ $record->{required_items} // [] };
    push @text, map { grep { defined } $_->{said}, $_->{heard} } @{ $record->{conversation} // [] };
    push @text, map { grep { defined } $_->{original_filename} } @{ $record->{attachments} // [] };

    return join ' ', @text;
}

# The filesystem is the database. An index is a second copy of the truth, and
# the moment a read believes the copy every guarantee built on that premise is
# gone - so the copy is keyed by the content hash of the file it describes. A
# row can never describe anything but the exact bytes on disk, because a
# changed file has a different hash and simply misses. There is no such thing
# as a stale row to detect, and nothing to fall back from.
sub _search_index_path {
    my ( $self, $root ) = @_;
    my $path = File::Spec->catfile( $root, '.tira', 'search.db' );
    ($path) = $path =~ /\A(.*)\z/s;
    return $path;
}

sub _search_index_dbh {
    my ( $self, $root, %opt ) = @_;
    my $path = $self->_search_index_path($root);

    # A project that never asked for an index pays nothing for it, and does not
    # need SQLite installed at all.
    return undef if !$opt{create} && !-e $path;
    return undef if !_sqlite_available();
    my $dbh = eval {
        my $handle = DBI->connect(
            "dbi:SQLite:dbname=$path", '', '',
            { RaiseError => 1, PrintError => 0, AutoCommit => 1 },
        );
        $handle->do( 'CREATE TABLE IF NOT EXISTS record_text ('
              . 'hash TEXT PRIMARY KEY, ref TEXT NOT NULL, haystack TEXT NOT NULL)' );
        $handle;
    };

    # Rubbish where a database was. Answering wrongly would be worse than
    # failing, and failing would be worse than reading the files - so it reads
    # the files, which is what it did before any of this existed.
    return $dbh;
}

sub _search_index_read {
    my ( $self, $root ) = @_;
    my $dbh = $self->_search_index_dbh($root) or return undef;
    my $rows = eval { $dbh->selectall_arrayref('SELECT hash, haystack FROM record_text') }
      or return undef;
    return { map { $_->[0] => $_->[1] } @{$rows} };
}

# One row per card, replaced rather than added to, so the table cannot grow a
# row for every version a card has ever had.
sub _search_index_write {
    my ( $self, $dbh, $ref, $content, $record ) = @_;
    $dbh->do( 'DELETE FROM record_text WHERE ref = ?', undef, $ref );
    $dbh->do( 'INSERT INTO record_text (hash, ref, haystack) VALUES (?, ?, ?)',
        undef, sha256_hex($content), $ref, _search_haystack($record) );
    return 1;
}

sub search_index {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $dbh = $self->_search_index_dbh( $root, create => 1 )
          or die "A search index needs SQLite. Install DBD::SQLite (for example: "
          . "cpanm DBD::SQLite) and run this again.\n";
        my $indexed = 0;

        # Rebuilt from the files, always. Nothing is in here that did not come
        # from them, so throwing it away costs only the time to read them again.
        $dbh->do('DELETE FROM record_text');
        for my $type (qw(sow epic ticket)) {
            my $board = File::Spec->catdir( $root, '.tira', $type );
            next if !-d $board;
            find( { no_chdir => 1, wanted => sub {
                return if !-f $File::Find::name || basename($File::Find::name) !~ /\.json\z/;
                my $path = $self->_canonical_path( $File::Find::name, 'record file' );
                my $content = $self->_slurp($path);
                my $record = $self->_json_from_content($content);
                $self->_search_index_write( $dbh, $record->{ref}, $content, $record );
                $indexed++;
            } }, $board );
        }
        return { indexed => $indexed, path => $self->_search_index_path($root) };
    } );
}

sub _annotate_log {
    my ( $self, %args ) = @_;
    die "$args{label} annotation note is required\n" if !defined $args{note} || $args{note} eq '';
    $self->_require_person( %args, person => $args{author} ) if defined $args{author};
    my $record = $self->record_show(%args);
    my ($entry) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $record->{ $args{field} } };
    die "$args{label} entry '$args{id}' not found\n" if !$entry;
    my $annotation = { note => $args{note}, author => $args{author}, created_at => $self->{clock}->() };
    push @{ $entry->{annotations} }, $annotation;
    $self->_replace_record( %args, record => $record );
    return $annotation;
}

sub _field_hits {
    my ( $self, $value, $path, $text ) = @_;
    my @hits;
    if ( !ref($value) ) {
        push @hits, { field => $path, value => $value }
          if defined $value && index( lc $value, lc( $text // '' ) ) >= 0;
    }
    elsif ( ref($value) eq 'ARRAY' ) {
        for my $index ( 0 .. $#{$value} ) {
            push @hits, $self->_field_hits( $value->[$index], "$path.$index", $text );
        }
    }
    elsif ( ref($value) eq 'HASH' ) {
        for my $key ( sort keys %{$value} ) {
            push @hits, $self->_field_hits( $value->{$key}, "$path.$key", $text );
        }
    }
    return @hits;
}

sub _replace_value {
    my ( $self, $value, $regex, $replacement ) = @_;
    my $changed = 0;
    if ( !ref($value) && defined $value ) {
        my $copy = $value;
        $changed = ( $copy =~ s/$regex/$replacement/g );
        $_[1] = $copy if $changed;
    }
    elsif ( ref($value) eq 'ARRAY' ) {
        $changed += $self->_replace_value( $value->[$_], $regex, $replacement ) for 0 .. $#{$value};
    }
    elsif ( ref($value) eq 'HASH' ) {
        $changed += $self->_replace_value( $value->{$_}, $regex, $replacement ) for keys %{$value};
    }
    return $changed;
}

sub bulk_import {
    my ( $self, %args ) = @_;
    my $changes = $args{changes};
    die "Import changes must be a JSON object\n" if ref($changes) ne 'HASH';
    my $root = $self->discover_project(%args);
    my %allowed = map { $_ => 1 } qw(
      title description key_details problem_or_feature solution_needed deliverables scope source
      acceptance_criteria test_steps bdd atdd assignee reporter labels due_date start_date
      sdlc_gate lifecycle priority fix_version affects_versions comments checklist
    );
    return $self->_with_project_lock( $root, sub {
        my ( @updates, @diffs );
        for my $ref ( sort keys %{$changes} ) {
            die "Import change for '$ref' must be a JSON object\n" if ref( $changes->{$ref} ) ne 'HASH';
            my ( $path, $record ) = $self->_record_data( project => $root, ref => $ref );
            for my $field ( sort keys %{ $changes->{$ref} } ) {
                die "Import field '$field' is not mutable\n" if !$allowed{$field};
                my $after = $changes->{$ref}{$field};
                my $before = $record->{$field};
                die "Import field '$field' has incompatible value type\n"
                  if defined $before && defined $after && ref($before) ne ref($after);
                my $encoder = json_object()->canonical->allow_nonref;
                next if $encoder->encode($before) eq $encoder->encode($after);
                push @diffs, { ref => $ref, field => $field, before => $before, after => $after };
                $record->{$field} = $after;
            }
            if ( grep { $_->{ref} eq $ref } @diffs ) {
                $record->{last_updated} = $self->{clock}->();
                push @updates, [ $path, $record ];
            }
        }
        $self->_write_json_transaction( \@updates ) if @updates && !$args{dry_run};
        my %changed = map { $_->{ref} => 1 } @diffs;
        return {
            dry_run => $args{dry_run} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
            changed_records => scalar keys %changed, changes => \@diffs,
            requested_changes => $changes,
        };
    } );
}

sub replace_records {
    my ( $self, %args ) = @_;
    die "Replacement pattern is required\n" if !defined $args{pattern} || $args{pattern} eq '';
    die "Replacement text is required\n" if !defined $args{with};
    my $regex = eval { qr/$args{pattern}/ };
    die "Invalid replacement pattern: $@" if !$regex;
    my %mutable = map { $_ => 1 } qw(
      title description key_details problem_or_feature solution_needed deliverables scope source
      acceptance_criteria test_steps bdd atdd labels sdlc_gate lifecycle fix_version
      affects_versions comments checklist
    );
    my @selected = defined $args{fields} ? @{ $args{fields} }
      : defined $args{field} ? ( $args{field} ) : ();
    for my $field (@selected) {
        die "Replace field '$field' is not mutable\n" if !$mutable{$field};
    }
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( @updates, @diffs );
        for my $summary ( @{ $self->record_list( project => $root, defined $args{type} ? ( type => $args{type} ) : () ) } ) {
            my ( $path, $record ) = $self->_record_data( project => $root, ref => $summary->{ref} );
            my @fields = @selected ? @selected : sort keys %mutable;
            for my $field (@fields) {
                next if !exists $record->{$field};
                my $cloner = json_object()->canonical->allow_nonref;
                my $before = $cloner->decode( $cloner->encode( $record->{$field} ) );
                next if !$self->_replace_value( $record->{$field}, $regex, $args{with} );
                push @diffs, { ref => $record->{ref}, field => $field, before => $before, after => $record->{$field} };
            }
            if ( grep { $_->{ref} eq $record->{ref} } @diffs ) {
                $record->{last_updated} = $self->{clock}->();
                push @updates, [ $path, $record ];
            }
        }
        $self->_write_json_transaction( \@updates ) if @updates && !$args{dry_run};
        my %changed = map { $_->{ref} => 1 } @diffs;
        return { dry_run => $args{dry_run} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false,
          changed_records => scalar keys %changed, changes => \@diffs };
    } );
}

# Yellow means somebody is waiting, in either direction: a question nobody has
# answered waits on the owner, and an answer nobody has read and marked waits on
# the agent. A discarded question settles nothing further - it was set aside.
# The exemption is about who holds the card, so it turns on answers alone: a
# question nobody has answered is waiting on the owner. Whether the agent has
# since marked the answer is its own business, and waiting for that would let an
# agent dodge reminders forever by never marking anything.
sub _card_blocked {
    my ($record) = @_;
    for my $question ( @{ $record->{questions} // [] } ) {
        next if $question->{discarded_at};
        return 1 if !$question->{answer};
    }
    return 0;
}

# When the block clears, the clock starts again from the answer rather than the
# move: otherwise answering after three days makes the card instantly overdue
# and blames the agent for the delay.
sub _card_unblocked_at {
    my ($record) = @_;
    my $latest;
    for my $question ( @{ $record->{questions} // [] } ) {
        next if $question->{discarded_at};
        my $answer = $question->{answer} or return undef;

        # An answer always carries answered_at, so there is nothing to guard.
        my $at = $answer->{updated_at} // $answer->{answered_at};
        $latest = $at if !defined $latest || $at gt $latest;
    }
    return $latest;
}

# Two colours, two directions, and never both at once. Yellow is the owner's:
# a question nobody has answered. Orange is the agent's: everything answered and
# something still unjudged. A card that is one is never the other, so the board
# says whose move it is rather than only that somebody is waiting.
sub _card_to_review {
    my ($record) = @_;
    my $unjudged = 0;
    for my $question ( @{ $record->{questions} // [] } ) {
        next if $question->{discarded_at};
        my $answer = $question->{answer} or return 0;
        $unjudged = 1 if !defined $answer->{mark};
    }
    return $unjudged;
}

# The same question two callers ask: the board asks it to choose a colour, the
# collector asks it to decide whether to chase. One rule, so they cannot drift
# into disagreeing about whose move it is.
sub _card_waiting { return _card_blocked(@_) }

sub dashboard {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my %dashboard;
    $dashboard{_column_order} = {};
    for my $type ( ( $args{type} // 'all' ) eq 'all' ? qw(sow epic ticket) : ( $args{type} ) ) {
        my @columns = grep { $_->{name} ne 'discard' || $args{include_discard} }
          @{ $self->column_list( project => $root, type => $type ) };
        my %by_column = map { $_->{name} => [] } @columns;
        for my $column (@columns) {
            my $dir = File::Spec->catdir( $root, '.tira', $type, $column->{name} );
            opendir my $dh, $dir or die "Cannot read dashboard column '$column->{name}': $!\n";
            my @cards;
            for my $filename ( readdir $dh ) {
                next if $filename !~ /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12})\.json\z/;
                my $ref = $1;
                my $path = File::Spec->catfile( $dir, $filename );
                next if !-f $path;
                my @stat = stat $path;
                die "Cannot stat dashboard card '$ref'\n" if !@stat;
                # Reading a card is what tells us whether anybody is waiting on
                # it, so the flag is set wherever the file is being opened
                # anyway. The ref-only path stays as cheap as it was.
                my $card;
                if ( $args{summary} ) {
                    $card = { ref => $ref };
                    if ( $args{with_title} || $args{with_questions} ) {
                        my $record = $self->_read_json($path);
                        $card->{title} = $record->{title} if $args{with_title};
                        $card->{waiting} = _card_waiting($record);
                        $card->{to_review} = _card_to_review($record);
                    }
                }
                else {
                    my $record = $self->_read_json($path);
                    $card = { %{$record}, column => $column->{name},
                        waiting => _card_waiting($record), to_review => _card_to_review($record) };
                }
                $card->{_mtime} = $stat[9];
                push @cards, $card;
            }
            closedir $dh;
            @cards = sort { $b->{_mtime} <=> $a->{_mtime} || $a->{ref} cmp $b->{ref} } @cards;
            if ( !$args{include_mtime} ) {
                delete $_->{_mtime} for @cards;
            }
            $by_column{ $column->{name} } = \@cards;
        }
        for my $column (@columns) {
            push @{ $dashboard{_column_order}{$type} }, $column->{name};
            $dashboard{$type}{ $column->{name} } = $by_column{ $column->{name} };
        }
    }
    return \%dashboard;
}

sub _project_data {
    my ( $self, $root ) = @_;
    my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
    my $data = $self->_load_yaml($path);
    for my $person ( @{ $data->{people} } ) {
        $person->{active} = Cpanel::JSON::XS::true if !exists $person->{active};
    }
    return ( $path, $data );
}

sub _set_person_active {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($person) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if !$person;
        $person->{active} = $args{active};
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return _person_for_return($person);
    } );
}

# A password that can be read back out of the project config is not a password,
# so only a salted, iterated digest is ever written. The iteration count is
# stored beside the hash rather than assumed, so raising it later does not
# invalidate everyone's existing password.
our $PASSWORD_ALGORITHM = 'pbkdf2-hmac-sha256';
our $PASSWORD_ITERATIONS = 210_000;

sub _password_derive {
    my ( $password, $salt, $iterations ) = @_;
    my $bytes = utf8::is_utf8($password) ? encode_utf8($password) : $password;
    my $block = Digest::SHA::hmac_sha256( pack( 'H*', $salt ) . pack( 'N', 1 ), $bytes );
    my $result = $block;
    for ( 2 .. $iterations ) {
        $block = Digest::SHA::hmac_sha256( $block, $bytes );
        $result ^= $block;
    }
    return unpack 'H*', $result;
}

# Comparing with eq would answer faster the sooner the two differ, which over
# enough attempts tells an attacker how much of a guess was right. This looks
# at every byte whatever happens.
sub _secret_equals {
    my ( $left, $right ) = @_;
    return 0 if length($left) != length($right);
    my $difference = 0;
    $difference |= ord( substr $left, $_, 1 ) ^ ord( substr $right, $_, 1 )
      for 0 .. length($left) - 1;
    return $difference == 0;
}

# Named rather than hard-coded so the Windows path below can be exercised on a
# machine that does have /dev/urandom. A fallback nobody has ever run is a
# fallback nobody knows works.
our $URANDOM = '/dev/urandom';

sub _random_hex {
    my ($bytes) = @_;
    if ( open my $fh, '<:raw', $URANDOM ) {
        my $buffer = '';
        my $read = read $fh, $buffer, $bytes;
        close $fh;
        return unpack 'H*', $buffer if ( $read // 0 ) == $bytes;
    }

    # Windows has no /dev/urandom. Stirring several unrelated sources through
    # SHA-512 is weaker than the kernel pool and is documented as such, but it
    # beats returning something predictable.
    my $anchor = [];
    my $pool = join '|', $$, time, "$anchor", map { rand } 1 .. 32;
    return substr Digest::SHA::sha512_hex($pool), 0, $bytes * 2;
}

# His rule: a person whose name says "bot" is a machine, and machines drive the
# board through the command line, not through a browser session. The id is
# checked as well as the display name so renaming one does not open a door.
sub _person_is_bot {
    my ($person) = @_;
    return 1 if ( $person->{id} // '' ) =~ /bot/i;
    return 1 if ( $person->{name} // '' ) =~ /bot/i;
    return 0;
}

sub _login_person {
    my ( $self, $root, $id ) = @_;
    my ( undef, $data ) = $self->_project_data($root);
    my ($person) = grep { $_->{id} eq ( $id // '' ) } @{ $data->{people} };
    return $person;
}

sub login_register {
    my ( $self, %args ) = @_;
    my $id = $args{id} // '';
    die "Password is required\n" if !defined $args{password} || $args{password} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($person) = grep { $_->{id} eq $id } @{ $data->{people} };
        die "Person '$id' not found\n" if !$person;
        die "Person '$id' is not active\n" if !$person->{active};
        die "Person '$id' is a bot and cannot sign in\n" if _person_is_bot($person);
        die "Person '$id' already has a password\n" if ref $person->{password} eq 'HASH';
        my $salt = _random_hex(16);
        $person->{password} = {
            algorithm => $PASSWORD_ALGORITHM,
            iterations => $PASSWORD_ITERATIONS,
            salt => $salt,
            hash => _password_derive( $args{password}, $salt, $PASSWORD_ITERATIONS ),
        };
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

sub login_verify {
    my ( $self, %args ) = @_;
    return 0 if !defined $args{password} || $args{password} eq '';
    my $root = $self->discover_project(%args);
    my $person = $self->_login_person( $root, $args{id} );
    return 0 if !$person;
    return 0 if !$person->{active};

    # Checked before the stored hash is consulted, so a hash written into the
    # file by hand is not a way around the rule.
    return 0 if _person_is_bot($person);
    my $stored = $person->{password};
    return 0 if ref $stored ne 'HASH';
    return 0 if ( $stored->{algorithm} // '' ) ne $PASSWORD_ALGORITHM;
    return 0 if !defined $stored->{salt} || !defined $stored->{hash};
    my $candidate = _password_derive( $args{password}, $stored->{salt}, $stored->{iterations} );
    return _secret_equals( $candidate, $stored->{hash} );
}

# Ten minutes of doing nothing, counted from the last deliberate action rather
# than from the login. The board polls itself in the background, so that poll
# reads a session without touching this clock - otherwise a tab left open
# overnight would keep itself signed in for ever.
our $SESSION_IDLE_SECONDS = 600;

# A board left open on a phone all day is no use if it is honest for ten
# minutes and silent afterwards. The expiry stays the default - a tab left open
# overnight should not keep itself signed in on a shared machine - so this is a
# decision the person running the board takes, with --no-session-expire, and it
# is theirs rather than the board's.
our $SESSION_NEVER_EXPIRES = 0;

sub _sessions_dir {
    my ( $self, $root ) = @_;
    return File::Spec->catdir( $root, '.tira', 'sessions' );
}

# The token names the file it lives in, so anything that is not plain lowercase
# hex is refused before it is ever joined to a path. A token is generated, never
# typed, so there is nothing to be gained by being generous about the shape.
sub _valid_session_token {
    my ($token) = @_;
    return undef if !defined $token;
    return $token =~ /\A([0-9a-f]{32,128})\z/ ? $1 : undef;
}

sub _session_path {
    my ( $self, $root, $token ) = @_;
    my $safe = _valid_session_token($token) or return undef;
    return File::Spec->catfile( $self->_sessions_dir($root), "$safe.json" );
}

sub _session_read {
    my ( $self, $path ) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    my $session = eval { json_decode($content) };
    return ref $session eq 'HASH' ? $session : undef;
}

sub _session_expired {
    my ( $self, $session ) = @_;
    my $seen = eval { _epoch_of_datetime( $session->{last_seen_at}, 'Session last seen' ) };

    # A session whose stamp cannot be read is treated as dead. Guessing in the
    # other direction would turn a corrupt file into a session that never ends.
    return 1 if !defined $seen;
    my $now = eval { _epoch_of_datetime( $self->{clock}->(), 'Clock' ) };
    return 1 if !defined $now;

    # Asked after the unreadable-stamp checks above, not before them: a
    # session whose stamp cannot be read is still dead, because never expiring
    # is a decision about idleness and not a reason to trust a corrupt file.
    return 0 if $SESSION_NEVER_EXPIRES;
    return $now - $seen > $SESSION_IDLE_SECONDS ? 1 : 0;
}

sub _session_write {
    my ( $self, $path, $session ) = @_;
    $self->_atomic_write( $path, json_object()->canonical->encode($session) );
    chmod 0600, $path;
    return 1;
}

sub _session_sweep {
    my ( $self, $root ) = @_;
    my $dir = $self->_sessions_dir($root);
    opendir my $dh, $dir or return [];
    my @names = readdir $dh;
    closedir $dh;
    my @alive;
    for my $name (@names) {
        my ($safe) = $name =~ /\A([0-9a-f]{32,128}\.json)\z/ or next;
        my $path = File::Spec->catfile( $dir, $safe );
        my $session = $self->_session_read($path);
        if ( !$session || $self->_session_expired($session) ) {
            unlink $path;
            next;
        }
        push @alive, { %{$session}, token => ( $safe =~ s/\.json\z//r ) };
    }
    return [ sort { $a->{started_at} cmp $b->{started_at} || $a->{token} cmp $b->{token} } @alive ];
}

sub login_start {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    die "Sign-in failed\n" if !$self->login_verify(%args);
    my $dir = $self->_sessions_dir($root);
    make_path($dir) if !-d $dir;
    my $now = $self->{clock}->();

    # 24 bytes, so a token cannot be arrived at by trying, and derived from the
    # random source alone - never from the person or the clock, either of which
    # an outsider could work out.
    my $token = _random_hex(24);
    $self->_session_write(
        $self->_session_path( $root, $token ),
        { person => $args{id}, started_at => $now, last_seen_at => $now },
    );
    return $token;
}

sub _session_load {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_session_path( $root, $args{token} ) or return ();
    my $session = $self->_session_read($path) or return ();
    if ( $self->_session_expired($session) ) {
        unlink $path;
        return ();
    }
    return ( $root, $path, $session );
}

sub session_peek {
    my ( $self, %args ) = @_;
    my ( undef, undef, $session ) = $self->_session_load(%args);
    return $session;
}

sub session_resume {
    my ( $self, %args ) = @_;
    my ( undef, $path, $session ) = $self->_session_load(%args);
    return undef if !$session;
    $session->{last_seen_at} = $self->{clock}->();
    $self->_session_write( $path, $session );
    return $session;
}

sub session_end {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $path = $self->_session_path( $root, $args{token} );
    die "Session not found\n" if !defined $path || !-f $path;
    unlink $path or die "Cannot end session: $!\n";
    return { ended => 1 };
}

sub session_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_session_sweep($root);
}

# The one page a stranger can reach. It names nobody, because the login page is
# the only thing outside the gate and a list of people is half of a login. The
# markup is self-contained - no font, stylesheet or script from anywhere else -
# and deliberately pure ASCII, because this renderer has no `use utf8` and a
# literal glyph here has produced mojibake before.
sub login_page_html {
    my ( $self, %args ) = @_;
    my $name = $self->_html_escape( $args{name} // 'Tira' );
    my $style = <<'CSS';
:root{color-scheme:light dark;--ink:#0f172a;--dim:#64748b;--line:#cbd5e1;--card:#fff;--bg:#eef2f7;--accent:#2563eb}
@media(prefers-color-scheme:dark){:root{--ink:#e2e8f0;--dim:#94a3b8;--line:#334155;--card:#111827;--bg:#0b1220;--accent:#60a5fa}}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--ink);
font:15px/1.5 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.card{width:min(92vw,25rem);background:var(--card);border:1px solid var(--line);border-radius:14px;
padding:2rem 1.75rem;box-shadow:0 10px 30px rgba(15,23,42,.10)}
h1{margin:0;font-size:1.35rem;letter-spacing:-.01em}
.sub{margin:.35rem 0 1.5rem;color:var(--dim);font-size:.875rem}
label{display:block;font-size:.8rem;font-weight:600;color:var(--dim);margin:0 0 .35rem}
input{width:100%;padding:.6rem .7rem;margin:0 0 1rem;border:1px solid var(--line);border-radius:8px;
background:transparent;color:inherit;font:inherit}
input:focus{outline:2px solid var(--accent);outline-offset:1px;border-color:transparent}
button{width:100%;padding:.65rem;border:0;border-radius:8px;background:var(--accent);color:#fff;
font:600 15px/1 inherit;cursor:pointer}
button:disabled{opacity:.6;cursor:default}
.note{margin:1rem 0 0;font-size:.8rem;color:var(--dim)}
.msg{margin:0 0 1rem;padding:.6rem .7rem;border-radius:8px;font-size:.85rem;display:none}
.msg.bad{display:block;background:rgba(220,38,38,.12);color:#dc2626}
.msg.good{display:block;background:rgba(22,163,74,.12);color:#16a34a}
CSS
    my $script = <<'JS';
var form=document.getElementById("f"),msg=document.getElementById("m"),go=document.getElementById("go");
form.addEventListener("submit",function(e){
  e.preventDefault();
  msg.className="msg";go.disabled=true;
  fetch("/login",{method:"POST",headers:{"Content-Type":"application/json"},
    body:JSON.stringify({id:form.id_.value,password:form.pw.value})})
  .then(function(r){return r.json().then(function(b){return{ok:r.ok,body:b}})})
  .then(function(r){
    if(!r.ok){
      // One message for a wrong password and for somebody who is not here at
      // all, so this page cannot be used to find out who is on the project.
      msg.textContent="That did not match. Check the name and try again.";
      msg.className="msg bad";go.disabled=false;form.pw.value="";form.pw.focus();return;
    }
    msg.textContent=r.body.claimed?"Password set. Signing you in.":"Signing you in.";
    msg.className="msg good";
    location.href="/";
  })
  .catch(function(){msg.textContent="The board did not answer. Try again.";msg.className="msg bad";go.disabled=false});
});
form.id_.focus();
JS
    return join '',
      '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
      "<title>Sign in \x{2014} $name</title>",
      "<style>$style</style>",
      '<div class="card">',
      "<h1>$name</h1>",
      '<p class="sub">Sign in to use this board.</p>',
      '<p class="msg" id="m"></p>',
      '<form id="f" autocomplete="on">',
      '<label for="id_">Name</label>',
      '<input id="id_" name="id_" autocomplete="username" autocapitalize="off" spellcheck="false" required>',
      '<label for="pw">Password</label>',
      '<input id="pw" name="pw" type="password" autocomplete="current-password" required>',
      '<button id="go" type="submit">Sign in</button>',
      '</form>',
      '<p class="note">First time here? Whatever you type becomes your password.</p>',
      '</div>',
      "<script>$script</script>";
}

# What police can be told to watch for. Every rule here traces to something
# that actually went wrong rather than something imagined, and each names the
# parameters it cannot work without - so a policy police could not follow is
# refused when it is set rather than discovered later, when it has been reading
# as cover the whole time.
my %POLICY_RULES = (
    'card-full-details'         => { needs => ['enter'] },
    'card-metrics'              => { needs => [ 'enter', 'require' ] },
    'card-duration'             => { needs => [ 'column', 'age' ] },
    'card-stalled'              => { needs => ['before'] },
    'checklist-idle'            => { needs => [ 'column', 'age' ] },

    # No age, deliberately, and this is what separates it from the rule
    # above. checklist-idle asks how long a checklist has stood still and
    # needs a grace or it is nagging. This one asks whether the card MOVED
    # without the checklist moving, which is an event rather than a
    # duration: the moment it has happened, waiting longer tells nobody
    # anything they did not already know.
    'checklist-unmoved'         => { needs => [] },
    'orphan-card'               => { needs => [] },

    # An upgrade traced to its end rather than announced and forgotten.
    #
    # The upgrade notice asks the agent to read what changed, learn what is new
    # and close the policy gaps, and then it is gone: no reference, no
    # escalation, nothing that notices whether any of it happened. He tested it
    # by hand across four agents - "They all answered partially" - and then
    # watched this one ignore it four times in a single day while a rule sat
    # undeclared on the board the whole time.
    #
    # What is traced is the part that can be observed. Whether the changes were
    # read cannot be checked, and a rule that settles on a promise is worse than
    # no rule; a rule this board has neither declared nor declined can be, and
    # it is the gap the reading is for. TKT-276.
    'rules-undeclared'          => { needs => [] },

    # A card nothing has happened to, wherever it is sitting. His question:
    # is there a policy for a card that has been in the same column with no
    # changes for too long. Partly - card-duration measures dwell in a named
    # column and says nothing about whether anybody is working it, and
    # checklist-idle watches the checklist alone. board-still asks the right
    # question of a whole board and there was no per-card version.
    #
    # No column to name: it is about the card being silent, not about where it
    # is silent, so one policy covers every column work happens in. TKT-278.
    'card-still'                => { needs => ['age'] },

    # No age. He asked for a reminder that the card changed under the agent,
    # and a change is not more or less true an hour later - waiting would only
    # decide how long the agent works from a card somebody has already
    # rewritten. TKT-307.
    'card-changed-by-owner'     => {},
    'question-unanswered'       => { needs => ['age'] },
    # An optional second age, counted from when the answer was read. Having
    # read it removes the excuse for not judging it, and the record already
    # knows the difference - so this is one rule sharpened rather than a
    # second that means almost the same thing, which is how a bridge
    # becomes noise.
    'answer-unjudged'           => { needs => ['age'] },

    # No age, deliberately. Every other rule about a question chases
    # neglect and needs a grace, or it is nagging. This one announces that
    # an answer arrived, and the agent could not have acted sooner because
    # it did not know - so a grace here would only be a delay.
    'answer-waiting'            => { needs => [], forbids => ['age'] },

    # No column, because the board already says which ones are work. Every
    # board is created with backlog and discard marked protected, and a
    # policy naming one column would stop covering the board the moment
    # somebody added another - silently, which is the shape of every check
    # this project has found not firing.
    'card-unassigned'           => { needs => [], forbids => [ 'column', 'enter' ] },

    # Arriving somewhere without having done the steps before it. Declared
    # rather than inferred from the column order: a documentation-only card has
    # no red test to write, and a rule that assumed the whole sequence would
    # report every legitimate shortcut, which is the noise that kills a channel.
    'column-skipped'            => { needs => [ 'enter', 'require' ] },

    # No age. A comment that has not been folded in is not neglect that
    # ripens - the card is already carrying two stories - and the quiet
    # ladder is what keeps it from being said twice a minute.
    'conversation-not-folded'   => { needs => [], forbids => ['age'] },
    'answer-ok-not-folded'      => { needs => ['age'] },
    'answer-not-ok-no-followup' => { needs => ['age'] },
    'wip-limit'                 => { needs => ['column'] },
    'commit-without-card'       => { needs => [] },
    'work-without-card'         => { needs => ['age'] },
    'unpushed-work'             => { needs => ['age'] },
    'board-unbacked'            => { needs => ['age'] },
    'gate-missing'              => { needs => ['column'] },
    'discard-unexplained'       => { needs => [] },
    'leftover-process'          => { needs => [ 'pattern', 'age' ] },
    'leftover-container'        => { needs => [ 'pattern', 'age' ] },
    'card-sandbox-missing'      => { needs => [ 'enter', 'sandbox' ] },
    'card-unlinked'             => { needs => ['require_link'] },
    'parent-ahead-of-children'  => { needs => [] },

    # No age. Being passed over does not ripen into being passed over more, and
    # the quiet ladder already stops the same line arriving twice a minute. An
    # age is refused when the policy is declared rather than ignored at run
    # time, because a policy police cannot follow reads as cover.
    'priority-skipped'          => { needs => [], forbids => ['age'] },

    # No age either. A question that left the board with its card is not
    # waiting for anything, so there is nothing for a grace period to be a
    # grace for.
    'discard-with-open-questions' => { needs => [], forbids => ['age'] },

    # The period is required and there is deliberately no default. An hour of
    # quiet is nothing on a research board and a working day is a crisis on a
    # delivery one, so a guess here would fire wrongly on somebody's board
    # rather than usefully on anybody's.
    'board-still'               => { needs => ['age'] },

    # What board-still cannot see. It reads the newest last_updated across every
    # card, so a board that receives reports from other projects always looks
    # busy - and the thing that stops is not the board, it is the agent.
    #
    # Measured on this board: the agent's last action was 01:31 and its next was
    # 07:27, five hours fifty-six minutes, while board-still was declared at 4h
    # and never fired. Seven cards arrived from elsewhere during the window and
    # each arrival refreshed the stamp board-still reads.
    #
    # The age is required for the same reason board-still's is, and this rule
    # does not replace it: a board with no other project filing into it is well
    # served by board-still, and one that is worked by a person rather than an
    # agent has no agent to measure.
    'agent-still'               => { needs => ['age'] },

    # How long an agent may go without looking is a decision about how it works
    # rather than something Tira can guess: a minute is absurd on a board polled
    # hourly and a day is useless on one being worked now.
    'bridge-unread'             => { needs => ['age'] },

    # No age and no column of its own. It is about the columns OTHER policies
    # name, so scoping it to one would be asking it to watch a single place for
    # a fault that is only visible across the whole board.
    'column-unwatched'          => { needs => [], forbids => [ 'age', 'column' ] },
);

# What each of these is about, for the refusal that explains why a card scope
# cannot narrow it. Written as the phrase the message needs rather than as a
# bare flag, so the reader is told what the rule watches instead.
# wip-limit is deliberately NOT here. It counts a column, so a card scope reads
# at first like something it could never use - but the cascade uses exactly that
# to give one card a different limit from the rest of its column, and
# t/87-policy-cascade.t has asserted it for as long as the cascade has existed.
# Refusing it broke a working, tested feature, and the assertion claiming it was
# meaningless was written without reading the test that already disproved it.
my %WHOLE_BOARD_RULE = (
    'board-still'   => 'the whole board',
    'agent-still'   => 'the whole board',
    'bridge-unread' => 'the whole board',

    # It is about which columns the OTHER policies name. A card cannot narrow
    # that any more than it can narrow the board being still.
    'column-unwatched' => 'the whole board',

    # A gap in what this board has considered, which no card can narrow.
    'rules-undeclared' => 'the whole board',
);

# Police speaks in exactly three ways: down the bridge the agent tails, in the
# owner's own terminal, and quietly into the log for a rule being tuned.
my %POLICY_ACTIONS = map { $_ => 1 } qw(bridge-reminder print-reminder log-only);

# Parameters a policy may carry, beyond the rule and the action. Every name here
# is read somewhere, and t/148 fails if one is not: this list has been wrong in
# both directions - base sat here unread for the life of the file, and read_age
# was accepted, validated and dropped for being missing from it.
my @POLICY_FIELDS = qw(enter before column age read_age max pattern message require sandbox require_link link_to);


# Where a policy was declared. A policy with none of these is the project's;
# each one named makes it narrower, and the narrowest wins.
my @POLICY_SCOPE = qw(type on_column ref);

# A rule may say which column it means, or which role.
my @POLICY_ROLE_FIELDS = qw(enter_role before_role column_role);

# What counts as the SAME policy for the purpose of "already declared" -
# everything that says WHAT is watched, as opposed to age, read_age, max and
# message, which say how strictly. Named once so _policy_already_declared and
# policy_duplicates cannot drift into two different definitions of a
# collision - a scope field added to one and not the other would let a board
# be told it has none while policy_add would in fact refuse to declare a
# matching pair. TKT-352.
my @POLICY_SCOPE_FIELDS = (
    @POLICY_SCOPE, @POLICY_ROLE_FIELDS,
    qw(column enter before pattern require sandbox require_link link_to)
);

# What police reports without being asked to.
#
# These are not policies. A policy says what a board wants watched; these two
# say whether watching was possible at all, so there is nothing to configure and
# nothing to scope, and a board that has declared nothing still hears them -
# silence about a corrupt record is the fault the whole of this subsystem exists
# to prevent.
#
# They must still be ANSWERABLE, which is what they were not. Every other rule
# can be put down for a while with a reason or refused outright; these were
# raised straight into the pass and so were outside the catalogue that both of
# those commands validate against. A board with permanently damaged files had a
# violation it could not stop by any means.
my %DIAGNOSTIC_RULES = map { $_ => 1 } qw(card-damaged card-unreadable);

sub policy_rules { return [ sort keys %POLICY_RULES ] }

# Everything a board can answer: what it may declare, and what it may only put
# down or refuse. Offered in the refusal when a rule is not recognised, because
# a list that omits half the answerable rules teaches the reader they do not
# exist.
sub answerable_rules { return [ sort ( keys %POLICY_RULES, keys %DIAGNOSTIC_RULES ) ] }
sub policy_actions { return [ sort keys %POLICY_ACTIONS ] }

sub _valid_duration {
    my ($value) = @_;
    return undef if !defined $value;
    return $value =~ /\A(\d+)([smhd])\z/ ? $value : undef;
}

# A policy already covering the same rule on the same scope.
#
# Scope, not settings: two policies differing only in their limit or their
# action are two answers to one question, and police takes the stricter without
# saying which. Identical declarations are handled before this is asked, and are
# a no-op. A method rather than inline so a test can replace it. TKT-339.
sub _policy_already_declared {
    my ( $self, $policies, $wanted ) = @_;
    for my $existing ( @{ $policies || [] } ) {
        next if ( $existing->{rule} // '' ) ne ( $wanted->{rule} // '' );
        # Scope is WHAT a policy covers; the settings are HOW STRICTLY. The
        # split does not follow the field lists - column, pattern and the rest
        # of what a policy watches live in @POLICY_FIELDS beside age and max.
        #
        # Both halves of this were got wrong on the way here and both were
        # caught by measuring rather than reasoning. Comparing only
        # @POLICY_SCOPE called two policies on different COLUMNS the same
        # scope. Adding the column but not the pattern would have refused two
        # of the three leftover-process policies on this project's own board,
        # which watch prove-the-gate, 'until timeout' and projects-skills - three
        # different things, declared board-wide, every one of them meant.
        #
        # So: what is watched is scope, and only age, read_age, max and message
        # are settings. Two policies differing in those alone are two answers
        # to one question, which is the fault reported. TKT-339.
        my $same_scope = 1;
        for my $field (@POLICY_SCOPE_FIELDS) {
            $same_scope = 0
              if ( $existing->{$field} // '' ) ne ( $wanted->{$field} // '' );
        }
        return $existing if $same_scope;
    }
    return;
}

# A stable key for "what this policy watches" - two policies produce the same
# key exactly when _policy_already_declared would call them the same scope.
# Grouping by this key finds every collision in one pass over what is stored,
# rather than comparing every policy against every other.
sub _policy_scope_key {
    my ($policy) = @_;
    return join( "\x1e", $policy->{rule} // '',
        map { $policy->{$_} // '' } @POLICY_SCOPE_FIELDS );
}

# Which currently-declared policies collide on rule and scope - two answers to
# the same question, sitting in the store together.
#
# policy_add has refused a NEW collision since 2.54 (TKT-339), which does
# nothing for a board that already carried one before the refusal existed: a
# board upgrading into the fix kept every pair it already had, and nothing
# said so. One project found four such pairs by grouping policy.list's JSON
# by hand after reading the changelog for what "same scope" meant - not a
# route most boards will take. TKT-352.
#
# Detection only. Which member of a pair to keep is a judgment call - the
# reporter's own workaround made it by hand, favouring the one with a written
# message - and guessing it here risks discarding a policy somebody actually
# wanted.
sub policy_duplicates {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);

    my %by_key;
    for my $policy ( @{ $self->policy_list( project => $root ) } ) {
        push @{ $by_key{ _policy_scope_key($policy) } }, $policy;
    }

    my @groups;
    for my $key ( sort keys %by_key ) {
        my $group = $by_key{$key};
        next if @{$group} < 2;
        push @groups,
          {
            rule     => $group->[0]{rule},
            policies => [ map { { id => $_->{id}, message => $_->{message}, age => $_->{age} } }
                  @{$group} ],
          };
    }
    return \@groups;
}

sub policy_add {
    my ( $self, %args ) = @_;
    my $rule = $args{rule} // '';
    my $spec = $POLICY_RULES{$rule}
      or die "Unknown policy rule '$rule'. Rules: " . join( ', ', @{ policy_rules() } ) . "\n";

    my $action = $args{action} // '';
    die "Policy action is required. Actions: " . join( ', ', @{ policy_actions() } ) . "\n"
      if $action eq '';
    die "Unknown policy action '$action'. Actions: " . join( ', ', @{ policy_actions() } ) . "\n"
      if !$POLICY_ACTIONS{$action};

    # The number a work-in-progress limit counts against belongs to the
    # project, because no one number is right for both a single agent and a
    # chain of six. A policy may still carry its own, which is narrower and
    # wins - but a policy with neither, on a project with neither, is refused
    # here rather than discovered when it silently never fires.
    if ( $rule eq 'wip-limit' && !defined $args{max} ) {
        my $stored = eval { $self->project_limit(%args) };
        die "Policy rule 'wip-limit' needs --max, or a limit set on the project"
          . " with tira.project.limit --max N\n"
          if !defined $stored;
    }

    # A scope a rule can never act on is refused rather than stored.
    #
    # wip-limit counts a column; board-still and bridge-unread are about the
    # whole board. A card scope cannot narrow any of them, so accepting one
    # leaves a policy nobody can make sense of: it reads as narrow, behaves as
    # wide, and the natural conclusion is that the rule is broken.
    if ( defined $args{ref} && $args{ref} ne '' && $WHOLE_BOARD_RULE{$rule} ) {
        die "Policy rule '$rule' is about $WHOLE_BOARD_RULE{$rule} rather than one "
          . "card, so a card scope could never narrow it. Declare it without --ref\n";
    }

    # The same argument as the rule below, and the same failure it prevents.
    # card-changed-by-owner settles by comparing the newest author against the
    # agent the board NAMES; a board that names none falls through to the card's
    # assignee alone, which the comment on the rule itself already calls
    # vacuous - it counts the board's own work as an outside edit and the
    # finding can never settle.
    #
    # Reported four times by two projects. I discarded two of those reports
    # after testing on a scratch board that declared an agent, because this
    # board declares one - and every new board declares none. It was reported
    # twice more, the second time escalating on two of their cards.
    # TKT-376, TKT-381.
    if ( $rule eq 'card-changed-by-owner' ) {
        my $named = $self->_agent_declared_for( $self->discover_project(%args) );
        die "Policy rule 'card-changed-by-owner' settles by asking whether a change was "
          . "the agent's own, and this project has not said which agent works it. "
          . "Name it with tira.project.update --agent ID\n"
          if !defined $named || $named eq '';
    }

    # The one rule that reads the machine needs to know which machine. Refused
    # here rather than discovered later as a violation nobody can clear, which
    # is their third suggestion and this project's own rule about missing
    # arguments: a policy police cannot follow is worse than no policy, because
    # it reads as cover.
    if ( $rule eq 'card-sandbox-missing' ) {
        my $root = $self->discover_project(%args);
        my $declared = eval { $self->project_show( project => $root )->{repo} };
        die "Policy rule 'card-sandbox-missing' reads branches and work trees from a "
          . "git repository, and this project is not in one. Say where the work lives "
          . "with tira.project.update --repo PATH\n"
          if !( defined $declared && $declared ne '' && _looks_like_repository($declared) )
          && !_looks_like_repository($root);
    }

    for my $needed ( @{ $spec->{needs} } ) {
        next if defined $args{"${needed}_role"} && $args{"${needed}_role"} ne '';
        # Named the way it is typed. A message telling somebody to pass a
        # flag that does not exist is worse than no message: they try it,
        # it fails differently, and they stop trusting what the tool says.
        ( my $flag = $needed ) =~ tr/_/-/;
        die "Policy rule '$rule' needs --$flag\n"
          if !defined $args{$needed} || $args{$needed} eq '';
    }
    # What a rule cannot accept is refused where it is set, like everything a
    # rule cannot work without. A grace on a rule whose whole point is that
    # there is none would be accepted, ignored, and believed - which is the
    # shape of a setting that does nothing and looks like it does.
    for my $refused ( @{ $spec->{forbids} // [] } ) {
        ( my $flag = $refused ) =~ tr/_/-/;
        die "Policy rule '$rule' takes no --$flag: it reports the moment there is "
          . "something to say, and a grace would only delay it\n"
          if defined $args{$refused} && $args{$refused} ne '';
    }

    if ( defined $args{age} ) {
        _valid_duration( $args{age} )
          or die "An age must be a duration like 10m, 2h or 30s, not '$args{age}'\n";
    }
    if ( defined $args{read_age} ) {
        _valid_duration( $args{read_age} )
          or die "A read age must be a duration like 10m, 2h or 30s, not '$args{read_age}'\n";
        die "A read age shortens the age it sits inside, so it cannot be longer than it\n"
          if defined $args{age}
          && ( _duration_seconds( $args{read_age} ) // 0 )
          > ( _duration_seconds( $args{age} ) // 0 );
    }
    if ( defined $args{max} ) {
        $args{max} =~ /\A\d+\z/ or die "A limit must be a whole number, not '$args{max}'\n";
    }

    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my $policies = $data->{policies} ||= [];

        my %policy = ( rule => $rule, action => $action );
        for my $field ( @POLICY_SCOPE, @POLICY_FIELDS, @POLICY_ROLE_FIELDS ) {
            $policy{$field} = "$args{$field}" if defined $args{$field} && $args{$field} ne '';
        }

        # The same rule watching a different column is a different intention,
        # not a duplicate. Only an identical declaration is the same policy,
        # and declaring one twice is a no-op rather than an error.
        for my $existing ( @{$policies} ) {
            my $same = 1;
            for my $field ( 'rule', 'action', @POLICY_SCOPE, @POLICY_FIELDS, @POLICY_ROLE_FIELDS ) {
                $same = 0 if ( $existing->{$field} // '' ) ne ( $policy{$field} // '' );
            }
            return $existing if $same;
        }

        # But the same rule on the same scope with DIFFERENT settings is two
        # policies for one question, and the stricter one wins silently.
        #
        # Reported by zen-framework, and the cost was not the duplicate. They
        # declared wip-limit at 5, the owner changed his mind, they ran
        # policy.add again with --max 9, and it returned success while leaving
        # the first active. The stricter one kept firing, so they told the
        # owner his decision was applied and the finding escalated to URGENT
        # minutes later. They found it by going back to ask why, not because
        # anything reported a conflict.
        #
        # Refused rather than replaced, which is this codebase's answer to the
        # same shape elsewhere: a command that quietly does something other
        # than what the caller meant is worse than one that stops and names
        # what is in the way. Replacing would also discard a policy somebody
        # may have wanted, without saying so. TKT-339.
        if ( my $clash = $self->_policy_already_declared( $policies, \%policy ) ) {
            die "This rule is already declared for that scope, as $clash->{id}.\n"
              . "  Change it:  tira.policy.remove --id $clash->{id}"
              . "  then declare it again\n"
              . "  See it:     tira.policy.list\n";
        }

        # Numbers are never reused, so a reference in an old log always means
        # the policy it meant when it was written.
        my $next = ( $data->{policy_counter} // 0 ) + 1;
        $data->{policy_counter} = $next;
        $policy{id} = sprintf 'POL-%03d', $next;
        $policy{declared_at} = $self->{clock}->();

        push @{$policies}, \%policy;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return \%policy;
    } );
}

sub policy_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( undef, $data ) = $self->_project_data($root);
    return $data->{policies} // [];
}

# Considered, and deliberately not used.
#
# The prompt lists every rule a project has not declared, because a rule nobody
# declared is silent in exactly the way a rule being obeyed is - and it prints
# on every run, because remembering which run was the first is not the owner's
# job. What it could not tell was "nobody has looked at this" from "somebody
# looked and said no", so on a board that has made those decisions it asked an
# answered question for ever. A channel that repeats itself is one everybody
# learns to read past, and this is the channel that exists to be read.
#
# The reason is required. A decision with none recorded is indistinguishable
# from having skipped the question, which is the thing this whole subsystem
# exists to remove - and it would turn this into a way of silencing the prompt,
# which is exactly what it must not become.
sub policy_decline {
    my ( $self, %args ) = @_;
    my $rule = $args{rule} // '';
    die "Unknown policy rule '$rule'. Rules: " . join( ', ', @{ answerable_rules() } ) . "\n"
      if !$POLICY_RULES{$rule} && !$DIAGNOSTIC_RULES{$rule};

    my $reason = $args{reason} // '';
    $reason =~ s/\A\s+|\s+\z//g;
    die "Declining a rule needs a reason - without one it is not a decision, "
      . "it is a way of silencing the prompt\n"
      if $reason eq '';

    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);

        # A rule the project is using cannot also be declined. It was stored
        # and then hidden: policy_declined filters out any rule that is
        # declared, which is right and is how declaring a rule clears the note
        # saying it was declined - so the caller was told a decision had been
        # recorded and could not read it back in any sense they could check.
        # Reported from another project, reproduced three times. A
        # contradiction is refused or resolved; answering with a decision
        # nobody can read is the third thing and the only one nobody can act
        # on. TKT-244.
        die "'$rule' is declared on this project, so it cannot also be "
          . "declined. Remove the policy first if that is what you meant.\n"
          if grep { ( $_->{rule} // '' ) eq $rule } @{ $data->{policies} // [] };

        my @kept = grep { ( $_->{rule} // '' ) ne $rule } @{ $data->{declined_policies} // [] };
        my $entry = {
            rule => $rule, reason => $reason,
            declined_at => $self->{clock}->(),
            ( defined $args{author} ? ( author => $args{author} ) : () ),
        };
        $data->{declined_policies} = [ @kept, $entry ];
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $entry;
    } );
}

sub policy_declined {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( undef, $data ) = $self->_project_data($root);
    my %declared = map { ( $_->{rule} // '' ) => 1 } @{ $data->{policies} // [] };

    # A rule that has since been declared is no longer declined, whatever the
    # file says. A project that changed its mind would otherwise carry a record
    # saying it had decided the opposite, which is worse than carrying nothing.
    return [ grep { !$declared{ $_->{rule} // '' } } @{ $data->{declined_policies} // [] } ];
}

sub policy_remove {
    my ( $self, %args ) = @_;
    my $id = $args{id} // '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my @kept = grep { $_->{id} ne $id } @{ $data->{policies} // [] };
        die "Policy '$id' not found\n" if @kept == @{ $data->{policies} // [] };
        $data->{policies} = \@kept;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return { removed => $id };
    } );
}

# Working out what is wrong without touching anything. Every rule here is a
# pure function of the board and the clock: nothing is written, no shell is
# invoked, and the six rules that need git or the process table are handed in
# as facts by police rather than looked up here.
my %POLICY_DURATION_SECONDS = ( s => 1, m => 60, h => 3600, d => 86_400 );

sub _duration_seconds {
    my ($value) = @_;
    my ( $count, $unit ) = ( $value // '' ) =~ /\A(\d+)([smhd])\z/ or return undef;
    return $count * $POLICY_DURATION_SECONDS{$unit};
}

sub _policy_older_than {
    my ( $self, $stamp, $age ) = @_;
    my $seconds = _duration_seconds($age) // return 0;
    my $then = eval { _epoch_of_datetime( $stamp, 'Stamp' ) } // return 0;
    my $now = eval { _epoch_of_datetime( $self->{clock}->(), 'Clock' ) } // return 0;
    return $now - $then > $seconds;
}

# The fields a card must carry to be real work rather than a title. Kept here
# rather than in a rule so one answer serves the engine, the reminder surface
# and anything else that later asks the same question.
my @POLICY_DETAIL_FIELDS = qw(
  description problem_or_feature solution_needed key_details deliverables
  acceptance_criteria test_steps bdd atdd priority
);

# What a complete card is, decided here and nowhere else.
#
# There were two definitions and they disagreed in both directions at once.
# Police read the list above and the scope beneath it; the push gate kept its
# own, which wanted a checklist and a parent and did not want a description.
# The same card at the same moment was complete to one and incomplete to the
# other: police said "missing: description" and the gate said "missing:
# parent", and neither mentioned the other's field. The bridge nagged about a
# field the gate calls finished, and three pushes died on a field police had
# never once mentioned. TKT-241.
#
# The gate is a separate program in another language, so it cannot share this
# variable. It asks for it instead, which is the only arrangement where the two
# cannot drift apart again.
my @CARD_REQUIRED = ( @POLICY_DETAIL_FIELDS, qw(scope_in scope_out checklist parent) );

sub card_required { return [@CARD_REQUIRED] }

# A parent is not asked of a SOW, which is the top of the hierarchy, nor of a
# card that says it stands alone - the gate already made both of those
# exceptions and they are part of the definition rather than of one reader.
sub card_missing {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $record = $self->record_show( %args, project => $root );
    return $self->_card_missing_from($record);
}

sub _card_missing_from {
    my ( $self, $record ) = @_;
    my @missing = @{ _policy_missing_detail($record) };

    my $checklist = $record->{checklist} // [];
    push @missing, 'checklist' if !@{$checklist};

    my $kind = $record->{type} // 'ticket';
    my %labels = map { lc $_ => 1 } @{ $record->{labels} // [] };
    push @missing, 'parent'
      if $kind ne 'sow' && !$record->{parent} && !$labels{standalone};

    return \@missing;
}

sub _policy_missing_detail {
    my ($record) = @_;
    my @missing;
    for my $field (@POLICY_DETAIL_FIELDS) {
        my $value = $record->{$field};
        push @missing, $field
          if ( ref $value eq 'ARRAY' ? !@{$value} : !defined $value || $value eq '' );
    }
    my $scope = $record->{scope} || {};
    push @missing, 'scope_in' if !@{ $scope->{included} // [] };
    push @missing, 'scope_out' if !@{ $scope->{excluded} // [] };
    return \@missing;
}

sub _policy_last_detail_change {
    my ( $self, %args ) = @_;

    # The history journal already records every field write, so asking it when
    # a detail last changed is exact rather than inferred - and it is the only
    # way to tell a card that was updated from one that merely had a comment
    # added, which is the whole point of the folding rules.
    my $history = eval { $self->history_list( %args, ref => $args{ref} ) } || [];
    my %detail = map { $_ => 1 } @POLICY_DETAIL_FIELDS, 'scope', 'description', 'title';
    my $latest;
    for my $entry ( @{$history} ) {
        next if !$detail{ $entry->{field} // '' };
        $latest = $entry->{at} if !defined $latest || ( $entry->{at} // '' ) gt $latest;
    }
    return $latest;
}

sub _policy_questions {
    my ($record) = @_;
    return grep { !$_->{discarded_at} } @{ $record->{questions} // [] };
}

# A policy may say what it wants said, in its own words, with a few things
# filled in. Every parameter is optional and an unknown one is left alone
# rather than blanked, because a message that quietly loses half its text is
# worse than one that shows a placeholder somebody can see and fix.
#
# The option exists whether or not anybody uses it. Without it an agent that
# wants a particular wording simply cannot have one; with it, saying nothing is
# a choice rather than a limit.
my %POLICY_MESSAGE_FIELDS = (
    ref => sub { $_[0] },
    rule => sub { $_[1]{rule} // '' },
    policy => sub { $_[1]{id} // '' },
    detail => sub { $_[2] // '' },
    column => sub { ref $_[3] ? ( $_[3]{column} // '' ) : '' },
    title => sub { ref $_[3] ? ( $_[3]{title} // '' ) : '' },
    assignee => sub { ref $_[3] ? ( $_[3]{assignee} // '' ) : '' },
    reporter => sub { ref $_[3] ? ( $_[3]{reporter} // '' ) : '' },
    age => sub { $_[1]{age} // '' },
    max => sub { $_[1]{max} // '' },
);

sub policy_message_fields { return [ sort keys %POLICY_MESSAGE_FIELDS ] }

# Whether one stamp is later than another. Both are written by Tira in the same
# shape, and a stamp that cannot be read is treated as not later - guessing here
# would announce an answer somebody had already dealt with.
# How long ago, in the shape the ages are written in. "Longer than the limit"
# is not actionable on its own: the reader has to be able to tell a quiet
# afternoon from a board abandoned on Friday, and the limit alone says only
# which side of it they are on.
sub _policy_elapsed {
    my ( $self, $stamp ) = @_;
    my $then = eval { _epoch_of_datetime( $stamp, 'Stamp' ) } // return 'some time';
    my $now = eval { _epoch_of_datetime( $self->{clock}->(), 'Clock' ) } // return 'some time';
    my $gap = $now - $then;
    return $gap . 's' if $gap < 60;
    return int( $gap / 60 ) . 'm' if $gap < 3600;
    return int( $gap / 3600 ) . 'h' if $gap < 86400;
    return int( $gap / 86400 ) . 'd';
}

sub _policy_stamp_after {
    my ( $stamp, $mark ) = @_;
    return 0 if !defined $stamp || !defined $mark;
    my $one = eval { _epoch_of_datetime( $stamp, 'Answer' ) } // return 0;
    my $two = eval { _epoch_of_datetime( $mark, 'Read at' ) } // return 0;
    return $one > $two ? 1 : 0;
}

sub _policy_message {
    my ( $policy, $record, $detail, $ref ) = @_;
    my $message = $policy->{message};
    return undef if !defined $message;
    $message =~ s{\{(\w+)\}}{
        my $field = $POLICY_MESSAGE_FIELDS{$1};
        $field ? $field->( $ref, $policy, $detail, $record ) : "{$1}";
    }ge;
    return $message;
}

# When the card itself was last written to, ignoring the writes that are the
# conversation rather than the card: a comment is not the card being brought up
# to date, and neither is a question or the stamp that every write touches.
# One card's journal, read the way a supervisor has to read it.
#
# A board where one card's history held a single byte of invalid UTF-8 reported
# nothing at all: the decode died inside the rule loop and took every rule on
# the board down with it - 27 policies, 359 cards, two real violations hidden -
# while the pass still answered "watching" with an empty list. A board that
# cannot be read looked exactly like a board with nothing wrong.
#
# So the read is guarded here, once, for every rule that needs a journal. The
# third reader in this file, _policy_last_detail_change, has always guarded its
# own; this is the same decision written where the other two can share it
# instead of drifting from it again.
#
# Undef means "could not read", which is not the same as "nothing recorded" -
# every caller has to tell those apart, because a rule that treats an
# unreadable card as an empty one reports a violation it cannot support.
#
# And the card is named rather than quietly skipped. Skipping is the same fault
# one level down: nobody can act on a card they are not told about.
sub _police_history {
    my ( $self, $root, $ref, $unreadable ) = @_;

    # Cleared first, so what is counted belongs to this read rather than to
    # whatever asked for this card's history earlier in the pass.
    delete $self->{_history_repaired}{$ref};
    my $entries = eval { $self->history_list( project => $root, ref => $ref ) };

    if ( defined $entries ) {

        # Read, and damaged. The card is checked by every rule exactly like any
        # other - that is the point of reading past the byte rather than
        # skipping - and the damage is still said once, because a corrupt record
        # that nothing mentions is the fault this whole thread started with.
        my $count = delete $self->{_history_repaired}{$ref};

        # Which byte, and where, and what to run about it.
        #
        # mt5-ai reported two cards raising this with nothing they could do:
        # the byte is in an old history entry, history is append-only, and the
        # record-level recovery the changelog documents cannot reach it. Their
        # words for why it matters past tidiness - "an unfixable violation sits
        # open for ever and is indistinguishable from one being ignored... a
        # line that cannot be acted on teaches whoever reads the bridge that
        # some lines are not worth acting on."
        #
        # They asked for the entry and the offset so a human can judge whether
        # anything was actually lost, which is the right question to be able to
        # ask of a record: a mangled multiplication sign and a mangled digit in
        # a figure somebody relies on read exactly alike without it. The file is
        # scanned by the same subroutine tira.doctor uses, so the two cannot
        # disagree about where the damage is.
        my $where = '';
        if ( $count && open my $fh, '<:raw', $self->_journal_path( $root, $ref ) ) {
            my $bytes = do { local $/; <$fh> };
            close $fh;
            my $bad = _bad_bytes($bytes);
            $where = ' (' . _bad_byte_detail($bad) . ')' if @{$bad};
        }

        push @{$unreadable}, {
            ref => $ref,
            repaired => $count,
            reason => "its history holds $count "
              . ( $count == 1 ? 'byte that is' : 'bytes that are' )
              . " not valid UTF-8$where, substituted while reading. The card was"
              . ' checked; the file on disk is untouched. Repair it with'
              . ' d2 tira.doctor --repair',
        } if $count && $unreadable && !grep { ( $_->{ref} // '' ) eq $ref } @{$unreadable};

        return $entries;
    }

    my $why = $@ || 'unknown failure';

    # Perl's own "at Tira.pm line 6813, <$fh> line 3" is where the decoder
    # stood, not what is wrong with his card. The owner reads this in his
    # terminal, so what survives is the part he can act on.
    $why =~ s/\s+at\s+\S+\s+line\s+\d+(?:,\s*<[^>]*>\s*line\s*\d+)?\.?\s*\z//;
    $why =~ s/\s+\z//;
    $why =~ s/\.\z//;
    push @{$unreadable}, { ref => $ref, reason => $why }
      if $unreadable && !grep { ( $_->{ref} // '' ) eq $ref } @{$unreadable};
    return undef;
}

sub _last_card_change {
    my ( $self, $root, $ref, $unreadable ) = @_;
    my $entries = $self->_police_history( $root, $ref, $unreadable );
    return ( 0, undef ) if !defined $entries;

    my $latest;
    for my $write ( @{$entries} ) {
        my $field = $write->{field} // '';
        next if $field =~ /\A(?:last_updated|comments|questions)\z/;
        my $at = $write->{at} // next;
        $latest = $at if !defined $latest || $at gt $latest;
    }
    return ( 1, $latest );
}

# Whether a column-scoped card-duration policy already watches the exact
# column a record sits in, for that record specifically.
#
# card-still is board-wide; card-duration is column-scoped. 2.54's duplicate
# refusal (TKT-339) cannot see the two overlapping, because it only refuses a
# SECOND policy on the SAME rule and scope - these are different rules. One
# board declared a column-scoped card-duration at 24h, with a written reason,
# for a column where a long wait is legitimate; card-still's own board-wide 4h
# reported it CRITICAL anyway, because nothing checked whether a more specific
# decision already covered that column. TKT-355.
sub _card_duration_governs {
    my ( $self, $root, $policies, $record, $resolved_for ) = @_;
    for my $candidate ( @{ $policies || [] } ) {
        next if ( $candidate->{rule} // '' ) ne 'card-duration';
        next if !$resolved_for->( $candidate, $record );
        my $watched = $self->_policy_column_for(
            project => $root, policy => $candidate, field => 'column', record => $record );
        return 1 if ( $record->{column} // '' ) eq ( $watched // '' );
    }
    return 0;
}

# Whether a process's command line is the bridge tail - the one process
# bridge-unread's own message tells an agent to keep running, and so the one
# process a leftover-process pattern can never legitimately be about, however
# broadly it was written. A named predicate rather than an inline check, so a
# test can turn it off and watch the original defect return. TKT-379.
sub _is_bridge_tail {
    my ($command) = @_;
    return ( $command // '' ) =~ /\bpolicy\.bridge\b/ ? 1 : 0;
}

sub policy_evaluate {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $policies = $self->policy_list( project => $root );
    return [] if !@{$policies};

    my $all = $self->record_list( project => $root, include_discard => 1 );

    # Discarded work is set aside, not neglected. Holding it to the same
    # standard as live work would teach an agent to read past the whole
    # channel, which is the one failure a warning system cannot survive. The
    # exception is the rule that exists to ask why it was set aside.
    my $records = [ grep { ( $_->{column} // '' ) ne 'discard' } @{$all} ];
    my @violations;

    # Cards whose journal could not be read on this pass. Collected rather than
    # thrown, so one of them cannot end the pass, and handed back rather than
    # swallowed, so it cannot be mistaken for a card with nothing wrong.
    my $unreadable = $args{unreadable} // [];

    # Read once here rather than in the rule, so it is the project in hand
    # rather than whatever a rule happens to be able to resolve.
    my $limit = $self->project_limit( project => $root );

    # What has been put down, read once. A rule quieted for a card must leave
    # the same rule watching every other card, so this is asked per violation
    # rather than per rule - the grain is what makes it worth having.
    my $quieted = $args{store} ? $self->_enforcement_read( $args{store} ) : { rules => {} };

    my $report = sub {
        my ( $policy, $record, $detail, $for ) = @_;
        my $ref = ref $record ? $record->{ref} : ( $record // '' );
        return if $self->_rule_suspended( $quieted, $policy->{rule}, $ref );
        push @violations, {
            rule => $policy->{rule},
            policy => $policy->{id},
            ref => $ref,
            detail => $detail,
            message => _policy_message( $policy, $record, $detail, $ref ),
            action => $policy->{action},

            # Who is meant to act on it. One agent per ticket means a violation
            # belongs to whoever is carrying that card, and a bridge that hands
            # every agent every violation is noise by construction - a channel
            # everybody learns to read past is the one failure a warning system
            # cannot survive.
            #
            # Except where the work is somebody else's whoever holds the card.
            # The four rules about what happens after an answer are the agent's
            # follow-through - reading it, judging it, writing it into the card,
            # asking anything further - and the owner's part ended when he
            # answered. On a board where he held the card he was told to fold in
            # his own answer, and the agent read "for Michael" and skipped it. A
            # violation addressed to the wrong party is not a message in the
            # wrong envelope; it is an instruction the right party never gets.
            assignee => ( $for // ( ref $record ? $record->{assignee} : undef ) ),
        };
    };

    # Each card is judged by the policies that resolved for IT, so an override
    # on one card cannot change what applies to another.
    my %for_record;
    for my $record ( @{$all} ) {
        $for_record{ $record->{ref} } =
          { map { $_->{rule} => $_ } @{ $self->policy_resolve( project => $root, record => $record ) } };
    }
    my $resolved_for = sub {
        my ( $policy, $record ) = @_;
        my $winner = $for_record{ $record->{ref} }{ $policy->{rule} };
        return defined $winner && ( $winner->{id} // '' ) eq ( $policy->{id} // '' ) ? $winner : undef;
    };

    for my $policy ( @{$policies} ) {
        my $rule = $policy->{rule};

        if ( $rule eq 'card-full-details' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                my $enter = $self->_policy_column_for(
                    project => $root, policy => $policy, field => 'enter', record => $record );
                next if ( $record->{column} // '' ) ne ( $enter // '' );
                my $missing = $self->_card_missing_from($record);
                next if !@{$missing};
                $report->( $policy, $record, 'missing: ' . join( ',', @{$missing} ) );
            }
        }
        elsif ( $rule eq 'card-metrics' ) {
            my @wanted = split /\s*,\s*/, $policy->{require} // '';
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                next if ( $record->{column} // '' ) ne ( $policy->{enter} // '' );
                my @missing = grep {
                    my $value = $record->{$_};
                    ref $value eq 'ARRAY' ? !@{$value} : !defined $value || $value eq '';
                } @wanted;
                next if !@missing;
                $report->( $policy, $record, 'missing: ' . join( ',', @missing ) );
            }
        }
        elsif ( $rule eq 'card-duration' ) {
            my %resting;
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                # This rule names its column outright, so it never asked which
                # columns to leave alone - and a board that switches a column
                # off means it for every rule, not only the ones that happened
                # to ask. TKT-287.
                my $kind = $record->{type} // 'ticket';
                $resting{$kind} //= $self->_resting_columns( $root, $kind );
                next if $resting{$kind}{ $record->{column} // '' };

                # By role where one was given, exactly as enter and before are
                # read. The role was storable and documented and no rule
                # resolved it, so a policy declared with --column-role watched
                # a column called nothing. TKT-221.
                my $watched = $self->_policy_column_for(
                    project => $root, policy => $policy, field => 'column', record => $record );
                next if ( $record->{column} // '' ) ne ( $watched // '' );
                my ($since) = $self->_dwell_start( $root, $record->{ref} );
                next if !defined $since;
                next if !$self->_policy_older_than( $since, $policy->{age} );
                $report->( $policy, $record, "in $watched since $since" );
            }
        }
        elsif ( $rule eq 'card-stalled' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                my $checklist = $record->{checklist} // [];
                next if !@{$checklist};

                # Status is documented as free text, and stays that way - only
                # the comparison against "done" is case-insensitive, so a card
                # ticked --status Done or DONE is not silently invisible to
                # the one rule whose job is noticing it finished. TKT-434.
                next if grep { lc( $_->{status} // '' ) ne 'done' } @{$checklist};
                my $before = $self->_policy_column_for(
                    project => $root, policy => $policy, field => 'before', record => $record );
                next if !$self->_policy_before_column( $root, $record, $before );
                $report->( $policy, $record,
                    "every checklist item is done but the card is still in $record->{column}" );
            }
        }
        elsif ( $rule eq 'checklist-idle' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                next if ( $record->{column} // '' ) ne ( $self->_policy_column_for(
                    project => $root, policy => $policy, field => 'column',
                    record => $record ) // '' );
                my $checklist = $record->{checklist} // [];
                next if !@{$checklist};
                my ($latest) = sort { $b cmp $a } map { $_->{last_updated} } @{$checklist};
                next if !$self->_policy_older_than( $latest, $policy->{age} );
                $report->( $policy, $record, "no checklist movement since $latest" );
            }
        }
        elsif ( $rule eq 'checklist-unmoved' ) {

            # The journal is the only account of a move, and column-skipped
            # already reads it the same way.
            my $resting = {};
            my $ordering = {};
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                # Nothing to have left behind.
                my $checklist = $record->{checklist} // [];
                next if !@{$checklist};

                # And nothing outstanding to have left behind. A card whose
                # checklist is finished has nothing to tick, and reporting it
                # would name every card that ever reached done. Case-
                # insensitively, the same as card-stalled: --status Done or
                # DONE is genuinely finished, not silently outstanding. TKT-434.
                next if !grep { lc( $_->{status} // '' ) ne 'done' } @{$checklist};

                my $type = $record->{type} // 'ticket';
                $resting->{$type} //= $self->_resting_columns( $root, $type );
                next if $resting->{$type}{ $record->{column} // '' };

                my $journal = $self->_police_history( $root, $record->{ref}, $unreadable );
                next if !defined $journal;

                # By position in the journal, not by timestamp. The journal is
                # append-only and ordered, and its stamps are only accurate to
                # the second - so a tick and a move made in the same second
                # cannot be told apart by time, and on a fixed clock they never
                # can. Asking which came first is the question anyway.
                #
                # op eq 'move' specifically, not just field eq 'column': a
                # card created directly into a column (TKT-433's birth entry)
                # has not advanced anywhere, and reporting it as though it had
                # would flag a card the moment it is created, before an agent
                # could possibly have ticked anything.
                my @where_moved = grep { ( $journal->[$_]{field} // '' ) eq 'column'
                    && ( $journal->[$_]{op} // '' ) eq 'move' }
                  0 .. $#{$journal};
                next if !@where_moved;
                my $window = @where_moved > 1 ? $where_moved[-2] : -1;
                next if grep {
                    ( $journal->[$_]{field} // '' ) eq 'checklist' && $_ > $window
                } 0 .. $#{$journal};
                my $moved_into = $journal->[ $where_moved[-1] ]{after};

                # Not a card that was sent back. This rule catches a card
                # advancing while nothing was done; a backwards move claims
                # nothing, and the checklist has not advanced precisely because
                # the work is not finished, which is why it went back. Reported
                # from another project on a card that went in-progress, to
                # in-review, and back again - the inverse of the rule's own
                # purpose. The board knows its column order, so which way a
                # move went is answerable without inventing anything. TKT-242.
                my $order = $ordering->{$type}
                  //= $self->_column_positions( $root, $type );
                my $came_from = $journal->[ $where_moved[-1] ]{before};
                next
                  if defined $came_from
                  && defined $order->{$moved_into}
                  && defined $order->{$came_from}
                  && $order->{$moved_into} < $order->{$came_from};

                $report->( $policy, $record,
                    "moved into $moved_into with nothing ticked since"
                      . ( $window >= 0 ? " it entered $journal->[$window]{after}" : ' it was raised' ) );
            }
        }
        elsif ( $rule eq 'card-unlinked' ) {
            # Work that has shipped cannot be linked to a gate it went through
            # before the gate existed, and chasing it teaches an agent to read
            # past the channel. If this board has said which column means done,
            # that column is left alone; if it has not, nothing is skipped,
            # because guessing which column means finished would be worse.
            my $finished = eval {
                $self->column_roles( project => $root, type => 'ticket' )->{done};
            };
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                next if defined $finished && ( $record->{column} // '' ) eq $finished;
                my $wanted = $policy->{require_link};
                my $to = $policy->{link_to};

                # A card cannot be its own dependency, so the card a policy
                # points everything at is never in breach of pointing at
                # itself.
                next if defined $to && $to ne '' && $to eq ( $record->{ref} // '' );
                my @links = @{ $record->{linkage}{links} // [] };
                next if grep {
                    ( $_->{type} // '' ) eq $wanted
                      && ( !defined $to || $to eq '' || ( $_->{ref} // '' ) eq $to )
                } @links;

                # A dependency written only in a description is a dependency
                # nobody can see and nothing can act on.
                $report->( $policy, $record,
                    "no '$wanted' link" . ( defined $to && $to ne '' ? " to $to" : '' )
                      . ' - a dependency that exists only in the words is one nothing can act on' );
            }
        }
        elsif ( $rule eq 'parent-ahead-of-children' ) {

            # A card in done with unticked work is a lie about itself; a parent
            # in done above a live child is the same lie one level up, and in
            # the direction that overstates progress. Every other rule here
            # looks at a card on its own, so nothing was going to see it.
            #
            # Which column means finished is the board's own word for it. A
            # rule hunting for a column called 'done' says nothing at all on a
            # project that calls it something else, and says it silently.
            my %live = map { $_->{ref} => $_ }
              grep { !$self->_policy_settled( $root, $_ ) } @{$records};
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                next if !$self->_policy_settled( $root, $record );
                my @open = sort map { $_->{ref} }
                  grep { ( $_->{parent} // '' ) eq $record->{ref} } values %live;
                next if !@open;
                $report->( $policy, $record,
                    'says it is finished while ' . join( ', ', @open )
                      . ( @open > 1 ? ' are' : ' is' ) . ' still open' );
            }
        }
        elsif ( $rule eq 'orphan-card' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                # Asked rather than decided again. A statement of work sits at
                # the top of the tree and a card labelled standalone is saying
                # somebody meant it to have no parent - both exceptions are
                # part of the definition of a complete card, honoured by the
                # engine, by the push gate and in the command reference, and
                # this rule had never heard of the second one.
                #
                # It cost 84 outstanding violations on this project's own
                # board: every one orphan-card, every one critical, every one
                # seen twelve times, and every one of them a card that had
                # declared it stands alone. A rule reporting the same
                # unactionable thing for ever is worse than no rule, on a
                # channel somebody reads. TKT-269.
                next if !grep { $_ eq 'parent' }
                  @{ $self->_card_missing_from($record) };
                $report->( $policy, $record, 'no parent' );
            }
        }
        elsif ( $rule eq 'question-unanswered' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                for my $question ( _policy_questions($record) ) {
                    next if $question->{answer};
                    next if !$self->_policy_older_than( $question->{asked_at}, $policy->{age} );
                    $report->( $policy, $record,
                        "$question->{id} has been waiting since $question->{asked_at}" );
                }
            }
        }
        elsif ( $rule eq 'conversation-not-folded' ) {

            # His answer, and it needed no new field: the work log already
            # records both halves. A comment later than the newest change to the
            # card means the conversation has outrun what the card says.
            #
            # Any change settles it, including one about something else. He was
            # asked about that and accepted it: the alternative is a marker
            # somebody has to remember to set, and a reminder that can be
            # silenced by forgetting is worse than one an unrelated edit clears.
            # Not on a card whose work has ended. Folding a conversation into
            # the details is how a decision stops living in a comment nobody
            # reads later; on a finished card there is nothing left to lose and
            # nothing anybody will read it in. Reported from another project,
            # where this was the largest group of violations on the board -
            # thirteen cards, every one of them in a column marked terminal.
            # The board says which those are and the engine already asks:
            # checklist-unmoved reads the same thing. TKT-238.
            # Endings, not resting columns. The first version of this asked
            # _resting_columns, which counts protected columns as well - and
            # backlog is protected, so a card waiting to be picked up with a
            # conversation that had outrun it went unreported. That is a
            # finding worth making: the card has not ended, it has not
            # started. Caught by an existing test that builds a board to break
            # every rule and asserts each one fires. TKT-238.
            my $ends = {};
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                my $type = $record->{type} // 'ticket';
                $ends->{$type} //= $self->_ending_columns( $root, $type );
                next if $ends->{$type}{ $record->{column} // '' };

                my @comments = @{ $record->{comments} // [] };
                next if !@comments;

                my ($said) = sort { $b cmp $a }
                  grep { defined } map { $_->{created_at} // $_->{at} } @comments;
                next if !defined $said;

                my ( $readable, $written ) =
                  $self->_last_card_change( $root, $record->{ref}, $unreadable );

                # An unreadable journal is not an unwritten card. Reporting it
                # would be this rule inventing a violation out of a fault of
                # its own, which is the worst of both silences.
                next if !$readable;
                next if defined $written && $written ge $said;

                $report->( $policy, $record,
                    'the newest comment is later than anything written on the card - '
                      . 'fold the conversation into the details' );
            }
        }
        elsif ( $rule eq 'card-unassigned' ) {

            # Neither waiting nor finished, and nobody holding it.
            #
            # The columns Tira owns are marked protected on every board and are
            # asked for rather than named here. Protected is not the same
            # question as "does work happen here", though: it distinguishes the
            # two columns Tira creates, and a board whose work ends in three
            # different columns - finished and waiting for a release, finished
            # and shipping nothing, finished and published - had this fire on
            # nine shipped cards within a minute of being declared.
            #
            # So a board says where work ends and this asks. `done` stays an
            # ending for a board that has said nothing, because no board should
            # change underneath anybody.
            #
            # Read per board rather than from the tickets. An epic finishing
            # somewhere the tickets do not was being judged against the wrong
            # list entirely.
            # Asked rather than worked out again. This built the helper's
            # answer inline, and agreed with it, which is the condition under
            # which nobody notices there are two. TKT-252.
            my %resting = map { $_ => $self->_resting_columns( $root, $_ ) }
              qw(sow epic ticket);
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                my $column = $record->{column} // '';
                next if $column eq '' || $resting{ $record->{type} // 'ticket' }{$column};
                next if defined $record->{assignee} && $record->{assignee} ne '';
                $report->( $policy, $record,
                    "in $column with nobody on it - work in progress needs an assignee" );
            }
        }
        elsif ( $rule eq 'answer-waiting' ) {

            # An answer nobody has read yet. Reading is recorded by reading, so
            # this stops when the agent has actually seen it rather than when
            # somebody says it has - and an answer reworded afterwards is news
            # again, because it is news the agent has not seen.
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                for my $question ( _policy_questions($record) ) {
                    next if ( $question->{status} // '' ) eq 'discarded';
                    my $answer = $question->{answer} or next;

                    # Judged, so certainly seen. Nobody can mark an answer they
                    # have not read, and marking does not record a read - so
                    # without this the rule chases every settled answer a board
                    # has ever had, for ever, which is the nagging the quiet
                    # ladder was built to end. Found the day it was turned on
                    # here: eleven answers, all marked ok, all from days before.
                    next if defined $answer->{mark};

                    my $said = $answer->{updated_at} // $answer->{answered_at};

                    # Read, and not reworded since. An answer amended after the
                    # agent read it is news the agent has not seen, so the
                    # comparison is against when it was last said rather than
                    # against whether it was ever read.
                    next if defined $answer->{read_at}
                      && !_policy_stamp_after( $said, $answer->{read_at} );
                    $report->( $policy, $record,
                        "$question->{id} was answered at $said and nobody has read it",
                        $question->{author} );
                }
            }
        }
        elsif ( $rule eq 'answer-unjudged' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                for my $question ( _policy_questions($record) ) {
                    my $answer = $question->{answer} or next;
                    next if defined $answer->{mark};

                    # Two clocks, and the shorter one only runs once somebody
                    # has looked. An answer nobody has opened waits the age the
                    # board set for noticing; one that has been read has had its
                    # excuse removed, and is chased from the moment it was read.
                    if ( defined $policy->{read_age} && defined $answer->{read_at} ) {
                        next
                          if !$self->_policy_older_than( $answer->{read_at}, $policy->{read_age} );
                        $report->( $policy, $record,
                            "$question->{id} was read at $answer->{read_at} and never marked",
                            $question->{author} );
                        next;
                    }

                    next if !$self->_policy_older_than( $answer->{answered_at}, $policy->{age} );
                    $report->( $policy, $record,
                        "$question->{id} was answered and never marked",
                        $question->{author} );
                }
            }
        }
        elsif ( $rule eq 'answer-ok-not-folded' || $rule eq 'answer-not-ok-no-followup' ) {
            my $wanted = $rule eq 'answer-ok-not-folded' ? 'ok' : 'not-ok';
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                my @questions = _policy_questions($record);
                for my $question (@questions) {
                    my $answer = $question->{answer} or next;
                    next if ( $answer->{mark} // '' ) ne $wanted;
                    my $marked = $answer->{marked_at} // $answer->{answered_at};
                    next if !$self->_policy_older_than( $marked, $policy->{age} );

                    # Whoever asked has to deal with the answer. A question with
                    # nobody named on it falls back to the card, because
                    # addressing it to nobody would be worse.
                    my $asker = $question->{author};

                    if ( $wanted eq 'ok' ) {
                        # A comment is not documentation. Only a detail field
                        # changing after the mark counts as folding it in.
                        my $changed = $self->_policy_last_detail_change(
                            project => $root, ref => $record->{ref} );

                        # At or after the mark, not strictly after it.
                        #
                        # Stamps here are second-resolution, so a fold written
                        # inside the same second as the mark cannot be strictly
                        # later - and an agent that marks and folds in one
                        # script, which is the correct thing to do and exactly
                        # what this rule asks for, lands in the same second
                        # whenever the board is quick. mt5-ai isolated it by
                        # comparing three cards their script had handled
                        # identically: marked 10:40:20 written 10:40:21 silent,
                        # marked 10:42:33 written 10:42:34 silent, marked
                        # 10:44:32 written 10:44:32 reported. Only the equal
                        # pair fired.
                        #
                        # So the rule was telling the agents that behave best
                        # that they had not - and telling them unfalsifiably,
                        # since the message says nothing was written down while
                        # the thing is written down. The obvious response is to
                        # write it again, which changes nothing until a second
                        # happens to elapse.
                        #
                        # What this gives up: a detail written in the same
                        # second BEFORE the mark now reads as a fold. That
                        # requires an agent to have just written a detail field,
                        # which is close to folding anyway - and the alternative
                        # is accusing the diligent.
                        next if defined $changed && $changed ge $marked;
                        # Where, not just that. A project wrote the whole
                        # decision into a comment, was told again and escalated
                        # to a warning, then wrote the same words into a field
                        # and it settled - and nothing had said which was
                        # wanted. A comment is where a conversation happens; a
                        # field is what an agent reads back off the card, which
                        # is what folding an answer in means.
                        $report->( $policy, $record,
                            "$question->{id} was marked ok and nothing was folded into the card"
                              . ' - write the decision into a card field (a comment is not folding it in)',
                            $asker );
                    }
                    else {
                        # A cross on its own settles nothing.
                        next if grep { ( $_->{asked_at} // '' ) gt $marked } @questions;
                        $report->( $policy, $record,
                            "$question->{id} was marked not-ok and nothing further was asked",
                            $asker );
                    }
                }
            }
        }
        elsif ( $rule eq 'column-skipped' ) {
            my @required = grep { length } map { s/\A\s+|\s+\z//gr }
              split /,/, ( $policy->{require} // '' );
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                # About arriving, not about being on the way. A card still in
                # implement has not skipped verify; it has not reached it.
                next if ( $record->{column} // '' ) ne ( $policy->{enter} // '' );

                # Where it has been, read from the work log rather than from
                # anything the card carries - the engine writes that on every
                # move, and it is the only account of the route that whoever
                # made the moves did not write themselves.
                my $journal = $self->_police_history( $root, $record->{ref}, $unreadable );
                next if !defined $journal;

                my %visited = map { ( $_->{after} // '' ) => 1 }
                  grep { ( $_->{field} // '' ) eq 'column' } @{$journal};

                my @missed = grep { !$visited{$_} } @required;
                next if !@missed;
                $report->( $policy, $record,
                    'arrived in ' . $policy->{enter} . ' without passing through '
                      . join( ', ', @missed ) );
            }
        }
        elsif ( $rule eq 'wip-limit' ) {
            my $watched = @{$records}
              ? $self->_policy_column_for( project => $root, policy => $policy,
                  field => 'column', record => $records->[0] )
              : $policy->{column};
            my @in = grep { ( $_->{column} // '' ) eq ( $watched // '' ) } @{$records};

            # Read when the rule runs rather than copied when the policy was
            # declared. An owner who raises the number and a rule still using
            # the old one is the worst of both, because he believes he has
            # changed it.
            my $max = $policy->{max} // $limit;
            next if !defined $max;
            next if @in <= $max;
            # Who is holding each one. Without it the message reads exactly
            # the same whether three agents have one card each or one agent
            # has three - and those are opposite situations: the first is the
            # board working as intended, the second is somebody who should
            # finish something before starting another. A rule that cannot
            # tell them apart gets its limit raised until it never fires,
            # which is the same as deleting it.
            $report->( $policy, undef,
                scalar(@in) . " cards in $watched, limit is $max: "
                  . join( ', ', map {
                    $_->{ref} . ' (' . ( ( $_->{assignee} // '' ) ne '' ? $_->{assignee} : 'nobody' ) . ')'
                } @in ) );
        }
        elsif ( $rule eq 'gate-missing' ) {
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                next if ( $record->{column} // '' ) ne ( $self->_policy_column_for(
                    project => $root, policy => $policy, field => 'column',
                    record => $record ) // '' );
                next if @{ $record->{gate_passing_log} // [] };
                $report->( $policy, $record,
                    "reached $record->{column} with no gate recorded" );
            }
        }
        elsif ( $rule eq 'column-unwatched' ) {

            # Adding a column does not silently narrow a rule.
            #
            # A rule naming one column stops covering the board the moment
            # somebody adds another, and nobody has to do anything wrong for
            # that to happen: the policy was complete when it was written. On
            # this project's own board checklist-idle and card-duration were
            # declared for one column out of five, and a card sat untouched in
            # one of the other four for six hours before he spotted it himself.
            #
            # Only rules the board has actually scoped by column. A board-wide
            # policy already covers everything, and telling somebody to narrow
            # what is as wide as it can be is noise.
            my %covered;
            for my $other ( @{$policies} ) {
                next if ( $other->{column} // '' ) eq '';
                $covered{ $other->{rule} }{ $other->{column} } = 1;
            }
            next if !keys %covered;

            # Where work happens, asked the way card-unassigned and
            # priority-skipped ask it: not protected, and not an ending. A board
            # that has marked nothing terminal ends in `done`, which is the same
            # fallback those rules use - without it every board would be told
            # its finished column is unwatched.
            # The endings first, across every board, and only then the columns
            # work happens in. This worked them out for each type separately
            # and merged the working columns of all three by name, so a column
            # marked as an ending for tickets and not for epics was both - and
            # the merge kept the second answer. A board that had marked three
            # endings was told about all three. The columns are per type and
            # the name is shared, so a name marked anywhere is an ending
            # everywhere: that is what somebody means by marking it. TKT-239.
            # The endings of every board, not of one. This rule reports column
            # names rather than cards, and a name marked as an ending on any
            # board is one wherever it appears - which is what somebody means
            # by marking it. Asked for, rather than assembled here, so it sits
            # beside the other answers instead of looking like a copy that
            # drifted. TKT-252.
            my %columns_by_type = map {
                $_ => ( eval { $self->column_list( project => $root, type => $_ ) } || [] )
            } qw(sow epic ticket);
            my %ends = %{ $self->_ending_columns_everywhere($root) };

            # Where work waits is asked, not decided again. This kept its own
            # copy - not protected and not an ending - which agreed with the
            # rest of the engine right up until TKT-310 replaced that
            # definition, and then disagreed by construction: a column a board
            # created is never protected, so a queue looked like a place work
            # happens that no policy mentions. Being asked to declare
            # gate-missing on a queue is the absurdity this rule's own comment
            # says it exists to avoid. Found by the bug hunt. TKT-330.
            my %working;
            for my $type (qw(sow epic ticket)) {
                my $queues = $self->_queue_columns( $root, $type );
                $working{ $_->{name} } = 1
                  for grep {
                      !$_->{protected}
                        && !$ends{ $_->{name} }
                        && !$queues->{ $_->{name} }
                  } @{ $columns_by_type{$type} };
            }

            # A column no column-scoped rule mentions at all.
            #
            # Not "a rule that does not cover every column", which is the wider
            # question and the wrong one. Which rule belongs on which column is
            # a judgment: gate-missing belongs at the late columns and would be
            # absurd on tests-red, and demanding it there would raise a
            # violation nobody could ever close - the exact complaint mt5-ai
            # made about card-damaged, arriving from the other direction.
            #
            # A column that no column-scoped rule names is not a judgment. It
            # is a place work happens that the board's column-scoped policies
            # do not know exists, which is what adding a column does and what
            # happened here: checklist-idle and card-duration named implement
            # on a board with five working columns, and a card sat in tests-red
            # for six hours with nothing to say so.
            #
            # Found by running the review this card also ships against this
            # project's own board. The wider version demanded gate-missing be
            # declared for tests-red, and there would have been no way to
            # answer it.
            my %named;
            $named{$_} = 1 for map { keys %{$_} } values %covered;

            my @blind = sort grep { !$named{$_} } keys %working;

            # One violation, however many columns are blind. A violation is
            # identified by its rule, its policy and its card, so several of
            # these would be one issue whose text changed under it - and this is
            # one state anyway: the board has grown past its policies, and it is
            # answered when they catch up.
            $report->( $policy, '',
                'no policy scoped by column watches '
                  . join( ', ', @blind )
                  . ', and ' . join( ', ', sort keys %covered )
                  . ( keys %covered == 1 ? ' is' : ' are' )
                  . ' declared for other columns - a rule naming a column stops covering '
                  . 'the board the moment another is added, silently. Declare what belongs '
                  . 'there, or decline the rules that do not' )
              if @blind;
        }
        elsif ( $rule eq 'bridge-unread' ) {

            # Whether anybody is listening. Every other rule here asks whether
            # the board is in order; this asks whether the answers are reaching
            # anyone, which is the question that makes the rest worth anything.
            #
            # Only when there is something to read. A bridge with nothing on it
            # is not unread - sending an agent to look at an empty file is how
            # it learns to stop looking.
            my $bridge = $self->bridge_log_path(%args);
            next if !-s $bridge;

            my $seen = $quieted->{bridge_read_at};
            next if defined $seen && !$self->_policy_older_than( $seen, $policy->{age} );

            $report->( $policy, '',
                ( defined $seen
                    ? "the bridge has not been read since $seen, which is "
                      . $self->_policy_elapsed($seen)
                    : 'the bridge has never been read' )
                  . ', and police has been writing to it. A rule nobody reads is the '
                  . 'same as a rule that never fired: tail it with d2 tira.policy.bridge '
                  . 'and keep it running while you work' );
        }
        elsif ( $rule eq 'card-still' ) {
            my ( %resting, %limits );
            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                # A card resting in the backlog has not started and a card in
                # an ending is over. Reporting either would put every board
                # permanently in violation of its own history. Asked per kind
                # and remembered, the way the rules beside this one do it -
                # a column can be terminal for tickets and not for epics.
                my $kind = $record->{type} // 'ticket';
                $resting{$kind} //= $self->_resting_columns( $root, $kind );
                next if $resting{$kind}{ $record->{column} // '' };

                # A card-duration policy already watching this exact column is
                # a considered decision about it - a written reason attached,
                # not a board-wide number that was never written with this
                # column in mind. It stands in for card-still here rather than
                # merely raising its age, so a column that genuinely goes past
                # its own considered limit is reported once, by the rule that
                # was declared for it, not twice. TKT-355.
                next if $self->_card_duration_governs( $root, $policies, $record, $resolved_for );

                # How long is too long, asked of the column the card is in.
                #
                # His refinement, and it is the difference between a reminder
                # and spam: a card may sit in one column far longer than in
                # another without anything being wrong, and some columns want
                # no watching at all. Every column already carries its own
                # limit in minutes and its own watched flag - tira.stale has
                # judged cards by them since they were added, and no rule ever
                # has. So this asks the column first, falls back to the age the
                # policy was declared with, and leaves an unwatched column
                # alone however old its cards are. TKT-278.
                $limits{$kind} //= $self->_column_limits( $root, $kind );
                my $column = $record->{column} // '';
                next if exists $limits{$kind}{$column} && !defined $limits{$kind}{$column};
                my $age = $limits{$kind}{$column} // $policy->{age};

                my $touched = $self->_card_last_activity( $root, $record );
                next if !$self->_policy_older_than( $touched, $age );

                $report->( $policy, $record,
                    "nothing has happened to this card since $touched, which is "
                      . $self->_policy_elapsed($touched)
                      . ", and it is sitting in $column" );
            }
        }
        elsif ( $rule eq 'card-changed-by-owner' ) {

            # Asked for directly: the card is the one place he has been told to
            # put instructions for the agent, and an edit made in the browser
            # was invisible until the agent happened to re-read it.
            #
            # Compared rather than remembered - the newest change was made by
            # somebody who is not the agent working the card - so it settles by
            # itself the moment the agent touches the card, and there is no
            # stored timestamp to go stale or to be quietly reset. TKT-307.
            # The board's agent, asked once. Comparing against the card's
            # assignee alone made this vacuous on an unassigned card: with
            # nobody working it, everybody is "somebody other than the agent
            # working it", so the board's own work counted as an outside edit
            # and the finding could never settle - the agent's next change was
            # by the same stranger as the last. 24 findings on this board within
            # a minute of declaring it, every one its own work, and Zenandi
            # reported the same from their side in the same minute. TKT-316.
            my $ours = $self->_agent_declared_for($root) // '';

            # A column nobody is watching is left alone, which is the TKT-287
            # answer and this rule did not ask it either - Zenandi found that
            # within minutes of the last one, from the same board. The watched
            # flag alone, not the whole resting set: a card waiting in the
            # backlog is exactly the kind he edits, and silencing the backlog
            # would silence the case this rule was built for. TKT-318.
            my ( %limits, %ends );

            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );

                my $kind = $record->{type} // 'ticket';
                $limits{$kind} //= $self->_column_limits( $root, $kind );
                my $column = $record->{column} // '';
                next
                  if exists $limits{$kind}{$column}
                  && !defined $limits{$kind}{$column};

                # And a column where work ends, which this rule did not ask
                # either. A finished card has no agent to remind, so the finding
                # has no addressee who can act on it - Zenandi reported it and
                # TKT-319 records that their owner chose to accept permanent
                # CRITICAL noise rather than mute the rule. The same shape as
                # TKT-287 and as the unwatched flag above: every card rule has
                # to ask which columns to leave alone. TKT-320.
                $ends{$kind} //= $self->_ending_columns( $root, $kind );
                next if $ends{$kind}{$column};

                my $last = $self->_card_last_author( $root, $record );
                next if !$last;
                next if ( $record->{assignee} // '' ) eq $last->{author};
                next if $ours ne '' && $ours eq $last->{author};

                $report->( $policy, $record,
                    "changed by $last->{author}"
                      . ( defined $last->{at} ? " at $last->{at}" : '' )
                      . ( defined $last->{field} ? " - $last->{field}" : '' )
                      . ' - read it before carrying on, it may not say what it did' );
            }
        }
        elsif ( $rule eq 'rules-undeclared' ) {
            my $unanswered = $self->policy_undeclared( project => $root );
            next if !@{$unanswered};
            $report->( $policy, undef,
                scalar( @{$unanswered} )
                  . ' rule(s) this board has neither declared nor declined: '
                  . join( ', ', sort @{$unanswered} )
                  . ' - see them with d2 tira.policy.undeclared, then declare or'
                  . ' decline each one' );
        }
        elsif ( $rule eq 'board-still' ) {

            # The one rule here that is not about a card. Every other rule needs
            # something to attach itself to, so a board where every card sits
            # untouched looks to all of them exactly like a board with nothing
            # wrong - the silence-is-not-compliance shape one level up, and the
            # reason he asked for it.
            #
            # Movement is read from what is already kept: a card created, a
            # field written, a comment, an answer, a checklist tick and a column
            # move all stamp last_updated, so the newest one on the board is
            # when the board last did anything. That was only true of a column
            # move from 1.89 - before it, a move renamed the file and left the
            # stamp alone, and this rule built on it would have called a board
            # busy with moves completely still.
            #
            # Discarded cards count. Setting one aside is a decision, and a
            # board whose only activity was tidying up has still been worked.
            my ($moved) = sort { $b cmp $a } grep { defined }
              map { $_->{last_updated} } @{$all};

            # An empty board is not a stuck board: nothing has moved for want of
            # anything to move, and greeting a new project with a complaint
            # about work nobody has raised yet would teach its agent to read
            # past this channel on its first day.
            #
            # No guard is written for it. A board with no cards leaves $moved
            # undefined, and _policy_older_than treats a stamp it cannot read as
            # not old - the same safe default it applies everywhere. A `next if
            # !defined` here was tried and removed: mutating it away changed no
            # verdict and produced no warning, which is a check that exists and
            # never fires.
            next if !$self->_policy_older_than( $moved, $policy->{age} );

            $report->( $policy, '',
                "nothing has moved on this board since $moved, which is "
                  . $self->_policy_elapsed($moved)
                  . " - no card created, no field written, no column changed. If that is "
                  . 'expected while something is being worked out, put this rule down for a '
                  . 'while with a reason rather than leaving it unanswered: '
                  . 'd2 tira.rule.suspend --rule board-still --seconds N --reason TEXT' );
        }
        elsif ( $rule eq 'agent-still' ) {

            # board-still one level in. It asks when the BOARD last changed;
            # this asks when the AGENT last acted, because on a board that
            # receives reports from other projects those are different
            # questions and only the second one is about whether work is
            # happening.
            my $acted = $self->_agent_last_acted( $root, $all );

            # Silent while anything is still ripening, and silent on a board
            # with no history at all - the same safe default board-still takes,
            # for the same reason.
            next if !$self->_policy_older_than( $acted, $policy->{age} );

            # An idle queue is not a stopped agent, and this is the half that
            # keeps the rule honest. An earlier 7h49m gap on this board was
            # investigated and found to be correct work throughout: there was
            # simply nothing in a working column. A rule that fired on elapsed
            # time alone would have been wrong then and right now, which is no
            # rule at all - so it reports only when something is actually
            # waiting on the agent.
            # Neither an ending nor a queue. The queue half is what the first
            # run of the test caught: seven cards filed by other projects sat
            # in the backlog, and counting those as work waiting would have
            # reported a stopped agent on a board whose only content was other
            # people's unstarted requests - which is the idle queue this rule
            # is required not to report.
            my %ends  = %{ $self->_ending_columns( $root, 'ticket' ) };
            my %queue = %{ $self->_queue_columns( $root, 'ticket' ) };
            my @waiting = sort map { $_->{ref} }
              grep {
                my $column = $_->{column} // '';
                !$ends{$column} && !$queue{$column} && $column ne 'discard'
              } @{$all};
            next if !@waiting;

            my $said =
                'nothing has been worked on this board since ' . $acted . ', which is '
              . $self->_policy_elapsed($acted)
              . ' - no card moved column and none edited by the agent. Cards still '
              . 'waiting: ' . join( ', ', @waiting[ 0 .. ( @waiting > 5 ? 4 : $#waiting ) ] )
              . ( @waiting > 5 ? ' and ' . ( @waiting - 5 ) . ' more' : '' )
              . '. Cards arriving from other projects do not count as work, which is '
              . 'why board-still can be quiet while this is not.';
            $report->( $policy, '', $said );

            # And out, to somebody who is not the agent. Every other rule here
            # writes to the bridge and trusts the agent to read it; this is the
            # one rule whose subject is the agent having stopped, so the bridge
            # is precisely the place it cannot usefully go. During the stoppage
            # this was written for, card-still reported both stranded cards and
            # escalated them to CRITICAL - addressed to the party that had
            # stopped.
            #
            # Through TKT-349's seam and its two variables, so there is one way
            # this board speaks off the machine and one place to configure it.
            # Opt-in for the same reason: a board that has set no address is not
            # made to reach out to one.
            #
            # Throttled, because nothing else was. Every rule that writes to
            # the bridge has the bridge's own seen/settle tracking to stop it
            # repeating itself; this rule goes around the bridge on purpose,
            # which means it also went around the only thing that would have
            # stopped it repeating - every ~30s poll that found the agent
            # still stopped sent another identical message, for as long as
            # the stall lasted. Measured live: one Telegram message per poll
            # tick, all identical. TKT-422.
            if ( $self->_agent_still_may_notify( $args{store}, $acted ) ) {
                my $sent = $self->_send_notification( project => $root,
                    text => 'Tira: the agent has stopped. ' . $said );
                $self->_agent_still_mark_notified( $args{store}, $acted ) if $sent;
            }
        }
        elsif ( $rule eq 'discard-with-open-questions' ) {

            # His request. A card can be set aside while it still carries
            # questions nobody answered, and nothing said so: the questions go
            # with the card - not answered, not withdrawn, not asked anywhere
            # else - and the decision they were waiting on is never made.
            #
            # Read from @{$all} rather than $records, because $records leaves
            # out exactly the cards this is about.
            #
            # Police asks and moves nothing. Whether a question still matters is
            # a judgement about the work, and a rule that carried questions
            # between cards on its own would be making that judgement by
            # machine - where a wrong guess is indistinguishable from a decision
            # somebody made.
            my %ends_by_type;
            for my $record ( @{$all} ) {
                my $rtype  = $record->{type} // 'ticket';
                my $ends   = $ends_by_type{$rtype} //= $self->_ending_columns( $root, $rtype );
                my $column = $record->{column} // '';
                next if $column ne 'discard' && !$ends->{$column};
                next if !$resolved_for->( $policy, $record );

                # Still open means still waiting. An answered question was
                # settled before the card was, and a withdrawn one is the agent
                # having already done what this rule asks - _policy_questions
                # leaves the discarded ones out.
                my @open = grep { !$_->{answer} } _policy_questions($record);
                next if !@open;

                # Named, so the reader does not have to open the card to find
                # out which decision was dropped.
                my $which = join ', ', map { $_->{id} } @open;
                $report->( $policy, $record,
                    "set aside carrying $which, still unanswered - decide whether each "
                      . 'still matters, ask the ones that do on the card they belong to now, '
                      . 'and discard them here. There is no command that moves a question: '
                      . 'asking it where it belongs and discarding it here is the move' );
            }
        }
        elsif ( $rule eq 'discard-unexplained' ) {
            for my $record ( @{$all} ) {

                # Narrowed if the policy said so. This branch read every record
                # and never asked, so a policy declared for one card reported
                # every discarded card on the board - a scope accepted, stored
                # on the policy, and never consulted, against a documented
                # promise that declaring on a card beats declaring on the board.
                next if !$resolved_for->( $policy, $record );
                next if ( $record->{column} // '' ) ne 'discard';
                next if @{ $record->{comments} // [] };
                # A comment, said so. The rule beside this one wants a field,
                # and a reader who learns one convention from one rule learns
                # the wrong thing about the other unless both say which.
                $report->( $policy, $record,
                    'discarded with no reason given - leave a comment saying why it was set aside' );
            }
        }
        elsif ( $rule eq 'priority-skipped' ) {

            # Work taken out of turn, checked by something other than the party
            # taking it. He caught this by eye once - "you randomly pick and
            # work on them disregard the card prioity" - and the repair was a
            # sentence in a document, which is the kind of check this project
            # has learned not to trust.
            #
            # It needs to be a rule for a sharper reason than forgetfulness:
            # the agent raises its own cards and sets their priority, so "work
            # the highest first" is a weak promise when the same party decides
            # what is highest. What a rule can watch is the part that cannot be
            # marked as its own homework - not what priority was set, but
            # whether something above the card being worked is being left.
            #
            # 5 is the urgent end here. That is stated in the refusal, in
            # SKILLS.md and in the command reference as of TKT-186, and it had
            # to be settled before this could be written: the first draft of
            # this rule's test had the scale inverted and would have enforced
            # the exact opposite of what was asked for.
            # Three kinds of column, and the difference matters. Work happens
            # in the ones a board added; work waits in the protected ones it did
            # not; work ends in whichever it marked terminal. A card in the last
            # of those is finished rather than waiting, and reporting a finished
            # card as passed over would put every board permanently in
            # violation of its own history.
            # Asked rather than worked out again, like card-unassigned.
            my %resting;
            $resting{$_} = $self->_resting_columns( $root, $_ )
              for qw(sow epic ticket);

            # Which cards are waiting, and which outranks which, is the same
            # question tira.next answers, so it is asked rather than sorted
            # again here - two copies of one ordering could disagree about the
            # same board, and this rule exists to enforce that ordering.
            # TKT-274, and TKT-252 before it.
            my @waiting = @{ $self->work_order( project => $root ) };

            for my $record ( @{$records} ) {
                next if !$resolved_for->( $policy, $record );
                my $type = $record->{type} // 'ticket';
                next if $resting{$type}{ $record->{column} // '' };
                next if !defined $record->{priority};

                for my $above (@waiting) {

                    # Cards of different kinds are not compared. An epic sits in
                    # the backlog for as long as its tickets take, which is what
                    # an epic is for, so judging a ticket against one would leave
                    # every board with a hierarchy permanently in violation.
                    next if ( $above->{type} // 'ticket' ) ne $type;
                    my ( $outranks, $decided_by ) = $self->_outranks_for_work( $above, $record );
                    next if !$outranks;

                    # Parked, not skipped. A higher card that cannot start until
                    # he answers is not being ignored, and reporting it would
                    # blame the agent for the one delay that is not its doing.
                    next if grep { !$_->{answer} } _policy_questions($above);

                    # Two different facts can decide this, and the message says
                    # whichever one actually did. Printing "above this card's N"
                    # when both cards sit at the same priority N disproves its
                    # own sentence with the number it prints - the tie-break is
                    # a real fact (who has waited longer) and is named as one.
                    my $why = $decided_by eq 'age'
                      ? do {
                          my ($date) = ( $above->{created_at} // '' ) =~ /\A(\d{4}-\d{2}-\d{2})/;
                          "waits at the same priority and has been waiting since "
                            . ( $date // $above->{created_at} );
                      }
                      : "waits at priority $above->{priority}, above this card's "
                      . ( $record->{priority} // 'none' );

                    $report->( $policy, $record, "being worked while $above->{ref} $why" );
                    last;
                }
            }
        }

        # The remaining rules are about the world outside the board. Police
        # evaluates those and hands them in, because this module invokes no
        # shell and is not going to start.
    }

    return \@violations;
}

# Whether a card sits before the column the policy names. Which column means
# "the work has moved on" is the project's decision, not Tira's - every board
# names its columns differently, and a rule that guesses is a rule that fires
# wrongly on somebody else's board.
sub _policy_before_column {
    my ( $self, $root, $record, $marker ) = @_;
    return 0 if ( $record->{column} // '' ) eq 'discard';
    my $order = $self->_column_positions( $root, $record->{type} );
    my $here  = $order->{ $record->{column} // '' };
    my $there = $order->{ $marker // '' };
    return 0 if !defined $here || !defined $there;
    return $here < $there ? 1 : 0;
}

# One problem getting louder, rather than fifty problems. A warning system
# dies by repetition: fifty numbers for one condition is noise, and noise is
# what gets ignored. One number that rises in tone is a fact.
#
# The ledger lives in police's own store rather than in the project. That is
# not tidiness - a ledger inside the board would make police a second writer,
# and two writers on one board is what destroyed this project's own board on
# the day this was designed.
my @VIOLATION_TONES = qw(note warning urgent critical);
our $VIOLATION_ESCALATES_AT = 5;

# One rule cannot wait for the fifth telling, because the wait is spent on the
# thing it is reporting. bridge-unread says nobody is reading the bridge, and
# the bridge is the only route that carries a violation before it escalates -
# so it is heard exactly when it is not needed and silent exactly when it is.
# Measured on this project's own board before this existed: four tellings over
# sixty-four minutes, at urgent, delivered to neither the agent nor the owner,
# and closed only because the owner happened to ask for a reader for an
# unrelated reason.
#
# Every other rule keeps the threshold. It is deliberate, it is what stops
# escalation becoming the noise it exists to rise above, and a rule with a
# working channel in the meantime loses nothing by waiting.
my %ESCALATES_SOONER = ( 'bridge-unread' => 1 );

# How long the same problem is left alone before it is said again, and it grows.
#
# The owner raised this: "the same issue been seen many times within few
# seconds... becomes spammy and the core agent might ignore the repeated ones
# and also wasting the LLM token or credit too." Police runs every thirty
# seconds and every pass wrote every violation still true, so a problem nobody
# had got to yet said the same thing twice a minute for ever.
#
# It grows because a problem that persists should get quieter rather than keep
# buzzing at one rate - the first repeat is a nudge, the fifth is a different
# kind of message and deserves a different spacing. The last entry is the
# spacing from then on.
our @VIOLATION_QUIET_LADDER = ( '5m', '15m', '30m', '60m' );

# When a problem may be said again: never before the ladder says so, and always
# at once the first time, because nobody has been told yet.
sub _violation_may_speak {
    my ( $self, $entry, $now ) = @_;
    return 1 if !defined $entry->{said_at};
    my $step = $entry->{seen} // 1;
    $step = @VIOLATION_QUIET_LADDER if $step > @VIOLATION_QUIET_LADDER;
    my $quiet = _duration_seconds( $VIOLATION_QUIET_LADDER[ $step - 1 ] ) // 0;
    my $then = eval { _epoch_of_datetime( $entry->{said_at}, 'Said at' ) } // return 1;
    my $clock = eval { _epoch_of_datetime( $now, 'Clock' ) } // return 1;
    return $clock - $then >= $quiet ? 1 : 0;
}

sub _violation_key {
    my ($violation) = @_;
    return join '|', map { $violation->{$_} // '' } qw(rule policy ref);
}

# Telling the owner a card moved, without an agent spending tokens to do it.
#
# His words: a police sentry rather than an agent sentry. The agent enables it
# once and police sends from then on. He worked the design out himself and
# rejected the obvious version - a notification on leaving a column and another
# on arriving sends two messages about one event, and ten tickets becomes
# twenty - so this is one message per move.
#
# Off until asked for, every column on by default, any column switchable off.
# His example is discard: he does not need to be told a card was set aside.
# TKT-349.
sub notify_moves {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);

        # Reading must not decide anything. "Has anybody turned this on?" is
        # exactly the question a bare call answers, and persisting a default
        # while answering it makes the answer yes regardless of what was
        # true a moment before - the evidence being asked about gets
        # destroyed by the asking. So a change is only written when one was
        # actually named: a chat, a column, or enabled.
        my $wants_change =
          ( defined $args{chat} && $args{chat} ne '' )
          || ( defined $args{column} && $args{column} ne '' )
          || defined $args{enabled};
        my $setting = $data->{notify_moves} // { enabled => 0, columns => {} };
        return $setting if !$wants_change;

        $data->{notify_moves} = $setting;

        # Where to send, stored on the board rather than read out of the
        # environment. His words on the card: "set once by the agent" - and an
        # agent cannot set an environment variable on a police process somebody
        # else started, which is why this never worked. The board is the thing
        # the agent can write, and every other per-board setting already lives
        # here. TKT-349.
        $setting->{chat} = $args{chat} if defined $args{chat} && $args{chat} ne '';

        if ( defined $args{column} && $args{column} ne '' ) {
            $setting->{columns}{ $args{column} } =
              $args{enabled} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false;
        }
        elsif ( defined $args{enabled} ) {
            $setting->{enabled} =
              $args{enabled} ? Cpanel::JSON::XS::true : Cpanel::JSON::XS::false;
        }

        $self->_write_yaml( $path, $data );
        return $setting;
    } );
}

# The move this board has already spoken about, so a pass every few minutes does
# not resend it. One stamp per card, kept beside the violations because it is
# police's memory rather than the card's - and a method so a test can forget.
# One message per move, said once.
#
# The stamp is the whole mechanism: a pass every few minutes must not resend a
# move it has already spoken about, and comparison alone cannot tell "is in a
# column" from "just arrived". TKT-349.
sub _announce_moves {
    my ( $self, $root, $store ) = @_;
    return if !defined $store;

    my ( undef, $data ) = $self->_project_data($root);
    my $wanted = $data->{notify_moves} || {};
    return if !$wanted->{enabled};

    my $records = eval { $self->record_list( project => $root, include_discard => 1 ) } || [];
    my $ledger  = $self->_violation_ledger($store);
    my $said    = $ledger->{notified_moves} ||= {};
    my $changed = 0;

    for my $record ( @{$records} ) {
        my $move = $self->_last_move( $root, $record );
        next if !$move || !defined $move->{at};

        my $already = $self->_notified_move_at( $store, $record->{ref} );
        next if defined $already && $already ge $move->{at};

        # A column switched off is silent, and still remembered - otherwise
        # switching it back on would announce a move that happened while
        # nobody was listening.
        my $column = $move->{column} // '';
        my $on = $wanted->{columns} && exists $wanted->{columns}{$column}
          ? $wanted->{columns}{$column} : 1;

        # Remembered only when the silence was deliberate. A column switched
        # off is a decision and is recorded, so switching it back on does not
        # announce a move nobody was listening for. A message that could not be
        # sent - no token, no chat id - is NOT recorded, because the owner has
        # not been told and configuring the variables should not lose the move.
        #
        # The test caught this: with the stamp written either way, a move that
        # happened while the variables were unset stayed silent for ever.
        my $told = $on
          ? $self->_send_notification( project => $root,
              text => "$record->{ref} moved to $column - " . ( $record->{title} // '' ) )
          : 1;
        next if !$told;

        $said->{ $record->{ref} } = $move->{at};
        $changed = 1;
    }

    $self->_atomic_write( $self->_violation_ledger_path($store),
        json_object()->canonical->encode($ledger) )
      if $changed;
    return;
}

sub _notified_move_at {
    my ( $self, $store, $ref ) = @_;
    return if !defined $store;
    my $ledger = $self->_violation_ledger($store);
    return ( $ledger->{notified_moves} // {} )->{ $ref // '' };
}

# The last column move on a card, read from what history already records.
sub _last_move {
    my ( $self, $root, $record ) = @_;
    my $entries = eval {
        $self->history_list( project => $root, ref => $record->{ref} );
    } || [];

    # field eq 'column' alone used to mean a real move, back when
    # record_move's own manual _journal_record call was the only source.
    # create_record now writes the same field for a card's starting column
    # too (TKT-433), tagged op => 'create' - a card simply arriving is not a
    # move to announce.
    my ($move) = grep { ( $_->{field} // '' ) eq 'column' && ( $_->{op} // '' ) eq 'move' } reverse @{$entries};
    return if ref $move ne 'HASH';
    return { at => $move->{at}, column => $record->{column} };
}

# How often agent-still is allowed to actually reach Telegram for the same
# stall. Fifteen minutes, the owner's own ceiling once he had to say what
# "too often" meant in numbers, on the same board this rule was built for.
my $AGENT_STILL_NOTIFY_SECONDS = 900;

# Whether agent-still may send again. Yes the first time a given stall
# ($acted, when the agent last acted, never changes while the stall
# continues) is seen; yes again if the last successful send for THIS stall
# was more than $AGENT_STILL_NOTIFY_SECONDS ago; no otherwise. A board that
# recovers and stalls again gets a new $acted and is told about it - this is
# a repeat throttle, not a permanent silence.
sub _agent_still_may_notify {
    my ( $self, $store, $acted ) = @_;
    return 1 if !$store;
    my $last = $self->_violation_ledger($store)->{agent_still_notified};
    return 1 if !defined $last || ( $last->{since} // '' ) ne $acted;
    my $now = _epoch_of_datetime( $self->{clock}->(), 'Clock' );
    return ( $now - $last->{at} ) >= $AGENT_STILL_NOTIFY_SECONDS ? 1 : 0;
}

# Recorded only once the message has actually arrived - the same discipline
# the move-reminder job below already follows, and for the same reason: a
# send that failed (no token, no chat id) must not be remembered as one that
# happened, or fixing the configuration would still stay silent for the
# throttle window.
sub _agent_still_mark_notified {
    my ( $self, $store, $acted ) = @_;
    return if !$store;
    my $ledger = $self->_violation_ledger($store);
    $ledger->{agent_still_notified} = {
        since => $acted, at => _epoch_of_datetime( $self->{clock}->(), 'Clock' ),
    };
    $self->_atomic_write( $self->_violation_ledger_path($store),
        json_object()->canonical->encode($ledger) );
    return 1;
}

# The seam. Nothing is sent unless both variables are set - his instruction,
# and the names are his: TELEGRAM_CHATID carries no underscore, which is not
# what I would have written and is why I asked (Q-043).
sub _send_notification {
    my ( $self, %args ) = @_;
    my $token = $ENV{TELEGRAM_BOT_TOKEN};

    # Resolved the same way notification_delivery resolves it, so what the board
    # is told it can do and what it actually does cannot disagree - the whole of
    # TKT-349 is that they did, silently, for a day.
    my $chat;
    $chat = eval {
        $self->project_show( project => $args{project} )->{notify_moves}{chat};
    } if defined $args{project};
    $chat = $ENV{TELEGRAM_CHATID} if !defined $chat || $chat eq '';

    return 0 if !defined $token || $token eq '';
    return 0 if !defined $chat  || $chat eq '';
    return $self->_post_telegram( $token, $chat, $args{text} );
}

sub _post_telegram {
    my ( $self, $token, $chat, $text ) = @_;
    require HTTP::Tiny;
    my $response = HTTP::Tiny->new( timeout => 10 )->post_form(
        "https://api.telegram.org/bot$token/sendMessage",
        { chat_id => $chat, text => $text // '' } );
    return $response->{success} ? 1 : 0;
}

sub _violation_ledger_path {
    my ( $self, $store ) = @_;
    make_path($store) if !-d $store;
    return File::Spec->catfile( $store, 'violations.json' );
}

sub _violation_ledger {
    my ( $self, $store ) = @_;
    my $path = $self->_violation_ledger_path($store);
    return { counter => 0, open => {} } if !-f $path;
    open my $fh, '<:raw', $path or return { counter => 0, open => {} };
    my $content = do { local $/; <$fh> };
    close $fh;
    my $ledger = eval { json_decode($content) };
    return ref $ledger eq 'HASH' ? $ledger : { counter => 0, open => {} };
}

# A count of one is a note; by five it has been ignored long enough to be
# critical. The ladder only ever climbs, so a persistent problem never quietly
# softens just because it has been around a while.
sub _violation_tone {
    my ($seen) = @_;
    return $VIOLATION_TONES[0] if $seen <= 1;
    return $VIOLATION_TONES[1] if $seen <= 3;
    return $VIOLATION_TONES[2] if $seen < $VIOLATION_ESCALATES_AT;
    return $VIOLATION_TONES[-1];
}

# What the owner sees in his own terminal when the agent has demonstrably
# stopped listening. It carries everything he needs to act without going and
# What to run about a violation. One expression, because two that agree today
# drift apart the first time somebody fixes only the one they were looking at -
# the fault this project has now found in its program lookup, in its message
# substitution, and here, where the bridge line and the owner's terminal each
# wrote it out.
#
# A rule about the board itself can name the command that answers it. Until
# 2026-08-13 every one of them ended in "list your policies", so board-unbacked
# said the board had never been backed up and then told whoever read it to go
# and read the policy list, which backs nothing up.
our %VIOLATION_FIX = (
    'board-unbacked' => 'd2 tira.backup',

    # The one rule whose remedy is a command rather than a look at the card.
    # mt5-ai read "fix: d2 tira.ticket.show --ref M5T-034" against a report of
    # corruption in that card's history - a viewer, which changes nothing about
    # the byte - and concluded, reasonably, that nothing could be done. The
    # repair has existed since 1.94.
    'card-damaged' => 'd2 tira.doctor --repair',
);

sub _violation_fix {
    my ($violation) = @_;

    # A rule that names its own remedy beats the card, because pointing at the
    # card is a good default and a bad answer when there is a command to run.
    # Asked first rather than last, which is the only change: every rule with
    # nothing of its own still points at its card exactly as before.
    my $named = $VIOLATION_FIX{ $violation->{rule} // '' };
    return $named if defined $named;

    my $ref = $violation->{ref} // '';
    return 'd2 tira.' . ( $1 eq 'SOW' ? 'sow' : 'epic' ) . ".show --ref $ref"
      if $ref =~ /\A(SOW|EPC)-/;
    return "d2 tira.ticket.show --ref $ref" if $ref ne '';
    return 'd2 tira.policy.list';
}

# looking anything up, including a command he can paste straight to the agent.
sub _violation_terminal_notice {
    my ( $entry, $violation ) = @_;
    my $ref = $violation->{ref} // '';
    my $fix = _violation_fix($violation);
    return join ' | ',
      $entry->{last_seen},
      $entry->{id},
      ( $ref ne '' ? $ref : 'the board' ),
      ( $violation->{detail} // $violation->{rule} ),
      "seen $entry->{seen} times, needs your attention",

      # Who to hand it to, by name. It said "the agent" for as long as there
      # was only ever one, and that is wrong the moment there are two - and
      # wrong in the worst place, because this is the line he reads with his
      # own eyes and acts on. A card somebody holds names them; a card nobody
      # holds is the core agent's, which is who handles it in a chain and is
      # simply him in a project of one.
      'hand to ' . ( ( $violation->{assignee} // '' ) ne ''
          ? $violation->{assignee} : 'the core agent' ) . ": $fix";
}

sub violation_record {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A violation store is required\n";
    my $now = $self->{clock}->();
    my $ledger = $self->_violation_ledger($store);
    my %still;

    my @view;
    for my $violation ( @{ $args{violations} // [] } ) {
        my $key = _violation_key($violation);
        $still{$key} = 1;
        my $entry = $ledger->{open}{$key};

        if ( !$entry ) {
            # Numbers are never reused, so a number in an old log always means
            # the problem it meant when it was written.
            my $closed = $ledger->{closed}{$key};
            $ledger->{counter} = ( $ledger->{counter} // 0 ) + 1 if !$closed;
            $entry = $closed || {
                id => sprintf( 'VIO-%04d', $ledger->{counter} ),
                first_seen => $now,
                seen => 0,
            };
            $entry->{returned} = 1 if $closed;
            delete $ledger->{closed}{$key};
            $ledger->{open}{$key} = $entry;
        }

        # Still true, so still last seen now - whether or not it is said again.
        $entry->{last_seen} = $now;

        # Enough to announce the settlement when this stops being true. Kept on
        # the entry rather than looked up then, because by that time the card
        # may have been reassigned, the policy removed, or the card discarded -
        # and a settlement addressed to somebody other than the reader who was
        # told about it reaches nobody.
        $entry->{about} = {
            map { defined $violation->{$_} ? ( $_ => $violation->{$_} ) : () }
              qw(rule ref action assignee project)
        };

        # And said only when there has been time to fix it. seen counts the
        # times it has been SAID rather than the passes it has survived, which
        # is what the line has always claimed: "seen 5 times" now means five
        # tellings rather than two and a half minutes of a thirty-second loop.
        #
        # An agent that asked for quiet is not told at all, so its violations
        # must not spend a telling either. Counting them would leave an agent
        # coming back from five minutes of silence owing the longest gap on the
        # ladder for a problem nobody ever mentioned to it - and would let a
        # short suspension carry a violation all the way to his terminal
        # without the agent having had one chance to fix it.
        my $for = $violation->{assignee} // '';
        my $muted = $for ne ''
          && $self->police_suspended( store => $store, agent => $for );
        my $speak = !$muted && $self->_violation_may_speak( $entry, $now );
        if ($speak) {
            $entry->{seen}++;
            $entry->{said_at} = $now;
        }
        $entry->{tone} = _violation_tone( $entry->{seen} );

        # Said once, at the moment it becomes true. Repeating it on every pass
        # afterwards would turn the escalation itself into the noise it exists
        # to rise above.
        my $at = $ESCALATES_SOONER{ $violation->{rule} // '' } // $VIOLATION_ESCALATES_AT;
        my $escalate = $speak && $entry->{seen} == $at && !$entry->{escalated};
        $entry->{escalated} = 1 if $escalate;

        push @view, {
            %{$violation},
            id => $entry->{id},
            seen => $entry->{seen},
            tone => $entry->{tone},
            first_seen => $entry->{first_seen},
            last_seen => $entry->{last_seen},
            ( $entry->{returned} ? ( returned => 1 ) : () ),
            ( $escalate ? ( escalate => 1 ) : () ),

            # Reported as true either way - what police knows is wrong must not
            # change - but only written to the bridge when it may speak. A
            # violation that vanished from the pass while it was quiet would
            # read as fixed to anybody looking at the pass itself.
            ( $speak ? () : ( quiet => 1 ) ),
            terminal => _violation_terminal_notice( $entry, $violation ),
        };
    }

    # A condition that is no longer true stops being reported at once. There is
    # nothing to acknowledge and nothing to clear by hand, because anything an
    # agent has to remember to dismiss becomes something it dismisses without
    # reading.
    my @settled;
    for my $key ( sort keys %{ $ledger->{open} } ) {
        next if $still{$key};

        # Absent from a pass that could not finish is not the same as no longer
        # true. Asked for by police when its pass failed, so a crash cannot
        # announce every open violation as fixed.
        next if $args{keep_open};
        my $entry = delete $ledger->{open}{$key};
        $entry->{closed_at} = $now;
        $ledger->{closed}{$key} = $entry;

        # Said, rather than left to be worked out. Police always knew this the
        # moment it happened and never told anybody, so the line that raised it
        # stayed in the log with nothing marking it dealt with - and an agent
        # replaying a backlog read it as work still to do. Once only: the entry
        # has left open, so no later pass can find it again.
        push @settled, {
            %{ $entry->{about} // {} },
            id => $entry->{id},
            seen => $entry->{seen},
            settled => 1,
        };
    }

    # When this board was last looked at, which nothing recorded. Every entry
    # carries first_seen and last_seen, so the age of a FINDING was knowable and
    # the age of the ANSWER was not - and on a board with no findings there is no
    # entry to read a time from at all, so "nothing is wrong" and "nothing has
    # been checked" printed the same thing.
    #
    # That is the half of TKT-378 that cost a day of small confusions: the
    # instruction for clearing violations ends "then run tira.police.outstanding
    # again and confirm that violation is gone", and outstanding reads this
    # ledger, which only a pass writes. Fix the fault, ask again, and the count
    # does not move until somebody runs a pass.
    $ledger->{last_pass} = $self->{clock}->();
    $self->_atomic_write(
        $self->_violation_ledger_path($store),
        json_object()->canonical->encode($ledger) );

    # Two answers, and the caller that only wants the violations still gets
    # exactly what it always did.
    return wantarray ? ( \@view, \@settled ) : \@view;
}

# The six rules that are about the world rather than the board. Police gathers
# the facts and hands them in; this module invokes no shell and is not going to
# start. That also makes every one of these testable without a repository, a
# container or a running process anywhere near the test.
sub _police_environment_violations {
    my ( $self, %args ) = @_;
    my $policies = $args{policies};
    my $records = $args{records};
    my $world = $args{world} || {};
    my @violations;

    # The same reading for the six rules that watch the machine rather than the
    # board. A rule put down is put down whichever half of police it lives in;
    # quieting it in one and not the other is the two-copies fault this codebase
    # has been caught with three times already.
    my $quieted = $args{store} ? $self->_enforcement_read( $args{store} ) : { rules => {} };

    my $report = sub {
        my ( $policy, $ref, $detail ) = @_;
        return if $self->_rule_suspended( $quieted, $policy->{rule}, $ref // '' );
        push @violations, {
            rule => $policy->{rule}, policy => $policy->{id}, ref => $ref // '',
            detail => $detail, action => $policy->{action},

            # Through the same substitution the board rules use, rather than
            # passing the wording along untouched. These six shipped their
            # placeholders raw, so a policy that had been written to say how
            # long it had been said "backed up in {age}" on the bridge - which
            # he read, in the lines he pasted as evidence of something else.
            message => _policy_message( $policy, undef, $detail, $ref // '' ),
        };
    };

    for my $policy ( @{$policies} ) {
        my $rule = $policy->{rule};

        if ( $rule eq 'card-sandbox-missing' ) {
            my %branch = map { $_ => 1 } @{ $world->{branches} // [] };
            my %worktree = map { $_ => 1 } @{ $world->{worktrees} // [] };
            for my $record ( @{$records} ) {
                next if ( $record->{column} // '' ) ne ( $policy->{enter} // '' );
                my @missing;

                # What it looked for, and what came back. A project read
                # "missing branch and the work tree it records, /path, which is
                # not there" while the directory, the work tree and the branch
                # all existed on their machine, and had nothing to check the
                # claim against. A rule that reads the machine has to say what
                # it asked it.
                if ( !$branch{ $record->{ref} } ) {

                    # Their case, and it is a real mismatch rather than a
                    # misreport: this wants a branch named exactly after the
                    # card, a reference is upper case by construction, and git
                    # branches are conventionally lower case - so on any project
                    # following that convention it can never match. Saying which
                    # branch differs only in case turns an hour of hypothesising
                    # into a rename.
                    my ($nearly) = grep { lc $_ eq lc $record->{ref} }
                      @{ $world->{branches} // [] };
                    push @missing, $nearly
                      ? "a branch named $record->{ref} - $nearly differs from it only in case"
                      : 'a branch named ' . $record->{ref} . ' (the machine reported '
                        . scalar( @{ $world->{branches} // [] } ) . ' branches)';
                }

                # Three different things, and each wants a different fix, so
                # each is said differently. A work tree existing on the machine
                # says nothing about which card it belongs to: matched by name
                # alone, one left behind by a card finished last week satisfies
                # the rule for a card started this morning. The card claiming
                # it is what makes the claim checkable, and it is what his
                # design asks for - made by the agent, recorded on the card.
                my $expected = ( $policy->{sandbox} // '' ) . '/' . $record->{ref};
                my $claimed = $record->{sandbox};
                if ( !defined $claimed || $claimed eq '' ) {
                    push @missing, $worktree{$expected}
                      ? "a work tree at $expected that is not recorded on the card"
                      : 'sandbox worktree';
                }
                elsif ( !$worktree{$claimed} ) {

                    # How many came back, because none is a different fault from
                    # one being gone: police pointed at a repository that does
                    # not hold the work trees reports an empty list, and that
                    # read exactly like a tree somebody had deleted.
                    my $seen = scalar @{ $world->{worktrees} // [] };
                    push @missing, $seen
                      ? "the work tree it records, $claimed, which is not among the $seen "
                        . 'the machine reported'
                      : "the work tree it records, $claimed - the machine reported no work trees "
                        . 'at all, which is what police watching the wrong repository looks like';
                }
                next if !@missing;

                # One card, one branch, one worktree. Two cards in one tree
                # means two sets of changes interleaved, and the first failing
                # test cannot say which card caused it.
                $report->( $policy, $record->{ref},
                    'missing ' . join( ' and ', @missing ) . " for $record->{ref}" );
            }
        }
        elsif ( $rule eq 'leftover-process' ) {
            for my $process ( @{ $world->{processes} // [] } ) {
                next if index( $process->{command} // '', $policy->{pattern} // '' ) < 0;

                # The one process this project's own advice tells an agent to
                # keep running - bridge-unread's own message says so outright:
                # "tail it with d2 tira.policy.bridge and keep it running
                # while you work." A pattern matching it by coincidence (a
                # shared project path, nothing more specific) turned the
                # escalation ladder against exactly the thing it was told
                # never to stop. TKT-379.
                next if _is_bridge_tail( $process->{command} );

                next if !$self->_policy_older_than( $process->{started_at}, $policy->{age} );
                $report->( $policy, undef, "still running: $process->{command}" );
            }
        }
        elsif ( $rule eq 'leftover-container' ) {

            # By name, like leftover-process, and for the same reason. Without
            # it this reported every container on the machine - eleven of them
            # the first time it could see any, most belonging to other projects
            # entirely. A rule that names somebody else's running work invites
            # exactly the thing this machine forbids, and one that reports what
            # nobody here can act on is one everybody learns to read past.
            for my $container ( @{ $world->{containers} // [] } ) {
                next if index( $container->{name} // '', $policy->{pattern} // '' ) < 0;
                next if !$self->_policy_older_than( $container->{started_at}, $policy->{age} );
                $report->( $policy, undef, "still up: $container->{name}" );
            }
        }
        elsif ( $rule eq 'commit-without-card' ) {
            for my $commit ( @{ $world->{commits} // [] } ) {
                next if ( $commit->{subject} // '' ) =~ /\b[A-Z]{2,}-\d{3,}\b/;
                $report->( $policy, undef,
                    "$commit->{sha} names no card: $commit->{subject}" );
            }
        }
        elsif ( $rule eq 'work-without-card' ) {
            next if !$world->{working_since};
            next if $world->{card_in_progress};
            next if !$self->_policy_older_than( $world->{working_since}, $policy->{age} );
            $report->( $policy, undef,
                "the tree has been changing since $world->{working_since} with no card at a working gate" );
        }
        elsif ( $rule eq 'unpushed-work' ) {
            next if !$world->{unpushed_since};
            next if !$self->_policy_older_than( $world->{unpushed_since}, $policy->{age} );
            $report->( $policy, undef,
                "commits unpushed since $world->{unpushed_since}, and push is part of done" );
        }
        elsif ( $rule eq 'board-unbacked' ) {
            my $when = $world->{backed_up_at};
            next if defined $when && !$self->_policy_older_than( $when, $policy->{age} );
            $report->( $policy, undef,
                defined $when ? "last backup was $when" : 'the board has never been backed up' );
        }
    }
    return \@violations;
}

# One pass. The loop that calls this lives in the command, so that everything
# worth testing can be tested without waiting for a timer.
# What the owner hands the agent. He runs police in a terminal of his own and
# it watches the board - and until now it never told him what to say to make
# the agent set anything up, so he wrote the instructions himself every time.
#
# Two situations needing different things said. A project with no policies has
# to be taught. A project that has some, but was set up before rules that now
# exist, has to be told which rules it is not using - by name, because
# "something new exists" is not something anybody can act on. A project using
# everything is left alone: nagging somebody who has already done it is how a
# prompt stops being read.
# What nobody has decided about yet.
#
# An agent is the only party that can declare a policy, and it had no way to
# find out what it had not declared: policy.list answers what is declared,
# policy.declined what was refused on purpose, and nothing answered the rest. A
# project lost eighty-four minutes to an owner's answer sitting unread because
# answer-waiting had never been set - not declined, never considered.
#
# A rule somebody looked at and said no to is answered, and asking again would
# make this a channel that repeats itself, which is the one failure a warning
# system cannot survive. That is why declining is an answer and why the declined
# list exists at all: so a deliberate no can be told from an omission.
#
# Police prints this for the owner every run and asks it here rather than
# working it out again, because two answers to one question is what this
# codebase keeps finding drifted apart.
# The whole set in one place, for the review he asked to do.
#
# His words: set up the correct policies yourself, then I come round behind and
# check. Checking means reading it somewhere, and reading it out of policy.list
# means holding the catalogue in your head to see what is missing - which is the
# work this is meant to save.
#
# Every rule in the catalogue appears exactly once, in one of three states, with
# the columns a declared rule covers, so a gap can be seen rather than worked
# out.
sub policy_review {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);

    my $declined = $self->policy_declined( project => $root );

    my %columns;
    my %declared;
    for my $policy ( @{ $self->policy_list( project => $root ) } ) {
        my $rule = $policy->{rule} // '';
        $declared{$rule} = 1;
        push @{ $columns{$rule} }, $policy->{column}
          if defined $policy->{column} && $policy->{column} ne '';
    }

    my @declared = map {
        { rule => $_, columns => [ sort keys %{ { map { $_ => 1 } @{ $columns{$_} // [] } } } ] }
    } sort keys %declared;

    return {
        declared   => \@declared,
        declined   => [ map { { rule => $_->{rule}, reason => $_->{reason} } } @{$declined} ],
        unanswered => $self->policy_undeclared( project => $root ),

        # Declared, declined and unanswered are three states a RULE can be
        # in; a duplicate is a fourth thing entirely - two policies already
        # sitting in the store answering the same question. Named here
        # because this is "the review he asked to do", the one place a
        # reader checks for what the catalogue looks like, rather than a
        # separate command nobody remembers to run. TKT-352.
        duplicates => $self->policy_duplicates( project => $root ),
    };
}

sub policy_undeclared {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my %answered = map { ( $_->{rule} // '' ) => 1 }
      ( @{ $self->policy_list( project => $root ) },
        @{ $self->policy_declined( project => $root ) } );
    return [ grep { !$answered{$_} } @{ policy_rules() } ];
}

# The columns a board rests cards in rather than works them in.
#
# Read from the board, because a project names its own columns: protected or
# terminal means resting, with done assumed when nothing is marked terminal.
# Extracted rather than copied - card-unassigned already made this decision
# inline, and a second copy of it is the drift this project keeps finding.
# Where each column sits, which is the board's own order turned into positions.
#
# Two rules needed it and each worked it out: one built a list of names to find
# two indices in, the other built a map of name to position. Different
# questions - is this card before that marker, did this move go backwards - and
# one fact underneath. They agreed, which is the condition under which nobody
# notices there are two, and a change to how the order is read would have
# reached whichever was edited. TKT-254.
sub _column_positions {
    my ( $self, $root, $type ) = @_;
    my $columns = eval { $self->column_list( project => $root, type => $type ) } || [];
    my $seen = 0;
    return { map { $_->{name} => $seen++ } @{$columns} };
}

# The endings alone, which is the other half of the same question: a column
# somebody marked as where work stops, or done when a board has marked nothing.
# _resting_columns adds the protected columns to these; two callers want the
# endings without them. Asked here so a change to what counts as an ending
# reaches every rule rather than the ones that happen to call the same helper.
# TKT-252.
# Every board's endings together, for the one rule that speaks about column
# names rather than about cards. A name marked as an ending anywhere is one
# everywhere: that is what marking it means, and computing it per board was how
# a column terminal for tickets and not for epics came to be reported as a
# column work happens in. TKT-239, kept here rather than inline. TKT-252.
sub _ending_columns_everywhere {
    my ( $self, $root ) = @_;
    my %ends;
    for my $type (qw(sow epic ticket)) {
        my $mine = $self->_ending_columns( $root, $type );
        $ends{$_} = 1 for keys %{$mine};
    }
    return \%ends;
}

# The same answer, for anything outside this module that needs it. The push
# gate worked out where work ends for itself, from the column roles, and could
# not read a board that marks its ending instead of naming it - so it refused
# to run on one and judged finished cards as live work on another. The same
# shape as what a complete card is, which used to be written twice and is now
# asked for. TKT-267.
#
# Without --type this answered for one type only, with nothing in the output
# saying so - a bare list read as a fact about the whole board rather than
# one type's. On a board where epic marks 'archived' terminal and ticket
# marks only 'done', the typeless answer was ticket's alone, and a reader
# comparing it against the epic board would have declared a real ending
# column redundant. column_roles already answers the identical ambiguity by
# returning a hash keyed by all three types when none is named; this follows
# that precedent rather than inventing a third shape. TKT-342.
sub column_endings {
    my ( $self, %args ) = @_;

    if ( !defined $args{type} || $args{type} eq '' ) {
        my $root = $self->discover_project(%args);
        return { map { $_ => $self->column_endings( project => $root, type => $_ ) }
              qw(sow epic ticket) };
    }
    my $root = $self->discover_project(%args);
    return [ sort keys %{ $self->_ending_columns( $root, $args{type} ) } ];
}

# The columns work waits in.
#
# A board that has marked its queues answers with those. A board that has said
# nothing gets what it has always had - protected and not an ending - because a
# default is there to be right about the common case, not to be the only answer
# available. The same shape as the terminal default, and for the same reason.
#
# Named replaces assumed rather than adding to it: a board that has said which
# column is its queue has answered the question, and a backlog it did not name
# is not a second answer. TKT-310.
# Whether a waiting card should have been taken before the one being worked.
#
# The board orders work by priority and then by the card that has waited
# longest, and work_order has sorted by both since it was written. This rule
# compared only priority, so two cards at the same priority were never compared
# and the older one could be passed over indefinitely in silence.
#
# Measured on this board rather than reasoned: TKT-281, created 01:59:54, was
# worked before TKT-274, created 23:23:45 the night before, both at priority 3,
# and nothing was said. It is the TKT-274 shape surviving in the half nobody
# looked at - the command and the rule agreeing about which cards are waiting
# and disagreeing about which of two equals should have been taken. TKT-301.
sub _outranks_for_work {
    my ( $self, $above, $record ) = @_;
    my $theirs = $above->{priority}  // 0;
    my $ours   = $record->{priority} // 0;

    # The reason a caller gets back is which fact actually decided it, not
    # merely whether $above outranks - a message that only knows "priority"
    # printed two equal numbers and claimed one was above the other whenever
    # the tie-break below is what fired. TKT-391.
    return ( 1, 'priority' ) if $theirs > $ours;
    return ( 0, undef ) if $theirs < $ours;

    # Equal urgency, so the one that has waited longer should have gone first.
    # A card with no creation stamp is not treated as older, because an unknown
    # age is not evidence of anything and would report a tie nobody can settle.
    my $their_age = $above->{created_at}  // '';
    my $our_age   = $record->{created_at} // '';
    return ( 0, undef ) if $their_age eq '' || $our_age eq '';
    return $their_age lt $our_age ? ( 1, 'age' ) : ( 0, undef );
}

sub _queue_columns {
    my ( $self, $root, $type ) = @_;
    my $columns = eval { $self->column_list( project => $root, type => $type ) } || [];

    my %named = map { $_->{name} => 1 } grep { $_->{queue} } @{$columns};
    return \%named if %named;

    my $ends = $self->_ending_columns( $root, $type );
    return { map { $_->{name} => 1 }
          grep { $_->{protected} && !$ends->{ $_->{name} } } @{$columns} };
}

sub _ending_columns {
    my ( $self, $root, $type ) = @_;

    # This is one type's worth of columns, always - never asked to answer
    # for all three the way column_list itself now can with no --type. The
    # old guard assumed a bad type made column_list die, caught by the eval
    # below; TKT-409 gave a missing type a different, successful answer (a
    # hash keyed by type) instead, so a type-blind caller now gets past the
    # eval with something that was never an array to begin with. Checked
    # explicitly rather than relying on how column_list happens to fail.
    my $columns = eval { $self->column_list( project => $root, type => $type ) };
    $columns = [] if ref $columns ne 'ARRAY';
    my %ends = map { $_->{name} => 1 } grep { $_->{terminal} } @{$columns};

    # done is where work ends unless the board has said otherwise, and saying
    # something true about a different column is not saying otherwise.
    #
    # This used to be all-or-nothing: mark ONE column terminal and the
    # assumption switched off for every other, so every finished card on the
    # board became live work at once. Reported by mt5-ai, who paid 171
    # card-unassigned findings in a single pass for it and reverted; measured
    # here at 0 to 20 of 20. The flag has always had three values, so a board
    # that means it can still set done to not-terminal - it just has to say so,
    # which is the difference between a default and a trap. TKT-300.
    #
    # A board with no done column at all is a different question, and it is
    # where the first attempt at this got it wrong: t/238's board names its
    # ending 'shipped' and has no done, so assuming one put a column there that
    # does not exist. For those boards the old fallback stands - done only when
    # nothing else is marked - and it is a name rather than a column either way.
    my ($done) = grep { ( $_->{name} // '' ) eq 'done' } @{$columns};
    $ends{done} = 1 if $done ? !defined $done->{terminal} : !keys %ends;
    return \%ends;
}

# What each column says about how long is too long, in the form a policy age is
# written in. A column carries its limit in minutes and a watched flag, both set
# by tira.column.update; tira.stale has judged cards by them since they arrived
# and no rule ever has. An unwatched column answers undef, which means leave its
# cards alone however old they are - told apart from "no limit here" by the key
# existing at all.
sub _column_limits {
    my ( $self, $root, $type ) = @_;
    my $columns = eval { $self->column_list( project => $root, type => $type ) } || [];
    my %limit;
    for my $column ( @{$columns} ) {
        if ( !$column->{watched} ) {
            $limit{ $column->{name} } = undef;
            next;
        }
        $limit{ $column->{name} } = $column->{notify_after} . 'm'
          if defined $column->{notify_after};
    }
    return \%limit;
}

# When anything last happened to one card. The same stamp board-still reads for
# a whole board, and for the same reason: a field written, a comment, an answer,
# a checklist tick and a column move all touch it, so the newest of them is when
# the card last did anything. Kept as a method of its own so a test can replace
# it and show what measuring dwell instead would report.
sub _card_last_activity {
    my ( $self, $root, $record ) = @_;
    return $record->{last_updated};
}

# What to work next, which the board has always decided and never said.
#
# priority-skipped reports work taken out of turn, so it has to know which cards
# are waiting - in a column the board protects that is not an ending, carrying a
# priority - and which outranks which, 5 being the urgent end. That decision has
# been in the engine since the rule was written and no command asked it: a
# caller read every card on the board and sorted them by hand, 1.95 MB of JSON
# on this project's own board to find the eleven that were waiting.
#
# Asked by the rule as well as by the command, so the two cannot give different
# answers about the same board - which is the shape this project keeps finding
# and the reason this is a method rather than a second sort. TKT-274.
sub work_order {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);

    my @waiting;
    my %next_ref;
    for my $type (qw(sow epic ticket)) {
        next if defined $args{type} && $args{type} ne $type;
        my %here = %{ $self->_queue_columns( $root, $type ) };

        # His channel, not the agent's - "you do not add card on it. i will add
        # which cards on it." A card he moves there must come first, ahead of
        # priority, because it is a deliberate override of the board's own
        # ordering: the column's NAME is this project's own, so the board
        # declares which of its columns plays the role and this reads the role
        # rather than a name. TKT-383.
        #
        # Read per type, like %here beside it - roles are per board (per type),
        # so a 'next' declared on tickets says nothing about epics.
        my $next_col = $self->column_roles( project => $root, type => $type )->{next};

        # Discarded work is not waiting work. discard is protected and is not
        # an ending, so it answers "yes" to both halves of the question above -
        # which made every abandoned card part of the queue. Measured when 2.43
        # shipped: 15 of the 24 cards offered, and the one named as the answer.
        # Dropped here in the shape police already uses, so the command and the
        # rule are fixed once rather than twice. TKT-295.
        # Parked, not waiting. A card held on a question nobody has answered
        # cannot be started, and priority-skipped has refused to name one as
        # passed over since it was written - "parked, not skipped", in its own
        # words. The hold was already readable; this is the command reading it.
        #
        # Reported by Zenandi, who had a SOW under an explicit order not to be
        # worked and recorded the hold in seven prose key_details because they
        # could find nowhere better to put it. There is somewhere better and it
        # is not a new field: a question names the condition, and the answer
        # arriving is the release trigger. TKT-296.
        my $records = eval { $self->record_list( project => $root, type => $type ) } || [];
        push @waiting, grep {
            my $card = $_;    # named, because the inner grep rebinds $_
            defined $card->{priority}
              && $here{ $card->{column} // '' }
              && ( $card->{column} // '' ) ne 'discard'
              && !grep { !$_->{answer} } _policy_questions($card)
        } @{$records};

        # Recorded once per card while $next_col is in scope, rather than
        # re-deriving the type from the ref later - a card's type is not on the
        # summary record itself.
        $next_ref{ $_->{ref} } = 1
          for grep { defined $next_col && ( $_->{column} // '' ) eq $next_col } @{$records};
    }

    # The same projection the read commands take, when a caller asks for one.
    #
    # Measured on two boards independently: 94KB on mt5-ai's and 223,584 bytes
    # on Zenandi's - a fifth of a megabyte to answer "which ref", because the
    # answer carried every acceptance criterion and key detail of every card it
    # was chosen over. Their probes are on the cards: --brief, --field ref and
    # --fields ref were all refused here, and the --field refusal is the 2.42
    # mechanism working exactly as designed, which neither of them asked to
    # relax. What was missing is the projection itself. TKT-312, TKT-299.
    # Priority first, then the one that has waited longest - his correction,
    # and the order police enforces. Sorted BEFORE any projection, because the
    # sort reads priority, created_at and ref, and a caller asking for --field
    # ref would otherwise be ordering by fields it had just removed.
    my @ordered = sort {
        ( $next_ref{ $b->{ref} } ? 1 : 0 ) <=> ( $next_ref{ $a->{ref} } ? 1 : 0 )
          || $b->{priority} <=> $a->{priority}
          || ( $a->{created_at} // '' ) cmp( $b->{created_at} // '' )
          || ( $a->{ref} // '' ) cmp( $b->{ref} // '' )
    } @waiting;

    my $plan = _field_projection(%args);
    return \@ordered if !$plan && !$args{brief};

    return [ map {
        my $shown = _project_record( $_, $plan );
        _apply_brief_title($shown) if $args{brief};
        $shown;
    } @ordered ];
}

# The columns a card rule leaves alone: work has not started there, or it has
# ended there, or the board has said it does not want that column watched.
#
# The third was missing and cost a project nine reminders it could not act on.
# Zenandi set their review column to --no-watch, moved a card into it fourteen
# minutes later, and checklist-unmoved reported it two minutes after that -
# while card-still, declared at the same moment against the same column, said
# nothing, because card-still was the only rule that had ever read the flag.
#
# The flag has existed as long as columns have carried it and tira.stale has
# judged cards by it all along. Answering it here rather than in each rule is
# the point: fixing only the rule they happened to declare would have sent the
# next report about the next rule. TKT-287.
# Who last changed a card, from what the journal already records. The browser
# dashboard puts the signed-in person on every change it makes - that is what
# _attributed is for - so an edit made there carries an author and an edit made
# from the CLI does not. Nothing new is stored; this only reads it.
#
# A method rather than inline, so a test can replace it and so the one question
# has one answer. TKT-307.
# When the agent working this board last did anything, as distinct from when
# the board last changed. board-still reads the newest last_updated across
# every card, which a card arriving from another project refreshes - so on a
# board that receives reports, board-still is measuring somebody else's work.
#
# Two things count as the agent acting, both already recorded and neither
# inferred: a card changing column, and a card edited by the agent this board
# names. A card created or edited by another project is neither.
#
# A move is counted whoever made it. Moving a card through this board's columns
# IS working this board, and the browser is where the owner moves cards - so
# reading the author of a move would report a stopped agent on a board being
# worked by hand, which is the opposite of the point.
#
# A method rather than inline, so a test can replace it with the board-pulse
# measure and show the stoppage going unreported exactly as it did. TKT-359.
sub _agent_last_acted {
    my ( $self, $root, $all ) = @_;
    my $agent = eval { $self->project_show( project => $root )->{agent} } // '';
    # Newest first, so the bound below starts biting immediately rather than
    # after the whole board has been read.
    my $newest;
    for my $record ( sort { ( $b->{last_updated} // '' ) cmp( $a->{last_updated} // '' ) }
        @{$all} )
    {
        # A card's newest history entry cannot be later than its own
        # last_updated, so a card already older than the best answer so far
        # cannot improve on it and its history never has to be opened. On this
        # board that is the difference between reading 372 histories a pass and
        # reading a handful: most cards are finished and old, and a police pass
        # without this rule already costs 3.65s.
        next
          if defined $newest
          && defined $record->{last_updated}
          && $record->{last_updated} le $newest;

        my $entries = eval {
            $self->history_list( project => $root, ref => $record->{ref} );
        } || [];
        for my $entry ( @{$entries} ) {
            next if ref $entry ne 'HASH';
            my $at = $entry->{at};
            next if !defined $at;

            # field eq 'column' alone used to mean a real move, back when
            # record_move's own manual _journal_record call was the only way
            # to get one. create_record now writes the same field for a
            # card's starting column too (TKT-433), tagged op => 'create'
            # rather than 'move' precisely so the two stay distinguishable -
            # a card arriving, created directly into a column, is not an
            # agent moving anything, and must not count as agent action here
            # any more than a card arriving from another project already does.
            my $is_move = ( $entry->{field} // '' ) eq 'column' && ( $entry->{op} // '' ) eq 'move';
            my $by_agent = $agent ne ''
              && defined $entry->{author}
              && $entry->{author} eq $agent;
            next if !$is_move && !$by_agent;
            $newest = $at if !defined $newest || $at gt $newest;
        }
    }
    return $newest;
}

# Which agent this board says works it, asked in one place. The declaration
# guard and the evaluation both need it, and a rule that refuses a declaration
# on one reading and evaluates on another would be two decisions again - which
# is the fault TKT-306 and TKT-360 were raised for elsewhere in this file.
#
# A method rather than an inline read, so a test can answer the precondition and
# show the refusal is the guard rather than an accident. TKT-376.
sub _agent_declared_for {
    my ( $self, $root ) = @_;
    return eval { $self->project_show( project => $root )->{agent} };
}

sub _card_last_author {
    my ( $self, $root, $record ) = @_;
    my $entries = eval {
        $self->history_list( project => $root, ref => $record->{ref}, last => 1 );
    } || [];

    # history_list answers with a list, always - checked by running it rather
    # than assumed, after a defensive unwrap here cost a statement nothing could
    # reach and the push gate refused the release for it.
    my $newest = $entries->[-1];
    return undef if ref $newest ne 'HASH';
    my $author = $newest->{author};
    return undef if !defined $author || $author eq '';
    return { author => $author, field => $newest->{field}, at => $newest->{at} };
}

sub _resting_columns {
    my ( $self, $root, $type ) = @_;
    my $columns = eval { $self->column_list( project => $root, type => $type ) } || [];
    my %resting = map { $_->{name} => 1 }
      grep { $_->{protected} || $_->{terminal} || !$_->{watched} } @{$columns};

    # The same assumption as _ending_columns and for the same reason: one
    # column marked terminal is not a board withdrawing what it never said.
    # TKT-300.
    my ($done) = grep { ( $_->{name} // '' ) eq 'done' } @{$columns};
    $resting{done} = 1
      if $done ? !defined $done->{terminal}
      : !grep { $_->{terminal} } @{$columns};
    return \%resting;
}

# Whether a notification this board tries to send could actually arrive, asked as
# a question with an answer rather than discovered by it not happening.
#
# _send_notification returns 0 when either variable is missing - silently, by
# construction - so the move-notification feature shipped in 2.58, passed its
# tests, and never delivered a message. He asked about it twice; the second time:
# "This isn't the first time. Treat this like a problem to solve."
#
# Reads the setting through project_show, which does not write. TKT-349.
sub notification_delivery {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $setting = eval { $self->project_show( project => $root )->{notify_moves} } || {};

    my $token = $ENV{TELEGRAM_BOT_TOKEN};

    # The board first, the environment second. A board that has been told where
    # to send keeps working when nobody exports anything; a board that has not is
    # exactly as it was before, so nothing that relied on the variable breaks.
    my $chat = $setting->{chat};
    $chat = $ENV{TELEGRAM_CHATID} if !defined $chat || $chat eq '';

    return { deliverable => 0, reason => 'TELEGRAM_BOT_TOKEN is not set, so nothing can be sent' }
      if !defined $token || $token eq '';
    return {
        deliverable => 0,
        reason      => 'no destination is set - give this board one with'
          . ' tira.notify.moves --chat ID, or set TELEGRAM_CHATID'
    } if !defined $chat || $chat eq '';
    return { deliverable => 1, wanted => ( $setting->{enabled} ? 1 : 0 ) };
}

# Said only to a board that has asked for notifications and cannot receive them.
# A warning every board sees is one nobody reads, and this one must not fire
# where nothing was ever turned on.
sub _notification_notice {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $setting = eval { $self->project_show( project => $root )->{notify_moves} } || {};
    return '' if !$setting->{enabled};

    my $state = $self->notification_delivery( project => $root );
    return '' if $state->{deliverable};
    return "This board asks for notifications and cannot send them: $state->{reason}.\n"
      . "Nothing has been delivered and nothing was going to say so.\n";
}

sub police_prompt {
    my ( $self, %args ) = @_;
    my $prompt = $self->_police_prompt_text(%args);
    my $notice = $self->_notification_notice(%args);

    # Appended once, around every branch below, rather than written into each of
    # them - three copies of one sentence is three places for it to drift out of
    # step, which is the fault this file keeps raising cards about.
    return $notice ? $prompt . "\n" . $notice : $prompt;
}

sub _police_prompt_text {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my @declared = @{ $self->policy_list( project => $root ) };
    my @unused = @{ $self->policy_undeclared( project => $root ) };

    # A board that has finished setting up still hears that police is here.
    #
    # This returned undef, and the reasoning was sound as far as it went: there
    # is nothing left to ask, and a heading with an empty list under it is
    # worse than nothing. But nothing is also what a board gets when police has
    # died, when it cannot read the project, and when nobody started it - so a
    # fully configured board and a broken one produced identical output, which
    # is the fault this whole subsystem exists to prevent. The owner reported it
    # as police saying nothing after a restart, on a board with thirty policies
    # declared and none outstanding.
    #
    # So: no instructions, no empty heading, one line saying what is watching
    # and against how much. What it does NOT say is as deliberate as what it
    # does - a board that has finished being told what to do should not be told
    # again every sixty seconds.
    if ( @declared && !@unused ) {
        my $declined = eval { scalar @{ $self->policy_declined( project => $root ) } } // 0;
        return sprintf
          "Police is watching this board against %d declared %s%s, with no rule"
          . " left to declare. Nothing here needs setting up.\n",
          scalar @declared,
          ( @declared == 1 ? 'policy' : 'policies' ),
          ( $declined ? " and $declined declined" : '' );
    }

    my $reading = <<'READING';
  d2 tira.skills      - what Tira is and how a board is meant to be worked
  d2 tira.usage       - every command, every argument, and when to use it
  d2 tira.policies    - how enforcement works here, every rule, and a hundred
                        worked examples of what to set and why
READING

    # Who should be tailing the bridge. It said "you" for as long as there
    # was only ever one agent to say it to; in a chain the core agent reads it
    # and walks each line down to the card's manager, and telling the wrong
    # one is worse than telling nobody, because he acts on it.
    my $mode = $self->project_mode( project => $root );
    my $reader = ( $mode // '' ) eq 'chain'
      ? 'In a chain that is the core agent, which reads every line and walks it'
        . " down to the agent that owns the card."
      : 'That is the agent working the board.';

    my $questions = <<'QUESTIONS';
Group every question you have into ONE ticket in the backlog rather than asking
them one at a time. Each question carries the reason you are asking it and the
choices you can see, and attach a voice note to it as well - I answer from my
phone and a voice note is faster for both of us. I will pick that ticket up and
answer all of them together.
QUESTIONS

    if ( !@declared ) {
        return <<"FRESH";
Tira has an enforcement feature: policies say where a card must be and what it
must carry at each stage, and police - which I am running in my own terminal -
watches the board against them and tells you when something has drifted.

Nothing is set up on this project yet, so police is watching and finding
nothing. That silence is not compliance; it is an empty rulebook.

Bring yourself up to date first:

$reading
Then decide what this project actually needs and declare it. Do not copy
somebody else's set: the columns, the words and the gates here are ours, and a
rule written against a column we do not have protects nothing while looking
like it does.

When the policies are in place, start the bridge so police can reach you, and
keep it running the way you keep the Telegram bridge running - it is how you
hear about a violation without me telling you. $reader

  d2 tira.policy.bridge

$questions
FRESH
    }

    my $missing = join "\n", map {"  $_"} @unused;
    return <<"BEHIND";
Tira has been upgraded and the enforcement catalogue has grown. This project
has policies, but it was set up before some of the rules that now exist - and a
rule nobody has declared is silent in exactly the way a rule being obeyed is,
so nothing here will tell you they are missing except this.

Rules this project is not using:

$missing

Read what they do and what they are for before deciding:

$reading
Then declare the ones that fit how we work, with the columns and the words this
project actually uses. Leave out the ones that do not fit - a rule declared for
the sake of a full list is a rule that will be ignored, and that is worse than
not having it.

Keep the bridge running so police can reach you. $reader

  d2 tira.policy.bridge

$questions
BEHIND
}

sub police_pass {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A violation store is required\n";
    my $policies = eval { $self->policy_list(%args) } || [];

    # Move notifications first, and before the policies check: he asked for a
    # sentry rather than a rule, so a board that has declared no policies can
    # still tell its owner a card moved. TKT-349.
    $self->_announce_moves( $self->discover_project(%args), $args{store} );

    # A board nobody asked to be watched is not a board with no problems.
    # Running while guarding nothing would be worse than not running, because
    # the presence of a watcher reads as cover.
    return {
        watching => 0,
        violations => [],
        terminal => [],
        advice => 'No policies are set on this project, so police has nothing to follow. '
          . 'Ask the agent to set some: d2 tira.policy.add --rule <rule> --action bridge-reminder '
          . '(d2 tira.policies lists every rule and what it needs).',
    } if !@{$policies};

    my ( $found, $error );
    my @unreadable;
    my $ok = eval {
        my $records = $self->record_list( %args, include_discard => 1 );
        $found = [
            @{ $self->policy_evaluate( %args, unreadable => \@unreadable ) },
            @{ $self->_police_environment_violations(
                    %args, policies => $policies, records => $records ) },
        ];
        1;
    };
    if ( !$ok ) {
        # A board mid-write or a lock held for a moment is not a reason to die,
        # and it is not a reason to invent an answer either. Police guessing is
        # worse than police silent.
        $error = $@ || 'Unknown failure reading the board';
        $error =~ s/\s+\z//;
        $found = [];
    }

    # A card police cannot read is a fact about the board like any other, so it
    # goes through the ledger rather than around it.
    #
    # The first version of this printed to the owner's terminal on every pass.
    # On a board whose damaged byte is never going to be fixed - the report that
    # prompted all this is about somebody else's file, six days old - that is a
    # line every thirty seconds for ever. He read it back within the hour: "I
    # thought you have a workaround". The workaround worked; the telling of it
    # was the repetition a warning system dies of, added by the fix for a
    # silence.
    #
    # Through the ledger it gets what every other violation gets: a number, a
    # count of tellings, the quiet ladder, one escalation to his terminal, and a
    # settlement line if the card ever becomes readable again.
    # Two different facts, and they get two names, because "read it anyway" and
    # "could not read it" call for opposite things from whoever is reading.
    # card-damaged is a file to clean at leisure; card-unreadable is a card
    # nobody is checking right now.
    # Answered the same way every other rule is. These are assembled here rather
    # than reported through the rule loop, so they never met the suspension
    # check at all - and a command that accepted the name without this would
    # hand an agent a suspension that reported success and changed nothing,
    # which is worse than the refusal it replaced.
    my $quieted = $self->_enforcement_read($store);
    my $declined = eval { $self->policy_declined(%args) } || [];
    my %refused = map { ( $_->{rule} // '' ) => 1 } @{$declined};

    push @{$found}, grep { defined } map {
        my $rule = $_->{repaired} ? 'card-damaged' : 'card-unreadable';
        my $ref  = $_->{ref};
          $refused{$rule} ? undef
        : $self->_rule_suspended( $quieted, $rule, $ref ) ? undef
        : {
            rule   => $rule,
            ref    => $ref,
            action => 'bridge-reminder',
            detail => (
                $_->{repaired}
                ? $_->{reason}
                : "its history could not be read: $_->{reason}. "
                  . 'Every other card was still checked; nothing on this one was.'
            ),
        };
    } @unreadable;

    # A new Tira, said to the agent once.
    #
    # When a version is installed the owner gets the setup prompt in his own
    # terminal and the agent gets nothing - though the agent is the party that
    # has to read what changed, learn the commands that are new, and declare the
    # rules that arrived with them. A rule nobody has declared is silent in
    # exactly the way a rule being obeyed is, so an upgrade nobody mentions
    # leaves a board quietly running an older rulebook.
    #
    # Once per version rather than once per start, because police restarts in
    # order to pick a new version up, and a line written on every start would
    # arrive on a loop for as long as nobody upgraded again.
    # Newer, not merely different. A difference has two directions, and the
    # documented arrangement is two watchers - police in the owner's terminal
    # and a bridge the agent tails - each running a pass. When they were at
    # different versions each saw a value that was not its own, announced an
    # upgrade and wrote its own, so the record flipped and the notice arrived
    # for ever. Measured on this board with five watchers running: "Tira is now
    # 2.35 - this board last heard 2.34" at 23:16:42, and the exact reverse at
    # 23:16:51.
    #
    # A lock would be the wrong answer, because two watchers is the
    # arrangement. What the board records is the newest version any watcher has
    # announced; an older watcher is behind rather than upgraded, and has
    # nothing to say. TKT-273.
    # Each distinct change said once, rather than every difference said for ever.
    #
    # Comparing for difference was right for one watcher and wrong for two. The
    # documented arrangement is two - police in the owner's terminal and a
    # bridge the agent tails - and both run a pass, so when they were at
    # different versions each saw a value that was not its own, announced an
    # upgrade and wrote its own. Measured on this board with five watchers
    # running: "Tira is now 2.35 - this board last heard 2.34" at 23:16:42, and
    # the exact reverse at 23:16:51, still going eight minutes later.
    #
    # Announcing only a newer version would have been the obvious fix and was
    # wrong: a rollback deserves the same line, because the rules the agent
    # learned about may not be there any more - which t/175 asserts, having got
    # it wrong that way round once already.
    #
    # So the record is what has been said, not merely what was last seen. A
    # change from one version to another is news the first time; the same
    # change again is not. Two watchers taking turns say it twice and then stop,
    # and a genuine move to something this board has not been told about is
    # still announced. TKT-273.
    my $upgraded;
    {
        my $told = $quieted->{announced_version};
        my $said = $quieted->{announced_changes} ||= [];
        my $change = ( $told // '' ) . '>' . $VERSION;
        if ( ( $told // '' ) ne $VERSION && !grep { $_ eq $change } @{$said} ) {
            $upgraded = { to => $VERSION, ( defined $told ? ( from => $told ) : () ) };
            push @{$said}, $change;
            $quieted->{announced_version} = $VERSION;
            $self->_enforcement_write( $store, $quieted );
        }
        elsif ( ( $told // '' ) ne $VERSION ) {

            # Said before, so nothing is written to the agent - but the board
            # still records which version it is looking at, or the next genuine
            # change would be measured from the wrong place.
            $quieted->{announced_version} = $VERSION;
            $self->_enforcement_write( $store, $quieted );
        }
    }

    if ( $self->police_suspended( store => $store ) ) {
        return {
            watching => 1, suspended => 1, violations => [], terminal => [],
            ( $upgraded ? ( upgraded => $upgraded ) : () ),
        };
    }

    # A pass that failed has not established that anything stopped being true.
    #
    # An empty violation list means "everything that was open is now resolved",
    # and a pass that died hands back an empty list - so a crash announced every
    # open violation as fixed. On his board the last thing the dying pass ever
    # said was:
    #
    #     SETTLED | VIO-0018 | answer-ok-not-folded no longer applies here
    #     | fix: nothing - this one is over
    #
    # nine seconds after the rule that killed it was declared. Silence is
    # ambiguous; "this one is over" is a false statement, and it is worse.
    #
    # So a failed pass leaves the ledger where it is: nothing new is opened,
    # nothing open is closed, and what was true before the failure is still
    # what police believes.
    my ( $view, $settled ) = defined $error
      ? ( scalar $self->violation_record(
            store => $store, violations => $found, keep_open => 1 ), [] )
      : $self->violation_record( store => $store, violations => $found );

    # What police has said about a card belongs on that card, written by police
    # and by nobody else.
    $self->_enforcement_record( store => $store, kind => 'violation',
        ref => $_->{ref}, detail => "$_->{id} $_->{detail}" )
      for grep { $_->{seen} == 1 } @{$view};

    return {
        watching => 1,
        violations => $view,

        # What stopped being true on this pass. Handed back rather than left in
        # the ledger for somebody to notice, because the reader who was told
        # about it is the one who has to be told it is over.
        settled => $settled,
        # Only what the policy asked to be said out loud. Escalation decides
        # WHEN the owner is told; the action decides WHETHER. Without this a
        # rule set to log-only reached his terminal exactly like one set to
        # bridge-reminder - and log-only is what somebody reaches for precisely
        # when they do not want the noise, so it made noise in the one
        # situation it exists to avoid. The guide had promised otherwise, and
        # the comment beside the bridge filter had described this design for as
        # long as nothing implemented it.
        terminal => [
            (
                map  { $_->{terminal} }
                grep { $_->{escalate} && ( $_->{action} // '' ) ne 'log-only' } @{$view}
            ),

            (
                defined $error
                ? ( "police could not finish this pass: $error. "
                      . 'This is not a board with nothing wrong, it is a board that was not read.' )
                : ()
            ),
        ],

        # What could not be read, handed back beside what was. A pass that
        # skipped a card quietly would be the same fault as the one this
        # exists to end.
        #
        # A card read past a bad byte does not belong here: it was read, and
        # every rule judged it. It is reported as damaged instead, which is a
        # file to clean rather than a card nobody looked at.
        unreadable => [ grep { !$_->{repaired} } @unreadable ],

        # Read, with substitutions. Named so a caller can tell "clean this when
        # you get to it" from "this one was not checked".
        damaged => [ grep { $_->{repaired} } @unreadable ],

        # A version this board has not been told about. Handed back rather than
        # written here, because what reaches the agent is the bridge's business
        # and this decides only whether there is anything to say.
        ( $upgraded ? ( upgraded => $upgraded ) : () ),
        ( defined $error ? ( error => $error ) : () ),
    };
}

# A supervisor that dies quietly is worse than none at all, because its silence
# reads as everything being fine.
sub police_farewell {
    my ( $self, %args ) = @_;
    my $reason = $args{reason} // 'unknown';
    return "police is stopping: $reason. Nothing is watching this board now - "
      . 'no longer watching means no violations will be reported until it is started again.';
}

# The one-way channel. Police writes here, the agent tails it, nothing comes
# back. Same shape as the Telegram bridge, which is the pattern that already
# works on this machine.
#
# Every line is one line. An LLM reads these, so a paragraph costs tokens on
# every pass and gets skimmed rather than parsed - and a warning without a fix
# beside it is a warning that gets deferred.
sub bridge_log_path {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";
    make_path($store) if !-d $store;
    return File::Spec->catfile( $store, 'bridge.log' );
}

# The end of a violation, in the shape of the line that raised it so a reader
# scanning one column sees both. Its number is the number that was said, which
# is the only way to match a settlement to what it settles.
sub _bridge_settled_line {
    my ( $self, $done ) = @_;
    return join ' | ',
      $self->{clock}->(),
      'SETTLED',
      $self->_bridge_audience( $done->{assignee} ),
      $done->{id} // 'VIO-0000',
      ( ( $done->{ref} // '' ) ne '' ? $done->{ref} : 'board' ),
      'said ' . ( $done->{seen} // 0 ) . ' times',
      ( $done->{rule} // 'a rule' ) . ' no longer applies here',
      'fix: nothing - this one is over'
      . ( ( $done->{board} // '' ) ne '' ? " | board: $done->{board}" : '' );
}

sub _bridge_line {
    my ( $self, $violation ) = @_;
    my @parts = (
        $self->{clock}->(),
        uc( $violation->{tone} // 'note' ),

        # Whose it is, written into the line: the reader filters on what the
        # bridge says rather than going back to the board, so a card
        # reassigned afterwards does not rewrite what was already said.
        $self->_bridge_audience( $violation->{assignee} ),

        # The way down to the card, for the reader that has to walk it. In a
        # chain the core agent is the only one reading this, and it tells the
        # card's manager rather than the card's agent. Written now rather than
        # looked up later, so a card reparented afterwards does not rewrite
        # what was already said.
        ( defined $violation->{path} ? 'via ' . $violation->{path} : () ),
        $violation->{id} // 'VIO-0000',
        ( $violation->{ref} // '' ) ne '' ? $violation->{ref} : 'board',
        'seen ' . ( $violation->{seen} // 1 ),
        $violation->{message} // $violation->{detail} // $violation->{rule} // 'unspecified',
    );
    my $ref = $violation->{ref} // '';
    my $fix = _violation_fix($violation);

    # Whose board this is, last.
    #
    # Every board's enforcement store counts its own violations from one, so
    # VIO-0453 on one board and VIO-0453 on another are unrelated problems -
    # and on 2026-08-15 two people looked that number up, got different
    # answers, and had no way to notice. The number is not the fault: within a
    # board it does its job, which is that one lasting problem reads as one
    # problem getting louder rather than as noise repeating. What went wrong is
    # that it escaped the board - into reports, into questions between
    # projects, into what an agent pastes to its owner - and three projects
    # file into this board now.
    #
    # Last, because mt5-ai and developer-dashboard have both written tooling
    # against this line: a reader splitting the first N fields sees exactly
    # what it saw before.
    my $board = ( $violation->{board} // '' ) ne '' ? " | board: $violation->{board}" : '';
    return join( ' | ', @parts ) . " | fix: $fix$board";
}

# Which board a store belongs to, remembered when it is written and read back
# whenever a line is built. Kept beside the ledger rather than derived from the
# store's directory name, which is a slug of an absolute path and not something
# to show a reader.
sub _bridge_board {
    my ( $self, %args ) = @_;
    return $args{board} if ( $args{board} // '' ) ne '';
    my $store = $args{store} or return undef;
    my $ledger = eval { $self->_enforcement_read($store) } || {};
    return $ledger->{board};
}

# Who a bridge line is for, which is nobody.
#
# Every line used to carry "for <who>", inferred from the card - the assignee if
# there was one, "anyone" if there was not. He watched what that does: "it never
# guessed right, and when wrong the agent ignores it instead of inspecting it
# first." A wrong addressee does not merely fail to help, it gives every other
# reader a reason to skip the line, so a guess that was right most of the time
# would still cost more than it saves.
#
# Returning an empty list rather than deleting four call sites, so the shape of
# each line stays visible and a test can put the addressee back to prove that
# taking it out is what changed. Which reader a line REACHES is untouched: that
# is a different question and he asked about the words. TKT-308.
sub _bridge_audience {
    return ();
}

sub bridge_write {
    my ( $self, %args ) = @_;
    my $path = $self->bridge_log_path(%args);
    my @lines;

    # Remembered once, so everything read out of this store afterwards can say
    # whose it is - including a tail started long after this write, and a line
    # pasted into a conversation on another project's board.
    my $board = $args{board};
    if ( !defined $board && ( $args{project} // '' ) ne '' ) {
        $board = eval { $self->project_show( project => $args{project} )->{name} };
    }
    if ( defined $board && $args{store} ) {
        my $ledger = eval { $self->_enforcement_read( $args{store} ) } || {};
        if ( ( $ledger->{board} // '' ) ne $board ) {
            $ledger->{board} = $board;
            eval { $self->_enforcement_write( $args{store}, $ledger ) };
        }
    }

    # First, because it changes how everything under it should be read: a rule
    # that arrived with this version is one the board has not declared yet, and
    # its absence from the lines below is not evidence of anything.
    #
    # Addressed to the board's agent rather than to anyone. The owner already
    # has the setup prompt in his terminal; reading the changes, learning the
    # commands and filling the policy gaps are the agent's work, and a line
    # addressed to the wrong party is worse than none because somebody acts on
    # it. The three commands are named rather than described - a note saying
    # "Tira has been updated" and leaving the reader to work out what to run is
    # an interruption rather than an instruction.
    if ( my $upgraded = $args{upgraded} ) {
        my $agent = eval { $self->project_show( project => $args{project} )->{agent} };
        push @lines, join ' | ',
          $self->{clock}->(),
          'UPGRADE',
          $self->_bridge_audience( $agent ),
          'Tira is now ' . $upgraded->{to}
          . ( defined $upgraded->{from} ? " - this board last heard $upgraded->{from}" : '' )
          . '. Read what changed, learn what is new, and see which rules this'
          . ' board has still neither declared nor declined',
          'fix: d2 tira.changes; d2 tira.usage; d2 tira.policy.undeclared';
    }

    for my $violation ( @{ $args{violations} // [] } ) {
        # Only what the policy asked for reaches the agent. A rule set to
        # log-only is being tuned and stays out of the way; one set to
        # print-reminder belongs in the owner's terminal instead.
        next if ( $violation->{action} // '' ) ne 'bridge-reminder';

        # Not again yet. The problem is still true and police still reports it;
        # this is only about how often the bridge repeats itself, which is the
        # difference between a channel that is read and one that is skimmed.
        next if $violation->{quiet};

        # An agent that asked for quiet is not written to while it lasts. The
        # others are, because their work is not its business - and the owner
        # watching police in his own terminal sees everything either way.
        my $for = $violation->{assignee} // '';
        next if $for ne '' && $args{store}
          && $self->police_suspended( store => $args{store}, agent => $for );

        # The path is worked out here, once, where the project is still in
        # hand. A violation about no card at all carries none, because there
        # is nothing to walk down.
        my %about = %{$violation};
        if ( ( $about{ref} // '' ) ne '' ) {
            my $path = eval {
                $self->card_path( %args, project => $about{project} // $args{project},
                    ref => $about{ref} );
            } // [];
            my @above = @{$path}[ 0 .. $#{$path} - 1 ];
            $about{path} = @above ? join( ' > ', @above ) : 'nobody';
        }
        $about{board} = $board if defined $board;
        push @lines, $self->_bridge_line( \%about );
    }

    # And what has stopped being true. The line that raised it stays in the log
    # - the log is a record, and rewriting it would be worse - so the settlement
    # is said beside it, carrying the same number, and an agent replaying a
    # backlog can see the demand and its end together.
    #
    # No quiet ladder here. The ladder exists to stop a standing problem being
    # repeated; a settlement happens once and is the one thing that stops the
    # repetition, so delaying it would be delaying the good news.
    for my $done ( @{ $args{settled} // [] } ) {
        next if ( $done->{action} // '' ) ne 'bridge-reminder';
        my $for = $done->{assignee} // '';
        next if $for ne '' && $args{store}
          && $self->police_suspended( store => $args{store}, agent => $for );
        push @lines, $self->_bridge_settled_line(
            { %{$done}, ( defined $board ? ( board => $board ) : () ) } );
    }

    # Police may say when it is unsure. Guessing would make it wrong, and
    # silence would let an under-specified policy read as cover.
    for my $notice ( @{ $args{notices} // [] } ) {
        push @lines, join ' | ', $self->{clock}->(), 'UNRESOLVED',
          ( $notice->{kind} // 'unresolved' ), ( $notice->{detail} // '' ),
          'fix: make the policy specific, or ask the owner';
    }

    # A pass with nothing wrong writes nothing at all. Announcing that
    # everything is fine, every thirty seconds, is how a channel becomes noise.
    return 0 if !@lines;

    # And what is still open, said after whatever this pass had to say.
    #
    # His observation, and it is about how a channel is read rather than about
    # what is in it: "Most agents think the last settle statement as end and all
    # done and forget everything." A settlement is written in the same shape as
    # a violation and arrives last, so it reads as a closing statement - and an
    # agent that has just been told something is over stops looking. This board
    # had 84 violations outstanding while settlements were landing on the same
    # channel, and the agent reading it moved on.
    #
    # One line, counted first and named after, so a reader who has seen it
    # before can skim it. Nothing at all when the board is clear, because
    # silence has to go on meaning silence.
    #
    # Filtered exactly as the lines above it are, and for the same reasons: a
    # rule set to log-only is being tuned, an agent that asked for quiet is not
    # written to while it lasts, and a violation already held back stays held
    # back. A summary that reaches a reader the lines themselves do not is a
    # second channel nobody asked for - three tests said so at once.
    #
    # The rules and the cards, not the VIO numbers. Everything that reads this
    # log tells a violation line from a header by looking for VIO- in it, so a
    # summary carrying those numbers is counted as one more violation by every
    # reader there is - which three tests said at once. The numbers are one
    # command away and the line names it. TKT-277.
    if ( $args{store} ) {
        # Only what the policy asked to reach the bridge, the same filter the
        # violation lines above use. Without it a board whose rules are all
        # log-only - a policy being tuned, deliberately out of the way - starts
        # getting bridge lines about them, which t/150 caught immediately and
        # is exactly the promise this channel makes.
        my $outstanding = eval { $self->police_outstanding( store => $args{store} ) };
        my @open = grep {
            my $violation = $_;
            my $for = $violation->{assignee} // '';
            ( $violation->{action} // '' ) eq 'bridge-reminder'
              && !$violation->{quiet}
              && !( $for ne ''
                && $self->police_suspended( store => $args{store}, agent => $for ) );
        } @{ $outstanding || [] };
        # One tail per audience, addressed the way every other line is. A
        # summary addressed to nobody reaches everybody, including an agent
        # the lines themselves were kept from - which is what a reader of this
        # channel is entitled not to see. It also makes the line more useful:
        # what is still open for YOU, rather than for the board at large.
        my %by_audience;
        push @{ $by_audience{ $_->{assignee} // '' } }, $_ for @open;

        for my $who ( sort keys %by_audience ) {
            my @theirs = @{ $by_audience{$who} };
            push @lines, join ' | ', $self->{clock}->(), 'STILL OPEN',
              $self->_bridge_audience( $who ),
              scalar(@theirs) . ' violation(s) outstanding: '
              . join( ', ',
                map { ( $_->{rule} // '?' )
                      . ( ( $_->{ref} // '' ) ne '' ? " $_->{ref}" : ' (board)' ) }
                @theirs[ 0 .. ( $#theirs > 9 ? 9 : $#theirs ) ] )
              . ( @theirs > 10 ? ' and ' . ( @theirs - 10 ) . ' more' : '' ),
              'fix: d2 tira.police.outstanding';
        }
    }

    # Appended, and the file is recreated if it has been taken away - a stream
    # that stops silently leaves the agent believing all is well, which is the
    # worst failure this channel could have.
    # Bytes, deliberately, the way the YAML shim and the journal already write
    # them. This board is worked in English and in Cantonese, and the raw layer
    # with text printed straight into it warned "Wide character in print" on the
    # owner's own screen while police was running - eight times in one pass -
    # and wrote bytes nobody could read back. The raw layer stays: it is what
    # keeps this file byte-identical on every platform.
    open my $fh, '>>:raw', $path or die "Cannot write the bridge log: $!\n";
    print {$fh} map { encode_utf8("$_\n") } @lines;
    close $fh;
    return scalar @lines;
}

# What the bridge shows on arrival. An agent restarting its bridge must see
# what is already outstanding, not only what happens next.
# Reading the bridge leaves a mark, so that nobody reading it is a fact rather
# than an absence.
#
# Police raised a violation on this project, escalated it to urgent, and
# repeated it for two hours while nobody read the channel it was written to. The
# rule worked and the reader did not exist - and there was no way to observe
# that, because nothing recorded a read. A board with policies declared and an
# agent that does not tail the bridge is an unwatched board that looks watched.
#
# Stamped here rather than by a command somebody runs to say they have looked:
# asking for the backlog is what tailing the bridge does, so the mark is made by
# the reading rather than by a claim about it.
sub bridge_touch {
    my ( $self, %args ) = @_;
    my $store = $args{store} or return 0;
    my $log = $self->_enforcement_read($store);
    $log->{bridge_read_at} = $self->{clock}->();
    $self->_enforcement_write( $store, $log );
    return 1;
}

sub bridge_backlog {
    my ( $self, %args ) = @_;
    $self->bridge_touch(%args);
    my $path = $self->bridge_log_path(%args);
    return [] if !-f $path;
    open my $fh, '<:raw', $path or return [];
    my @lines = <$fh>;
    close $fh;
    chomp @lines;
    # Decoded back into text, because the file holds bytes. A line written in
    # Cantonese and read as bytes is a line the agent cannot match its own name
    # against, and a filter that quietly matches nothing is the worst thing this
    # channel could do. FB_QUIET rather than a die: a corrupted byte somewhere
    # in the log must not stop the agent hearing the rest of it.
    @lines = map { decode( 'UTF-8', $_, FB_QUIET ) } @lines;
    # An agent hears about its own cards, and about anything belonging to
    # nobody - filtering that loses the unowned card trades noise for silence,
    # which is worse, because nobody is watching it by definition. Naming no
    # agent hears everything, which is how the owner reads the board.
    #
    # Whose a line is comes from the store rather than from the words in the
    # line. It used to be read back out of "for <who>", which meant the one
    # thing he asked to have removed was also the thing doing the routing -
    # taking the words out would have quietly stopped every agent-scoped read
    # from filtering at all, and three tests caught exactly that. The store
    # already knows whose each violation is, so the reference in the line is
    # enough to ask. TKT-308.
    if ( defined $args{agent} && $args{agent} ne '' ) {
        my %whose;
        my $outstanding = eval { $self->police_outstanding( store => $args{store} ) };
        $whose{ $_->{id} // '' } = $_->{assignee} // ''
          for @{ $outstanding || [] };
        # Only what is still outstanding is looked up. A settled line says a
        # finding is over, and a reader hearing that about somebody else's card
        # is told nothing it has to act on - so there is no second lookup for
        # the settled log, and the four statements that did it are gone.
        # The summary tail carries no VIO id on purpose - every reader tells a
        # violation line from a header by looking for VIO-, so putting one
        # there would have every reader counting the summary as one more
        # violation (TKT-277). It names rules and cards instead, so it is
        # routed on the cards it names: a tail listing nothing of this agent's
        # is a tail built for somebody else.
        my %card_of;
        push @{ $card_of{ $_->{ref} // '' } }, $_->{assignee} // ''
          for @{ $outstanding || [] };

        @lines = grep {
            my $line = $_;
            my ($id) = $line =~ /\b(VIO-\d+)\b/;
            if ( defined $id ) {
                my $for = $whose{$id} // '';
                $for eq '' || $for eq $args{agent};
            }
            elsif ( $line =~ /STILL OPEN/ ) {
                my @named = grep { exists $card_of{$_} }
                  ( $line =~ /\b([A-Z][A-Z0-9]*-\d+)\b/g );
                !@named || grep {
                    my $ref = $_;
                    grep { $_ eq '' || $_ eq $args{agent} } @{ $card_of{$ref} };
                } @named;
            }
            else { 1 }
        } @lines;
    }

    my $wanted = $args{lines} // 20;
    splice @lines, 0, @lines - $wanted if @lines > $wanted;
    return \@lines if !@lines;

    # What this pile is, before the pile. A bridge prints what is outstanding
    # and then live traffic with nothing between them, so old lines about cards
    # that have moved on read as a storm of new violations - and the project
    # that asked for this had already filed a false report from exactly that,
    # and offered it as the evidence.
    #
    # A settlement line says a violation stopped being true. It does not say
    # that the twelve lines in front of you are history. Fixing the buffering
    # made this matter more rather than less, because now the backlogs get read
    # and an agent restarting a bridge meets its worst moment first.
    #
    # One line, not a mark on every line: an agent parses these, and changing
    # the shape of all of them for a distinction that only matters at the
    # boundary costs more than it settles. The count is what this reader will
    # actually see, because a number about somebody else's work is worse than
    # no number.
    my ( $oldest, $newest ) = ( $lines[0], $lines[-1] );
    ($oldest) = $oldest =~ /\A(\S+)/;
    ($newest) = $newest =~ /\A(\S+)/;
    my $span = ( $oldest // '' ) eq ( $newest // '' )
      ? "at $oldest" : "between $oldest and $newest";
    # The board, in the line that introduces the replay, so a tail pasted into a
    # conversation carries its own identity from its first line.
    #
    # Read from the store rather than passed in: bridge_backlog is called by a
    # tail that may have been started long after the board was last written to.
    my $whose = $self->_bridge_board(%args);
    $whose = ( $whose // '' ) ne '' ? " on $whose" : '';
    unshift @lines, sprintf 'replaying %d outstanding violation%s%s raised %s - '
      . 'this is history, not new traffic',
      scalar @lines, ( @lines == 1 ? '' : 's' ), $whose, $span;

    return \@lines;
}

# The smaller config is king. A policy declared on a card beats one on its
# column, which beats one on its board, which beats one on the project.
#
# Resolution is per RULE rather than per list: a card that overrides one rule
# keeps every other rule the project declared. The alternative would let a
# single exception switch everything else off, which is exactly the class of
# quiet failure this subsystem exists to catch.
sub _policy_specificity {
    my ($policy) = @_;
    return 3 if defined $policy->{ref} && $policy->{ref} ne '';
    return 2 if defined $policy->{on_column} && $policy->{on_column} ne '';
    return 1 if defined $policy->{type} && $policy->{type} ne '';
    return 0;
}

sub _policy_applies_to {
    my ( $policy, $record ) = @_;
    return 0 if defined $policy->{ref} && $policy->{ref} ne ''
      && $policy->{ref} ne ( $record->{ref} // '' );
    return 0 if defined $policy->{type} && $policy->{type} ne ''
      && $policy->{type} ne ( $record->{type} // '' );
    return 0 if defined $policy->{on_column} && $policy->{on_column} ne ''
      && $policy->{on_column} ne ( $record->{column} // '' );
    return 1;
}

sub policy_resolve {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $record = $args{record};
    if ( !$record && defined $args{ref} ) {
        $record = eval { $self->record_show( project => $root, ref => $args{ref} ) };
    }
    return [] if !$record;

    my %winner;
    for my $policy ( @{ $self->policy_list( project => $root ) } ) {
        next if !_policy_applies_to( $policy, $record );
        my $rule = $policy->{rule};
        my $rank = _policy_specificity($policy);
        next if exists $winner{$rule} && _policy_specificity( $winner{$rule} ) > $rank;
        $winner{$rule} = $policy;
    }
    return [ map { $winner{$_} } sort keys %winner ];
}

# What police could not work out. Guessing would make it wrong and silence
# would let an under-specified policy read as cover, so it says so instead.
sub policy_unresolved {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my @unresolved;
    for my $policy ( @{ $self->policy_list( project => $root ) } ) {

        # This one asks the board which column means finished, and a board that
        # has never said cannot be guessed at. Reported here rather than left
        # to match nothing quietly, which is how a rule somebody believes in
        # protects nothing at all.
        if ( ( $policy->{rule} // '' ) eq 'parent-ahead-of-children' ) {
            my @named = grep {
                my $roles = eval { $self->column_roles( project => $root, type => $_ ) } || {};
                defined $roles->{done} && $roles->{done} ne '';
            } ( defined $policy->{type} && $policy->{type} ne ''
                ? ( $policy->{type} ) : qw(sow epic ticket) );
            push @unresolved, {
                policy => $policy->{id},
                detail => "$policy->{id} cannot tell which column means finished on this board. "
                  . 'Say so once: tira.column.roles --type ticket --role done=COLUMN',
            } if !@named;
        }

        for my $field ( qw(enter before column on_column), @POLICY_ROLE_FIELDS ) {
            my $wanted = $policy->{$field};
            next if !defined $wanted || $wanted eq '';
            my $is_role = $field =~ /_role\z/;
            my $seen = 0;
            if ($is_role) {
                for my $type ( defined $policy->{type} && $policy->{type} ne ''
                    ? ( $policy->{type} ) : qw(sow epic ticket) )
                {
                    my $roles = eval { $self->column_roles( project => $root, type => $type ) } || {};
                    $seen = 1 if exists $roles->{$wanted};
                }
                next if $seen;
                push @unresolved, {
                    policy => $policy->{id},
                    detail => "$policy->{id} names a role no column carries: $wanted"
                      . " (--$field). Say which column plays it with tira.column.roles.",
                };
                next;
            }
            for my $type ( defined $policy->{type} && $policy->{type} ne ''
                ? ( $policy->{type} ) : qw(sow epic ticket) )
            {
                my $columns = eval { $self->column_list( project => $root, type => $type ) } || [];
                $seen = 1 if grep { $_->{name} eq $wanted } @{$columns};
            }
            next if $seen;
            push @unresolved, {
                policy => $policy->{id},
                detail => "$policy->{id} names a column that is not on this board: $wanted"
                  . " (--$field). Name a column that exists, or add it.",
            };
        }
    }
    return \@unresolved;
}

# Finished, in the board's own word for it. Discard counts too: discarding is a
# decision, not unfinished work. A board that has never said which of its
# columns means finished is not guessed at - the policy is reported as
# unresolved instead, so the silence is visible.
sub _policy_settled {
    my ( $self, $root, $record ) = @_;
    my $column = $record->{column} // '';
    return 1 if $column eq 'discard';
    my $roles = eval { $self->column_roles( project => $root, type => $record->{type} ) } || {};
    my $finished = $roles->{done};
    return 0 if !defined $finished || $finished eq '';
    return $column eq $finished ? 1 : 0;
}

# Which column is the backlog, which is in progress, which is deployed to
# production. A rule that names a column outright is tied to one board's
# vocabulary - it says nothing on a project that uses different words, and
# nothing at all the moment somebody renames the column. A role follows the
# meaning instead.
#
# The vocabulary belongs to the project. Tira matches a role without needing to
# understand it, and anything police must say about a card going forwards or
# backwards comes from the column order rather than from the role's name.
sub column_roles {
    my ( $self, %args ) = @_;

    # Columns are per board, so roles are too - but "which column is the
    # backlog" has an answer for every board, and there is no reason to make
    # somebody name one to ask it. Without a board, it answers for all three.
    if ( !defined $args{type} || $args{type} eq '' ) {
        my $root = $self->discover_project(%args);
        return { map { $_ => $self->column_roles( project => $root, type => $_ ) }
              qw(sow epic ticket) };
    }
    my ( undef, $config ) = $self->_board_data(%args);
    return $config->{roles} // {};
}

# Taking a role back, which nothing could do. column_roles_set merges what it is
# given into what is there and never deletes, so a role declared by mistake was
# permanent: an empty value is refused as malformed rather than read as a
# removal. I proved that by making the mistake - a probe put 'nonsense=backlog'
# on the live board - and undoing one command meant editing .tira by hand.
#
# It matters more since roles became load-bearing: he asked for the card to work
# next to be chosen by a column HE picks, and pointed out the column's name is
# this project's own, so the board declares which of its columns means it. A
# vocabulary the board cannot correct is a worse thing to depend on than one it
# can. TKT-384.
sub column_roles_remove {
    my ( $self, %args ) = @_;
    my @wanted = @{ $args{roles} || [] };

    # The same promise the setter makes, for the same reason: reading without
    # naming a board is a convenience, writing to one nobody named is a surprise.
    die "Which board? Roles are per board, because columns are.\n"
      . "  tira.column.roles --type ticket "
      . join( ' ', map {"--remove-role $_"} sort @wanted ) . "\n"
      if !defined $args{type} || $args{type} eq '';

    # His requirement, and the same one rule.suspend already makes: "if they do,
    # they need to provide a reason for it and there will be a column logs to log
    # that reason. who and why." A role leaving a board's vocabulary changes what
    # every policy written against it means, so it is accountable in the way
    # putting a rule down is - a change nobody can account for is worse than the
    # mistake it corrects.
    my $reason = $args{reason};
    die "A reason is required - a role leaving a board's vocabulary changes what "
      . "every policy naming it means, and a change nobody can account for is worse "
      . "than the mistake it corrects\n"
      if !defined $reason || $reason eq '';

    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( %args, project => $root );
        my $roles = $config->{roles} // {};

        for my $role (@wanted) {

            # Refused rather than succeeding quietly, so a typo in the REMOVAL
            # cannot read as a removal that worked.
            die "No role named '$role' on this board, so there is nothing to remove\n"
              if !exists $roles->{$role};

            # And not out from under a policy. A policy whose role stops
            # existing matches nothing at all, silently, which is exactly what
            # the declaration guard refuses in the other direction.
            for my $policy ( @{ $self->policy_list( project => $root ) } ) {
                for my $field (@POLICY_ROLE_FIELDS) {
                    next if ( $policy->{$field} // '' ) ne $role;
                    die "Policy $policy->{id} names the role '$role', and a policy whose "
                      . "role stops existing matches nothing at all. Remove the policy "
                      . "first:\n  tira.policy.remove --id $policy->{id}\n";
                }
            }
        }

        # Who and why, beside the roles themselves so the board carries its own
        # account rather than depending on a police store that a board may not
        # have. Appended, never replaced: a log that can be rewritten is not one.
        push @{ $config->{role_log} }, {
            at     => $self->{clock}->(),
            author => ( defined $args{author} && $args{author} ne '' ? $args{author} : 'nobody' ),
            role   => $_,
            column => $roles->{$_},
            reason => $reason,
        } for @wanted;

        delete $roles->{$_} for @wanted;
        $config->{roles} = $roles;
        $self->_write_yaml( $path, $config );
        return $config->{roles};
    } );
}

# What was taken out of this board's vocabulary, and why. Read-only, and empty
# rather than absent on a board nothing has been removed from. TKT-384.
sub column_role_log {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my ( undef, $config ) = $self->_board_data( %args, project => $root );
    return $config->{role_log} // [];
}

sub column_roles_set {
    my ( $self, %args ) = @_;
    my $wanted = $args{roles} || {};

    # Reading without naming a board is a convenience. Writing to one nobody
    # named is a surprise, so it is refused - and the refusal is a command that
    # can be run as it stands rather than the name of an argument.
    die "Which board? Roles are per board, because columns are.\n"
      . "  tira.column.roles --type ticket "
      . join( ' ', map {"--role $_=$wanted->{$_}"} sort keys %{$wanted} ) . "\n"
      if !defined $args{type} || $args{type} eq '';
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $config ) = $self->_board_data( %args, project => $root );
        my %columns = map { $_->{name} => 1 } @{ $config->{columns} };

        # A role pointing at nothing would make every rule written against it
        # match nothing at all, silently, while somebody believed it was
        # protecting them. Refusing is the only safe answer.
        for my $role ( sort keys %{$wanted} ) {
            my $column = $wanted->{$role};
            die "No column named '$column' on this board, so '$role' cannot mean it\n"
              if !$columns{ $column // '' };
        }

        $config->{roles} = { %{ $config->{roles} // {} }, %{$wanted} };
        $self->_write_yaml( $path, $config );
        return $config->{roles};
    } );
}

# A rule may name a column or a role. Naming a role is resolved here, once,
# rather than in every rule that accepts one.
sub _policy_column_for {
    my ( $self, %args ) = @_;
    my ( $policy, $field, $record ) = @args{qw(policy field record)};
    my $role = $policy->{"${field}_role"};
    return $policy->{$field} if !defined $role || $role eq '';
    my $roles = eval {
        $self->column_roles( project => $args{project}, type => $record->{type} );
    } || {};
    return $roles->{$role};
}

# Asking police to look away, without anybody losing sight of the fact that it
# was asked. There is no open-ended off switch: a duration is required, the
# ceiling is short, and enforcement resumes on its own with nothing to
# remember and nothing to undo.
#
# The escape hatch is the part most likely to be abused, and by the agent. A
# ceiling alone is defeated by asking again the moment each one expires, so a
# renewal inside the hour is an event in its own right and the running total
# makes a pattern visible - without ever blocking work, because an obstacle
# gets worked around and this must not become one.
our $SUSPENSION_CEILING_SECONDS = 600;
our $SUSPENSION_REASON_LIMIT = 500;

sub _enforcement_path {
    my ( $self, $store ) = @_;
    make_path($store) if !-d $store;
    return File::Spec->catfile( $store, 'enforcement.json' );
}

sub _enforcement_read {
    my ( $self, $store ) = @_;
    my $path = $self->_enforcement_path($store);
    return { entries => [], suspended_until => undef } if !-f $path;
    open my $fh, '<:raw', $path or return { entries => [], suspended_until => undef };
    my $content = do { local $/; <$fh> };
    close $fh;
    my $log = eval { json_decode($content) };
    return ref $log eq 'HASH' ? $log : { entries => [], suspended_until => undef };
}

sub _enforcement_write {
    my ( $self, $store, $log ) = @_;
    $self->_atomic_write( $self->_enforcement_path($store),
        json_object()->canonical->encode($log) );
    return 1;
}

# Police writes here and nobody else does. There is deliberately no command to
# add, change or remove an entry: a log that exists to hold somebody to account
# cannot be one they can write, and that includes the agent's own words about
# its own suspension, which reach the record through police rather than around
# it.
sub _enforcement_record {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";
    my $log = $self->_enforcement_read($store);
    push @{ $log->{entries} }, {
        at => $self->{clock}->(),
        kind => $args{kind},
        ref => $args{ref} // '',
        detail => $args{detail} // '',
    };
    $self->_enforcement_write( $store, $log );
    return 1;
}

# What is still true, asked as a question.
#
# The bridge is a stream and is right to be one, but a stream can only be read
# from where you joined it: it replays everything on connect and repeats each
# finding as it climbs its ladder, so what is outstanding sits buried in
# history and repetition. The enforcement log is flat - every row is something
# that happened, and nothing on a row says whether it is still true.
#
# So the question could not be asked and therefore was not. Measured on this
# project's own board the night this was written: one finding open for two and
# a half hours, escalated from note to critical, read four times and acted on
# never, and the outstanding set looked at for the first time only because the
# owner asked why. An answer that depends on somebody remembering to look is
# the thing this whole subsystem exists to remove. TKT-237.
#
# One entry per finding rather than one per telling, carrying what it is about,
# how many times it has been said, when it started and how loud it has become -
# an hour-old finding reads differently from a new one, and the difference is
# the whole reason to ask.
sub police_outstanding {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";
    my $ledger = $self->_violation_ledger($store);
    my @open;
    for my $key ( sort keys %{ $ledger->{open} // {} } ) {
        my $entry = $ledger->{open}{$key};
        push @open, {
            id => $entry->{id},
            rule => $entry->{about}{rule},
            ref => $entry->{about}{ref} // '',
            assignee => $entry->{about}{assignee} // '',
            action => $entry->{about}{action} // '',
            seen => $entry->{seen},
            tone => $entry->{tone},
            first_seen => $entry->{first_seen},
            last_seen => $entry->{last_seen},
        };
    }
    return \@open;
}

# When the answer above was last true. Undefined on a board no pass has ever
# touched, which is the case that most needs saying: an empty list of findings
# and a board nobody has policed are the same list, and only this tells them
# apart.
#
# A method rather than a field read inline, so a test can take it away and show
# a board fixed half an hour ago reading exactly like one that was never
# checked. TKT-378.
sub police_outstanding_taken_at {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";
    return $self->_violation_ledger($store)->{last_pass};
}

sub enforcement_log {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";
    my $log = $self->_enforcement_read($store);
    my $wanted = $args{ref};
    return [ grep { !defined $wanted || ( $_->{ref} // '' ) eq $wanted }
             @{ $log->{entries} // [] } ];
}

# Putting one rule down for a while, instead of going deaf to everything.
#
# police.suspend quiets police entirely, which is right when an agent needs to
# concentrate and wrong when one rule is chasing one card. A card being worked
# hard collects comments faster than anybody can fold them, and silencing the
# whole bridge to get through that afternoon makes the escape hatch worse than
# the noise it escapes.
#
# The same promises as police.suspend, for the same reasons: an end that arrives
# by itself, so there is nothing to remember to switch back on, and a reason
# that cannot be skipped, because a silence nobody can account for is worse than
# the noise it replaces.
sub rule_suspend {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";

    my $rule = $args{rule};
    die "Which rule? Name it: --rule <rule>\n" if !defined $rule || $rule eq '';
    die "Unknown policy rule '$rule'. Rules: " . join( ', ', @{ answerable_rules() } ) . "\n"
      if !$POLICY_RULES{$rule} && !$DIAGNOSTIC_RULES{$rule};

    my $seconds = $args{seconds};
    die "How many seconds? A rule put down has to come back by itself\n"
      if !defined $seconds || $seconds !~ /\A\d+\z/ || $seconds == 0;
    die "Putting a rule down for $seconds seconds is past the ceiling of "
      . "$SUSPENSION_CEILING_SECONDS (ten minutes)\n"
      if $seconds > $SUSPENSION_CEILING_SECONDS;

    my $reason = $args{reason};
    die "A reason is required - a silence nobody can account for is worse than the noise\n"
      if !defined $reason || $reason eq '';
    die 'A reason must be at most ' . $SUSPENSION_REASON_LIMIT . " characters\n"
      if length($reason) > $SUSPENSION_REASON_LIMIT;

    my $ref = $args{ref} // '';
    my $at = _epoch_of_datetime( $self->{clock}->(), 'Clock' );
    my $until = _iso_from_epoch( $at + $seconds );

    my $log = $self->_enforcement_read($store);

    # Kept by rule, and within a rule by card. A rule put down for one card must
    # leave the same rule watching every other card, which is the grain that
    # makes this worth having at all.
    $log->{rules}{$rule}{ $ref eq '' ? '' : $ref } = $until;
    $self->_enforcement_write( $store, $log );

    $self->_enforcement_record(
        store  => $store,
        kind   => 'rule-suspension',
        ref    => $ref,
        detail => "$rule "
          . ( $ref eq '' ? 'on this board' : "on $ref" )
          . " for ${seconds}s: $reason",
    );

    return { rule => $rule, ref => $ref, until => $until, reason => $reason };
}

# Whether a rule is down for this card, or for the board. Asked once per rule
# per pass rather than per violation, because a rule that is down has nothing to
# say and working that out for every card it would have reported is waste.
sub _rule_suspended {
    my ( $self, $log, $rule, $ref ) = @_;
    my $down = $log->{rules}{$rule} or return 0;
    my $now = eval { _epoch_of_datetime( $self->{clock}->(), 'Clock' ) } // return 0;
    for my $scope ( '', ( defined $ref && $ref ne '' ? $ref : () ) ) {
        my $until = $down->{$scope} or next;
        my $ends = eval { _epoch_of_datetime( $until, 'Stamp' ) } // next;
        return 1 if $now < $ends;
    }
    return 0;
}

sub police_suspend {
    my ( $self, %args ) = @_;
    my $store = $args{store} or die "A police store is required\n";
    my $seconds = $args{seconds};
    die "How many seconds? A suspension has to end by itself\n"
      if !defined $seconds || $seconds !~ /\A\d+\z/ || $seconds == 0;
    die "A suspension of $seconds seconds is past the ceiling of "
      . "$SUSPENSION_CEILING_SECONDS (ten minutes)\n"
      if $seconds > $SUSPENSION_CEILING_SECONDS;

    my $reason = $args{reason};
    die "A reason is required - a silence nobody can account for is worse than the noise\n"
      if !defined $reason || $reason eq '';
    die 'A reason must be at most ' . $SUSPENSION_REASON_LIMIT
      . " characters, and is not trimmed for you\n"
      if length($reason) > $SUSPENSION_REASON_LIMIT;

    my $now = $self->{clock}->();
    my $at = _epoch_of_datetime( $now, 'Clock' );
    my $log = $self->_enforcement_read($store);

    # A renewal is any suspension asked for within the hour of the last one.
    my ($previous) = grep { ( $_->{kind} // '' ) eq 'suspension' }
      reverse @{ $log->{entries} // [] };
    my $renewal = 0;
    my $quiet_so_far = 0;
    if ($previous) {
        my $then = eval { _epoch_of_datetime( $previous->{at}, 'Stamp' ) };
        $renewal = 1 if defined $then && $at - $then <= 3600;
    }
    for my $entry ( @{ $log->{entries} // [] } ) {
        next if ( $entry->{kind} // '' ) ne 'suspension';
        my $then = eval { _epoch_of_datetime( $entry->{at}, 'Stamp' ) } // next;
        next if $at - $then > 86_400;
        $quiet_so_far += $1 if ( $entry->{detail} // '' ) =~ /(\d+)s\b/;
    }
    $quiet_so_far += $seconds;

    my $until = _iso_from_epoch( $at + $seconds );

    # Quiet belongs to the agent that asked for it. One agent per ticket means
    # a board-wide switch lets one agent stop the others being told about their
    # own work, which is the opposite of what an escape hatch is for. A
    # suspension with nobody named is still board-wide, because that is what it
    # meant before anybody was named and somebody may be relying on it.
    if ( defined $args{author} && $args{author} ne '' ) {
        $log->{suspended}{ $args{author} } = $until;
    }
    else {
        $log->{suspended_until} = $until;
    }
    $self->_enforcement_write( $store, $log );
    $self->_enforcement_record(
        store => $store, kind => 'suspension', ref => $args{ref},
        detail => "${seconds}s: $reason" );

    my $terminal = join ' | ', $now,
      ( $renewal ? 'SUSPENSION RENEWAL' : 'SUSPENSION' ),
      "${seconds}s until $until", $reason,
      "quiet time in the last day: ${quiet_so_far}s";

    return {
        seconds => $seconds, until => $until, reason => $reason,
        renewal => $renewal, quiet_seconds_today => $quiet_so_far,
        terminal => $terminal,
    };
}

sub police_suspended {
    my ( $self, %args ) = @_;
    my $store = $args{store} or return 0;
    my $log = $self->_enforcement_read($store);

    # Asked about an agent: only that agent's own quiet counts. Asked about
    # nobody: only a board-wide suspension counts, so one agent going quiet
    # never reads as the board going quiet.
    my $until = defined $args{agent} && $args{agent} ne ''
      ? ( $log->{suspended}{ $args{agent} } // $log->{suspended_until} )
      : $log->{suspended_until};
    $until or return 0;
    my $now = eval { _epoch_of_datetime( $self->{clock}->(), 'Clock' ) } // return 0;
    my $ends = eval { _epoch_of_datetime( $until, 'Stamp' ) } // return 0;
    return $now < $ends ? 1 : 0;
}

sub _iso_from_epoch {
    my ($epoch) = @_;

    # The same offset arithmetic _now uses for every other timestamp this
    # project writes, so rule.suspend's and rule.decline's 'until' field
    # reads in the board's own convention instead of a second one nobody
    # chose - gmtime and a literal Z were the only place this project ever
    # answered "when" in a timezone different from the one it runs in.
    # TKT-419.
    my @local = localtime $epoch;
    my $seconds = timegm_modern( @local[ 0 .. 4 ], $local[5] + 1900 ) - $epoch;
    my $minutes = int( $seconds / 60 + ( $seconds < 0 ? -0.5 : 0.5 ) );
    my $sign = $minutes < 0 ? '-' : '+';
    $minutes = abs $minutes;
    return strftime( '%Y-%m-%dT%H:%M:%S', @local )
      . sprintf( '%s%02d%02d', $sign, int( $minutes / 60 ), $minutes % 60 );
}

# The gates a project runs, written by Tira rather than by each agent that
# adopts it. They lived as shell scripts in one repository on one machine,
# which is scaffolding: another project got none of it, and another agent
# writing its own would get it subtly different.
#
# Everything they call is a Tira command, so an installed gate works on a
# machine that has never seen this repository.
my $COMMIT_GATE = <<'HOOK';
#!/usr/bin/env bash
#
# A commit must name the card it belongs to, and that card must be somewhere
# that means "being worked on".
#
# The push gate catches a board that has drifted, but hours after the drift
# began. A commit is the frequent, unavoidable moment - so this is where the
# board is forced to be current. If the work is real enough to commit, the card
# is real enough to have been moved.
#
# Installed by: d2 tira.gates.install
set -euo pipefail

message="$(cat "$1")"

case "$message" in
  Merge\ *|Revert\ *|fixup!\ *|squash!\ *) exit 0 ;;
esac

# Prefixes belong to the project, not to Tira. Hard-coding this project's
# own three meant the gate refused every commit on a board that names its
# boards anything else - which is the whole difference between scaffolding
# and a product, and it only showed up by installing it somewhere real.
refs="$(grep -oE '\b[A-Z][A-Z0-9]*-[0-9]{3,}\b' <<<"$message" | sort -u || true)"
if [ -z "$refs" ]; then
  echo "commit-msg: name the card this commit belongs to, e.g. TKT-001." >&2
  echo "A commit with no card is work the board cannot account for." >&2
  exit 1
fi

command -v d2 >/dev/null || {
  echo "commit-msg: d2 is not on PATH, so the card cannot be checked - refusing rather than skipping." >&2
  exit 1
}

named=0
for ref in $refs; do
  card=""
  kind=""
  # Which board a reference belongs to is the board's business. Asking each in
  # turn costs three calls and works on every project.
  for try in ticket epic sow; do
    found="$(d2 "tira.$try.show" --ref "$ref" -o json 2>/dev/null || true)"
    if [ -n "$found" ] && ! grep -q '"error"' <<<"$found"; then
      card="$found"; kind="$try"; break
    fi
  done
  if [ -z "$card" ]; then
    continue    # not a card on this board; somebody's issue tracker, or a version
  fi
  named=1
  column="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("column",""))' <<<"$card")"
  case "$column" in
    backlog|discard|done)
      echo "commit-msg: $ref is in '$column'." >&2
      echo "Move it to the gate the work is at before committing against it:" >&2
      echo "  d2 tira.$kind.move --ref $ref --column implement" >&2
      exit 1
      ;;
  esac
done

if [ "$named" = "0" ]; then
  echo "commit-msg: none of the references in this message are on the board." >&2
  echo "A commit with no card is work the board cannot account for." >&2
  exit 1
fi
HOOK

my $PUSH_GATE = <<'HOOK';
#!/usr/bin/env bash
#
# The release gate. Push is part of "done", so this is the last moment anything
# can be caught, and everything here fails closed - a missing tool is a failure
# rather than a skip, because a gate that disappears when you delete a file is
# not a gate.
#
# Installed by: d2 tira.gates.install
set -euo pipefail

fail() { printf '\npre-push: %s\n' "$1" >&2; exit 1; }

command -v d2 >/dev/null || fail 'd2 is not on PATH - refusing rather than skipping'

echo "pre-push: asking police about the board"
if ! d2 tira.police --once -o json >/tmp/tira-police.$$ 2>/tmp/tira-police-err.$$; then
  cat /tmp/tira-police-err.$$ >&2
  rm -f /tmp/tira-police.$$ /tmp/tira-police-err.$$
  fail 'police could not read the board'
fi

count="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get("violations",[])))' /tmp/tira-police.$$ 2>/dev/null || echo missing)"
[ "$count" = "missing" ] && { rm -f /tmp/tira-police.$$ /tmp/tira-police-err.$$; fail 'could not read what police said'; }

if [ "$count" != "0" ]; then
  python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for v in d.get("violations", []):
    print("  {} {} {}".format(v.get("id",""), v.get("ref",""), v.get("detail","")))' /tmp/tira-police.$$ >&2
  rm -f /tmp/tira-police.$$ /tmp/tira-police-err.$$
  fail "police has $count things to say about this board - fix them, or discard what is not real work"
fi
rm -f /tmp/tira-police.$$ /tmp/tira-police-err.$$

echo "pre-push: the board is in order"
HOOK

sub gates_install {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $git = File::Spec->catdir( $root, '.git' );
    die "There is no git repository at '$root', so a gate would never run\n"
      if !-d $git;

    my $hooks = File::Spec->catdir( $git, 'hooks' );
    make_path($hooks) if !-d $hooks;

    my %gate = ( 'commit-msg' => $COMMIT_GATE, 'pre-push' => $PUSH_GATE );
    my @installed;
    for my $name ( sort keys %gate ) {
        my $path = File::Spec->catfile( $hooks, $name );
        $self->_atomic_write( $path, $gate{$name} );
        chmod 0755, $path;
        push @installed, $name;
    }
    return { installed => \@installed, into => $hooks };
}

# What actually happened to a card, in order. Built from the journal the engine
# already writes on every field change, plus the events that are not field
# changes at all - a comment left, a question asked, an answer given or judged.
#
# It is derived rather than stored, which is why there is no command to add to
# it and never will be. An agent that has to remember to log keeps a log worth
# nothing; here, adding a comment IS the entry and changing a title logs
# itself. And because it is read from what the engine wrote, the command line
# and the browser produce identical entries without either wrapper knowing this
# exists.
my %WORK_LOG_KIND = (
    ref => 'created',
    column => 'moved',
);

sub work_log {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $ref = $args{ref} or die "A card reference is required\n";
    my $record = $self->record_show( project => $root, ref => $ref );
    my @entries;

    for my $write ( @{ $self->history_list( project => $root, ref => $ref ) } ) {
        my $field = $write->{field} // '';
        next if $field eq 'last_updated';

        # These have events of their own further down. Keeping the field write
        # as well would report one comment twice, which reads as two things
        # happening.
        next if $field =~ /\A(?:comments|questions)\z/;

        my $kind = $WORK_LOG_KIND{$field} // 'changed';
        next if $kind eq 'created' && ( $write->{op} // '' ) ne 'create';

        # Creating a card writes every field at once. That is one event, not
        # eight, and "title changed" on a card made a second ago is noise that
        # would bury the things somebody actually wants to see.
        next if ( $write->{op} // '' ) eq 'create' && $field ne 'ref';

        my $detail =
            $kind eq 'created' ? 'raised'
          : $kind eq 'moved'
          ? ( ( $write->{before} // 'nowhere' ) . ' to ' . ( $write->{after} // 'nowhere' ) )
          : "$field changed";

        push @entries, {
            at => $write->{at}, kind => $kind, who => $write->{author}, detail => $detail,
        };
    }

    # An attachment set aside, read off the card itself: the stamp is the
    # record, so this cannot be forgotten and cannot be written by hand.
    for my $pool ( $record->{attachments},
        map { $_->{attachments} } @{ $record->{comments} // [] } )
    {
        for my $reference ( @{ $pool // [] } ) {
            next if !$reference->{discarded_at};
            push @entries, {
                at => $reference->{discarded_at}, kind => 'attachment-discarded',
                who => $reference->{discarded_by},
                detail => ( $reference->{original_filename} // $reference->{sha} )
                  . '.' . ( $reference->{extension} // 'bin' ),
            };
        }
    }

    # The events that are not field writes. A comment is the agent's own record
    # of what it did, which is exactly why it does not need a second one.
    for my $comment ( @{ $record->{comments} // [] } ) {
        push @entries, {
            at => $comment->{created_at} // $comment->{at},
            kind => 'commented', who => $comment->{author},
            detail => substr( $comment->{body} // $comment->{text} // '', 0, 120 ),
        };
    }

    for my $question ( @{ $record->{questions} // [] } ) {
        push @entries, {
            at => $question->{asked_at}, kind => 'asked', who => $question->{author},
            detail => "$question->{id}: " . substr( $question->{text} // '', 0, 120 ),
        };
        my $answer = $question->{answer} or next;
        push @entries, {
            at => $answer->{answered_at}, kind => 'answered', who => $answer->{author},
            detail => "$question->{id}: " . substr( $answer->{text} // '', 0, 120 ),
        };
        next if !defined $answer->{mark};
        push @entries, {
            at => $answer->{marked_at} // $answer->{answered_at},
            kind => 'marked', who => $answer->{author},
            detail => "$question->{id} marked $answer->{mark}",
        };
    }

    my @ordered = sort { ( $a->{at} // '' ) cmp ( $b->{at} // '' ) } @entries;

    my @collapsed;
    for my $entry (@ordered) {
        my $last = $collapsed[-1];
        if (   $last
            && $last->{kind} eq $entry->{kind}
            && ( $last->{detail} // '' ) eq ( $entry->{detail} // '' )
            && ( $last->{who} // '' ) eq ( $entry->{who} // '' ) )
        {
            $last->{times}++;
            $last->{until} = $entry->{at};
            next;
        }
        push @collapsed, { %{$entry}, times => 1 };
    }
    return \@collapsed;
}

sub _replace_record {
    my ( $self, %args ) = @_;
    my ( $path, undef, $column ) = $self->_record_data(%args);
    my %record = %{ $args{record} };
    delete $record{column};
    $record{last_updated} = $self->{clock}->();
    $self->_write_json( $path, \%record );
    $self->_journal_flush( $self->discover_project(%args) ) if !$self->{_journal_depth};
    return { %record, column => $column };
}

sub _require_person {
    my ( $self, %args ) = @_;
    my $person = $args{person};
    die "Project person is required\n" if !defined $person || $person eq '';
    die "Unknown project person '$person'\n" if !grep { $_->{id} eq $person } @{ $self->person_list(%args) };
    return $person;
}

# record_move refuses a caller with no author (TKT-457) because a move with
# nobody attached to it let a card cross the chain and required-action
# checks unrecorded. Every other write that reaches this file's own journal
# or history deserves the same guarantee - an entry that says WHAT happened
# and never WHO is most of what a work log is for. TKT-466, caught live: an
# entire session's worth of ticket.update/required-action.update/
# checklist.update/release.record calls landed attributed to nobody because
# --author was easy to forget on these four command families and nothing
# refused. The browser dashboard is unaffected: it always threads the
# signed-in person through as author on every mutating route (_attributed),
# the same exemption record_move already has.
sub _require_author {
    my ( $self, %args ) = @_;
    die "A change needs to say who is making it\n" if !defined $args{author} || $args{author} eq '';
    return $args{author};
}

# Builds required_exempt entries from --exempt-required/--exempt-reason
# pairs, shared by create_record and record_update so a card cannot be
# born with an unreasoned exemption any more than it can gain one later.
# Returns undef when no --exempt-required was given, so a caller can tell
# "nothing exempted" from "exempt this, with no items" (never possible)
# apart, matching every other accumulating field's own convention.
sub _exempt_entries {
    my ( $self, %args ) = @_;
    return $args{required_exempt} if !defined $args{required_exempt};
    my @items = @{ $args{required_exempt} };
    return \@items if !@items;

    # An already-formed entry (record_clone forwards a source record's own
    # required_exempt verbatim through this same argument, whole record
    # copied field-for-field) is preserved as-is rather than re-paired -
    # only a caller handing over bare strings, the shape --exempt-required
    # actually types, goes through the reason requirement below.
    return \@items if grep { ref $_ } @items;
    my @reasons = @{ $args{exempt_reason} // [] };
    die "Exempting a required item needs a reason - pair each --exempt-required with an --exempt-reason\n"
      if !@reasons;
    die "Every --exempt-required needs a matching --exempt-reason, and every --exempt-reason an --exempt-required "
      . "(got " . scalar(@items) . " item(s), " . scalar(@reasons) . " reason(s))\n"
      if @items != @reasons;
    my $now = $self->{clock}->();
    return [ map { { item => $items[$_], reason => $reasons[$_], exempted_at => $now, author => $args{author} } }
        0 .. $#items ];
}

sub _require_active_person {
    my ( $self, %args ) = @_;
    my $person = $args{person};
    die "Project person is required\n" if !defined $person || $person eq '';
    my ($match) = grep { $_->{id} eq $person } @{ $self->person_list(%args) };
    die "Unknown project person '$person'\n" if !$match;
    die "Project person '$person' is inactive\n" if exists $match->{active} && !$match->{active};
    return $person;
}

sub _unique_casefold {
    my ( $self, $values ) = @_;
    die "Expected an array of text values\n" if ref($values) ne 'ARRAY';
    my ( %seen, @unique );
    for my $value ( @{$values} ) {
        die "Array values must be non-empty text\n" if !defined $value || ref($value) || $value eq '';
        push @unique, $value if !$seen{ lc $value }++;
    }
    return \@unique;
}

sub _valid_priority {
    my ( $self, $priority ) = @_;
    return undef if !defined $priority || $priority eq '';
    # The direction, said here because this is where somebody who typed the
    # wrong number meets the scale, and for a long time it was said nowhere at
    # all. Tira runs 5-is-urgent, which is the opposite of the P1 convention
    # most trackers use, so a reader who assumes rather than checks gets it
    # exactly backwards - and did, for a whole session, silently.
    die "Priority must be an integer from 1 to 5, where 5 is the most urgent\n"
      if $priority !~ /\A([1-5])\z/;
    return 0 + $1;
}

sub _valid_datetime {
    my ( $self, $value, $label ) = @_;
    return undef if !defined $value || $value eq '';
    die "$label must be an ISO 8601 date-time with timezone\n"
      if $value !~ /\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))\z/;
    return $1;
}

sub _reciprocal_type {
    my ( $self, $root, $type ) = @_;
    for my $pair ( @{ $self->link_type_list( project => $root ) } ) {
        return $pair->{inward} if $pair->{outward} eq ( $type // '' );
        return $pair->{outward} if $pair->{inward} eq ( $type // '' );
    }
    die "Unknown link type '$type'\n";
}

sub _is_subitem_descendant {
    my ( $self, $root, $start, $wanted ) = @_;
    return 1 if $start eq $wanted;
    my $record = $self->record_show( project => $root, ref => $start );
    my $key = "sub_$record->{type}_refs";
    for my $child ( @{ $record->{linkage}{$key} } ) {
        return 1 if $self->_is_subitem_descendant( $root, $child, $wanted );
    }
    return 0;
}

sub _attachment_path {
    my ( $self, $root, %args ) = @_;
    my $sha = $args{sha} // '';
    die "Invalid attachment SHA\n" if $sha !~ /\A([0-9a-f]{64})\z/;
    $sha = $1;
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    if ( defined $args{extension} ) {
        die "Invalid attachment extension\n" if $args{extension} !~ /\A([A-Za-z0-9]+)\z/;
        my $extension = $1;
        return File::Spec->catfile( $dir, "$sha.$extension" );
    }
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @matches = map { /\A(\Q$sha\E)\.([A-Za-z0-9]+)\z/ ? File::Spec->catfile( $dir, "$1.$2" ) : () } readdir $dh;
    closedir $dh;
    die "Attachment SHA '$sha' has multiple extensions\n" if @matches > 1;
    return $matches[0];
}

sub _board_data {
    my ( $self, %args ) = @_;
    my $type = $self->_valid_type( $args{type} );
    my $root = $self->discover_project(%args);
    my $path = File::Spec->catfile( $root, '.tira', $type, 'config.yml' );
    my $config = $self->_load_yaml($path);
    $_->{name} = $self->_valid_slug( $_->{name} ) for @{ $config->{columns} };
    return ( $path, $config );
}

sub _record_data {
    my ( $self, %args ) = @_;
    my $ref = $args{ref} // '';
    die "Record reference is required\n" if $ref eq '';
    die "Invalid record reference '$ref'\n" if $ref !~ /\A[A-Z][A-Z0-9-]{0,31}-\d{1,12}\z/;
    my $root = $self->discover_project(%args);
    my @found;
    for my $type (qw(sow epic ticket)) {
        my $board = File::Spec->catdir( $root, '.tira', $type );
        find( { no_chdir => 1, wanted => sub {
            push @found, $self->_canonical_path( $File::Find::name, "record '$ref'" )
              if -f $File::Find::name && basename( $File::Find::name ) eq "$ref.json";
        } }, $board );
    }
    die "Record '$ref' not found\n" if !@found;
    die "Duplicate record '$ref' found\n" if @found > 1;
    my $path = $found[0];
    return ( $path, $self->_read_json($path), basename( dirname($path) ) );
}

# The measurement behind the rule: decoding a mature board of 138 records
# averaging 32KB cost 1992ms with the pure-Perl parser and 6ms with the
# compiled one, while reading the same files without parsing costs 2ms. The
# parser was the board walk.
#
# Cpanel::JSON::XS is required rather than preferred. Its booleans are
# JSON::PP::Boolean - the class, not the parser - which is what keeps stored
# records byte-identical across the change, so nothing rewrites and no content
# hash drifts. t/38 proves that.
# Owner's rule, 2026-08-12: no pure-Perl parsers where a compiled one exists.
# A board walk parses every card, so the parser is not a detail of the walk -
# it is the walk. Required outright rather than preferred, which is his
# decision on Q-017: speed over an easy install.
my @JSON_BACKENDS = qw(Cpanel::JSON::XS);
my $JSON_BACKEND;

# The version actually installed on disk, which is not necessarily the
# one this process loaded. A dashboard left open for a week is running whatever
# Tira it started with until something notices.
sub installed_version {
    my $here = __FILE__;
    $here =~ /\A([^\x00-\x1f\x7f]+)\z/ or return undef;
    my $env = File::Spec->catfile( dirname( dirname($1) ), '.env' );
    open my $fh, '<:raw', $env or return undef;
    my $body = do { local $/; <$fh> };
    close $fh;
    return $body =~ /^VERSION=(\S+)/m ? $1 : undef;
}

sub _select_json_backend {
    my (@candidates) = @_;
    for my $class (@candidates) {
        ( my $file = $class ) =~ s{::}{/}g;
        return $class if eval { require "$file.pm"; 1 };
    }

    # No falling back to a pure-Perl parser. A machine without it is a machine
    # this will not run on, and saying so here is better than running slowly
    # everywhere so that one machine can run at all.
    die "Tira needs Cpanel::JSON::XS. Install it (for example: cpanm Cpanel::JSON::XS)\n"
      . "and run this again.\n";
}

sub json_backend {
    $JSON_BACKEND //= _select_json_backend(@JSON_BACKENDS);
    return $JSON_BACKEND;
}

sub json_object { return json_backend()->new }

# Drop-in for JSON::PP::decode_json: UTF-8 bytes in, characters out.
sub json_decode { return json_object()->utf8->decode( $_[0] ) }

# The same, for a line somebody else's tool has already damaged.
#
# Strict decoding treats a byte that is not valid UTF-8 as fatal, which is
# correct for anything Tira writes and useless for reading a record written
# years ago by something that got it wrong. One raw 0xD7 - a multiplication
# sign written as latin-1 - in one card's journal was enough to stop every rule
# on a board of 359 cards.
#
# His instruction, and it is the right one: read it anyway. Decoding with
# substitution returns the whole entry; only the byte that was never valid
# becomes a replacement character. Proved on the damaged line itself before this
# was written - field, reference and the text on both sides of it all came back.
#
# Two things this must not become. It must not be what Tira writes with: a
# substitution written back into a record turns damage into data, quietly and
# permanently. And it must not be silent - police reports a file it had to read
# this way, so a corrupt record cannot pass for a clean one.
# Finding and repairing bytes that were never valid, on purpose and on request.
#
# His request, and his name for it. Two boards carry history files holding a
# multiplication sign written as latin-1, which silenced twenty-seven rules
# until 1.78 and has been read past since 1.80. Reading past it keeps a board
# policed; this is how the file itself gets better.
#
# It searches for BYTES rather than for U+FFFD. The replacement character is
# what a lenient decode produces when it meets a byte it cannot read - what he
# sees in output, not what is on disk - so a doctor looking for it would find
# nothing and report every damaged file clean, which is the worst answer a
# repair tool can give.
#
# And it repairs by reading each bad byte as latin-1 and writing it back as
# UTF-8, so 0xD7 becomes the multiplication sign somebody meant. Substituting
# U+FFFD instead would turn the damage into data permanently, which is exactly
# what the lenient read is careful never to write back.
#
# Nothing is repaired without being asked. History is the permanent record of a
# board, and a record somebody's tooling quietly rewrites is not evidence any
# more - so this reports by default and writes only when told to.
# Every byte in a string that UTF-8 cannot read, with where each one is.
#
# Asked in two places and therefore written in one. doctor reports and repairs
# them; card-damaged names them in its violation, so a reader can judge whether
# anything was actually lost rather than being told only that something was
# substituted. Two copies of this arithmetic would drift the first time somebody
# fixed the one they happened to be looking at.
#
# FB_QUIET consumes what it can and leaves the rest in the buffer it was given -
# it modifies its argument, which is the whole trick. Whatever is left begins
# with the byte it could not read, so the position is arithmetic on lengths
# rather than a guess.
#
# The first version re-encoded the decoded part to measure how far it had got,
# and reported byte 0x00 at offset 570 for a file whose only bad byte was 0xD7
# near the start: FB_QUIET had already advanced the buffer, so every offset
# after the first was counted twice.
sub _bad_bytes {
    my ($bytes) = @_;
    return [] if !defined $bytes;

    my @bad;
    my $offset = 0;
    my $rest = $bytes;
    while ( length $rest ) {
        my $remaining = $rest;
        Encode::decode( 'UTF-8', $remaining, Encode::FB_QUIET() );
        last if !length $remaining;

        my $used = length($rest) - length($remaining);
        push @bad, { at => $offset + $used, byte => substr( $remaining, 0, 1 ) };
        $rest = substr $remaining, 1;
        $offset += $used + 1;
    }
    return \@bad;
}

# One wording for both, because "which byte, and where" is one answer.
sub _bad_byte_detail {
    my ($bad) = @_;
    return join ', ',
      map { sprintf 'byte 0x%02X at offset %d', ord( $_->{byte} ), $_->{at} } @{$bad};
}

sub doctor {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $home = File::Spec->catdir( $root, '.tira' );

    my ( @damaged, @repaired );
    my $look = sub {
        my $path = $File::Find::name;
        return if !-f $path;

        # Attachments are bytes that were never meant to decode - a recording,
        # an image, a bundle. Repairing one would corrupt the thing it was
        # trying to protect. The notification database is the same.
        return if $path =~ m{/attachments/};
        return if $path =~ /\.db\z/;
        return if $path =~ m{/\.git/};

        open my $fh, '<:raw', $path or return;
        my $bytes = do { local $/; <$fh> };
        close $fh;
        return if !defined $bytes;

        # Every byte the decoder cannot read, found by decoding strictly and
        # letting it tell us where it stopped, one at a time.
        # FB_QUIET consumes what it can and leaves the rest in the buffer it
        # was given - it modifies its argument, which is the whole trick here.
        # Whatever is left begins with the byte it could not read, so the
        # position is arithmetic on lengths rather than a guess.
        #
        # The first version re-encoded the decoded part to measure how far it
        # had got, and reported byte 0x00 at offset 570 for a file whose only
        # bad byte was 0xD7 near the start: FB_QUIET had already advanced the
        # buffer, so every offset after the first was counted twice.
        my @bad = @{ _bad_bytes($bytes) };
        return if !@bad;

        push @damaged, {
            path => $path,
            bytes => scalar @bad,
            detail => _bad_byte_detail( \@bad ),
        };
        return if !$args{repair};

        # Read as latin-1 and written back as UTF-8, which recovers the
        # character rather than marking its absence.
        my $mended = $bytes;
        for my $bad ( reverse @bad ) {
            substr( $mended, $bad->{at}, 1 ) = Encode::encode( 'UTF-8',
                Encode::decode( 'ISO-8859-1', $bad->{byte} ) );
        }
        $self->_atomic_write( $path, $mended );
        push @repaired, {
            path => $path,
            bytes => scalar @bad,
            detail => _bad_byte_detail( \@bad ),
        };
        return;
    };

    find( { wanted => $look, no_chdir => 1 }, $home ) if -d $home;

    return {
        damaged  => [ sort { $a->{path} cmp $b->{path} } @damaged ],
        repaired => [ sort { $a->{path} cmp $b->{path} } @repaired ],
    };
}

sub json_decode_repaired {
    my ($bytes) = @_;
    my $strict = eval { json_decode($bytes) };
    return wantarray ? ( $strict, 0 ) : $strict if !$@;

    # FB_DEFAULT substitutes rather than dies, so what comes back is characters
    # with U+FFFD where the bad bytes were, and json decodes characters.
    my $text = Encode::decode( 'UTF-8', $bytes, Encode::FB_DEFAULT() );
    my $repaired = json_object()->decode($text);
    return wantarray ? ( $repaired, 1 ) : $repaired;
}

# Per-field history. Every record write funnels through
# _write_json, so the diff is taken there rather than in twenty commands
# — a command added later cannot escape history by forgetting to call
# something. Entries buffer for the duration of the locked operation and
# flush only when it succeeds, so a rolled-back transaction can never
# leave history claiming a change that did not happen. The journal lives
# outside the boards, so records, content hashes, and board scans are
# untouched.
my %HISTORY_FIELD = ( map { $_ => 1 } @RECORD_FIELDS, 'op', 'author', 'at' );

# Attribution is optional; when given it must name a known project person
# (active or not, so historical people can still be credited).
sub _journal_attribution {
    my ( $self, %args ) = @_;
    return undef if !defined $args{author} || $args{author} eq '';
    return $self->_require_person( %args, person => $args{author} );
}

# Reads reuse the CA20 window semantics and the CA09 truncation.
sub history_list {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $last = delete $args{last};
    my $first = delete $args{first};
    my $count_mode = delete $args{count};
    my $field = delete $args{field};
    my $since = delete $args{since};
    my $where = _parse_where( delete $args{where}, \%HISTORY_FIELD, 'history ' );
    die "Cannot combine --first with --last\n" if defined $first && defined $last;
    for my $window ( grep { defined } $first, $last ) {
        die "History windows must be zero or a positive count\n" if $window < 0;
    }
    if ( defined $field ) {
        die "Unknown field '$field'\n" if !$HISTORY_FIELD{$field};
    }
    my ( undef, $record ) = $self->_record_data( %args, project => $root );
    my $path = $self->_journal_path( $root, $record->{ref} );
    my @entries;
    if ( -f $path ) {
        open my $fh, '<:raw', $path or die "Cannot read history: $!\n";
        while ( my $line = <$fh> ) {
            next if $line !~ /\S/;

            # Read past a byte somebody else's tool wrote wrongly, rather than
            # losing the card. Counted, so police can say the file is damaged
            # without anybody having to notice a replacement character.
            my ( $entry, $repaired ) = json_decode_repaired($line);
            $self->{_history_repaired}{ $record->{ref} }++ if $repaired;
            push @entries, $entry;
        }
        close $fh or die "Cannot close history: $!\n";
    }
    @entries = grep { ( $_->{field} // '' ) eq $field } @entries if defined $field;
    if ( defined $since ) {
        my $threshold = _epoch_of_datetime( $since, 'Since' );
        @entries = grep {
            my $stamp = eval { _epoch_of_datetime( $_->{at}, 'History stamp' ) };
            !defined $stamp || $stamp >= $threshold;
        } @entries;
    }
    @entries = grep { _where_matches( $_, $where ) } @entries if $where;
    my $total = scalar @entries;
    return { count => $total }
      if $count_mode || ( defined $last && $last == 0 ) || ( defined $first && $first == 0 );
    if ( defined $last ) {
        my $window = $last > $total ? $total : $last;
        @entries = $window ? @entries[ $total - $window .. $total - 1 ] : ();
    }
    elsif ( defined $first ) {
        my $window = $first > $total ? $total : $first;
        @entries = @entries[ 0 .. $window - 1 ];
    }
    if ( defined $args{truncate} ) {
        _truncate_text_slot( $_, 'before', $args{truncate} ) for @entries;
        _truncate_text_slot( $_, 'after', $args{truncate} ) for @entries;
    }
    return \@entries;
}

sub _journal_path {
    my ( $self, $root, $ref ) = @_;
    return File::Spec->catfile( $root, '.tira', 'history', "$ref.jsonl" );
}

sub _journal_changes {
    my ( $self, $previous, $current ) = @_;
    my @entries;
    for my $field (@RECORD_FIELDS) {
        next if $field eq 'column' || $field eq 'last_updated';
        my ( $before, $after ) = ( $previous->{$field}, $current->{$field} );
        next if _values_equal( $before, $after );
        if ( ref $before || ref $after ) {
            push @entries, { field => $field, changed => Cpanel::JSON::XS::true };
        }
        else {
            push @entries, { field => $field, before => $before, after => $after };
        }
    }
    return @entries;
}

sub _journal_record {
    my ( $self, %args ) = @_;
    my $ref = $args{ref} // return;
    push @{ $self->{_journal} },
      map { { at => $self->{clock}->(), ref => $ref, op => $args{op}, author => $self->{_journal_author}, %{$_} } }
      @{ $args{entries} };
    return;
}

sub _journal_flush {
    my ( $self, $root ) = @_;
    my $pending = delete $self->{_journal};
    return if !$pending || !@{$pending};
    my $dir = File::Spec->catdir( $root, '.tira', 'history' );
    make_path($dir) if !-d $dir;
    my %grouped;
    push @{ $grouped{ $_->{ref} } }, $_ for @{$pending};
    for my $ref ( sort keys %grouped ) {
        my $path = $self->_journal_path( $root, $ref );
        open my $fh, '>>:raw', $path or die "Cannot append history for '$ref': $!\n";
        # Bytes, like every other write here. This encoded characters and wrote
        # them to a raw handle, so a card with a pound sign or any non-ASCII
        # text put a "Wide character" warning on stderr and broken bytes in the
        # journal - which is what the work log reads.
        print {$fh} map { json_object()->canonical->utf8->encode($_) . "\n" } @{ $grouped{$ref} }
          or die "Cannot write history for '$ref': $!\n";
        close $fh or die "Cannot close history for '$ref': $!\n";
    }
    return;
}

sub _read_json {
    my ( $self, $path ) = @_;
    return $self->_json_from_content( $self->_slurp($path) );
}

# strftime's %z is a numeric offset on POSIX and a zone name on Windows, so
# every stamp Tira wrote there was malformed - and a malformed timestamp is
# worse than a missing one, because it fails wherever it is next parsed rather
# than where it was made. The offset arithmetic lives in _iso_from_epoch,
# which every other timestamp-from-an-instant in this project shares - two
# copies of the same rounding logic is exactly how it went stale once
# already (TKT-419).
sub _now {
    return _iso_from_epoch(time);
}

sub _slurp {
    my ( $self, $path ) = @_;
    open my $fh, '<:raw', $path or die "Cannot read JSON '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close JSON '$path': $!\n";
    return $content;
}

# YAML::PP's load_file leaves the handle open. On Linux that is untidy and
# harmless; on Windows an open handle makes the file impossible to replace, and
# every board config write failed with "Access is denied" because the config had
# been read a moment earlier. Reading the bytes here and parsing them as a
# string closes the file when we say so rather than when somebody else's object
# is collected.
sub _load_yaml {
    my ( $self, $path ) = @_;
    return $self->{yaml}->load_string( decode( 'UTF-8', $self->_slurp($path) ) );
}

# Decoding is separated from reading so a caller that already has the bytes -
# the search index, which hashes them - does not read the same file twice.
sub _json_from_content {
    my ( $self, $content ) = @_;
    my $record = eval { json_object()->utf8->decode($content) };
    if ( !defined $record ) {
        my $characters = $self->_decode_legacy_utf8($content);
        $record = json_object()->decode($characters);
    }
    if ( !exists $record->{assignee} && exists $record->{assignees} ) {
        $record->{assignee} = @{ $record->{assignees} // [] } ? $record->{assignees}[0] : undef;
    }
    delete $record->{assignees};
    for my $field (qw(assignee reporter due_date start_date sdlc_gate lifecycle priority fix_version)) {
        $record->{$field} = undef if !exists $record->{$field};
    }
    for my $field (qw(labels affects_versions)) {
        $record->{$field} = [] if !exists $record->{$field};
    }
    for my $index ( 0 .. $#{ $record->{gate_passing_log} // [] } ) {
        my $entry = $record->{gate_passing_log}[$index];
        $entry->{id} //= sprintf( 'GATE-%03d', $index + 1 );
        $entry->{annotations} //= [];
    }
    for my $index ( 0 .. $#{ $record->{evidence} // [] } ) {
        my $entry = $record->{evidence}[$index];
        $entry->{id} //= sprintf( 'EVD-%03d', $index + 1 );
        $entry->{annotations} //= [];
    }
    $record->{checklist} = [] if !exists $record->{checklist};
    $record->{questions} = [] if !exists $record->{questions};
    $record->{parent} = $record->{linkage}{"parent_$record->{type}_ref"}
      // $record->{linkage}{sow_ref} // $record->{linkage}{epic_ref};
    return $record;
}

sub _valid_slug {
    my ( $self, $slug ) = @_;
    die "Invalid column name\n" if !defined $slug || $slug !~ /\A([a-z0-9]+(?:-[a-z0-9]+)*)\z/;
    return $1;
}

sub _decode_legacy_utf8 {
    my ( $self, $bytes ) = @_;
    my $characters = '';
    while ( length $bytes ) {
        $characters .= decode( 'UTF-8', $bytes, FB_QUIET );
        $characters .= chr unpack( 'C', substr( $bytes, 0, 1, '' ) ) if length $bytes;
    }
    return $characters;
}

# Refused in the words somebody would type, not in the vocabulary of the thing
# that noticed. This said "Unsupported record type ''" when the option was
# simply absent, from five commands - board.refs, board.show, column.list,
# column.sync and column.update - while their usage line named no option at
# all. There was no path from the message to --type ticket except guessing, and
# the usage said the opposite of the truth.
#
# The standard is this project's own, and he named it: "Policy rule
# card-sandbox-missing needs --enter" takes no guessing. So a missing type says
# which option and what it takes; a type that is not one of the three says what
# was typed and what would have been accepted.
sub _valid_type {
    my ( $self, $type ) = @_;
    $type //= '';
    die "This command needs --type ticket, epic or sow\n" if $type eq '';
    die "'$type' is not a type this board has - --type takes ticket, epic or sow\n"
      if $type !~ /\A(sow|epic|ticket)\z/;
    return $1;
}

sub _safe_path_input {
    my ( $self, $path, $label ) = @_;
    die "Unsafe control character in $label\n" if !defined $path || $path =~ /[\x00-\x1f\x7f]/;
    $path =~ /\A(.+)\z/ or die "Cannot validate $label\n";
    return $1;
}

# A string that looks like a number is still a string.
#
# TOON is the default output and the one every agent reads. Data::TOON tests a
# scalar against a number pattern before it tests whether it needs quoting, so
# "2.20" is encoded as the number 2.2 - a different release - and 1.10 as 1.1,
# 007 as 7, 0100 as 100. Measured across this project's own board: 20,732 string
# values, 22 of which did not survive a round trip, 19 of them a fix_version.
# Every release whose version ends in a zero has always read as another one.
#
# The module has the right rule and never reaches it: its _needs_quoting returns
# true for a numeric-looking string, and _encode_primitive returns the
# canonicalised number first. That is a check that exists and cannot fire.
#
# So the order is restored here, for values Perl still knows are strings. A
# number stays a number and is not quoted; a string is only quoted when leaving
# it alone would change it, so ordinary output is untouched. Delegated to the
# module rather than reimplemented, which means a version that stops needing
# this stops being changed by it.
our $TOON_PRIMITIVE_BEFORE = \&Data::TOON::Encoder::_encode_primitive;

sub _toon_is_string {
    my ($value) = @_;
    return 0 if ref $value;
    my $flags = B::svref_2object( \$value )->FLAGS;
    return 0 if !( $flags & B::SVp_POK() );
    return 0 if $flags & ( B::SVp_IOK() | B::SVp_NOK() );
    return 1;
}

{
    no warnings 'redefine';
    *Data::TOON::Encoder::_encode_primitive = sub {
        my ( $self, $value ) = @_;
        my $encoded = $TOON_PRIMITIVE_BEFORE->( $self, $value );
        return $encoded if !defined $value || !defined $encoded;
        return $encoded if !_toon_is_string($value);
        return $encoded if $encoded eq $value;
        return $encoded if $encoded =~ /\A"/;
        return '"' . $self->_escape_string($value) . '"';
    };
}

# A map nested inside a list element was printed flattened into the map
# around it. Data::TOON's list branch renders each of an item's keys as
# "$key: $value" with the value already encoded, which assumes a value is one
# line. A map is many, so its first key landed on its own key's line and the
# rest at the outer map's indent - two 'author' keys at one level, with 'mark'
# reading as a field of the question rather than of its answer.
#
# What it cost, measured on a real reader. A project filed two bug reports
# saying tira.question.mark stores nothing, citing 0 marks across 89
# questions. The mark was stored the whole time, at answer.mark. They read the
# flattened output, applied one bad predicate 89 times, and got a confident
# wrong number; they retracted it themselves after recounting 86 of 89 marked.
# TOON is the default output and its readers are agents, so an output that
# makes the correct reading unreachable is a defect here, not in the reader.
#
# Unlike the _encode_primitive patch above, this one cannot be pure
# delegation - there is nothing to delegate to when the branch itself is
# wrong. So it delegates every shape the module renders correctly (the
# tabular form, lists of primitives, lists of flat maps, arrays inside items)
# and reimplements only the case where an item carries a map.
#
# The predicate was narrowed twice while being written. Widening it to any
# ref turned the compact "tags[2]: a,b" into a dash list nobody asked for;
# and the first version re-indented nested lines flat, which read correctly
# for one level and destroyed everything below it - {a=>{b=>{c=>1}}} came
# back with c standing beside b. Both were found by testing shapes the fix
# was not aimed at, and both are asserted now.
#
# Round-tripping is NOT fixed and is no longer claimed: Data::TOON's decoder
# has the matching gap and cannot read this shape even written correctly.
# Raised as TKT-393. Nothing inside Tira is affected - it decodes TOON in one
# test only, and cards are stored as YAML. TKT-386.
our $TOON_ARRAY_BEFORE = \&Data::TOON::Encoder::_encode_object_with_array;

sub _toon_item_carries_map {
    my ($array) = @_;
    return 0 if ref $array ne 'ARRAY';
    for my $item ( @{$array} ) {
        next if ref $item ne 'HASH';
        return 1 if grep { ref $_ eq 'HASH' } values %{$item};
    }
    return 0;
}

{
    no warnings 'redefine';
    *Data::TOON::Encoder::_encode_object_with_array = sub {
        my ( $self, $indent, $key, $array ) = @_;
        return $TOON_ARRAY_BEFORE->( $self, $indent, $key, $array )
          if !_toon_item_carries_map($array);

        my @lines = ( $indent . $key . '[' . scalar( @{$array} ) . ']:' );
        local $self->{depth} = $self->{depth} + 1;
        my $item_indent  = ' ' x ( $self->{depth} * $self->{indent} );
        my $field_indent = ' ' x ( ( $self->{depth} + 1 ) * $self->{indent} );

        for my $obj ( @{$array} ) {
            my @keys = $self->_sort_fields( keys %{$obj} );
            if ( !@keys ) { push @lines, $item_indent . '-'; next }

            for my $i ( 0 .. $#keys ) {
                my $k     = $keys[$i];
                my $value = $obj->{$k};

                my $lead = $i == 0 ? $item_indent . '- ' : $field_indent;
                my $own  = $i == 0 ? $item_indent . '  ' : $field_indent;

                if ( ref $value ne 'HASH' ) {
                    local $self->{depth} = $self->{depth} + 1;
                    my $v = $self->_encode_value($value);
                    $v = '' if !defined $v;
                    my @sub = split /\n/, $v;
                    if ( @sub <= 1 ) { push @lines, $lead . "$k: $v"; next }
                    push @lines, $lead . "$k:";
                    push @lines, $own . ( ' ' x $self->{indent} ) . $_ for @sub;
                    next;
                }

                if ( !%{$value} ) { push @lines, $lead . "$k:"; next }

                local $self->{depth} = $self->{depth} + 1;
                my $body = $self->_encode_object($value);
                my @sub = split /\n/, ( defined $body ? $body : '' );

                my $least;
                for my $line (@sub) {
                    next if $line !~ /\S/;
                    my ($lead_ws) = $line =~ /\A(\s*)/;
                    $least = length $lead_ws
                      if !defined $least || length($lead_ws) < $least;
                }
                $least //= 0;
                my $body_indent = $own . ( ' ' x $self->{indent} );
                push @lines, $lead . "$k:";
                push @lines, $body_indent . substr( $_, $least ) for @sub;
            }
        }
        return join "\n", @lines;
    };
}

sub format_output {
    my ( $self, $data, %args ) = @_;
    my $output = $args{output} // 'toon';
    if ( $output eq 'toon' ) {
        local $SIG{__WARN__} = sub { };
        return Data::TOON->encode($data) . "\n";
    }
    return json_object()->canonical->allow_nonref->encode($data) . "\n" if $output eq 'json';
    return json_object()->canonical->allow_nonref->pretty->encode($data) if $output eq 'json-pretty';
    # A record narrowed to named fields is shown as those fields. The card
    # template below assumes a whole record and prints an empty placeholder for
    # every key it does not find, so asking for one field rendered a filled card
    # as a hollow one and left out the field that was asked for - wrong in both
    # directions at once, and worst on a board whose rules exist to catch
    # exactly the hollow card it was drawing.
    return $self->_markdown_fields( $data, %args )
      if $output eq 'human' && $args{fields} && @{ $args{fields} };

    return $self->_markdown( $data, %args ) if $output eq 'human';
    return $self->_dashboard_table( $data, %args ) if $output eq 'table';
    die "Unsupported output format '$output'\n";
}

# The narrowed answer: what is here, named, and nothing invented about what is
# not. Records keep their reference as a heading because that is how a reader
# tells one from the next; everything else is a line.
sub _markdown_fields {
    my ( $self, $data, %args ) = @_;
    my @records = ref $data eq 'ARRAY' ? @{$data} : ($data);
    my $text = '';
    for my $record (@records) {
        my %shown = %{$record};
        my $ref = delete $shown{ref};
        $text .= '# ' . $ref . "\n\n" if defined $ref;
        for my $field ( sort keys %shown ) {
            $text .= "- $field: " . _markdown_value( $shown{$field} ) . "\n";
        }
        $text .= "\n";
    }
    return $text;
}

sub _markdown_value {
    my ($value) = @_;
    return '_None_' if !defined $value;
    return @{$value} ? join( ', ', map { _markdown_value($_) } @{$value} ) : '_Empty._'
      if ref $value eq 'ARRAY';
    return join ', ', map { "$_: " . _markdown_value( $value->{$_} ) } sort keys %{$value}
      if ref $value eq 'HASH';
    return $value eq '' ? '_Empty._' : $value;
}

sub _html_escape {
    my ( $self, $value ) = @_;
    $value = '' if !defined $value;
    $value =~ s/&/&amp;/g;
    $value =~ s/</&lt;/g;
    $value =~ s/>/&gt;/g;
    $value =~ s/"/&quot;/g;
    $value =~ s/'/&#39;/g;
    return $value;
}

sub _dashboard_table {
    my ( $self, $data, %args ) = @_;
    die "Table output requires dashboard data\n"
      if ref($data) ne 'HASH' || ref( $data->{_column_order} ) ne 'HASH';
    my %heading = ( sow => 'Statements of Work', epic => 'Epics', ticket => 'Tickets' );
    my ( $rendered_cards, @rendered_boards ) = (0);
    my $boards = '';
    for my $type (qw(sow epic ticket)) {
        next if !exists $data->{_column_order}{$type};
        my @columns = @{ $data->{_column_order}{$type} };
        my $cells = join '', map {
            my $column = $_;
            my $cards = join '', map {
                my $ref = $self->_html_escape( $_->{ref} );
                my $title = defined $_->{title}
                  ? '<span class="card__title">' . $self->_html_escape( $_->{title} ) . '</span>' : '';
                my $mtime = 0 + ( $_->{_mtime} // 0 );

                # Empty rather than nought when nobody has set one. A card
                # nobody has prioritised is unassessed, not lowest, and the
                # sort has to be able to tell the difference.
                my $priority = defined $_->{priority} ? 0 + $_->{priority} : '';
                my $waiting = ( $_->{waiting} ? ' card--waiting' : '' )
                  . ( $_->{to_review} ? ' card--to-review' : '' );
                '<li data-ref="' . $ref . '" data-mtime="' . $mtime
                  . '" data-priority="' . $priority
                  . '"><button class="card' . $waiting . '" type="button" data-ref="' . $ref
                  . '"><span class="card__ref">' . $ref . '</span>' . $title . '</button></li>';
            } @{ $data->{$type}{$column} // [] };
            my $slug = $self->_html_escape($column);
            $rendered_cards += scalar @{ $data->{$type}{$column} // [] };
            '<section class="column' . ( $column eq 'discard' ? ' column--discard' : '' )
              . '"><h3 class="column__head"><span class="column__name">' . $slug
              . '</span><span class="column__count" data-count-for="' . $slug . '" hidden></span></h3>'
              . '<div class="column__body"><ol class="cards" data-column="' . $slug . '">' . $cards . '</ol>'
              . ( $args{live} && $column ne 'discard'

                # Nobody creates work straight into the discard pile. Offering
                # it there was a side effect of showing the column at all.
                ? '<button class="column__add" type="button" data-add-card="' . $slug . '">+ Add card</button>'
                : '' )
              . '</div></section>';
        } @columns;
        push @rendered_boards, $heading{$type};
        $boards .= '<section class="board board--' . $type . '" data-type="' . $type . '">'
          . '<header class="board__header"><span class="board__kicker">Tira board</span><h2>'
          . $heading{$type} . '</h2><div class="sorter" role="group" aria-label="Sort cards">'
          . '<button type="button" data-sort="mtime" class="is-active">Last modified</button>'
          . '<button type="button" data-sort="ref">Card reference</button>'
          . '<button type="button" data-sort="priority">Priority</button></div>'
          . '<input class="board-filter" type="search" data-filter="' . $type
          . '" placeholder="Filter cards" aria-label="Filter cards">'
          . '<div class="widther" role="group" aria-label="Column width">'
          . '<button type="button" data-width="standard" class="is-active">Standard</button>'
          . '<button type="button" data-width="fit">Fit all</button></div>'
          . '<button type="button" class="board-review" data-queue="answer"'
          . ' aria-pressed="false" title="Show only cards with a question nobody has answered">'
          . 'Questions to answer</button>'
          . '<button type="button" class="board-review" data-queue="review"'
          . ' aria-pressed="false" title="Show only cards whose answers are waiting to be accepted or rejected">'
          . 'Answers to review</button>'
          . (
            # Only where it can work. Editing columns posts to the server, so
            # on a page saved to disk this was a button that looked live, said
            # "Columns", and did nothing when clicked - the second such control
            # found on that page, after the queue toggles, and found the same
            # way. The toggles could be bound because filtering happens in the
            # page; this cannot, so the page does not offer it.
            $args{live}
            ? '<button type="button" class="board-columns" data-columns="' . $type . '">Columns</button>'
            : ''
          )
          . '</header>'
          . '<div class="board__scroll"><div class="board__columns">'
          . $cells . '</div></div></section>';
    }
    my $project_heading = 'Tira Kanban';
    if ( defined $args{project} ) {
        my $project_name = eval { $self->project_show( project => $args{project} )->{name} };
        $project_heading = $self->_html_escape($project_name) if defined $project_name && $project_name ne '';
    }
    my $refresh_action = $args{live}
      ? q{fetch("/data",{cache:"no-store"}).then(response=>{if(response.status===401){location.reload();return null}if(!response.ok)throw new Error("refresh failed");return response.json()}).then(data=>{if(!data)return;if(data._version&&data._version!==document.documentElement.dataset.version){location.reload();return}markStale(data._stale);updateBoards(data);markUpdated();maybeRefreshDialog()}).catch(()=>{})}
      : q{location.reload()};
        my $column_editor = $args{live} ? q{const columnDialog=document.querySelector(".column-dialog");const columnList=columnDialog.querySelector(".column-editor");const columnError=columnDialog.querySelector(".column-dialog__error");let columnType="";const columnFail=message=>{columnError.textContent=message;columnError.hidden=false};const columnRow=(column,allNames)=>{allNames=allNames||[];const row=document.createElement("li");row.className="column-row";row.dataset.name=column.name;if(column.protected)row.dataset.protected="1";const grip=document.createElement("span");grip.className="column-row__grip";grip.setAttribute("aria-hidden","true");grip.textContent="\u2261";const label=document.createElement("input");label.className="column-row__label";label.setAttribute("aria-label","Column label");label.value=column.label||column.name;const minutes=document.createElement("input");minutes.className="column-row__minutes";minutes.type="number";minutes.min="1";minutes.placeholder="none";minutes.setAttribute("aria-label","Minutes before a card here counts as stuck");if(column.notify_after!==null&&column.notify_after!==undefined)minutes.value=column.notify_after;const eye=document.createElement("button");eye.type="button";eye.className="column-row__eye";eye.title="Send reminders about cards left in this column";const watched=column.watched===undefined?true:!!column.watched;eye.setAttribute("aria-pressed",watched?"true":"false");eye.textContent=watched?"\u25c9":"\u25cb";eye.addEventListener("click",()=>{const on=eye.getAttribute("aria-pressed")!=="true";eye.setAttribute("aria-pressed",on?"true":"false");eye.textContent=on?"\u25c9":"\u25cb"});row.append(grip,label,minutes,eye);const nextWrap=document.createElement("div");nextWrap.className="column-row__next-wrap";const nextLabel=document.createElement("span");nextLabel.className="column-row__next-label";nextLabel.textContent="Next";const nextList=document.createElement("div");nextList.className="column-row__next-list";allNames.filter(name=>name!==column.name).forEach(name=>{const chip=document.createElement("label");chip.className="column-row__next-chip";const checkbox=document.createElement("input");checkbox.type="checkbox";checkbox.className="column-row__next-checkbox";checkbox.value=name;checkbox.checked=Array.isArray(column.next)&&column.next.includes(name);const chipText=document.createElement("span");chipText.textContent=name;chip.append(checkbox,chipText);nextList.append(chip)});nextWrap.append(nextLabel,nextList);row.append(nextWrap);const actionsWrap=document.createElement("div");actionsWrap.className="column-row__actions-wrap";const actionsLabel=document.createElement("span");actionsLabel.className="column-row__actions-label";actionsLabel.textContent="Required actions";const actionsList=document.createElement("div");actionsList.className="column-row__actions-list";const buildActionRow=(value,isBlank)=>{const actionRow=document.createElement("div");actionRow.className="column-row__action-row";const input=document.createElement("input");input.type="text";input.className="column-row__action-input";input.value=value||"";input.placeholder=isBlank?"Add a required action\u2026":"";input.setAttribute("aria-label",isBlank?"Add a required action":"Required action");const btn=document.createElement("button");btn.type="button";if(isBlank){btn.className="column-row__action-add";btn.textContent="\u2713";btn.setAttribute("aria-label","Add this required action");btn.addEventListener("click",()=>{const text=input.value.trim();if(!text)return;actionsList.insertBefore(buildActionRow(text,false),actionRow);input.value=""})}else{btn.className="column-row__action-remove";btn.textContent="\u00d7";btn.setAttribute("aria-label","Remove this required action");btn.addEventListener("click",()=>actionRow.remove())}actionRow.append(input,btn);return actionRow};(Array.isArray(column.required_actions)?column.required_actions:[]).forEach(item=>actionsList.append(buildActionRow(item,false)));actionsList.append(buildActionRow("",true));actionsWrap.append(actionsLabel,actionsList);row.append(actionsWrap);if(!column.protected){const remove=document.createElement("button");remove.type="button";remove.className="column-row__remove";remove.textContent="\u00d7";remove.setAttribute("aria-label","Remove this column");remove.title="Remove this column. Any cards in it go to Discard.";remove.addEventListener("click",()=>row.remove());row.append(remove)}return row};const columnLayout=()=>Array.from(columnList.querySelectorAll(".column-row")).map(row=>{const minutes=row.querySelector(".column-row__minutes").value.trim();const entry={name:row.dataset.name,label:row.querySelector(".column-row__label").value.trim()||row.dataset.name,watched:row.querySelector(".column-row__eye").getAttribute("aria-pressed")==="true"?1:0};if(minutes!=="")entry.notify_after=Number(minutes);const nextVals=Array.from(row.querySelectorAll(".column-row__next-checkbox:checked")).map(c=>c.value);if(nextVals.length)entry.next=nextVals;const actionLines=Array.from(row.querySelectorAll(".column-row__action-input")).map(i=>i.value.trim()).filter(Boolean);if(actionLines.length)entry.required_actions=actionLines;return entry});const openColumns=type=>{columnType=type;columnError.hidden=true;columnList.textContent="";columnDialog.showModal();return fetch("/columns?type="+encodeURIComponent(type),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("columns failed");return response.json()}).then(list=>{const allNames=list.map(column=>column.name);list.forEach(column=>columnList.append(columnRow(column,allNames)))}).catch(()=>columnFail("Could not read the columns."))};const saveColumns=()=>fetch("/columns/apply",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:columnType,columns:columnLayout()})}).then(response=>response.json().then(body=>({ok:response.ok,body}))).then(result=>{if(!result.ok||result.body.error){columnFail(result.body.error||"Could not save the columns.");return}columnDialog.close();location.reload()}).catch(()=>columnFail("Could not save the columns."));const addColumn=()=>{const field=columnDialog.querySelector(".column-dialog__new");const text=field.value.trim();if(text==="")return;const slug=text.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-+|-+$/g,"");if(slug===""){columnFail("That name has no letters or digits in it.");return}if(columnList.querySelector('[data-name="'+slug+'"]')){columnFail("This board already has a column called "+slug+".");return}columnError.hidden=true;const rows=columnList.querySelectorAll(".column-row");const last=rows[rows.length-1];const allNames=Array.from(rows).map(r=>r.dataset.name);const row=columnRow({name:slug,label:text,watched:1},allNames);if(last&&last.dataset.protected)columnList.insertBefore(row,last);else columnList.append(row);field.value=""};let columnDragged=null;const columnDragMove=event=>{if(!columnDragged)return;event.preventDefault();const over=Array.from(columnList.querySelectorAll(".column-row")).find(row=>{if(row===columnDragged)return false;const box=row.getBoundingClientRect();return event.clientY>=box.top&&event.clientY<=box.bottom});if(!over)return;const box=over.getBoundingClientRect();columnList.insertBefore(columnDragged,event.clientY>box.top+box.height/2?over.nextSibling:over)};const columnDragEnd=()=>{if(columnDragged)columnDragged.classList.remove("is-dragging");columnDragged=null;window.removeEventListener("pointermove",columnDragMove,{passive:false});window.removeEventListener("pointerup",columnDragEnd)};columnList.addEventListener("pointerdown",event=>{const grip=event.target.closest(".column-row__grip");if(!grip)return;event.preventDefault();columnDragged=grip.closest(".column-row");if(!columnDragged)return;columnDragged.classList.add("is-dragging");window.addEventListener("pointermove",columnDragMove,{passive:false});window.addEventListener("pointerup",columnDragEnd)});columnDialog.querySelector(".column-dialog__save").addEventListener("click",saveColumns);columnDialog.querySelector(".column-dialog__cancel").addEventListener("click",()=>columnDialog.close());columnDialog.querySelector(".column-dialog__close").addEventListener("click",()=>columnDialog.close());columnDialog.querySelector(".column-dialog__addbtn").addEventListener("click",addColumn);document.querySelectorAll("[data-columns]").forEach(button=>button.addEventListener("click",()=>openColumns(button.dataset.columns)));window.tiraColumns={open:openColumns,save:saveColumns,add:addColumn,layout:columnLayout};} : '';
my $live_helpers = $args{live} ? q{const recordsByRef=new Map();const showTitles=document.documentElement.dataset.withTitle==="1";const dialog=document.querySelector(".card-dialog");const sectionsHost=dialog.querySelector(".card-dialog__sections");const errorHost=dialog.querySelector(".card-dialog__error");let lastDialogRecordJson="";let worklogOpen=false;let worklogRefresh=null;const priorityLabels={1:"Low",2:"Medium Low",3:"Medium",4:"High",5:"Very High"};let people=[];const peopleName=id=>{const match=people.find(person=>person.id===id);return match?match.name:id};fetch("/people",{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("people failed");return response.json()}).then(list=>{people=list}).catch(()=>{});let linkTypes=[];fetch("/link-types",{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("link types failed");return response.json()}).then(list=>{linkTypes=list}).catch(()=>{});const el=(tag,cls,text)=>{const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node};const dash="\u2014";const textOr=value=>value===null||value===undefined||value===""?dash:String(value);const entryText=entry=>{if(entry===null||entry===undefined)return dash;if(typeof entry!=="object")return String(entry);if(entry.original_filename)return entry.original_filename+"."+(entry.extension||"bin");return Object.values(entry).filter(value=>typeof value==="string"&&value!=="").join(" \u00b7 ")||dash};const humanDate=value=>value?String(value).replace("T"," ").replace(/[+Z].*$/,""):dash;const showError=message=>{errorHost.textContent=message||"";errorHost.hidden=!message};const viewer=dialog.querySelector(".card-viewer");const imageExts={png:1,jpg:1,jpeg:1,gif:1,webp:1,svg:1};const attachmentUrl=(sha,ext)=>"/attachment?ref="+encodeURIComponent(dialog.dataset.ref)+"&sha="+encodeURIComponent(sha)+"&extension="+encodeURIComponent(ext);const textExts={txt:1,md:1,log:1,csv:1,json:1,yml:1,yaml:1,xml:1,html:1};const videoExts={mp4:1,m4v:1,mov:1,webm:1};const audioExts={mp3:1,wav:1,m4a:1,ogg:1,flac:1};const tiffExts={tif:1,tiff:1};const docExts={pdf:1};const viewerPanes=()=>({frame:viewer.querySelector("iframe"),image:viewer.querySelector("img"),textPane:viewer.querySelector(".card-viewer__text"),video:viewer.querySelector(".card-viewer__video"),audio:viewer.querySelector(".card-viewer__audio"),fallback:viewer.querySelector(".card-viewer__fallback")});const hideAllPanes=()=>{const panes=viewerPanes();panes.frame.hidden=true;panes.frame.src="about:blank";panes.image.hidden=true;panes.image.removeAttribute("src");panes.image.onerror=null;panes.textPane.hidden=true;panes.textPane.textContent="";panes.video.hidden=true;panes.video.pause();panes.video.removeAttribute("src");panes.video.load();panes.audio.hidden=true;panes.audio.pause();panes.audio.removeAttribute("src");panes.fallback.hidden=true};const openViewer=(sha,ext,name)=>{const panes=viewerPanes();const download=viewer.querySelector(".card-viewer__download");viewer.querySelector(".card-viewer__name").textContent=name;const url=attachmentUrl(sha,ext);download.href=url;download.setAttribute("download",name);hideAllPanes();if(imageExts[ext]||tiffExts[ext]){panes.image.onerror=()=>{panes.image.hidden=true;panes.fallback.hidden=false};panes.image.src=url;panes.image.hidden=false}else if(videoExts[ext]){panes.video.src=url;panes.video.hidden=false}else if(audioExts[ext]){panes.audio.src=url;panes.audio.hidden=false}else if(textExts[ext]){panes.textPane.textContent="Loading\u2026";panes.textPane.hidden=false;fetch(url,{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("attachment failed");return response.text()}).then(content=>{panes.textPane.textContent=content}).catch(()=>{panes.textPane.textContent="Unable to load attachment"})}else if(docExts[ext]){panes.frame.src=url;panes.frame.hidden=false}else{panes.fallback.hidden=false}viewer.hidden=false};const closeViewer=()=>{viewer.hidden=true;hideAllPanes()};viewer.querySelector(".card-viewer__close").addEventListener("click",closeViewer);dialog.addEventListener("cancel",event=>{if(!viewer.hidden){event.preventDefault();closeViewer()}});dialog.addEventListener("close",()=>{closeViewer();showError("");cardNavStack=[];updateBackButton()});const uploadFile=(file,commentId)=>{const reader=new FileReader();reader.onload=()=>{const base64=String(reader.result).split(",")[1]||"";const payload={ref:dialog.dataset.ref,filename:file.name,content_base64:base64};if(commentId)payload.comment=commentId;mutate("/attachment/add",payload)};reader.readAsDataURL(file)};const inlineMd=(host,text)=>{const pattern=/(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)/g;let last=0;let match;while((match=pattern.exec(text))){if(match.index>last)host.appendChild(document.createTextNode(text.slice(last,match.index)));const token=match[0];if(token.indexOf("**")===0)host.appendChild(el("strong","",token.slice(2,-2)));else if(token.indexOf("`")===0)host.appendChild(el("code","card-md-code",token.slice(1,-1)));else host.appendChild(el("em","",token.slice(1,-1)));last=match.index+token.length}if(last<text.length)host.appendChild(document.createTextNode(text.slice(last)))};const renderMarkdown=body=>{const container=el("div","card-comment__body");String(body||"").split(/\n{2,}/).forEach(block=>{const lines=block.split("\n");if(lines.length&&lines.every(line=>/^\s*[-*] /.test(line))){const listNode=el("ul","card-md-list");lines.forEach(line=>{const item=el("li","");inlineMd(item,line.replace(/^\s*[-*] /,""));listNode.appendChild(item)});container.appendChild(listNode)}else{const paragraph=el("p","card-md-p");lines.forEach((line,index)=>{if(index)paragraph.appendChild(document.createElement("br"));inlineMd(paragraph,line)});container.appendChild(paragraph)}});return container};const sortByStamp=(items,key)=>[...(items||[])].sort((a,b)=>String(b[key]||"").localeCompare(String(a[key]||"")));const attachChip=(reference,commentId)=>{const chip=el("span","card-attachment"+(reference.discarded_at?" card-attachment--discarded":""));const key=reference.sha+"."+reference.extension;const name=reference.original_filename||key;const view=el("button","card-attachment__view",name);view.appendChild(el("span","card-attachment__date",humanDate(reference.added_at)));view.type="button";view.dataset.viewAttachment=key;view.onclick=()=>openViewer(reference.sha,reference.extension,name);const drop=el("button","card-attachment__delete","\u00d7");drop.type="button";drop.dataset.detachAttachment=key;drop.title=reference.discarded_at?("Discarded "+humanDate(reference.discarded_at)+(reference.discarded_by?" by "+reference.discarded_by:"")):"Discard attachment";drop.disabled=!!reference.discarded_at;drop.onclick=()=>{if(!confirm("Discard "+name+"?"))return;const payload={ref:dialog.dataset.ref,sha:reference.sha,extension:reference.extension};if(commentId)payload.comment=commentId;mutate("/attachment/discard",payload)};chip.append(view,drop);return chip};const attachInput=commentId=>{const label=el("label","card-attach-add");label.append(el("span","","Attach file"));const input=el("input","card-attach-input");input.type="file";if(commentId){input.dataset.attachComment=commentId}else{input.dataset.attachTarget="record"}input.onchange=()=>{if(input.files[0])uploadFile(input.files[0],commentId)};label.appendChild(input);return label};const listFields={labels:1,affects_versions:1,key_details:1,deliverables:1,scope_included:1,scope_excluded:1,acceptance_criteria:1,test_steps:1,bdd:1,atdd:1};const sendList=(field,items)=>mutate("/update",{ref:dialog.dataset.ref,field:field,value:items});const editableList=(field,items)=>{const wrap=el("div","card-list-wrap");const list=el("ul","card-list card-list--editable");(items||[]).forEach((item,index)=>{const row=el("li","card-list__row");const text=el("span","card-list__text",String(item));const editBtn=el("button","card-list__action","\u270e");editBtn.type="button";editBtn.dataset.listEdit=field+":"+index;editBtn.title="Edit item";editBtn.onclick=()=>{const input=el("input","card-edit-input");input.type="text";input.value=String(item);input.dataset.listInput=field;const save=el("button","card-edit-save","Save");save.type="button";save.dataset.listSave=field;save.onclick=()=>{const next=(items||[]).map(String);next[index]=input.value;sendList(field,next)};const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const editor=el("span","card-edit");editor.append(input,save,cancel);row.replaceChildren(editor);input.focus()};const removeBtn=el("button","card-list__action card-list__action--danger","\u00d7");removeBtn.type="button";removeBtn.dataset.listRemove=field+":"+index;removeBtn.title="Remove item";removeBtn.onclick=()=>{const next=(items||[]).map(String);next.splice(index,1);sendList(field,next)};row.append(text,editBtn,removeBtn);list.appendChild(row)});wrap.appendChild(list);const adder=el("div","card-list__adder");const input=el("input","card-edit-input");input.type="text";input.placeholder="Add item";input.setAttribute("data-list-add",field);const save=el("button","card-edit-save","Add");save.type="button";save.dataset.listAddSave=field;const submit=()=>{if(!input.value)return;sendList(field,(items||[]).map(String).concat(input.value))};save.onclick=submit;input.onkeydown=event=>{if(event.key==="Enter"){event.preventDefault();submit()}};adder.append(input,save);wrap.appendChild(adder);return wrap};const reloadCard=()=>fetch("/record?type="+encodeURIComponent(dialog.dataset.type)+"&ref="+encodeURIComponent(dialog.dataset.ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(record=>{renderCard(record);renderQuestions(record);renderPoliceLog(record);renderWorkLog(record);return record}).catch(()=>null);const dialogEditingActive=()=>!!(dialog.querySelector(".card-new")||dialog.querySelector(".card-edit")||dialog.querySelector(".card-comment__edit")||(document.activeElement&&dialog.contains(document.activeElement)&&/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName))||(dialog.querySelector(".card-comment-form")&&!dialog.querySelector(".card-comment-form").hidden));const maybeRefreshDialog=()=>{if(!dialog.open)return;if(!dialog.dataset.ref)return;if(dialogEditingActive())return;fetch("/record?type="+encodeURIComponent(dialog.dataset.type)+"&ref="+encodeURIComponent(dialog.dataset.ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(record=>{if(!record||!dialog.open||dialogEditingActive())return;if(JSON.stringify(record)===lastDialogRecordJson){if(worklogRefresh)worklogRefresh();return}renderCard(record);renderQuestions(record);renderPoliceLog(record);renderWorkLog(record)}).catch(()=>null)};const mutate=(path,payload)=>fetch(path,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)}).then(response=>response.json()).then(result=>{window.__tiraLastMutation=path;window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;if(result.ok){showError("");return reloadCard()}if(result.conflict){showError(result.error||"This card changed while you were editing \u2014 review and retry");return reloadCard()}showError(result.error||"Change failed");return null}).catch(()=>{window.__tiraLastMutation=path;window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;showError("Change failed");return null});const longFields={description:1,problem_or_feature:1,solution_needed:1};const editorFor=field=>{if(field==="priority"){const select=el("select","card-edit-input");["","1","2","3","4","5"].forEach(value=>{const option=el("option","",value===""?dash:value+" "+priorityLabels[value]);option.value=value;select.appendChild(option)});return select}if(field==="assignee"||field==="reporter"){const select=el("select","card-edit-input");const empty=el("option","",dash);empty.value="";select.appendChild(empty);people.forEach(person=>{const option=el("option","",person.name);option.value=person.id;select.appendChild(option)});return select}if(longFields[field]){const area=el("textarea","card-edit-input");area.rows=5;return area}const input=el("input","card-edit-input");input.type="text";return input};const beginEdit=(field,current,slot)=>{const editor=editorFor(field);editor.value=current===null||current===undefined?"":String(current);const base=current===undefined?null:current;const save=el("button","card-edit-save","Save");save.type="button";save.dataset.save=field;save.onclick=()=>mutate("/update",{ref:dialog.dataset.ref,field:field,value:editor.value,base:base});const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const wrap=el("span","card-edit");wrap.append(editor,save,cancel);slot.replaceChildren(wrap);editor.focus()};const editableValue=(field,record,display)=>{const slot=el("span","card-value");slot.appendChild(el("span","card-value__text",display));const edit=el("button","card-edit-button","\u270e");edit.type="button";edit.dataset.edit=field;edit.title="Edit "+field.replace(/_/g," ");edit.onclick=()=>beginEdit(field,record[field],slot);slot.appendChild(edit);return slot};const section=(title,body)=>{const box=el("section","card-section");box.dataset.section=title.toLowerCase();box.appendChild(el("h3","card-section__title",title));box.appendChild(body);return box};const listBody=values=>{const list=el("ul","card-list");values.forEach(value=>list.appendChild(el("li","",value)));return list};const maybeListSection=(title,items,map)=>{const values=(items||[]).map(map||entryText);if(!values.length)return;sectionsHost.appendChild(section(title,listBody(values)))};const detailRow=(grid,label,value)=>{grid.appendChild(el("dt","",label));const dd=el("dd","");if(value instanceof Node){dd.appendChild(value)}else{dd.textContent=value}grid.appendChild(dd)};const renderCard=record=>{if(!record)return;lastDialogRecordJson=JSON.stringify(record);dialog.dataset.ref=record.ref;dialog.dataset.type=record.type;{const refLine=dialog.querySelector(".card-dialog__ref");refLine.replaceChildren(el("span","",[record.ref||"Card",record.type].filter(Boolean).join(" \u00b7 ")+" \u00b7 "));const statusSelect=el("select","card-status");statusSelect.title="Move to column";const board=document.querySelector(".board--"+record.type);if(board){const lists=[...board.querySelectorAll(".cards")];const headers=[...board.querySelectorAll(".column__head")];lists.forEach((list,index)=>{const header=headers[index];const headerName=header?header.querySelector(".column__name"):null;const option=el("option","",headerName?headerName.textContent:(header?header.textContent:list.dataset.column));option.value=list.dataset.column;if(list.dataset.column===record.column)option.selected=true;statusSelect.appendChild(option)})}else{const option=el("option","",record.column||"");option.value=record.column||"";option.selected=true;statusSelect.appendChild(option)}statusSelect.onchange=()=>{fetch("/move",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:record.type,ref:record.ref,column:statusSelect.value})}).then(response=>{if(!response.ok)throw new Error("move failed");return response.json()}).then(()=>{window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;refreshDashboard();return reloadCard()}).catch(()=>showError("Unable to move the card"))};refLine.appendChild(statusSelect)};dialog.querySelector(".card-dialog__title").replaceChildren(editableValue("title",record,textOr(record.title)));sectionsHost.replaceChildren();const grid=el("dl","card-details");detailRow(grid,"Assignee",editableValue("assignee",record,record.assignee?peopleName(record.assignee):dash));detailRow(grid,"Reporter",editableValue("reporter",record,record.reporter?peopleName(record.reporter):dash));detailRow(grid,"Priority",editableValue("priority",record,record.priority?record.priority+" "+priorityLabels[record.priority]:dash));detailRow(grid,"Labels",editableList("labels",record.labels));detailRow(grid,"Start date",editableValue("start_date",record,humanDate(record.start_date)));detailRow(grid,"Due date",editableValue("due_date",record,humanDate(record.due_date)));detailRow(grid,"Fix version",editableValue("fix_version",record,textOr(record.fix_version)));detailRow(grid,"Affects versions",editableList("affects_versions",record.affects_versions));detailRow(grid,"SDLC gate",editableValue("sdlc_gate",record,textOr(record.sdlc_gate)));detailRow(grid,"Lifecycle",editableValue("lifecycle",record,textOr(record.lifecycle)));detailRow(grid,"Parent",textOr(record.parent));detailRow(grid,"Source",editableValue("source",record,textOr(record.source)));detailRow(grid,"Created",humanDate(record.created_at));detailRow(grid,"Last updated",humanDate(record.last_updated));sectionsHost.appendChild(section("Details",grid));const sectionWithEdit=(title,field)=>{const box=el("section","card-section");const heading=el("h3","card-section__title",title);const edit=el("button","card-edit-button","\u270e");edit.type="button";edit.dataset.edit=field;edit.title="Edit "+title;heading.appendChild(edit);const body=el("div","card-text");const slot=el("span","card-value");slot.appendChild(el("span","card-value__text",textOr(record[field])));body.appendChild(slot);edit.onclick=()=>beginEdit(field,record[field],slot);box.append(heading,body);return box};[["Description","description"],["Problem / Feature","problem_or_feature"],["Solution Needed","solution_needed"]].forEach(pair=>sectionsHost.appendChild(sectionWithEdit(pair[0],pair[1])));[["Key Details","key_details",record.key_details],["Deliverables","deliverables",record.deliverables],["Scope Included","scope_included",record.scope&&record.scope.included],["Scope Excluded","scope_excluded",record.scope&&record.scope.excluded],["Acceptance Criteria","acceptance_criteria",record.acceptance_criteria],["Test Steps","test_steps",record.test_steps],["BDD","bdd",record.bdd],["ATDD","atdd",record.atdd]].forEach(triple=>sectionsHost.appendChild(section(triple[0],editableList(triple[1],triple[2]))));{const box=el("div","card-checklist");const list=el("ul","card-list");(record.checklist||[]).forEach(entry=>{const row=el("li","card-list__row");row.dataset.checklist=entry.id;const text=el("span","card-list__text","["+(entry.status||"open")+"] "+(entry.item||dash));const editBtn=el("button","card-list__action","\u270e");editBtn.type="button";editBtn.dataset.checklistEdit=entry.id;editBtn.title="Edit checklist entry";editBtn.onclick=()=>{const itemInput=el("input","card-edit-input");itemInput.type="text";itemInput.value=entry.item||"";itemInput.dataset.checklistItem=entry.id;const statusInput=el("input","card-edit-input");statusInput.type="text";statusInput.value=entry.status||"";statusInput.dataset.checklistStatus=entry.id;const save=el("button","card-edit-save","Save");save.type="button";save.dataset.checklistSave=entry.id;save.onclick=()=>mutate("/checklist/update",{ref:dialog.dataset.ref,id:entry.id,item:itemInput.value,status:statusInput.value});const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const editor=el("span","card-edit");editor.append(itemInput,statusInput,save,cancel);row.replaceChildren(editor);statusInput.focus()};row.append(text,editBtn);list.appendChild(row)});box.appendChild(list);const form=el("form","card-checklist-form");const itemInput=el("input","");itemInput.name="item";itemInput.placeholder="New checklist item";const statusInput=el("input","");statusInput.name="status";statusInput.placeholder="Status";const submit=el("button","","Add entry");submit.type="submit";form.append(itemInput,statusInput,submit);form.onsubmit=event=>{event.preventDefault();if(!itemInput.value||!statusInput.value)return;mutate("/checklist/add",{ref:dialog.dataset.ref,item:itemInput.value,status:statusInput.value})};box.appendChild(form);sectionsHost.appendChild(section("Checklist",box))};if((record.required_items||[]).length){const box=el("div","card-required");const total=record.required_items.length;const done=record.required_items.filter(entry=>entry.status==="done").length;const exemptByItem=new Map((record.required_exempt||[]).map(entry=>typeof entry==="object"&&entry!==null?[entry.item,entry.reason]:[entry,null]));const byColumn=new Map();record.required_items.forEach(entry=>{const col=entry.column||dash;if(!byColumn.has(col))byColumn.set(col,[]);byColumn.get(col).push(entry)});byColumn.forEach((entries,col)=>{const group=el("div","card-required__group");group.appendChild(el("h4","card-required__column",col));const list=el("ul","card-list");entries.forEach(entry=>{const row=el("li","card-list__row");row.dataset.requiredAction=entry.id;const exempt=exemptByItem.has(entry.item);const icon=exempt?"\u2796":(entry.status==="done"?"\u2705":"\u2b1c");const textSpan=el("span","card-list__text",icon+" "+humanDate(entry.last_updated)+" "+(entry.item||dash));if(exempt)textSpan.classList.add("card-list__text--exempt");row.appendChild(textSpan);if(entry.status!=="done"&&!exempt){const doneCheck=document.createElement("input");doneCheck.type="checkbox";doneCheck.className="card-list__check";doneCheck.dataset.requiredActionDone=entry.id;doneCheck.onclick=()=>mutate("/required-action/update",{ref:dialog.dataset.ref,id:entry.id,status:"done"});row.appendChild(doneCheck)}list.appendChild(row);if(exempt){textSpan.classList.add("card-list__text--expandable");textSpan.tabIndex=0;textSpan.setAttribute("role","button");textSpan.setAttribute("aria-expanded","false");const openExempt=()=>{const proofDialog=document.querySelector(".proof-dialog");const body=proofDialog.querySelector(".proof-dialog__body");body.textContent="";const pairBox=el("div","proof-dialog__pair");pairBox.appendChild(el("div","proof-dialog__command","Exempt"));pairBox.appendChild(el("div","proof-dialog__detail",exemptByItem.get(entry.item)||"(no reason recorded)"));body.appendChild(pairBox);textSpan.setAttribute("aria-expanded","true");proofDialog.addEventListener("close",()=>textSpan.setAttribute("aria-expanded","false"),{once:true});proofDialog.showModal()};textSpan.onclick=openExempt;textSpan.onkeydown=keyEvent=>{if(keyEvent.key==="Enter"||keyEvent.key===" "){keyEvent.preventDefault();openExempt()}}}else if(entry.proof&&entry.proof.length){textSpan.classList.add("card-list__text--expandable");textSpan.tabIndex=0;textSpan.setAttribute("role","button");textSpan.setAttribute("aria-expanded","false");const proofRow=el("li","card-list__proof");proofRow.hidden=true;proofRow.dataset.requiredActionProof=entry.id;entry.proof.forEach(pair=>{const line=el("div","card-list__proof-line");line.appendChild(el("span","card-list__proof-command",pair.command||dash));line.appendChild(el("span","card-list__proof-detail",pair.proof||(pair.attachment?"(attachment)":dash)));proofRow.appendChild(line)});const openProof=()=>{const proofDialog=document.querySelector(".proof-dialog");const body=proofDialog.querySelector(".proof-dialog__body");body.textContent="";entry.proof.forEach(pair=>{const pairBox=el("div","proof-dialog__pair");pairBox.appendChild(el("div","proof-dialog__command",pair.command||dash));pairBox.appendChild(el("div","proof-dialog__detail",pair.proof||(pair.attachment?"(attachment)":dash)));body.appendChild(pairBox)});textSpan.setAttribute("aria-expanded","true");proofDialog.addEventListener("close",()=>textSpan.setAttribute("aria-expanded","false"),{once:true});proofDialog.showModal()};textSpan.onclick=openProof;textSpan.onkeydown=keyEvent=>{if(keyEvent.key==="Enter"||keyEvent.key===" "){keyEvent.preventDefault();openProof()}};list.appendChild(proofRow)}});group.appendChild(list);box.appendChild(group)});const requiredSection=section("Required actions ("+done+"/"+total+")",box);requiredSection.classList.add("card-section--required");sectionsHost.appendChild(requiredSection)}maybeListSection("Subtasks",record.subtasks);if(record.linkage){const box=el("div","card-linkage");const linkedCache=new Map();const priorityRank=info=>info&&typeof info.priority==="number"?info.priority:-1;const linkedInfo=ref=>{if(linkedCache.has(ref))return linkedCache.get(ref);const seed=recordsByRef.get(ref);const promise=fetch("/record?type="+encodeURIComponent(dialog.dataset.type)+"&ref="+encodeURIComponent(ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("linked record failed");return response.json()}).catch(()=>seed||null);linkedCache.set(ref,promise);return promise};const sortLinkageTable=table=>{[...table.children].sort((a,b)=>(Number(b.dataset.priority??-1)-Number(a.dataset.priority??-1))||(a.getAttribute("data-linkage-row")||"").localeCompare(b.getAttribute("data-linkage-row")||"")).forEach(row=>table.appendChild(row))};const linkageRow=(ref,drop)=>{const row=el("div","card-linkage-table__row");row.setAttribute("data-linkage-row",ref);const titleCell=el("span","card-linkage__title","\u2026");const statusCell=el("span","card-linkage__status","");row.append(el("span","card-linkage__ref",ref),titleCell,statusCell);if(drop)row.appendChild(drop);row.addEventListener("click",event=>{if(event.target.closest("[data-linkage-unlink],[data-link-remove]"))return;navigateToCard(ref)});linkedInfo(ref).then(info=>{titleCell.textContent=info&&info.title?info.title:dash;statusCell.textContent=info&&info.column?info.column:"";row.dataset.priority=priorityRank(info);if(row.parentElement&&row.parentElement.classList.contains("card-linkage-table"))sortLinkageTable(row.parentElement)});return row};const linkRoutes={hierarchy:{link:"/hierarchy/link",unlink:"/hierarchy/unlink"},subitem:{link:"/subitem/link",unlink:"/subitem/unlink"}};const linkageSpec={sow_ref:"hierarchy",epic_ref:"hierarchy",parent_sow_ref:"subitem",parent_epic_ref:"subitem",parent_ticket_ref:"subitem",epic_refs:"hierarchy",ticket_refs:"hierarchy",sub_sow_refs:"subitem",sub_epic_refs:"subitem",sub_ticket_refs:"subitem"};Object.keys(record.linkage).forEach(key=>{if(key==="links")return;const kind=linkageSpec[key];if(!kind)return;const value=record.linkage[key];const row=el("div","card-linkage__row");row.appendChild(el("span","card-linkage__label",key.replace(/_/g," ")));const holder=el("span","card-linkage__list");if(Array.isArray(value)){const table=el("div","card-linkage-table");value.forEach(ref=>{const drop=el("button","card-list__action card-list__action--danger","\u00d7");drop.type="button";drop.setAttribute("data-linkage-unlink",key+":"+ref);drop.title="Unlink";drop.onclick=()=>mutate(linkRoutes[kind].unlink,{parent:dialog.dataset.ref,child:ref});table.appendChild(linkageRow(ref,drop))});holder.appendChild(table);const input=el("input","card-edit-input");input.type="text";input.placeholder="REF";input.setAttribute("data-linkage-add",key);const add=el("button","card-edit-save","Link");add.type="button";add.setAttribute("data-linkage-add-save",key);add.onclick=()=>{if(input.value)mutate(linkRoutes[kind].link,{parent:dialog.dataset.ref,child:input.value})};holder.append(input,add)}else if(value){const table=el("div","card-linkage-table");const drop=el("button","card-list__action card-list__action--danger","Unlink");drop.type="button";drop.setAttribute("data-linkage-unlink",key+":"+String(value));drop.onclick=()=>mutate(linkRoutes[kind].unlink,{parent:String(value),child:dialog.dataset.ref});table.appendChild(linkageRow(String(value),drop));holder.appendChild(table)}else{const input=el("input","card-edit-input");input.type="text";input.placeholder="Parent REF";input.setAttribute("data-linkage-add",key);const add=el("button","card-edit-save","Link");add.type="button";add.setAttribute("data-linkage-add-save",key);add.onclick=()=>{if(input.value)mutate(linkRoutes[kind].link,{parent:input.value,child:dialog.dataset.ref})};holder.append(input,add)}row.appendChild(holder);box.appendChild(row)});const linksBox=el("div","card-linkage__links");const linkList=el("div","card-linkage-table");(record.linkage.links||[]).forEach(entry=>{const drop=el("button","card-list__action card-list__action--danger","\u00d7");drop.type="button";drop.setAttribute("data-link-remove",entry.type+":"+entry.ref);drop.title="Remove link";drop.onclick=()=>mutate("/link/remove",{from:dialog.dataset.ref,type:entry.type,to:entry.ref});const row=linkageRow(entry.ref,drop);row.classList.add("card-linkage-table__row--typed");row.insertBefore(el("span","card-linkage__type",entry.type),row.firstChild);linkList.appendChild(row)});linksBox.appendChild(linkList);const form=el("form","card-link-form");const select=el("select","");select.name="type";linkTypes.forEach(pair=>{[pair.outward,pair.inward].forEach(nameValue=>{if([...select.options].some(option=>option.value===nameValue))return;const option=el("option","",nameValue);option.value=nameValue;select.appendChild(option)})});const refInput=el("input","");refInput.name="to";refInput.placeholder="REF";const submit=el("button","","Add link");submit.type="submit";form.append(select,refInput,submit);form.onsubmit=event=>{event.preventDefault();if(!refInput.value)return;mutate("/link/add",{from:dialog.dataset.ref,type:select.value,to:refInput.value})};linksBox.appendChild(form);box.appendChild(linksBox);sectionsHost.appendChild(section("Linkage",box))}maybeListSection("Gate Passing Log",record.gate_passing_log);maybeListSection("Evidence",record.evidence);{const box=el("div","card-attachments");const strip=el("div","card-attachment-strip");sortByStamp(record.attachments,"added_at").forEach(reference=>strip.appendChild(attachChip(reference)));box.appendChild(strip);box.appendChild(attachInput());sectionsHost.appendChild(section("Attachments",box))};const comments=el("div","card-comments-box");const commentList=el("ul","card-comments");sortByStamp(record.comments,"created_at").forEach(comment=>{const item=el("li","card-comment");item.dataset.comment=comment.id;const head=el("div","card-comment__head");head.appendChild(el("strong","",peopleName(comment.author)));head.appendChild(el("span","card-comment__meta",comment.id+" \u00b7 "+humanDate(comment.created_at)+(comment.last_updated&&comment.last_updated!==comment.created_at?" \u00b7 edited "+humanDate(comment.last_updated):"")));const editButton=el("button","card-comment__action","Edit");editButton.type="button";editButton.dataset.commentEdit=comment.id;const removeButton=el("button","card-comment__action card-comment__action--danger","Delete");removeButton.type="button";removeButton.dataset.commentRemove=comment.id;head.append(editButton,removeButton);const body=comment.format==="text"?el("div","card-comment__body",comment.body):renderMarkdown(comment.body);item.append(head,body);const commentAttachments=el("div","card-comment__attachments");sortByStamp(comment.attachments,"added_at").forEach(reference=>commentAttachments.appendChild(attachChip(reference,comment.id)));commentAttachments.appendChild(attachInput(comment.id));item.appendChild(commentAttachments);editButton.onclick=()=>{const area=el("textarea","card-comment__editor");area.value=comment.body;const save=el("button","card-comment__action","Save");save.type="button";save.dataset.commentSave=comment.id;save.onclick=()=>mutate("/comment/update",{ref:dialog.dataset.ref,comment:comment.id,text:area.value});const cancel=el("button","card-comment__action","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const editor=el("div","card-comment__edit");editor.append(area,save,cancel);body.replaceChildren(editor)};removeButton.onclick=()=>mutate("/comment/remove",{ref:dialog.dataset.ref,comment:comment.id});commentList.appendChild(item)});const composer=el("div","card-composer");const toggle=el("button","card-composer-toggle","\u002b Add a comment");toggle.type="button";const form=el("form","card-comment-form");form.hidden=true;const bar=el("div","card-md-bar");const text=el("textarea","");text.name="text";text.rows=4;text.placeholder="Write a comment - basic markdown supported";[["bold","B","**"],["italic","I","*"],["code","<>","`"],["list","\u2022","- "]].forEach(spec=>{const control=el("button","card-md-button",spec[1]);control.type="button";control.setAttribute("data-md",spec[0]);control.onclick=()=>{const start=text.selectionStart||0;const end=text.selectionEnd||0;const value=text.value;const selected=value.slice(start,end);if(spec[0]==="list"){const lines=(selected||"item").split("\n").map(line=>"- "+line).join("\n");text.value=value.slice(0,start)+lines+value.slice(end)}else{const mark=spec[2];text.value=value.slice(0,start)+mark+(selected||"text")+mark+value.slice(end)}text.focus()};bar.appendChild(control)});const submit=el("button","","Comment");submit.type="submit";form.append(bar,text,submit);toggle.onclick=()=>{toggle.hidden=true;form.hidden=false;text.focus()};form.onsubmit=event=>{event.preventDefault();if(!text.value)return;mutate("/comment/add",{ref:dialog.dataset.ref,text:text.value})};composer.append(toggle,form);comments.appendChild(composer);comments.appendChild(commentList);sectionsHost.appendChild(section("Comments",comments))};const questionRank=question=>question.discarded_at?3:!question.answer?0:!question.answer.mark?1:2;const renderPoliceLog=record=>{const host=sectionsHost;if(!host)return;const box=el("section","card-section card-section--policelog");box.dataset.section="policelog";box.hidden=true;const head=el("h3","card-section__title","What police has said");const list=el("ol","card-policelog__list");box.append(head,list);host.appendChild(box);fetch("/policelog?ref="+encodeURIComponent(record.ref),{cache:"no-store"}).then(r=>{if(!r.ok)throw new Error("police log failed");return r.json()}).then(entries=>{if(!entries||!entries.length){box.hidden=true;return}head.textContent="What police has said ("+entries.length+")";entries.forEach(entry=>{const item=el("li","card-policelog__entry");item.appendChild(el("span","card-policelog__when",humanDate(entry.at)));item.appendChild(el("span","card-policelog__kind",entry.kind||dash));item.appendChild(el("span","card-policelog__detail",entry.detail||dash));list.appendChild(item)});box.hidden=false}).catch(()=>{box.hidden=true})};const renderWorkLog=record=>{const host=sectionsHost;if(!host)return;const box=el("section","card-section card-section--worklog");box.dataset.section="worklog";const head=el("button","card-worklog__toggle","Work log");head.type="button";head.setAttribute("aria-expanded","false");const body=el("div","card-worklog__body");body.hidden=!worklogOpen;let loaded=false;const draw=entries=>{body.textContent="";if(!entries.length){body.appendChild(el("p","card-worklog__empty","Nothing has happened to this card yet."));return}const list=el("ol","card-worklog__list");entries.forEach(entry=>{const item=el("li","card-worklog__entry");item.appendChild(el("span","card-worklog__when",humanDate(entry.at)));item.appendChild(el("span","card-worklog__kind",entry.kind));item.appendChild(el("span","card-worklog__who",entry.who||dash));item.appendChild(el("span","card-worklog__detail",entry.detail||""));list.appendChild(item)});body.appendChild(list)};const readLog=()=>fetch("/worklog?ref="+encodeURIComponent(dialog.dataset.ref||record.ref),{cache:"no-store"}).then(r=>{if(!r.ok)throw new Error("work log failed");return r.json()}).then(draw).catch(()=>{loaded=false;body.textContent="The work log could not be read."});worklogRefresh=()=>{if(loaded&&!body.hidden)readLog()};head.addEventListener("click",()=>{const open=body.hidden;body.hidden=!open;worklogOpen=open;head.setAttribute("aria-expanded",open?"true":"false");if(!open||loaded)return;loaded=true;body.textContent="reading...";readLog()});if(worklogOpen){head.setAttribute("aria-expanded","true");loaded=true;readLog()}box.appendChild(head);box.appendChild(body);host.appendChild(box)};const renderQuestions=record=>{const all=[...(record.questions||[])];if(!all.length)return;all.sort((a,b)=>questionRank(a)-questionRank(b));const host=el("div","card-questions");all.forEach(question=>{const block=el("div","card-question");const status=question.discarded_at?"discarded":question.answer?"answered":"new";block.dataset.status=status;const settled=!!(question.answer&&question.answer.mark);if(settled)block.dataset.settled="1";const head=el("div","card-question__head");head.appendChild(el("span","card-question__id",question.id));if(settled)head.appendChild(el("span","card-question__verdict",question.answer.mark==="ok"?"\u2705":"\u274c"));else head.appendChild(el("span","card-question__status",status));block.appendChild(head);block.appendChild(el("p","card-question__text",question.text));if(settled){block.appendChild(el("blockquote","card-question__answer",question.answer.text));host.appendChild(block);return}if(question.reason)block.appendChild(el("p","card-question__reason","Why: "+question.reason));const fileList=(files,label)=>{if(!files||!files.length)return;const box=el("div","card-question__files");box.appendChild(el("span","card-question__files-label",label));files.forEach(file=>{const link=document.createElement("a");link.className="card-question__file";link.target="_blank";link.href=attachmentUrl(file.sha,file.extension);link.textContent=file.original_filename||(file.sha.slice(0,8)+"."+file.extension);box.appendChild(link)});block.appendChild(box)};fileList(question.attachments,"Asked with:");fileList(question.answer&&question.answer.attachments,"Answered with:");if(!question.discarded_at){const drop=el("div","card-question__drop","Drop a file here to attach it");drop.addEventListener("dragover",event=>{event.preventDefault();drop.classList.add("is-over")});drop.addEventListener("dragleave",()=>drop.classList.remove("is-over"));drop.addEventListener("drop",event=>{event.preventDefault();drop.classList.remove("is-over");[...(event.dataTransfer&&event.dataTransfer.files||[])].forEach(file=>{const reader=new FileReader();reader.onload=()=>mutate("/question/attach",{id:question.id,filename:file.name,to:question.answer?"answer":"question",content_base64:String(reader.result).split(",")[1]||""});reader.readAsDataURL(file)})});block.appendChild(drop);}if(question.voice){const play=el("button","card-question__play","\u25b6 Play the question");play.type="button";const audio=document.createElement("audio");audio.controls=true;audio.hidden=true;audio.className="card-question__audio";audio.src=attachmentUrl(question.voice.sha,question.voice.extension);play.onclick=()=>{audio.hidden=false;play.hidden=true;audio.play().catch(()=>{})};block.append(play,audio)}const answerWith=text=>mutate("/question/answer",{id:question.id,text:text});const box=document.createElement("textarea");box.className="card-question__box";box.rows=3;box.value=question.answer?question.answer.text:"";const grow=()=>{box.style.height="auto";box.style.height=Math.min(box.scrollHeight,420)+"px"};box.addEventListener("input",grow);setTimeout(grow,0);box.placeholder=question.answer?"Edit this answer":"Type another answer";const send=el("button","card-question__send",question.answer?"Save answer":"Answer");send.type="button";send.onclick=()=>{if(box.value)answerWith(box.value)};if(status!=="discarded"&&(question.options||[]).length){const choices=el("div","card-question__choices");question.options.forEach(choice=>{const pick=el("button","card-question__choice",choice);pick.type="button";if(question.answer&&question.answer.text===choice)pick.classList.add("is-chosen");pick.onclick=()=>answerWith(choice);choices.appendChild(pick)});const other=el("button","card-question__choice card-question__other","Other\u2026");other.type="button";other.onclick=()=>{typed.hidden=false;box.focus()};choices.appendChild(other);block.appendChild(choices)}if(question.answer){block.appendChild(el("blockquote","card-question__answer",question.answer.text));block.appendChild(el("p","card-question__state",(question.answer.mark?"marked "+question.answer.mark:"not yet marked")+(question.answer.read_at?", read":", not yet read")));const marks=el("div","card-question__marks");[["ok","This settles it"],["not-ok","This does not settle it"]].forEach(pair=>{const button=el("button","card-question__mark",pair[1]);button.type="button";if(question.answer.mark===pair[0])button.classList.add("is-active");button.onclick=()=>mutate("/question/mark",{id:question.id,mark:pair[0]});marks.appendChild(button)});block.appendChild(marks)}const typed=el("div","card-question__typed");typed.append(box,send);typed.hidden=status==="discarded"||(!question.answer&&(question.options||[]).length>0);if(status!=="discarded")block.appendChild(typed);if(question.discarded_at)block.appendChild(el("p","card-question__state","Set aside "+question.discarded_at));host.appendChild(block)});const details=sectionsHost.querySelector('[data-section="details"]');const comments=sectionsHost.querySelector('[data-section="comments"]');sectionsHost.insertBefore(section("Questions",host),(details&&details.nextSibling)||comments||null)};const showCard=record=>{if(!record)return;showError("");renderCard(record);renderQuestions(record);renderPoliceLog(record);renderWorkLog(record);if(!dialog.open)dialog.showModal()};let cardNavStack=[];const backButton=dialog.querySelector(".card-dialog__back");const updateBackButton=()=>{backButton.hidden=cardNavStack.length===0};const fetchRecord=(type,ref)=>fetch("/record?type="+encodeURIComponent(type)+"&ref="+encodeURIComponent(ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("linked record failed");return response.json()});const navigateToCard=ref=>{const current=dialog.dataset.ref&&dialog.dataset.type?{ref:dialog.dataset.ref,type:dialog.dataset.type}:null;fetchRecord(dialog.dataset.type,ref).then(record=>{if(!record)return;if(current)cardNavStack.push(current);showCard(record);updateBackButton()}).catch(()=>{})};backButton.addEventListener("click",()=>{const previous=cardNavStack.pop();updateBackButton();if(!previous)return;fetchRecord(previous.type,previous.ref).then(record=>{if(record)showCard(record)}).catch(()=>{})});const newCardField=(label,control)=>{const row=el("div","card-new__row");row.appendChild(el("label","card-new__label",label));row.appendChild(control);return row};const openNewCard=(type,column)=>{dialog.dataset.ref="";dialog.dataset.type=type;dialog.dataset.newColumn=column;lastDialogRecordJson="";showError("");const refLine=dialog.querySelector(".card-dialog__ref");refLine.replaceChildren(el("span","","New "+type+" \u00b7 "+column+" \u00b7 reference assigned on save"));dialog.querySelector("h2").replaceChildren(el("span","","New card"));const form=el("form","card-new");form.noValidate=true;const title=el("input","card-edit-input");title.type="text";title.required=true;title.name="title";title.placeholder="Title (required)";const description=el("textarea","card-edit-input");description.rows=4;description.name="description";const priority=el("select","card-edit-input");priority.name="priority";["","1","2","3","4","5"].forEach(value=>{const option=el("option","",value===""?dash:value+" "+priorityLabels[value]);option.value=value;priority.appendChild(option)});const assignee=el("select","card-edit-input");assignee.name="assignee";const noone=el("option","",dash);noone.value="";assignee.appendChild(noone);people.forEach(person=>{const option=el("option","",person.name);option.value=person.id;assignee.appendChild(option)});form.append(newCardField("Title",title),newCardField("Description",description),newCardField("Priority",priority),newCardField("Assignee",assignee));const submit=el("button","card-edit-save","Create card");submit.type="submit";submit.dataset.createCard=column;const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>dialog.close();const actions=el("div","card-new__actions");actions.append(submit,cancel);form.appendChild(actions);form.onsubmit=event=>{event.preventDefault();if(!title.value.trim()){showError("A title is required");title.focus();return}fetch("/create",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:type,column:column,title:title.value,description:description.value,priority:priority.value,assignee:assignee.value})}).then(response=>response.json()).then(result=>{window.__tiraLastMutation="/create";window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;if(!result.ok){showError(result.error||"Unable to create the card");return}dialog.dataset.ref=result.record.ref;delete dialog.dataset.newColumn;showError("");renderCard(result.record);refreshDashboard()}).catch(()=>{window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;showError("Unable to create the card")})};sectionsHost.replaceChildren(section("New card",form));if(!dialog.open)dialog.showModal();title.focus()};dialog.querySelector(".card-dialog__close").addEventListener("click",()=>dialog.close());const proofDialog=document.querySelector(".proof-dialog");proofDialog.querySelector(".proof-dialog__close").addEventListener("click",()=>proofDialog.close());const buildCard=record=>{const item=document.createElement("li");item.dataset.ref=record.ref;item.dataset.mtime=String(((record._mtime||0)*1000)||Date.parse(record.updated_at||record.last_updated||"")||0);item.dataset.priority=record.priority===undefined||record.priority===null?"":String(record.priority);const button=document.createElement("button");button.className="card"+(record.waiting?" card--waiting":"")+(record.to_review?" card--to-review":"");button.type="button";button.dataset.ref=record.ref;const ref=document.createElement("span");ref.className="card__ref";ref.textContent=record.ref;button.appendChild(ref);if(showTitles){const title=document.createElement("span");title.className="card__title";title.textContent=record.title||"";button.appendChild(title)}item.appendChild(button);return item};const updateBoards=data=>{recordsByRef.clear();document.querySelectorAll(".board").forEach(board=>{const type=board.dataset.type;(data._column_order?.[type]||[]).forEach(column=>{const list=[...board.querySelectorAll(".cards")].find(node=>node.dataset.column===column);if(!list)return;const records=data[type]?.[column]||[];records.forEach(record=>recordsByRef.set(record.ref,record));list.replaceChildren(...records.map(buildCard))});sortBoard(board,document.documentElement.dataset.sort)});bindBoards();updateColumnCounts();markSelection()};}
      : '';
    my $card_binding = $args{live}
      ? q{card.onclick=event=>{if(window.__tiraDragEndAt&&Date.now()-window.__tiraDragEndAt<50){window.__tiraDragEndAt=0;return}if(event.shiftKey){event.preventDefault();toggleSelection(card);return}if(selection.size)clearSelection();const ref=card.dataset.ref;const type=card.closest(".board").dataset.type;fetch("/record?type="+encodeURIComponent(type)+"&ref="+encodeURIComponent(ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(record=>{cardNavStack=[];updateBackButton();showCard(record)}).catch(()=>{});};}
      : q{card.onclick=()=>card.classList.toggle("is-selected");};
    my $dialog = $args{live}
      ? '<dialog class="card-dialog"><header><button class="card-dialog__back" type="button" aria-label="Back" hidden>&larr;</button><div><span class="card-dialog__ref">Card</span><h2 class="card-dialog__title">Details</h2></div><button class="card-dialog__close" type="button" aria-label="Close" autofocus>&times;</button></header><p class="card-dialog__error" hidden></p><div class="card-viewer" hidden><header><span class="card-viewer__name"></span><a class="card-viewer__download" target="_blank">Download</a><button class="card-viewer__close" type="button" aria-label="Close viewer">&times;</button></header><img hidden alt="attachment preview"><iframe hidden title="attachment preview"></iframe><pre class="card-viewer__text" hidden></pre><video class="card-viewer__video" hidden controls playsinline></video><audio class="card-viewer__audio" hidden controls></audio><div class="card-viewer__fallback" hidden><p>Preview is not supported for this file in this browser.</p><p>Use the Download button above to open it locally.</p></div></div><div class="card-dialog__sections"></div></dialog>'
        . '<dialog class="column-dialog"><header><h2>Columns</h2>'
        . '<button class="column-dialog__close" type="button" aria-label="Close" autofocus>&times;</button></header>'
        . '<p class="column-dialog__error" hidden></p><ol class="column-editor"></ol>'
        . '<div class="column-dialog__add"><input class="column-dialog__new" type="text" placeholder="New column name" aria-label="New column name">'
        . '<button type="button" class="column-dialog__addbtn">Add column</button></div>'
        . '<footer><button type="button" class="column-dialog__cancel">Cancel</button>'
        . '<button type="button" class="column-dialog__save">Save</button></footer></dialog>'
        . '<dialog class="proof-dialog"><header><h2>Proof</h2>'
        . '<button class="proof-dialog__close" type="button" aria-label="Close" autofocus>&times;</button></header>'
        . '<div class="proof-dialog__body"></div></dialog>'
      : '';
    my $with_title = $args{with_title} ? '1' : '0';
    my $initial_refresh = $args{live} ? 'refreshDashboard();' : '';
    my $drag_script = $args{live}
      ? q{const selection=new Set();const selectedCards=()=>[...document.querySelectorAll(".card.is-selected")];const markSelection=()=>{document.querySelectorAll(".card").forEach(card=>card.classList.toggle("is-selected",selection.has(card.dataset.ref)))};const clearSelection=()=>{selection.clear();markSelection()};const toggleSelection=card=>{const ref=card.dataset.ref;if(selection.has(ref))selection.delete(ref);else selection.add(ref);markSelection()};const dragState={card:null,ghost:null,started:false,startX:0,startY:0,lastX:0,lastY:0,timer:null,pointerId:null,fromTouch:false};const clearDrag=()=>{if(dragState.timer)clearTimeout(dragState.timer);if(dragState.ghost)dragState.ghost.remove();document.querySelectorAll(".cards.is-drop-target").forEach(node=>node.classList.remove("is-drop-target"));dragState.card=null;dragState.ghost=null;dragState.started=false;dragState.timer=null;dragState.pointerId=null};const positionGhost=(x,y)=>{if(dragState.ghost){dragState.ghost.style.left=x+"px";dragState.ghost.style.top=y+"px"}};const beginDrag=()=>{if(!dragState.card||dragState.started)return;dragState.started=true;const ghost=dragState.card.cloneNode(true);ghost.className="card card--ghost";ghost.style.width=dragState.card.offsetWidth+"px";const moving=dragState.refs.length;if(moving>1){const badge=document.createElement("span");badge.className="card__batch";badge.textContent=moving+" cards";ghost.appendChild(badge)}document.body.appendChild(ghost);dragState.ghost=ghost;positionGhost(dragState.lastX,dragState.lastY)};const columnAt=(x,y)=>{const board=dragState.card?dragState.card.closest(".board"):null;if(!board)return null;const hit=document.elementFromPoint(x,y);const direct=hit?hit.closest(".cards"):null;if(direct&&direct.closest(".board")===board)return direct;const boardRect=board.getBoundingClientRect();if(y<boardRect.top||y>boardRect.bottom)return null;let best=null;[...board.querySelectorAll(".cards")].forEach(list=>{const rect=list.getBoundingClientRect();if(x>=rect.left&&x<=rect.right)best=list});return best};document.addEventListener("pointerdown",event=>{const card=event.target.closest(".card");if(!card||event.button)return;if(event.shiftKey)return;dragState.card=card;dragState.refs=selection.has(card.dataset.ref)&&selection.size>1?selectedCards().map(node=>node.dataset.ref):[card.dataset.ref];dragState.startX=dragState.lastX=event.clientX;dragState.startY=dragState.lastY=event.clientY;dragState.pointerId=event.pointerId;dragState.fromTouch=event.pointerType==="touch";if(dragState.fromTouch){dragState.timer=setTimeout(beginDrag,250)}});document.addEventListener("pointermove",event=>{if(!dragState.card||event.pointerId!==dragState.pointerId)return;dragState.lastX=event.clientX;dragState.lastY=event.clientY;if(!dragState.started){const distance=Math.hypot(event.clientX-dragState.startX,event.clientY-dragState.startY);if(!dragState.fromTouch&&distance>6)beginDrag();else if(dragState.fromTouch&&distance>14&&dragState.timer){clearTimeout(dragState.timer);dragState.timer=null}}if(dragState.started){if(event.cancelable)event.preventDefault();positionGhost(event.clientX,event.clientY);const list=columnAt(event.clientX,event.clientY);document.querySelectorAll(".cards.is-drop-target").forEach(node=>{if(node!==list)node.classList.remove("is-drop-target")});if(list)list.classList.add("is-drop-target")}},{passive:false});document.addEventListener("pointerup",event=>{if(!dragState.card||event.pointerId!==dragState.pointerId)return;const wasStarted=dragState.started;const movingRefs=(dragState.refs&&dragState.refs.length?dragState.refs:[dragState.card.dataset.ref]).slice();const board=dragState.card.closest(".board");const list=wasStarted?columnAt(event.clientX,event.clientY):null;clearDrag();if(wasStarted){window.__tiraDragEndAt=Date.now();if(list&&board){Promise.all(movingRefs.map(ref=>fetch("/move",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:board.dataset.type,ref:ref,column:list.dataset.column})}).then(response=>{if(!response.ok)throw new Error("move failed");return response.json()}))).then(()=>{clearSelection();return refreshDashboard()}).catch(()=>{})}}});document.addEventListener("touchmove",event=>{if(dragState.started&&event.cancelable)event.preventDefault()},{passive:false});document.addEventListener("pointercancel",()=>clearDrag());}
      : '';
    return '<!doctype html><html lang="en" data-version="' . $VERSION
      . '" data-with-title="' . $with_title . '"><head><meta charset="utf-8">'
      . '<meta name="viewport" content="width=device-width,initial-scale=1"><title>'
      . $project_heading . ' :: '
      . ( @rendered_boards == 1 ? $rendered_boards[0] : 'Kanban' )
      . ' :: ' . $rendered_cards . '</title><style>'
      . <<'CSS'
:root{color-scheme:dark;--ink:#f8fafc;--muted:#9aa8bd;--panel:rgba(14,23,42,.76);--line:rgba(148,163,184,.16);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}*{box-sizing:border-box}body{margin:0;min-height:100vh;color:var(--ink);background:radial-gradient(circle at 12% 4%,rgba(99,102,241,.3),transparent 30rem),radial-gradient(circle at 88% 18%,rgba(14,165,233,.2),transparent 32rem),linear-gradient(145deg,#050816 0%,#0b1022 52%,#11182c 100%);background-attachment:fixed}body:before{content:"";position:fixed;inset:0;pointer-events:none;background-image:linear-gradient(rgba(255,255,255,.018) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.018) 1px,transparent 1px);background-size:32px 32px}.shell{position:relative;width:min(96rem,calc(100% - 2rem));margin:auto;padding:3.5rem 0 5rem}.hero{display:flex;align-items:end;justify-content:space-between;gap:2rem;margin:0 0 2.5rem;padding:0 .4rem}.hero__aside{display:grid;justify-items:end;gap:.7rem}.eyebrow,.board__kicker{color:#a5b4fc;font-size:.72rem;font-weight:800;letter-spacing:.18em;text-transform:uppercase}.hero h1{margin:.35rem 0 0;font-size:clamp(2.2rem,6vw,4.8rem);line-height:.9;letter-spacing:-.055em;background:linear-gradient(110deg,#fff 15%,#c4b5fd 52%,#67e8f9);-webkit-background-clip:text;color:transparent}.hero p{max-width:30rem;margin:0;color:var(--muted);line-height:1.6;text-align:right}.refresh-status{display:inline-flex;align-items:center;gap:.45rem;padding:.38rem .7rem;color:#a5f3fc;background:rgba(8,145,178,.13);border:1px solid rgba(103,232,249,.25);border-radius:999px;font:750 .72rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.04em}.refresh-status:before{content:"";width:.42rem;height:.42rem;border-radius:50%;background:#22d3ee;box-shadow:0 0 12px #22d3ee}.board{--accent:#818cf8;margin:0 0 2rem;padding:1.15rem;border:1px solid var(--line);border-radius:1.5rem;background:linear-gradient(145deg,rgba(255,255,255,.075),rgba(255,255,255,.025)),var(--panel);box-shadow:0 28px 70px rgba(0,0,0,.32),inset 0 1px rgba(255,255,255,.08);backdrop-filter:blur(20px)}.board--sow{--accent:#34d399}.board--epic{--accent:#a78bfa}.board--ticket{--accent:#22d3ee}.board__header{display:flex;align-items:center;gap:1rem;padding:.4rem .45rem 1.15rem}.board__header:before{content:"";width:.62rem;height:2.8rem;border-radius:1rem;background:var(--accent);box-shadow:0 0 28px var(--accent)}.board__header h2{margin:0;font-size:1.35rem;letter-spacing:-.025em}.board__kicker{margin-left:auto;color:var(--muted)}.sorter,.widther{display:flex;gap:.35rem;padding:.3rem;margin-left:.3rem;border:1px solid var(--line);border-radius:.8rem;background:rgba(2,6,23,.32)}.sorter button,.widther button{padding:.48rem .68rem;color:var(--muted);background:transparent;border:0;border-radius:.55rem;font-size:.72rem;font-weight:750;cursor:pointer}.sorter button:hover,.sorter button.is-active,.widther button:hover,.widther button.is-active{color:#07111f;background:var(--accent)}html[data-width="fit"] .shell{width:100%}html[data-width="fit"] .board{margin-left:0;margin-right:0;padding-left:0;padding-right:0}html[data-width="fit"] .board__header{padding-left:.5rem;padding-right:.5rem}html[data-width="fit"] .board__scroll{overflow-x:hidden}html[data-width="fit"] .board__columns{display:grid;grid-template-columns:repeat(auto-fill,minmax(14rem,1fr));min-width:0}html[data-width="fit"] .column{flex:none;width:auto;min-width:0}html[data-width="fit"] .column--discard{opacity:.6}.column--discard .column__head{color:var(--muted);border-bottom-color:var(--line)}.column--discard .card{filter:saturate(.4)}.column--discard:hover{opacity:.9}.column__head{position:static;padding:.75rem .6rem;font-size:.7rem;overflow-wrap:anywhere}html[data-width="fit"] .card{padding:.7rem}html[data-width="fit"] .card__title{margin-top:.45rem;font-size:.8rem;line-height:1.3;overflow-wrap:break-word;hyphens:auto}html[data-width="fit"] .card__ref{font-size:.68rem;overflow-wrap:anywhere}.board__scroll{overflow-x:auto;padding:0 0 .4rem;scrollbar-color:var(--accent) transparent}.board__columns{display:flex;align-items:flex-start;gap:.7rem;min-width:max-content}.column{flex:0 0 17rem;width:17rem;min-width:0;display:flex;flex-direction:column}.column__head{position:sticky;top:0;z-index:2;margin:0;padding:.9rem 1rem;text-align:left;color:#dbeafe;background:rgba(15,23,42,.94);border:1px solid var(--line);border-bottom:2px solid var(--accent);border-radius:.85rem .85rem .25rem .25rem;font-size:.78rem;font-weight:750;letter-spacing:.08em;text-transform:uppercase}.column__body{padding:.75rem .35rem;background:rgba(2,6,23,.28);border-radius:0 0 1rem 1rem;min-width:0}.cards{display:grid;gap:.7rem;margin:0;padding:0;list-style:none;min-width:0}.cards>li{min-width:0}.card{display:block;width:100%;min-width:0;padding:1rem;text-align:left;color:var(--ink);background:linear-gradient(145deg,rgba(255,255,255,.1),rgba(255,255,255,.045));border:1px solid rgba(255,255,255,.1);border-radius:1rem;box-shadow:0 10px 25px rgba(0,0,0,.18);cursor:pointer;transition:transform .18s ease,border-color .18s ease,box-shadow .18s ease}.card--waiting{border-color:rgba(250,204,21,.75);background:linear-gradient(145deg,rgba(250,204,21,.22),rgba(250,204,21,.08));box-shadow:0 10px 25px rgba(161,98,7,.28)}.card--waiting .card__ref{color:#fde68a}.card:hover{transform:translateY(-3px);border-color:var(--accent);box-shadow:0 14px 34px rgba(0,0,0,.28),0 0 0 1px var(--accent)}.card.is-selected{border-color:var(--accent);box-shadow:0 0 0 2px var(--accent),0 16px 40px rgba(0,0,0,.32)}.card__batch{display:block;margin-top:.5rem;padding:.2rem .45rem;color:#07111f;background:var(--accent);border-radius:.5rem;font:800 .7rem/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;text-align:center}.card__ref{display:block;color:var(--accent);font:800 .76rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.06em}.card__title{display:block;margin-top:.62rem;color:#eef2ff;font-size:.94rem;font-weight:650;line-height:1.35}.card{touch-action:pan-y;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}.card--ghost{position:fixed;z-index:60;opacity:.88;transform:translate(-50%,-30%) rotate(3deg);pointer-events:none;box-shadow:0 24px 60px rgba(0,0,0,.55),0 0 0 1px var(--accent)}.cards.is-drop-target{outline:2px dashed #67e8f9;outline-offset:4px;border-radius:.8rem;background:rgba(103,232,249,.07)}@media(max-width:720px){html[data-width="fit"] .board__scroll{overflow-x:auto}html[data-width="fit"] th,html[data-width="fit"] td{min-width:15rem;width:15rem}.shell{width:min(100% - 1rem,96rem);padding-top:2rem}.hero{display:block}.hero__aside{justify-items:start;margin-top:1rem}.hero p{margin:0;text-align:left}.board{padding:.7rem;border-radius:1rem}.board__header{flex-wrap:wrap}.board__kicker{margin-left:0}.sorter{width:100%;margin:0}th,td{min-width:15rem;width:15rem}}
.last-updated{color:#7dd3fc;font:650 .7rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace}
.stale-notice{color:#fbbf24;font:650 .7rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace}
.stale-notice[hidden]{display:none}
.cards{min-height:2rem}
.board-review{margin-left:.3rem;padding:.48rem .68rem;color:var(--muted);background:transparent;border:1px solid var(--line);border-radius:.55rem;font-size:.72rem;font-weight:750;cursor:pointer}.board-review:hover{color:var(--ink)}.board-review.is-active{color:var(--ink);border-color:var(--accent);background:rgba(52,211,153,.14)}.card{background-image:linear-gradient(0deg,rgba(34,197,94,calc(var(--fresh,0)*.22)),rgba(34,197,94,calc(var(--fresh,0)*.22)))}
.card--to-review{opacity:.55;filter:saturate(.35);border-color:rgba(148,163,184,.35);background:linear-gradient(145deg,rgba(148,163,184,.12),rgba(148,163,184,.05));box-shadow:none}.card--to-review .card__ref{color:var(--muted)}.card--to-review:hover{opacity:.85}.board-columns{margin-left:.3rem;padding:.48rem .68rem;color:var(--muted);background:transparent;border:1px solid var(--line);border-radius:.55rem;font-size:.72rem;font-weight:750;cursor:pointer}.board-columns:hover{color:var(--ink)}.column-dialog{width:min(46rem,92vw);max-height:86vh;overflow:auto;border:1px solid var(--line);border-radius:1rem;background:var(--panel);color:var(--ink);padding:1.2rem}.column-dialog::backdrop{background:rgba(2,6,23,.72)}.column-dialog header{display:flex;align-items:center;justify-content:space-between;margin-bottom:.8rem}.column-dialog h2{margin:0;font-size:1rem}.column-dialog__error{color:#fca5a5;margin:0 0 .6rem}.column-editor{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:.4rem}.column-row{display:flex;flex-wrap:wrap;align-items:center;gap:.5rem;padding:.45rem .6rem;border:1px solid var(--line);border-radius:.6rem;background:rgba(2,6,23,.32)}.column-row.is-dragging{opacity:.45}.column-row__grip{cursor:grab;color:var(--muted);touch-action:none;user-select:none;padding:0 .2rem}.column-row__label{flex:1;min-width:0}.column-row__minutes{width:6rem}.column-row__next-wrap{flex-basis:100%;order:5;display:flex;flex-wrap:wrap;align-items:center;gap:.4rem}.column-row__next-label{color:var(--muted);font-size:.78rem}.column-row__next-list{display:flex;flex-wrap:wrap;gap:.35rem;flex:1;min-width:0}.column-row__next-chip{display:inline-flex;align-items:center;gap:.3rem;padding:.25rem .5rem;border:1px solid var(--line);border-radius:.5rem;background:rgba(2,6,23,.5);color:var(--ink);font-size:.8rem;cursor:pointer}.column-row__next-chip:has(.column-row__next-checkbox:checked){border-color:var(--accent);color:var(--ink);background:rgba(103,232,249,.1)}.column-row__actions-wrap{flex-basis:100%;order:6;display:flex;flex-direction:column;gap:.3rem}.column-row__actions-label{color:var(--muted);font-size:.78rem}.column-row__actions-list{display:flex;flex-direction:column;gap:.3rem}.column-row__action-row{display:flex;gap:.4rem;align-items:center}.column-row__action-input{flex:1;min-width:0;padding:.3rem .5rem;border:1px solid var(--line);border-radius:.5rem;background:rgba(2,6,23,.5);color:var(--ink);font:inherit}.column-row__action-add,.column-row__action-remove{border:1px solid var(--line);border-radius:.5rem;background:transparent;color:var(--muted);cursor:pointer;padding:.3rem .6rem;font:inherit}.column-row__action-add:hover{border-color:var(--accent);color:var(--ink)}.column-row__action-remove:hover{color:#fca5a5;border-color:#fca5a5}.column-dialog input{padding:.4rem .55rem;border:1px solid var(--line);border-radius:.5rem;background:rgba(2,6,23,.5);color:var(--ink);font:inherit}.column-row__eye,.column-row__remove,.column-dialog__addbtn,.column-dialog__save,.column-dialog__cancel,.column-dialog__close{border:1px solid var(--line);border-radius:.5rem;background:transparent;color:var(--muted);cursor:pointer;padding:.35rem .6rem;font:inherit}.column-dialog__add{display:flex;gap:.5rem;margin-top:.9rem}.column-dialog__new{flex:1}.column-dialog footer{display:flex;justify-content:flex-end;gap:.5rem;margin-top:1rem}.column-dialog__save{color:var(--ink);font-weight:700}.proof-dialog{width:min(40rem,92vw);max-height:80vh;overflow:auto;border:1px solid var(--line);border-radius:1rem;background:var(--panel);color:var(--ink);padding:1.2rem}.proof-dialog::backdrop{background:rgba(2,6,23,.72)}.proof-dialog header{display:flex;align-items:center;justify-content:space-between;margin-bottom:.8rem}.proof-dialog h2{margin:0;font-size:1rem}.proof-dialog__close{border:1px solid var(--line);border-radius:.5rem;background:transparent;color:var(--muted);cursor:pointer;padding:.35rem .6rem;font:inherit}.proof-dialog__body{display:flex;flex-direction:column;gap:.9rem}.proof-dialog__pair{display:flex;flex-direction:column;gap:.3rem;padding:.6rem .7rem;border:1px solid var(--line);border-radius:.6rem;background:rgba(2,6,23,.32)}.proof-dialog__command{font-weight:700;overflow-wrap:break-word;white-space:pre-wrap}.proof-dialog__detail{color:var(--dim);overflow-wrap:break-word;white-space:pre-wrap}.card-question[data-settled="1"]{padding:.5rem .7rem;opacity:.75}.card-question[data-settled="1"] .card-question__text{margin-bottom:.3rem;font-weight:600}.card-question[data-settled="1"] .card-question__answer{margin:.2rem 0 0}.card-question__verdict{font-size:.95rem;line-height:1}.card-question__head{display:flex;align-items:center;gap:.5rem;margin-bottom:.4rem}.card-question__status{padding:.1rem .45rem;border-radius:.4rem;font-size:.68rem;letter-spacing:.06em;text-transform:uppercase;border:1px solid var(--line);color:var(--muted)}.card-question[data-status="new"] .card-question__status{color:#fde68a;border-color:rgba(250,204,21,.6)}.card-question[data-status="discarded"]{opacity:.6}.card-question[data-status="discarded"] .card-question__text{text-decoration:line-through}.card-question__choices{display:flex;flex-wrap:wrap;gap:.4rem;margin:.5rem 0}.card-question__choice{padding:.4rem .7rem;border:1px solid var(--line);border-radius:.5rem;background:rgba(2,6,23,.4);color:var(--ink);cursor:pointer;font:inherit}.card-question__choice:hover{border-color:var(--accent)}.card-question__choice.is-chosen{border-color:var(--accent);color:var(--ink);font-weight:650}.card-question__other{color:var(--muted)}.card-question__typed{display:flex;flex-direction:column;gap:.4rem;margin-top:.5rem}.card-question__typed[hidden],.card-question__play[hidden],.card-question__audio[hidden]{display:none}.card-policelog__list{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:.35rem}.card-policelog__entry{display:grid;grid-template-columns:11rem 7rem 1fr;gap:.6rem;font-size:.82rem;align-items:baseline}.card-policelog__when{color:var(--dim);font-variant-numeric:tabular-nums}.card-policelog__kind{color:#fbbf24;text-transform:uppercase;letter-spacing:.06em;font-size:.72rem}.card-section--policelog[hidden]{display:none}.card-worklog,.card-section--worklog{margin-top:.4rem}.card-worklog__toggle{width:100%;text-align:left;background:none;border:0;border-top:1px solid var(--line);padding:.7rem 0;color:var(--dim);font:600 .8rem/1 inherit;letter-spacing:.08em;text-transform:uppercase;cursor:pointer}.card-worklog__toggle:hover{color:var(--ink)}.card-worklog__toggle::before{content:"\25b8 ";display:inline-block;transition:transform .1s}.card-worklog__toggle[aria-expanded="true"]::before{transform:rotate(90deg)}.card-worklog__body[hidden]{display:none}.card-worklog__list{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:.35rem}.card-worklog__entry{display:grid;grid-template-columns:11rem 6rem 7rem 1fr;gap:.6rem;font-size:.82rem;align-items:baseline}.card-worklog__when,.card-worklog__who{color:var(--dim)}.card-worklog__kind{font-weight:600}.card-worklog__empty{color:var(--dim);font-size:.85rem}@media(max-width:720px){.card-policelog__entry,.card-worklog__entry{grid-template-columns:1fr;gap:.15rem}.card-policelog__detail,.card-worklog__detail{overflow-wrap:break-word}}.card-questions{display:flex;flex-direction:column;gap:.8rem}.card-question{padding:.8rem;border:1px solid var(--line);border-radius:.7rem;background:rgba(2,6,23,.32)}.card-question[data-status="new"]{border-color:rgba(250,204,21,.6)}.card-question__id{margin:0 0 .4rem;font-size:.75rem;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}.card-question__text{margin:0 0 .5rem;font-weight:650}.card-question__play{margin:0 0 .5rem;padding:.4rem .7rem;border:1px solid var(--line);border-radius:.5rem;background:rgba(2,6,23,.4);color:var(--ink);cursor:pointer;font:inherit}.card-question__play:hover{border-color:var(--accent)}.card-question__audio{width:100%;margin:0 0 .5rem}.card-question__files{display:flex;flex-wrap:wrap;align-items:center;gap:.4rem;margin:0 0 .5rem}.card-question__files-label{color:var(--muted);font-size:.78rem}.card-question__file{padding:.2rem .5rem;color:var(--ink);background:rgba(2,6,23,.5);border:1px solid var(--line);border-radius:.4rem;font-size:.78rem;text-decoration:none}.card-question__file:hover{border-color:var(--accent)}.card-question__drop{margin:0 0 .5rem;padding:.5rem .7rem;color:var(--muted);border:1px dashed var(--line);border-radius:.5rem;font-size:.78rem;text-align:center}.card-question__drop.is-over{color:var(--ink);border-color:var(--accent);background:rgba(103,232,249,.08)}.card-question__reason{margin:0 0 .5rem;color:var(--muted);font-size:.85rem}.card-question__answer{margin:.4rem 0;padding:.5rem .7rem;border-left:3px solid var(--accent);background:rgba(2,6,23,.4);white-space:pre-wrap}.card-question__state{margin:.3rem 0;color:var(--muted);font-size:.8rem}.card-question__marks{display:flex;gap:.4rem}.card-question__mark,.card-question__send{padding:.4rem .7rem;border:1px solid var(--line);border-radius:.5rem;background:transparent;color:var(--muted);cursor:pointer;font:inherit}.card-question__mark.is-active{color:var(--ink);border-color:var(--accent)}.card-question__reply{display:flex;flex-direction:column;gap:.4rem;margin-top:.5rem}.card-question__box{padding:.5rem;border:1px solid var(--line);border-radius:.5rem;background:rgba(2,6,23,.5);color:var(--ink);font:inherit;resize:vertical}.card-dialog{position:fixed;inset:0;margin:auto;width:min(54rem,calc(100% - 2rem));height:fit-content;max-height:86vh;padding:0;color:var(--ink);background:linear-gradient(145deg,#111a32,#080d1c);border:1px solid rgba(103,232,249,.3);border-radius:1.4rem;box-shadow:0 35px 100px rgba(0,0,0,.7)}.card-dialog::backdrop{background:rgba(2,6,23,.78);backdrop-filter:blur(8px)}.card-dialog header{display:flex;justify-content:space-between;align-items:start;padding:1.4rem 1.5rem;border-bottom:1px solid var(--line)}.card-dialog h2{margin:.35rem 0 0;font-size:1.3rem}.card-dialog__ref{display:inline-flex;align-items:center;gap:.4rem;color:#67e8f9;font:800 .76rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}.card-status{padding:.3rem .5rem;color:#67e8f9;background:rgba(8,145,178,.12);border:1px solid rgba(103,232,249,.3);border-radius:.5rem;font:750 .74rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;cursor:pointer}.card-dialog__close{color:var(--ink);background:rgba(255,255,255,.08);border:1px solid var(--line);border-radius:.7rem;font-size:1.4rem;cursor:pointer}.card-dialog__back{color:var(--ink);background:rgba(255,255,255,.08);border:1px solid var(--line);border-radius:.7rem;font-size:1.2rem;cursor:pointer;padding:.3rem .6rem;margin-right:.6rem}.card-dialog__back[hidden]{display:none}.card-linkage-table__row{cursor:pointer}.card-linkage-table__row:hover{background:rgba(103,232,249,.08)}
.card-dialog__error{margin:0;padding:.75rem 1.5rem;color:#fecaca;background:rgba(153,27,27,.35);border-bottom:1px solid rgba(248,113,113,.4);font-size:.82rem}.card-dialog__sections{display:grid;gap:1.1rem;padding:1.3rem 1.5rem;overflow-y:auto;overflow-x:hidden;max-height:calc(86vh - 6.5rem)}
.card-section{padding:1rem 1.1rem;background:rgba(255,255,255,.035);border:1px solid var(--line);border-radius:1rem;overflow-wrap:anywhere;min-width:0}.card-section__title{margin:0 0 .7rem;color:#a5b4fc;font-size:.72rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase}
.card-details{display:grid;grid-template-columns:auto 1fr auto 1fr;gap:.45rem 1rem;margin:0}.card-details dt{color:var(--muted);font-size:.74rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;align-self:center}.card-details dd{margin:0;font-size:.88rem;align-self:center}
.card-text{color:#dbeafe;font-size:.9rem;line-height:1.6;white-space:pre-wrap}
.card-list{margin:0;padding-left:1.2rem;display:grid;gap:.3rem;color:#dbeafe;font-size:.88rem;line-height:1.5}
.card-value{display:inline-flex;align-items:center;gap:.45rem}.card-edit-button{padding:.1rem .38rem;color:#67e8f9;background:transparent;border:1px solid rgba(103,232,249,.25);border-radius:.5rem;font-size:.82rem;cursor:pointer;opacity:.65;transition:opacity .15s ease}.card-value:hover .card-edit-button,.card-dialog h2 .card-edit-button,.card-edit-button:focus-visible{opacity:1}.card-edit-button:hover{border-color:rgba(103,232,249,.4);background:rgba(8,145,178,.15)}
.card-edit{display:inline-flex;align-items:center;gap:.45rem;flex-wrap:wrap}.card-edit-input{min-width:12rem;padding:.45rem .6rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid rgba(103,232,249,.35);border-radius:.6rem;font:inherit;font-size:.86rem}textarea.card-edit-input{width:100%;min-width:16rem}.card-edit-save,.card-edit-cancel,.card-comment__action{padding:.4rem .7rem;color:#07111f;background:#67e8f9;border:0;border-radius:.55rem;font-size:.74rem;font-weight:750;cursor:pointer}.card-edit-cancel,.card-comment__action{color:var(--ink);background:rgba(255,255,255,.1);border:1px solid var(--line)}.card-comment__action--danger:hover{color:#fecaca;border-color:rgba(248,113,113,.5);background:rgba(153,27,27,.3)}
.card-comments{margin:0;padding:0;list-style:none;display:grid;gap:.8rem}.card-comment{padding:.85rem 1rem;background:rgba(2,6,23,.4);border:1px solid var(--line);border-radius:.9rem}.card-comment__head{display:flex;align-items:center;gap:.7rem;margin-bottom:.45rem;flex-wrap:wrap}.card-comment__head strong{font-size:.86rem}.card-comment__meta{margin-right:auto;color:var(--muted);font:650 .68rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace}.card-comment__body{color:#dbeafe;font-size:.88rem;line-height:1.55;white-space:pre-wrap}.card-comment__edit{display:grid;gap:.5rem}.card-comment__editor{width:100%;min-height:4.5rem;padding:.55rem .7rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid rgba(103,232,249,.35);border-radius:.6rem;font:inherit;font-size:.86rem}
.card-comment-form[hidden]{display:none}.card-comment-form{display:grid;gap:.6rem;margin-top:.9rem;padding-top:.9rem;border-top:1px solid var(--line)}.card-comment-form select,.card-comment-form textarea{padding:.5rem .65rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid var(--line);border-radius:.6rem;font:inherit;font-size:.86rem}.card-comment-form button{justify-self:start;padding:.5rem 1rem;color:#07111f;background:linear-gradient(110deg,#67e8f9,#a5b4fc);border:0;border-radius:.6rem;font-size:.8rem;font-weight:800;cursor:pointer}
.card-attachment-strip{display:flex;flex-direction:column;gap:.45rem;margin-bottom:.8rem}.card-attachment--discarded{text-decoration:line-through;opacity:.45}.card-attachment{display:flex;width:100%;align-items:center;overflow:hidden;border:1px solid rgba(103,232,249,.3);border-radius:.7rem;background:rgba(8,145,178,.12)}.card-attachment__view{flex:1;display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:.5rem .8rem;color:#a5f3fc;background:transparent;border:0;font-size:.8rem;font-weight:650;cursor:pointer;text-align:left;min-width:0}.card-attachment__view:hover{background:rgba(8,145,178,.25)}.card-attachment__delete{padding:.5rem .6rem;color:var(--muted);background:transparent;border:0;border-left:1px solid rgba(103,232,249,.2);font-size:.9rem;cursor:pointer}.card-attachment__delete:hover{color:#fecaca;background:rgba(153,27,27,.3)}
.card-attach-add{display:inline-flex;align-items:center;padding:.45rem .8rem;color:var(--muted);border:1px dashed var(--line);border-radius:.7rem;font-size:.76rem;font-weight:700;cursor:pointer}.card-attach-add:hover{color:#a5f3fc;border-color:rgba(103,232,249,.4)}.card-attach-add input{display:none}
.card-comment__attachments{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.6rem}
.card-attachment__date{margin-left:auto;flex-shrink:0;color:var(--muted);font:650 .68rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}
.card-composer{margin-bottom:.9rem}.card-composer-toggle{width:100%;padding:.6rem .9rem;text-align:left;color:var(--muted);background:rgba(2,6,23,.4);border:1px dashed var(--line);border-radius:.8rem;font-size:.84rem;font-weight:650;cursor:pointer}.card-composer-toggle:hover{color:#a5f3fc;border-color:rgba(103,232,249,.4)}
.card-md-bar{display:flex;gap:.4rem}.card-md-button{min-width:2.1rem;padding:.35rem .5rem;color:#a5f3fc;background:rgba(8,145,178,.12);border:1px solid rgba(103,232,249,.3);border-radius:.5rem;font-size:.78rem;font-weight:800;cursor:pointer}.card-md-button:hover{background:rgba(8,145,178,.3)}
.card-md-p{margin:.2rem 0}.card-md-list{margin:.2rem 0;padding-left:1.2rem}.card-md-code{padding:.08rem .35rem;background:rgba(2,6,23,.65);border:1px solid var(--line);border-radius:.35rem;font:600 .82em ui-monospace,SFMono-Regular,Menlo,monospace;color:#a5f3fc}
.card-list__row{display:flex;align-items:center;gap:.5rem}.card-list__check{margin-left:auto;width:1.1rem;height:1.1rem;flex-shrink:0;cursor:pointer}.card-list__text--expandable{cursor:pointer}.card-list__text--exempt{text-decoration:line-through;color:var(--muted)}.card-list__text--expandable:hover{text-decoration:underline}.card-list__proof{padding:.3rem .5rem .3rem 1.5rem;display:flex;flex-direction:column;gap:.25rem;font-size:.8rem;color:var(--dim)}.card-list__proof[hidden]{display:none}.card-list__proof-line{display:flex;gap:.5rem}.card-list__proof-command{font-weight:600;flex-shrink:0}.card-list__text{margin-right:auto}.card-list__action{padding:.1rem .4rem;color:#67e8f9;background:transparent;border:1px solid rgba(103,232,249,.25);border-radius:.5rem;font-size:.78rem;cursor:pointer;opacity:.65}.card-list__action:hover{opacity:1}.card-list__action--danger:hover{color:#fecaca;border-color:rgba(248,113,113,.5);background:rgba(153,27,27,.3)}
.card-list-wrap{display:grid;gap:.6rem}.card-list__adder{display:flex;gap:.5rem;align-items:center}.card-list__adder .card-edit-input{flex:1;min-width:8rem}
.card-checklist{display:grid;gap:.7rem}.card-required{display:grid;gap:.9rem}.card-required__group+.card-required__group{padding-top:.7rem;border-top:1px solid var(--line)}.card-required__column{margin:0 0 .4rem;font-size:.78rem;text-transform:uppercase;letter-spacing:.04em;color:var(--muted)}.card-checklist-form{display:flex;gap:.5rem;flex-wrap:wrap;padding-top:.6rem;border-top:1px solid var(--line)}.card-checklist-form input{flex:1;min-width:8rem;padding:.5rem .65rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid var(--line);border-radius:.6rem;font:inherit;font-size:.86rem}.card-checklist-form button{padding:.5rem 1rem;color:#07111f;background:linear-gradient(110deg,#67e8f9,#a5b4fc);border:0;border-radius:.6rem;font-size:.78rem;font-weight:800;cursor:pointer}
.card-viewer{position:absolute;inset:0;z-index:5;display:flex;flex-direction:column;background:rgba(2,6,23,.96);border-radius:1.4rem}.card-viewer[hidden]{display:none}.card-viewer header{display:flex;align-items:center;gap:1rem;padding:1rem 1.4rem;border-bottom:1px solid var(--line)}.card-viewer__name{color:#a5f3fc;font:750 .8rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;margin-right:auto}.card-viewer__download{color:#07111f;background:#67e8f9;padding:.4rem .8rem;border-radius:.55rem;font-size:.74rem;font-weight:800;text-decoration:none}.card-viewer__close{color:var(--ink);background:rgba(255,255,255,.08);border:1px solid var(--line);border-radius:.7rem;font-size:1.2rem;cursor:pointer}.card-viewer img{max-width:100%;max-height:100%;margin:auto;object-fit:contain}.card-viewer iframe{flex:1;width:100%;border:0;background:#f8fafc}.card-viewer__text{flex:1;overflow:auto;margin:0;padding:1.2rem 1.4rem;color:#dbeafe;background:transparent;font:500 .82rem/1.65 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;word-break:break-word}.card-viewer__text[hidden]{display:none}.card-viewer__video{flex:1;width:100%;max-height:100%;background:#000}.card-viewer__audio{width:calc(100% - 2.8rem);margin:2rem 1.4rem}.card-viewer__fallback{margin:auto;padding:2rem;text-align:center;color:var(--muted);font-size:.92rem;line-height:1.7}.card-viewer__video[hidden],.card-viewer__audio[hidden],.card-viewer__fallback[hidden]{display:none}
.card-new{display:grid;gap:.75rem}
.card-new__row{display:grid;gap:.3rem}
.card-new__label{color:var(--muted);font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase}
.card-new__actions{display:flex;gap:.5rem;margin-top:.3rem}
.column__count{display:inline-flex;align-items:center;justify-content:center;min-width:1.45rem;margin-left:.5rem;padding:.1rem .35rem;color:#07111f;background:var(--accent);border-radius:999px;font:800 .68rem/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
.column__count[hidden]{display:none}
.column__add{display:block;width:100%;margin-top:.7rem;padding:.6rem;color:var(--muted);background:transparent;border:1px dashed var(--line);border-radius:.8rem;font-size:.78rem;font-weight:700;cursor:pointer}
.column__add:hover{color:#07111f;background:var(--accent);border-style:solid}
.card-linkage{display:grid;gap:.65rem}
.card-linkage-table{display:flex;flex-direction:column;gap:.35rem;flex:1 1 100%;min-width:min(100%,22rem)}
.card-linkage-table__row{display:grid;grid-template-columns:auto minmax(0,1fr) auto auto auto;gap:.55rem;align-items:center;padding:.35rem .5rem;background:rgba(148,163,184,.06);border:1px solid var(--line);border-radius:.55rem}
.card-linkage-table__row--typed{grid-template-columns:auto auto minmax(0,1fr) auto auto}
.card-linkage__title{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:.85rem}
.card-linkage__status{padding:.22rem .5rem;color:#bae6fd;background:rgba(14,116,144,.18);border:1px solid rgba(103,232,249,.25);border-radius:.5rem;font-size:.68rem;font-weight:700;letter-spacing:.04em;text-transform:uppercase}
.card-linkage__status:empty{display:none}
.card-linkage__type{color:var(--muted);font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.04em}.card-linkage__row{display:flex;align-items:center;gap:.7rem;flex-wrap:wrap}.card-linkage__label{min-width:9rem;color:var(--muted);font-size:.72rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase}.card-linkage__list{display:inline-flex;align-items:center;gap:.5rem;flex-wrap:wrap}.card-linkage__list .card-attachment{display:inline-flex;width:auto}.card-linkage__ref{padding:.3rem .55rem;color:#a5f3fc;background:rgba(8,145,178,.12);border:1px solid rgba(103,232,249,.3);border-radius:.55rem;font:750 .76rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}.card-linkage__links{margin-top:.4rem;padding-top:.7rem;border-top:1px solid var(--line);display:grid;gap:.6rem}.card-link-form{display:flex;gap:.5rem;flex-wrap:wrap}.card-link-form select,.card-link-form input{padding:.5rem .65rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid var(--line);border-radius:.6rem;font:inherit;font-size:.86rem}.card-link-form input{flex:1;min-width:7rem}.card-link-form button{padding:.5rem 1rem;color:#07111f;background:linear-gradient(110deg,#67e8f9,#a5b4fc);border:0;border-radius:.6rem;font-size:.78rem;font-weight:800;cursor:pointer}
@media(max-width:720px){.card-details{grid-template-columns:auto 1fr}}
@media(max-width:520px){.shell{width:calc(100% - .8rem);padding-top:1.2rem}.hero h1{font-size:2.2rem}.card-dialog{width:calc(100% - .6rem);max-height:96vh;border-radius:.9rem}.card-dialog header{padding:.9rem 1rem}.card-dialog__sections{padding:.8rem;max-height:calc(96vh - 5.6rem)}.card-section{padding:.75rem .8rem}.card-details{grid-template-columns:1fr;gap:.1rem .5rem}.card-details dt{margin-top:.55rem}.card-comment-form,.card-checklist-form,.card-link-form{flex-direction:column;display:flex}.card-comment-form select,.card-comment-form textarea{width:100%}.card-linkage__label{min-width:100%}th,td{min-width:13rem;width:13rem}}
CSS
      . '</style></head><body><main class="shell"><header class="hero"><div><span class="eyebrow">Tira Kanban &middot; Filesystem-native flow</span><h1>' . $project_heading . '</h1></div><div class="hero__aside"><p>Focused work, arranged by state. Select a card to keep your place.</p><span class="refresh-status" aria-live="polite">Refresh 60s</span><span class="last-updated">Last updated: pending</span><span class="stale-notice" hidden></span></div></header>'
      . $boards
      . '</main>' . $dialog
      . q~<script>const pageSize=10;const pageState=new Map();const filterState=new Map();const columnKey=list=>list.closest(".board").dataset.type+"::"+list.dataset.column;
const queueClass={answer:".card--waiting",review:".card--to-review"};const queues={answer:false,review:false};const applyQueue=(name,on)=>{queues[name]=on;document.querySelectorAll('[data-queue="'+name+'"]').forEach(button=>{button.setAttribute("aria-pressed",on?"true":"false");button.classList.toggle("is-active",on)});pageState.clear();renderColumns()};const paintFreshness=list=>{const shown=[...list.children].filter(item=>!item.hidden);shown.forEach(item=>item.style.removeProperty("--fresh"));const ranked=shown.filter(item=>!item.querySelector(".card--waiting")).sort((a,b)=>Number(b.dataset.mtime||0)-Number(a.dataset.mtime||0));if(ranked.length<2)return;const newest=Number(ranked[0].dataset.mtime||0);const oldest=Number(ranked[ranked.length-1].dataset.mtime||0);if(newest===oldest)return;ranked.forEach(item=>{const age=(Number(item.dataset.mtime||0)-oldest)/(newest-oldest);item.style.setProperty("--fresh",String(age))})};
const renderColumns=()=>{document.querySelectorAll(".board").forEach(board=>{const matches=filterState.get(board.dataset.type);board.querySelectorAll(".cards").forEach(list=>{const key=columnKey(list);const limit=pageState.get(key)||pageSize;const items=[...list.children];const matched=items.filter(item=>(!matches||matches.has(item.dataset.ref))&&(()=>{const on=Object.keys(queues).filter(name=>queues[name]);return !on.length||on.some(name=>item.querySelector(queueClass[name]))})());items.forEach(item=>{item.hidden=true});matched.slice(0,limit).forEach(item=>{item.hidden=false});paintFreshness(list);const cell=list.parentElement;let more=cell.querySelector(".column__more");if(!more){more=document.createElement("button");more.type="button";more.className="column__more";more.setAttribute("data-more-for",list.dataset.column);more.onclick=()=>{pageState.set(key,(pageState.get(key)||pageSize)+pageSize);renderColumns()};list.insertAdjacentElement("afterend",more)}const remaining=matched.length-Math.min(limit,matched.length);more.textContent="Show "+Math.min(remaining,pageSize)+" more of "+remaining;more.hidden=remaining<=0;const badge=board.querySelector('[data-count-for="'+list.dataset.column+'"]');if(badge){const total=matched.length;badge.textContent=total?String(total):"";badge.hidden=total===0}})})};
const applyFilter=(type,text)=>{document.querySelectorAll("[data-filter]").forEach(box=>{if(box.value!==text)box.value=text});pageState.clear();if(!text){filterState.clear();renderColumns();return Promise.resolve()}return fetch("/search?text="+encodeURIComponent(text),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("filter failed");return response.json()}).then(refs=>{const found=new Set(refs);document.querySelectorAll(".board").forEach(board=>filterState.set(board.dataset.type,found));window.__tiraFilterSeq=(window.__tiraFilterSeq||0)+1;renderColumns()}).catch(()=>{filterState.clear();renderColumns()})};
const updateColumnCounts=()=>renderColumns();const sortBoard=(board,mode)=>{board.querySelectorAll(".cards").forEach(list=>{const cards=[...list.children];cards.sort((a,b)=>mode==="ref"?a.dataset.ref.localeCompare(b.dataset.ref):mode==="priority"?(Number(b.dataset.priority||0)-Number(a.dataset.priority||0)||a.dataset.ref.localeCompare(b.dataset.ref)):(Number(b.dataset.mtime)-Number(a.dataset.mtime)||a.dataset.ref.localeCompare(b.dataset.ref)));cards.forEach(card=>list.appendChild(card))});board.querySelectorAll("[data-sort]").forEach(button=>button.classList.toggle("is-active",button.dataset.sort===mode));document.documentElement.dataset.sort=mode};const widthStorageKey="tira-column-width";const readStoredWidth=()=>{try{return localStorage.getItem(widthStorageKey)}catch(error){return null}};const storeWidth=mode=>{try{localStorage.setItem(widthStorageKey,mode)}catch(error){}};const applyWidth=(mode,persist)=>{const chosen=mode==="fit"?"fit":"standard";document.documentElement.dataset.width=chosen;document.querySelectorAll("[data-width]").forEach(button=>button.classList.toggle("is-active",button.dataset.width===chosen));if(persist)storeWidth(chosen)};~ . $live_helpers . $column_editor
      . q~const bindBoards=()=>{document.querySelectorAll(".card").forEach(card=>{~ . $card_binding
      . q~});document.querySelectorAll(".board").forEach(board=>board.querySelectorAll("[data-sort]").forEach(button=>button.onclick=()=>sortBoard(board,button.dataset.sort)));document.querySelectorAll("[data-width]").forEach(button=>button.onclick=()=>applyWidth(button.dataset.width,true));document.querySelectorAll("[data-queue]").forEach(button=>button.addEventListener("click",()=>applyQueue(button.dataset.queue,!queues[button.dataset.queue])));document.querySelectorAll("[data-add-card]").forEach(button=>button.onclick=()=>openNewCard(button.closest(".board").dataset.type,button.dataset.addCard));document.querySelectorAll("[data-filter]").forEach(input=>{if(input.dataset.bound)return;input.dataset.bound="1";let timer=null;input.oninput=()=>{if(timer)clearTimeout(timer);timer=setTimeout(()=>applyFilter(input.dataset.filter,input.value.trim()),200)}})};const markStale=version=>{const notice=document.querySelector(".stale-notice");if(!notice)return;if(!version){notice.hidden=true;notice.textContent="";return}notice.textContent=`Tira ${version} is installed - restart this board to run it`;notice.hidden=false};const markUpdated=()=>{document.querySelector(".last-updated").textContent=`Last updated: ${new Date().toLocaleString()}`};document.documentElement.dataset.sort="mtime";bindBoards();updateColumnCounts();applyWidth(readStoredWidth(),false);document.documentElement.dataset.ready="true";markUpdated();const params=new URLSearchParams(location.search);const rawRefresh=params.get("refresh");const refreshSeconds=/^\d+$/.test(rawRefresh||"")?Math.max(1,Number(rawRefresh)):60;document.documentElement.dataset.refresh=String(refreshSeconds);document.querySelector(".refresh-status").textContent=`Refresh ${refreshSeconds}s`;const refreshDashboard=()=>~ . $refresh_action
      . q~;const scheduleRefresh=()=>setTimeout(()=>{Promise.resolve(refreshDashboard()).finally(scheduleRefresh)},refreshSeconds*1000);~ . $initial_refresh
      . q~scheduleRefresh();~ . $drag_script . q~</script></body></html>~;
}

sub _empty_linkage {
    my ( $self, $type ) = @_;
    return {
        parent_sow_ref => undef,
        sub_sow_refs   => [],
        epic_refs      => [],
        links          => [],
      } if $type eq 'sow';
    return {
        sow_ref         => undef,
        parent_epic_ref => undef,
        sub_epic_refs   => [],
        ticket_refs     => [],
        links           => [],
      } if $type eq 'epic';
    return {
        epic_ref          => undef,
        parent_ticket_ref => undef,
        sub_ticket_refs   => [],
        links             => [],
    };
}

sub _markdown {
    my ( $self, $data, %args ) = @_;

    # a question list carries a ref, so without this it was taken for a
    # record and drawn as a card with no title. The person who owns the
    # decision reads this view, not the JSON, so it is the one that matters.
    if ( ref($data) eq 'HASH' && ref( $data->{questions} ) eq 'ARRAY' && exists $data->{instruction} ) {
        my $heading = '# Questions on ' . $data->{ref}
          . ( defined $data->{title} && $data->{title} ne '' ? ": $data->{title}" : '' )
          . "\n\n";
        return $heading . "_No questions have been asked about this card._\n"
          if !@{ $data->{questions} };
        my $body = '';
        for my $question ( @{ $data->{questions} } ) {
            my $asked = $question->{author} ? " by $question->{author}" : '';
            $body .= "## $question->{id} \x{2014} $question->{status}\n\n"
              . "$question->{text}\n\n";
            $body .= "_Why:_ $question->{reason}\n\n" if $question->{reason};
            if ( @{ $question->{options} // [] } ) {
                my $n = 0;
                $body .= "_Options:_\n\n"
                  . join( '', map { ++$n . ". $_\n" } @{ $question->{options} } ) . "\n";
            }
            $body .= "_Asked $question->{asked_at}$asked._\n\n";
            $body .= "_Set aside $question->{discarded_at}._\n\n" if $question->{discarded_at};
            my $answer = $question->{answer};
            if ( !$answer ) {
                $body .= "_No answer yet \x{2014} this card is waiting on the owner._\n\n";
                next;
            }
            $body .= "> " . join( "\n> ", split /\n/, $answer->{text} ) . "\n\n";
            my @state = ("answered $answer->{answered_at}");
            push @state, "edited $answer->{updated_at}" if $answer->{updated_at};
            push @state, $answer->{read_at} ? "read $answer->{read_at}" : 'not yet read';
            push @state, $answer->{mark} ? "marked $answer->{mark}" : 'not yet marked';
            $body .= '_' . join( ', ', @state ) . "._\n\n";
        }
        return $heading . $body . "---\n\n$data->{instruction}\n";
    }

    if ( ref($data) eq 'HASH' && exists $data->{ref} ) {

        # An absent description is normal, not a reason to warn on every read.
        my $description = ( $data->{description} // '' ) ne ''
          ? $data->{description} : '_No description._';
        my %priority = ( 1 => 'Low', 2 => 'Medium Low', 3 => 'Medium', 4 => 'High', 5 => 'Very High' );
        my %names;
        my $people = eval {
            $self->person_list( defined $args{project} ? ( project => $args{project} ) : () );
        } // [];
        %names = map { $_->{id} => $_->{name} } @{$people};
        my $assignee = defined $data->{assignee} ? ( $names{ $data->{assignee} } // $data->{assignee} ) : '_Unassigned_';
        my $reporter = defined $data->{reporter} ? ( $names{ $data->{reporter} } // $data->{reporter} ) : '_None_';
        my $priority = defined $data->{priority} ? $priority{ $data->{priority} } : '_None_';
        my $checklist = @{ $data->{checklist} // [] }
          ? "\n## Checklist\n\n" . join( '', map { "- [$_->{status}] $_->{item}\n" } @{ $data->{checklist} } )
          : "\n## Checklist\n\n_Empty._\n";
        my $children = exists $data->{children}
          ? "\n## Children\n\n" . ( @{ $data->{children} }
              ? join( '', map { "- `$_->{ref}`" . ( defined $_->{title} ? " $_->{title}" : '' ) . "\n" }
                  @{ $data->{children} } )
              : "_Empty._\n" )
          : '';
        return '# ' . $data->{ref} . ': ' . ( $data->{title} // '' ) . "\n\n$description\n\n"
          . '- Type: `' . ( $data->{type} // '' ) . "`\n"
          . "- Assignee: $assignee\n"
          . "- Reporter: $reporter\n"
          . "- Priority: $priority\n"
          . '- Created: ' . ( $data->{created_at} // '' ) . "\n"
          . '- Last Updated: ' . ( $data->{last_updated} // '' ) . "\n"
          . $checklist
          . $children;
    }
    if ( ref($data) eq 'HASH' && ref( $data->{_column_order} ) eq 'HASH' ) {
        my $markdown = "# Tira Dashboard\n";
        for my $type (qw(sow epic ticket)) {
            next if !exists $data->{_column_order}{$type};
            $markdown .= "\n## " . uc($type) . "\n";
            for my $column ( @{ $data->{_column_order}{$type} } ) {
                $markdown .= "\n### $column\n";
                my $records = $data->{$type}{$column};
                $markdown .= @{$records}
                  ? join( '', map { "- `$_->{ref}`" . ( defined $_->{title} ? " $_->{title}" : '' ) . "\n" } @{$records} )
                  : "_Empty._\n";
            }
        }
        return $markdown;
    }
    return "# Tira Result\n\n```json\n" . json_object()->canonical->allow_nonref->pretty->encode($data) . "```\n";
}

sub _with_project_lock {
    my ( $self, $root, $code ) = @_;

    # Reentrant. Two handles on one file are two lock entries even in
    # the same process, so a locked operation taking the lock again used to
    # deadlock against itself - which is why the comment, checklist, gate and
    # evidence writers ran outside it and could lose a concurrent write. A root
    # already ours runs inside the lock we are holding.
    if ( $self->{_locked}{$root} ) {
        local $self->{_journal_depth} = ( $self->{_journal_depth} // 0 ) + 1;
        return $code->();
    }
    local $self->{_locked}{$root} = 1;
    my $lock_path = File::Spec->catfile( $root, '.tira', '.lock' );
    open my $lock, '>>', $lock_path or die "Cannot open project lock '$lock_path': $!\n";
    flock( $lock, LOCK_EX ) or die "Cannot lock Tira project '$root': $!\n";
    my ( $result, $error );
    {
        local $self->{_journal_depth} = ( $self->{_journal_depth} // 0 ) + 1;
        eval { $result = $code->(); 1 } or $error = $@ || 'Unknown locked operation failure';
    }
    if ( defined $error ) { delete $self->{_journal} }
    else { eval { $self->_journal_flush($root); 1 } or $error = $@ }
    close $lock or die "Cannot close project lock '$lock_path': $!\n";
    die $error if defined $error;
    return $result;
}

sub _write_yaml {
    my ( $self, $path, $data ) = @_;
    my $yaml = $self->{yaml}->dump_string($data);
    $self->_atomic_write( $path, utf8::is_utf8($yaml) ? encode_utf8($yaml) : $yaml );
}

sub _validated_counter {
    my ( $self, $config, $path ) = @_;
    my $prefix = $config->{prefix};
    die "Invalid prefix in '$path'\n" if !defined $prefix || $prefix !~ /\A([A-Z][A-Z0-9-]{0,31})\z/;
    $prefix = $1;
    my $digits = $config->{digits};
    die "Invalid digits in '$path'\n" if !defined $digits || $digits !~ /\A(\d+)\z/ || $1 < 1 || $1 > 12;
    $digits = 0 + $1;
    my $number = $config->{next_number};
    die "Invalid next_number in '$path'\n" if !defined $number || $number !~ /\A(\d+)\z/ || $1 < 1;
    $number = 0 + $1;
    return ( $prefix, $digits, $number );
}

sub _canonical_path {
    my ( $self, $candidate, $label ) = @_;
    my $resolved = realpath($candidate);
    die "Cannot resolve $label\n" if !defined $resolved;
    die "Unsafe control character in $label\n" if $resolved =~ /[\x00-\x1f\x7f]/;
    $resolved =~ /\A(.+)\z/ or die "Cannot validate $label\n";
    return $1;
}

sub _write_json {
    my ( $self, $path, $data ) = @_;
    my ( $previous, $ref );
    if ( ref $data eq 'HASH' && defined $data->{ref} && $data->{ref} =~ /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12})\z/ ) {
        $ref = $1;
        $previous = -f $path ? eval { $self->_read_json($path) } : undef;
        my @entries = $self->_journal_changes( $previous // {}, $data );
        $self->_journal_record( ref => $ref, op => ( $previous ? 'update' : 'create' ), entries => \@entries )
          if @entries;
    }
    my $json = json_object()->canonical->pretty->utf8->encode($data);
    $self->_atomic_write( $path, $json );
    $self->_search_index_refresh( $path, $json, $data, $ref ) if defined $ref;
    return 1;
}

# A write already holds the project lock and is already writing, so it keeps the
# index warm for the card it just changed. Nobody has to remember to rebuild.
# Where there is no index there is nothing to keep warm, and a project that
# never asked for one pays a single -e for the whole business.
sub _search_index_refresh {
    my ( $self, $path, $json, $data, $ref ) = @_;

    # <root>/.tira/<type>/<column>/<REF>.json
    my $root = dirname( dirname( dirname( dirname($path) ) ) );
    my $dbh = $self->_search_index_dbh($root) or return;
    $self->_search_index_write( $dbh, $ref, $json, $data );
    return;
}

sub _write_json_transaction {
    my ( $self, $updates ) = @_;
    my %original;
    for my $update ( @{$updates} ) {
        my ($path) = @{$update};
        open my $fh, '<:raw', $path or die "Cannot snapshot '$path': $!\n";
        $original{$path} = do { local $/; <$fh> };
        close $fh or die "Cannot close snapshot '$path': $!\n";
    }
    my $ok = eval {
        $self->_write_json( @{$_} ) for @{$updates};
        1;
    };
    if ( !$ok ) {
        my $error = $@ || 'Unknown multi-record write failure';
        for my $path ( keys %original ) {
            $self->_atomic_write( $path, $original{$path} );
        }
        die $error;
    }
    return 1;
}

# A number that goes up whenever anything in a project changes. The read cache
# used to decide it was current by comparing modification times, and Windows
# hands out the same time to two writes inside the same clock tick - about
# sixteen milliseconds - so a caller could be served the board as it was before
# its own write. A counter answers the question exactly, with no clock in it.
sub _bump_generation {
    my ( $self, $path ) = @_;
    my $tira = dirname( dirname( dirname($path) ) );
    return if basename($tira) ne '.tira';
    my $counter = File::Spec->catfile( $tira, '.generation' );
    my $now = 0;
    if ( open my $in, '<', $counter ) {
        my $line = <$in>;
        close $in;
        $now = $1 if defined $line && $line =~ /\A(\d+)/;
    }

    # Written in place rather than through _atomic_write, which is what calls
    # this: it is a single short line under the project lock, and a torn read
    # of it can only ever make the cache more cautious.
    open my $out, '>', $counter or return;
    print {$out} $now + 1, "\n";
    close $out;
    return;
}

sub _atomic_write {
    my ( $self, $path, $content ) = @_;
    my $dir = dirname($path);
    my ( $fh, $temporary ) = tempfile( '.tira-write-XXXXXX', DIR => $dir, UNLINK => 0 );
    $temporary = $self->_canonical_path( $temporary, "temporary file for '$path'" );
    binmode $fh, ':raw';
    print {$fh} $content or die "Cannot write temporary file for '$path': $!\n";
    close $fh or die "Cannot close temporary file for '$path': $!\n";
    my $replaced = $self->_replace_file( $temporary, $path );
    $self->_bump_generation($path) if $replaced;
    $replaced or do {

        # $! is meaningless after a Win32 API call - it reported "Inappropriate
        # I/O control operation" for a permission problem - so the platform's
        # own error is what gets reported where there is one.
        my $error = $WINDOWS ? "$^E" : "$!";
        unlink $temporary;
        die "Cannot replace '$path': $error\n";
    };
    return 1;
}

# POSIX rename replaces the destination. Win32 rename refuses when it exists,
# so on Windows every write to a file that was already there died with
# "Permission denied" - which is every card update, every board change and
# every config write. The platform lab found it; Linux never could.
#
# MoveFileEx with MOVEFILE_REPLACE_EXISTING is a same-volume atomic replace and
# ships with Perl on Windows, so nothing new is depended on. Unlinking the
# target first would also work and is not used: it opens a window where the
# file does not exist, and an atomic replacement is what the documentation
# promises and what a reader of this board relies on.

sub _replace_file {
    my ( $self, $temporary, $path ) = @_;
    return rename( $temporary, $path ) if !$WINDOWS;
    require Win32API::File;
    return Win32API::File::MoveFileEx( $temporary, $path,
        Win32API::File::MOVEFILE_REPLACE_EXISTING() | Win32API::File::MOVEFILE_WRITE_THROUGH() );
}

1;

__END__

=head1 NAME

Tira - Filesystem-native Kanban project management engine

=head1 SYNOPSIS

  my $tira = Tira->new;
  $tira->create_project(dir => 'demo', name => 'Demo');
  my $ticket = $tira->create_record(type => 'ticket', title => 'Ship it');
  print $tira->format_output($ticket);

=head1 DESCRIPTION

Tira stores project configuration beneath C<.tira>, represents board columns as
folders, and stores SOW, epic, and ticket records as JSON files. This module owns
safe project discovery, atomic persistence, monotonic reference allocation, and
the shared TOON, JSON, and Markdown output contract. Text persistence is
canonical UTF-8; legacy isolated bytes are repaired during record reads.
Every work record also supports ordered checklist entries with item/status
values and immutable record-local IDs.

=head1 METHODS

=head2 new

Creates an engine. Tests may supply a C<clock> callback.

=head2 create_project

Creates the canonical project and board layout.

=head2 discover_project

Finds C<.tira/project.yml> by explicit root or upward directory traversal.

=head2 create_record

Creates one free-ranging SOW, epic, or ticket in its Backlog column.
Release 0.03 records include singular assignee, optional reporter, planning and
version metadata, numeric priority, and an immediate generated parent.

=head2 format_output

Encodes data as TOON by default, pretty JSON, or Markdown.

=cut
