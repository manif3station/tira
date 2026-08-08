package Tira;

use strict;
use warnings;

use Cwd qw(abs_path realpath);
use Data::TOON;
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode_utf8 FB_QUIET);
use Fcntl qw(:flock);
use File::Basename qw(basename dirname);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use JSON::PP ();
use POSIX qw(strftime);
use Time::Local qw(timegm_modern);
use YAML::PP;

our $VERSION = '0.64';

my %TYPE_PREFIX = (
    sow    => 'SOW',
    epic   => 'EPC',
    ticket => 'TKT',
);

sub new {
    my ( $class, %args ) = @_;
    return bless {
        clock => $args{clock} || sub { strftime( '%Y-%m-%dT%H:%M:%S%z', localtime ) },
        yaml  => YAML::PP->new( boolean => 'JSON::PP' ),
        path_resolver => $args{path_resolver},
    }, $class;
}

# DD-446: one-command bootstrap. The project lock is not re-entrant, so this
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

sub project_new {
    my ( $self, %args ) = @_;
    die "Project name is required\n" if !defined $args{name} || $args{name} eq '';

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

    my $project = eval { $self->create_project( name => $args{name}, dir => $args{dir} // '.' ) };
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

sub create_project {
    my ( $self, %args ) = @_;
    my $name = $args{name};
    die "Project name is required\n" if !defined $name || $name eq '';
    my $dir = defined $args{dir} && $args{dir} ne '' ? $args{dir} : '.';
    $dir = $self->_safe_path_input( $dir, 'project directory' );

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
                    { name => 'backlog', label => 'Backlog', protected => JSON::PP::true },
                    { name => 'discard', label => 'Discard', protected => JSON::PP::true },
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
                { outward => 'blocks', inward => 'is-blocked-by', protected => JSON::PP::true },
                { outward => 'clones', inward => 'is-cloned-by', protected => JSON::PP::true },
                { outward => 'duplicates', inward => 'is-duplicated-by', protected => JSON::PP::true },
                { outward => 'relates-to', inward => 'relates-to', protected => JSON::PP::true },
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

    return $self->_with_project_lock(
        $root,
        sub {
            my $config_path = File::Spec->catfile( $board, 'config.yml' );
            my $config = $self->{yaml}->load_file($config_path);
            my ( $prefix, $digits, $number ) = $self->_validated_counter( $config, $config_path );
            my $ref = sprintf '%s-%0*d', $prefix, $digits, $number;
            my $record_path = File::Spec->catfile( $board, 'backlog', "$ref.json" );
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
                gate_passing_log     => [],
                evidence             => [],
                attachments          => [],
                checklist            => [],
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
            return $record;
        },
    );
}

sub project_show {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    my $data = $self->{yaml}->load_file( File::Spec->catfile( $root, '.tira', 'project.yml' ) );
    for my $person ( @{ $data->{people} } ) {
        $person->{active} = JSON::PP::true if !exists $person->{active};
    }
    return $data;
}

sub project_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my $path = File::Spec->catfile( $root, '.tira', 'project.yml' );
        my $data = $self->{yaml}->load_file($path);
        $data->{name} = $args{name} if defined $args{name};
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
        my $person = { id => $args{id}, name => $args{name}, email => $args{email} // '', active => JSON::PP::true };
        push @{ $data->{people} }, $person;
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

sub person_update {
    my ( $self, %args ) = @_;
    my $root = $self->discover_project(%args);
    return $self->_with_project_lock( $root, sub {
        my ( $path, $data ) = $self->_project_data($root);
        my ($person) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $data->{people} };
        die "Person '$args{id}' not found\n" if !$person;
        $person->{name} = $args{name} if defined $args{name};
        $person->{email} = $args{email} if defined $args{email};
        $data->{last_updated} = $self->{clock}->();
        $self->_write_yaml( $path, $data );
        return $person;
    } );
}

sub person_remove {
    my ( $self, %args ) = @_;
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
    return $self->_set_person_active( %args, active => JSON::PP::true );
}

sub person_deactivate {
    my ( $self, %args ) = @_;
    return $self->_set_person_active( %args, active => JSON::PP::false );
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
        my $link = { outward => $args{outward}, inward => $args{inward}, protected => JSON::PP::false };
        push @{ $data->{link_types} }, $link;
        $self->_write_yaml( $path, $data );
        return $link;
    } );
}

sub link_type_remove {
    my ( $self, %args ) = @_;
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

sub column_list {
    my ( $self, %args ) = @_;
    my ( undef, $config ) = $self->_board_data(%args);
    return $config->{columns};
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
        my $column = { name => $args{name}, label => $args{label} // $args{name}, protected => JSON::PP::false };
        my $position = @{ $config->{columns} } - 1;
        for my $i ( 0 .. $#{ $config->{columns} } ) {
            $position = $i + 1 if defined $args{after} && $config->{columns}[$i]{name} eq $args{after};
            $position = $i if defined $args{before} && $config->{columns}[$i]{name} eq $args{before};
        }
        splice @{ $config->{columns} }, $position, 0, $column;
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
    gate_passing_log evidence attachments checklist subtasks linkage assignee
    reporter labels due_date start_date sdlc_gate lifecycle priority
    fix_version affects_versions parent comments created_at last_updated column
    content_hash attachment_count
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
    $container->{"${key}_truncated"} = JSON::PP::true;
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
        return { unchanged => JSON::PP::true } if _record_content_hash($full) eq $args{if_changed};
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
        $reference->{added_at} = strftime( '%Y-%m-%dT%H:%M:%S%z', localtime( ( stat $stored )[9] ) );
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
                      { field => 'comments', ( @added ? ( added => \@added ) : ( changed => JSON::PP::true ) ) };
                }
                elsif ( !ref $old && !ref $new ) {
                    push @field_changes, { field => $field, before => $old, after => $new };
                }
                else {
                    push @field_changes, { field => $field, changed => JSON::PP::true };
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
        $by_ref{$ref} = defined $record ? $record : { ref => $ref, not_found => JSON::PP::true };
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
    my @records;
    for my $candidate ( defined $args{type} ? ( $args{type} ) : qw(sow epic ticket) ) {
        my $type = $self->_valid_type($candidate);
        my $board = File::Spec->catdir( $root, '.tira', $type );
        next if !-d $board;
        find( { no_chdir => 1, wanted => sub {
            return if !-f $File::Find::name || basename( $File::Find::name ) !~ /\.json\z/;
            my $path = $self->_canonical_path( $File::Find::name, 'record file' );
            my $record = $self->_read_json($path);
            my $column = basename( dirname($path) );
            return if defined $args{column} && $column ne $args{column};
            return if defined $args{assignee} && ( $record->{assignee} // '' ) ne $args{assignee};
            my $parent = $record->{parent} // '';
            return if defined $args{parent} && $parent ne $args{parent};
            if ( defined $args{text} ) {
                my $haystack = join ' ', $record->{ref}, $record->{title}, $record->{description};
                return if index( lc $haystack, lc $args{text} ) < 0;
            }
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
        return { unchanged => JSON::PP::true }
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
        for my $field (qw(title description problem_or_feature solution_needed source sdlc_gate lifecycle fix_version)) {
            $record->{$field} = $args{$field} if defined $args{$field};
        }
        for my $field (qw(sdlc_gate lifecycle fix_version)) {
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
        $self->_journal_record(
            ref => $record->{ref}, op => 'move',
            entries => [ { field => 'column', before => $previous_column, after => $column } ],
        ) if $previous_column ne $column;
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
    return { valid => @issues ? JSON::PP::false : JSON::PP::true, issues => \@issues };
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
        push @columns, map { { name => $_, label => $_, protected => JSON::PP::false } } @unconfigured;
        push @columns, $discard;
        $config->{columns} = \@columns;
        $self->_write_yaml( $path, $config );
    }
    return { missing => \@missing, unconfigured => \@unconfigured, applied => $args{apply} ? JSON::PP::true : JSON::PP::false };
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
            die "Hierarchy requires SOW-to-epic or epic-to-ticket\n";
        }
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
        return { parent => $parent->{ref}, child => $child->{ref}, unlinked => JSON::PP::true };
    } );
}

sub hierarchy_show {
    my ( $self, %args ) = @_;
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
        return { parent => $parent->{ref}, child => $child->{ref}, unlinked => JSON::PP::true };
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
        return { removed => JSON::PP::true };
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

sub comment_add {
    my ( $self, %args ) = @_;
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
}

sub comment_update {
    my ( $self, %args ) = @_;
    my $record = $self->record_show(%args);
    my ($comment) = grep { $_->{id} eq ( $args{comment} // '' ) } @{ $record->{comments} };
    die "Comment '$args{comment}' not found\n" if !$comment;
    $comment->{body} = $args{text} if defined $args{text};
    $comment->{format} = $args{format} if defined $args{format};
    $comment->{last_updated} = $self->{clock}->();
    $self->_replace_record( %args, record => $record );
    return $comment;
}

sub comment_remove {
    my ( $self, %args ) = @_;
    my $record = $self->record_show(%args);
    my $id = $args{comment} // '';
    my ($removed) = grep { $_->{id} eq $id } @{ $record->{comments} };
    die "Comment '$id' not found\n" if !$removed;
    $record->{comments} = [ grep { $_->{id} ne $id } @{ $record->{comments} } ];
    $self->_replace_record( %args, record => $record );
    return $removed;
}

sub comment_attach {
    my ( $self, %args ) = @_;
    return $self->attachment_add(%args);
}

sub attachment_add {
    my ( $self, %args ) = @_;
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
    my $deduped = defined $retained;
    if ( !$deduped ) {
        push @{$attachments}, $reference;
        $retained = $reference;
    }
    $self->_replace_record( project => $root, ref => $args{ref}, record => $record );
    return {
        %{$retained}, supplied_filename => $name,
        deduped => $deduped ? JSON::PP::true : JSON::PP::false,
    };
}

# Removes one attachment reference from a record (or one of its comments).
# Storage is deduplicated by content hash, so the stored file is physically
# removed - through the logged attachment_remove workflow - only when no
# record or comment anywhere in the project still references it.
sub attachment_detach {
    my ( $self, %args ) = @_;
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
        detached => JSON::PP::true, sha => $sha, extension => $extension,
        removed_from_store => $removed ? JSON::PP::true : JSON::PP::false,
    };
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
        my $entries = $self->{yaml}->load_file($log_path) || [];
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
    my $entries = -f $log_path ? ( $self->{yaml}->load_file($log_path) || [] ) : [];
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
        my $references = $self->record_show(%args)->{attachments};
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
    return $self->record_show(%args)->{attachments} if defined $args{ref};
    my $root = $self->discover_project(%args);
    my $dir = File::Spec->catdir( $root, '.tira', 'attachments' );
    opendir my $dh, $dir or die "Cannot read attachments: $!\n";
    my @items = map { my ( $sha, $ext ) = /\A([0-9a-f]{64})\.([^.]+)\z/; { sha => $sha, extension => $ext } }
      grep { /\A[0-9a-f]{64}\.[^.]+\z/ } readdir $dh;
    closedir $dh;
    if ( $args{include_deleted} ) {
        my $log_path = File::Spec->catfile( $root, '.tira', 'attachments', 'delete.log.yml' );
        if ( -f $log_path ) {
            push @items, map { { %{$_}, deleted => JSON::PP::true } } @{ $self->{yaml}->load_file($log_path) || [] };
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
    $clone = $self->record_update( project => $args{project}, ref => $clone->{ref}, %copy );
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
    $self->_require_person( %args, person => $args{author} ) if defined $args{author};
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
    die "Invalid gate result\n" if ( $args{result} // '' ) !~ /\A(?:pass|fail|blocked)\z/;
    $self->_require_person( %args, person => $args{author} ) if defined $args{author};
    my $record = $self->record_show(%args);
    my $entry = {
        id => sprintf( 'GATE-%03d', @{ $record->{gate_passing_log} } + 1 ),
        gate => $args{gate}, result => $args{result}, details => $args{details},
        author => $args{author}, annotations => [], created_at => $self->{clock}->(),
    };
    push @{ $record->{gate_passing_log} }, $entry;
    $self->_replace_record( %args, record => $record );
    return $entry;
}

sub gate_annotate {
    my ( $self, %args ) = @_;
    return $self->_annotate_log( %args, field => 'gate_passing_log', label => 'Gate' );
}

sub checklist_list {
    my ( $self, %args ) = @_;
    return $self->record_show(%args)->{checklist};
}

sub checklist_add {
    my ( $self, %args ) = @_;
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
    $self->_replace_record( %args, record => $record );
    return $entry;
}

sub checklist_update {
    my ( $self, %args ) = @_;
    die "Checklist item or status is required\n" if !defined $args{item} && !defined $args{status};
    die "Checklist item is required\n" if defined $args{item} && $args{item} eq '';
    die "Checklist status is required\n" if defined $args{status} && $args{status} eq '';
    my $record = $self->record_show(%args);
    my ($entry) = grep { $_->{id} eq ( $args{id} // '' ) } @{ $record->{checklist} };
    die "Checklist entry '$args{id}' not found\n" if !$entry;
    $entry->{item} = $args{item} if defined $args{item};
    $entry->{status} = $args{status} if defined $args{status};
    $entry->{last_updated} = $self->{clock}->();
    $self->_replace_record( %args, record => $record );
    return $entry;
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
            dry_run => $args{dry_run} ? JSON::PP::true : JSON::PP::false,
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
        return { dry_run => $args{dry_run} ? JSON::PP::true : JSON::PP::false,
          changed_records => scalar keys %changed, changes => \@diffs };
    } );
}

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
                my $card = $args{summary} ? { ref => $ref } : { %{ $self->_read_json($path) }, column => $column->{name} };
                $card->{title} = $self->_read_json($path)->{title} if $args{summary} && $args{with_title};
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
    my $data = $self->{yaml}->load_file($path);
    for my $person ( @{ $data->{people} } ) {
        $person->{active} = JSON::PP::true if !exists $person->{active};
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
        return $person;
    } );
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
    die "Priority must be an integer from 1 to 5\n" if $priority !~ /\A([1-5])\z/;
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
    my $config = $self->{yaml}->load_file($path);
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

# JSON::PP is core but pure Perl: decoding a mature board costs seconds
# (measured on 138 records averaging 32KB — 1992ms with JSON::PP, 6ms with
# an XS backend, while reading the same files without parsing costs 2ms).
# Cpanel::JSON::XS is used when installed and JSON::PP otherwise. The two
# emit byte-identical canonical and pretty output and share
# JSON::PP::Boolean, so stored records never rewrite and content hashes
# never drift — t/38 proves that against whichever backend is present.
my @JSON_BACKENDS = qw(Cpanel::JSON::XS JSON::PP);
my $JSON_BACKEND;

sub _select_json_backend {
    my (@candidates) = @_;
    for my $class (@candidates) {
        ( my $file = $class ) =~ s{::}{/}g;
        return $class if eval { require "$file.pm"; 1 };
    }
    return 'JSON::PP';
}

sub json_backend {
    $JSON_BACKEND //= _select_json_backend(@JSON_BACKENDS);
    return $JSON_BACKEND;
}

sub json_object { return json_backend()->new }

# Drop-in for JSON::PP::decode_json: UTF-8 bytes in, characters out.
sub json_decode { return json_object()->utf8->decode( $_[0] ) }

# DD-443: per-field history. Every record write funnels through
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

# DD-443 reads reuse the CA20 window semantics and the CA09 truncation.
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
            push @entries, json_decode($line);
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
            push @entries, { field => $field, changed => JSON::PP::true };
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
        print {$fh} map { json_object()->canonical->encode($_) . "\n" } @{ $grouped{$ref} }
          or die "Cannot write history for '$ref': $!\n";
        close $fh or die "Cannot close history for '$ref': $!\n";
    }
    return;
}

sub _read_json {
    my ( $self, $path ) = @_;
    open my $fh, '<:raw', $path or die "Cannot read JSON '$path': $!\n";
    my $content = do { local $/; <$fh> };
    close $fh or die "Cannot close JSON '$path': $!\n";
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

sub _valid_type {
    my ( $self, $type ) = @_;
    $type //= '';
    die "Unsupported record type '$type'\n" if $type !~ /\A(sow|epic|ticket)\z/;
    return $1;
}

sub _safe_path_input {
    my ( $self, $path, $label ) = @_;
    die "Unsafe control character in $label\n" if !defined $path || $path =~ /[\x00-\x1f\x7f]/;
    $path =~ /\A(.+)\z/ or die "Cannot validate $label\n";
    return $1;
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
    return $self->_markdown( $data, %args ) if $output eq 'human';
    return $self->_dashboard_table( $data, %args ) if $output eq 'table';
    die "Unsupported output format '$output'\n";
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
        my $headers = join '', map {
            '<th scope="col"><span class="column__name">' . $self->_html_escape($_)
              . '</span><span class="column__count" data-count-for="' . $self->_html_escape($_) . '" hidden></span></th>'
        } @columns;
        my $cells = join '', map {
            my $column = $_;
            my $cards = join '', map {
                my $ref = $self->_html_escape( $_->{ref} );
                my $title = defined $_->{title}
                  ? '<span class="card__title">' . $self->_html_escape( $_->{title} ) . '</span>' : '';
                my $mtime = 0 + ( $_->{_mtime} // 0 );
                '<li data-ref="' . $ref . '" data-mtime="' . $mtime
                  . '"><button class="card" type="button" data-ref="' . $ref
                  . '"><span class="card__ref">' . $ref . '</span>' . $title . '</button></li>';
            } @{ $data->{$type}{$column} // [] };
            my $slug = $self->_html_escape($column);
            $rendered_cards += scalar @{ $data->{$type}{$column} // [] };
            '<td><ol class="cards" data-column="' . $slug . '">' . $cards . '</ol>'
              . ( $args{live}
                ? '<button class="column__add" type="button" data-add-card="' . $slug . '">+ Add card</button>'
                : '' )
              . '</td>';
        } @columns;
        push @rendered_boards, $heading{$type};
        $boards .= '<section class="board board--' . $type . '" data-type="' . $type . '">'
          . '<header class="board__header"><span class="board__kicker">Tira board</span><h2>'
          . $heading{$type} . '</h2><div class="sorter" role="group" aria-label="Sort cards">'
          . '<button type="button" data-sort="mtime" class="is-active">Last modified</button>'
          . '<button type="button" data-sort="ref">Card reference</button></div>'
          . '<input class="board-filter" type="search" data-filter="' . $type
          . '" placeholder="Filter cards" aria-label="Filter cards">'
          . '<div class="widther" role="group" aria-label="Column width">'
          . '<button type="button" data-width="standard" class="is-active">Standard</button>'
          . '<button type="button" data-width="fit">Fit all</button></div></header>'
          . '<div class="board__scroll"><table><thead><tr>'
          . $headers . '</tr></thead><tbody><tr>' . $cells . '</tr></tbody></table></div></section>';
    }
    my $project_heading = 'Tira Kanban';
    if ( defined $args{project} ) {
        my $project_name = eval { $self->project_show( project => $args{project} )->{name} };
        $project_heading = $self->_html_escape($project_name) if defined $project_name && $project_name ne '';
    }
    my $refresh_action = $args{live}
      ? q{fetch("/data",{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("refresh failed");return response.json()}).then(data=>{updateBoards(data);markUpdated();maybeRefreshDialog()}).catch(()=>{})}
      : q{location.reload()};
    my $live_helpers = $args{live} ? q{const recordsByRef=new Map();const showTitles=document.documentElement.dataset.withTitle==="1";const dialog=document.querySelector(".card-dialog");const sectionsHost=dialog.querySelector(".card-dialog__sections");const errorHost=dialog.querySelector(".card-dialog__error");let lastDialogRecordJson="";const priorityLabels={1:"Low",2:"Medium Low",3:"Medium",4:"High",5:"Very High"};let people=[];const peopleName=id=>{const match=people.find(person=>person.id===id);return match?match.name:id};fetch("/people",{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("people failed");return response.json()}).then(list=>{people=list}).catch(()=>{});let linkTypes=[];fetch("/link-types",{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("link types failed");return response.json()}).then(list=>{linkTypes=list}).catch(()=>{});const el=(tag,cls,text)=>{const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node};const dash="\u2014";const textOr=value=>value===null||value===undefined||value===""?dash:String(value);const entryText=entry=>{if(entry===null||entry===undefined)return dash;if(typeof entry!=="object")return String(entry);if(entry.original_filename)return entry.original_filename+"."+(entry.extension||"bin");return Object.values(entry).filter(value=>typeof value==="string"&&value!=="").join(" \u00b7 ")||dash};const humanDate=value=>value?String(value).replace("T"," ").replace(/[+Z].*$/,""):dash;const showError=message=>{errorHost.textContent=message||"";errorHost.hidden=!message};const viewer=dialog.querySelector(".card-viewer");const imageExts={png:1,jpg:1,jpeg:1,gif:1,webp:1,svg:1};const attachmentUrl=(sha,ext)=>"/attachment?ref="+encodeURIComponent(dialog.dataset.ref)+"&sha="+encodeURIComponent(sha)+"&extension="+encodeURIComponent(ext);const textExts={txt:1,md:1,log:1,csv:1,json:1,yml:1,yaml:1,xml:1,html:1};const videoExts={mp4:1,m4v:1,mov:1,webm:1};const audioExts={mp3:1,wav:1,m4a:1,ogg:1,flac:1};const tiffExts={tif:1,tiff:1};const docExts={pdf:1};const viewerPanes=()=>({frame:viewer.querySelector("iframe"),image:viewer.querySelector("img"),textPane:viewer.querySelector(".card-viewer__text"),video:viewer.querySelector(".card-viewer__video"),audio:viewer.querySelector(".card-viewer__audio"),fallback:viewer.querySelector(".card-viewer__fallback")});const hideAllPanes=()=>{const panes=viewerPanes();panes.frame.hidden=true;panes.frame.src="about:blank";panes.image.hidden=true;panes.image.removeAttribute("src");panes.image.onerror=null;panes.textPane.hidden=true;panes.textPane.textContent="";panes.video.hidden=true;panes.video.pause();panes.video.removeAttribute("src");panes.video.load();panes.audio.hidden=true;panes.audio.pause();panes.audio.removeAttribute("src");panes.fallback.hidden=true};const openViewer=(sha,ext,name)=>{const panes=viewerPanes();const download=viewer.querySelector(".card-viewer__download");viewer.querySelector(".card-viewer__name").textContent=name;const url=attachmentUrl(sha,ext);download.href=url;download.setAttribute("download",name);hideAllPanes();if(imageExts[ext]||tiffExts[ext]){panes.image.onerror=()=>{panes.image.hidden=true;panes.fallback.hidden=false};panes.image.src=url;panes.image.hidden=false}else if(videoExts[ext]){panes.video.src=url;panes.video.hidden=false}else if(audioExts[ext]){panes.audio.src=url;panes.audio.hidden=false}else if(textExts[ext]){panes.textPane.textContent="Loading\u2026";panes.textPane.hidden=false;fetch(url,{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("attachment failed");return response.text()}).then(content=>{panes.textPane.textContent=content}).catch(()=>{panes.textPane.textContent="Unable to load attachment"})}else if(docExts[ext]){panes.frame.src=url;panes.frame.hidden=false}else{panes.fallback.hidden=false}viewer.hidden=false};const closeViewer=()=>{viewer.hidden=true;hideAllPanes()};viewer.querySelector(".card-viewer__close").addEventListener("click",closeViewer);dialog.addEventListener("cancel",event=>{if(!viewer.hidden){event.preventDefault();closeViewer()}});dialog.addEventListener("close",()=>{closeViewer();showError("")});const uploadFile=(file,commentId)=>{const reader=new FileReader();reader.onload=()=>{const base64=String(reader.result).split(",")[1]||"";const payload={ref:dialog.dataset.ref,filename:file.name,content_base64:base64};if(commentId)payload.comment=commentId;mutate("/attachment/add",payload)};reader.readAsDataURL(file)};const inlineMd=(host,text)=>{const pattern=/(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)/g;let last=0;let match;while((match=pattern.exec(text))){if(match.index>last)host.appendChild(document.createTextNode(text.slice(last,match.index)));const token=match[0];if(token.indexOf("**")===0)host.appendChild(el("strong","",token.slice(2,-2)));else if(token.indexOf("`")===0)host.appendChild(el("code","card-md-code",token.slice(1,-1)));else host.appendChild(el("em","",token.slice(1,-1)));last=match.index+token.length}if(last<text.length)host.appendChild(document.createTextNode(text.slice(last)))};const renderMarkdown=body=>{const container=el("div","card-comment__body");String(body||"").split(/\n{2,}/).forEach(block=>{const lines=block.split("\n");if(lines.length&&lines.every(line=>/^\s*[-*] /.test(line))){const listNode=el("ul","card-md-list");lines.forEach(line=>{const item=el("li","");inlineMd(item,line.replace(/^\s*[-*] /,""));listNode.appendChild(item)});container.appendChild(listNode)}else{const paragraph=el("p","card-md-p");lines.forEach((line,index)=>{if(index)paragraph.appendChild(document.createElement("br"));inlineMd(paragraph,line)});container.appendChild(paragraph)}});return container};const sortByStamp=(items,key)=>[...(items||[])].sort((a,b)=>String(b[key]||"").localeCompare(String(a[key]||"")));const attachChip=(reference,commentId)=>{const chip=el("span","card-attachment");const key=reference.sha+"."+reference.extension;const name=reference.original_filename||key;const view=el("button","card-attachment__view",name);view.appendChild(el("span","card-attachment__date",humanDate(reference.added_at)));view.type="button";view.dataset.viewAttachment=key;view.onclick=()=>openViewer(reference.sha,reference.extension,name);const drop=el("button","card-attachment__delete","\u00d7");drop.type="button";drop.dataset.detachAttachment=key;drop.title="Delete attachment";drop.onclick=()=>{if(!confirm("Delete "+name+"?"))return;const payload={ref:dialog.dataset.ref,sha:reference.sha,extension:reference.extension};if(commentId)payload.comment=commentId;mutate("/attachment/remove",payload)};chip.append(view,drop);return chip};const attachInput=commentId=>{const label=el("label","card-attach-add");label.append(el("span","","Attach file"));const input=el("input","card-attach-input");input.type="file";if(commentId){input.dataset.attachComment=commentId}else{input.dataset.attachTarget="record"}input.onchange=()=>{if(input.files[0])uploadFile(input.files[0],commentId)};label.appendChild(input);return label};const listFields={labels:1,affects_versions:1,key_details:1,deliverables:1,scope_included:1,scope_excluded:1,acceptance_criteria:1,test_steps:1,bdd:1,atdd:1};const sendList=(field,items)=>mutate("/update",{ref:dialog.dataset.ref,field:field,value:items});const editableList=(field,items)=>{const wrap=el("div","card-list-wrap");const list=el("ul","card-list card-list--editable");(items||[]).forEach((item,index)=>{const row=el("li","card-list__row");const text=el("span","card-list__text",String(item));const editBtn=el("button","card-list__action","\u270e");editBtn.type="button";editBtn.dataset.listEdit=field+":"+index;editBtn.title="Edit item";editBtn.onclick=()=>{const input=el("input","card-edit-input");input.type="text";input.value=String(item);input.dataset.listInput=field;const save=el("button","card-edit-save","Save");save.type="button";save.dataset.listSave=field;save.onclick=()=>{const next=(items||[]).map(String);next[index]=input.value;sendList(field,next)};const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const editor=el("span","card-edit");editor.append(input,save,cancel);row.replaceChildren(editor);input.focus()};const removeBtn=el("button","card-list__action card-list__action--danger","\u00d7");removeBtn.type="button";removeBtn.dataset.listRemove=field+":"+index;removeBtn.title="Remove item";removeBtn.onclick=()=>{const next=(items||[]).map(String);next.splice(index,1);sendList(field,next)};row.append(text,editBtn,removeBtn);list.appendChild(row)});wrap.appendChild(list);const adder=el("div","card-list__adder");const input=el("input","card-edit-input");input.type="text";input.placeholder="Add item";input.setAttribute("data-list-add",field);const save=el("button","card-edit-save","Add");save.type="button";save.dataset.listAddSave=field;const submit=()=>{if(!input.value)return;sendList(field,(items||[]).map(String).concat(input.value))};save.onclick=submit;input.onkeydown=event=>{if(event.key==="Enter"){event.preventDefault();submit()}};adder.append(input,save);wrap.appendChild(adder);return wrap};const reloadCard=()=>fetch("/record?type="+encodeURIComponent(dialog.dataset.type)+"&ref="+encodeURIComponent(dialog.dataset.ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(record=>{renderCard(record);return record}).catch(()=>null);const dialogEditingActive=()=>!!(dialog.querySelector(".card-new")||dialog.querySelector(".card-edit")||dialog.querySelector(".card-comment__edit")||(document.activeElement&&dialog.contains(document.activeElement)&&/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName))||(dialog.querySelector(".card-comment-form")&&!dialog.querySelector(".card-comment-form").hidden));const maybeRefreshDialog=()=>{if(!dialog.open)return;if(!dialog.dataset.ref)return;if(dialogEditingActive())return;fetch("/record?type="+encodeURIComponent(dialog.dataset.type)+"&ref="+encodeURIComponent(dialog.dataset.ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(record=>{if(!record||!dialog.open||dialogEditingActive())return;if(JSON.stringify(record)===lastDialogRecordJson)return;renderCard(record)}).catch(()=>null)};const mutate=(path,payload)=>fetch(path,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(payload)}).then(response=>response.json()).then(result=>{window.__tiraLastMutation=path;window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;if(result.ok){showError("");return reloadCard()}if(result.conflict){showError(result.error||"This card changed while you were editing \u2014 review and retry");return reloadCard()}showError(result.error||"Change failed");return null}).catch(()=>{window.__tiraLastMutation=path;window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;showError("Change failed");return null});const longFields={description:1,problem_or_feature:1,solution_needed:1};const editorFor=field=>{if(field==="priority"){const select=el("select","card-edit-input");["","1","2","3","4","5"].forEach(value=>{const option=el("option","",value===""?dash:value+" "+priorityLabels[value]);option.value=value;select.appendChild(option)});return select}if(field==="assignee"||field==="reporter"){const select=el("select","card-edit-input");const empty=el("option","",dash);empty.value="";select.appendChild(empty);people.forEach(person=>{const option=el("option","",person.name);option.value=person.id;select.appendChild(option)});return select}if(longFields[field]){const area=el("textarea","card-edit-input");area.rows=5;return area}const input=el("input","card-edit-input");input.type="text";return input};const beginEdit=(field,current,slot)=>{const editor=editorFor(field);editor.value=current===null||current===undefined?"":String(current);const base=current===undefined?null:current;const save=el("button","card-edit-save","Save");save.type="button";save.dataset.save=field;save.onclick=()=>mutate("/update",{ref:dialog.dataset.ref,field:field,value:editor.value,base:base});const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const wrap=el("span","card-edit");wrap.append(editor,save,cancel);slot.replaceChildren(wrap);editor.focus()};const editableValue=(field,record,display)=>{const slot=el("span","card-value");slot.appendChild(el("span","card-value__text",display));const edit=el("button","card-edit-button","\u270e");edit.type="button";edit.dataset.edit=field;edit.title="Edit "+field.replace(/_/g," ");edit.onclick=()=>beginEdit(field,record[field],slot);slot.appendChild(edit);return slot};const section=(title,body)=>{const box=el("section","card-section");box.appendChild(el("h3","card-section__title",title));box.appendChild(body);return box};const listBody=values=>{const list=el("ul","card-list");values.forEach(value=>list.appendChild(el("li","",value)));return list};const maybeListSection=(title,items,map)=>{const values=(items||[]).map(map||entryText);if(!values.length)return;sectionsHost.appendChild(section(title,listBody(values)))};const detailRow=(grid,label,value)=>{grid.appendChild(el("dt","",label));const dd=el("dd","");if(value instanceof Node){dd.appendChild(value)}else{dd.textContent=value}grid.appendChild(dd)};const renderCard=record=>{if(!record)return;lastDialogRecordJson=JSON.stringify(record);dialog.dataset.ref=record.ref;dialog.dataset.type=record.type;{const refLine=dialog.querySelector(".card-dialog__ref");refLine.replaceChildren(el("span","",[record.ref||"Card",record.type].filter(Boolean).join(" \u00b7 ")+" \u00b7 "));const statusSelect=el("select","card-status");statusSelect.title="Move to column";const board=document.querySelector(".board--"+record.type);if(board){const lists=[...board.querySelectorAll(".cards")];const headers=[...board.querySelectorAll("th")];lists.forEach((list,index)=>{const header=headers[index];const headerName=header?header.querySelector(".column__name"):null;const option=el("option","",headerName?headerName.textContent:(header?header.textContent:list.dataset.column));option.value=list.dataset.column;if(list.dataset.column===record.column)option.selected=true;statusSelect.appendChild(option)})}else{const option=el("option","",record.column||"");option.value=record.column||"";option.selected=true;statusSelect.appendChild(option)}statusSelect.onchange=()=>{fetch("/move",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:record.type,ref:record.ref,column:statusSelect.value})}).then(response=>{if(!response.ok)throw new Error("move failed");return response.json()}).then(()=>{window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;refreshDashboard();return reloadCard()}).catch(()=>showError("Unable to move the card"))};refLine.appendChild(statusSelect)};dialog.querySelector(".card-dialog__title").replaceChildren(editableValue("title",record,textOr(record.title)));sectionsHost.replaceChildren();const grid=el("dl","card-details");detailRow(grid,"Assignee",editableValue("assignee",record,record.assignee?peopleName(record.assignee):dash));detailRow(grid,"Reporter",editableValue("reporter",record,record.reporter?peopleName(record.reporter):dash));detailRow(grid,"Priority",editableValue("priority",record,record.priority?record.priority+" "+priorityLabels[record.priority]:dash));detailRow(grid,"Labels",editableList("labels",record.labels));detailRow(grid,"Start date",editableValue("start_date",record,humanDate(record.start_date)));detailRow(grid,"Due date",editableValue("due_date",record,humanDate(record.due_date)));detailRow(grid,"Fix version",editableValue("fix_version",record,textOr(record.fix_version)));detailRow(grid,"Affects versions",editableList("affects_versions",record.affects_versions));detailRow(grid,"SDLC gate",editableValue("sdlc_gate",record,textOr(record.sdlc_gate)));detailRow(grid,"Lifecycle",editableValue("lifecycle",record,textOr(record.lifecycle)));detailRow(grid,"Parent",textOr(record.parent));detailRow(grid,"Source",editableValue("source",record,textOr(record.source)));detailRow(grid,"Created",humanDate(record.created_at));detailRow(grid,"Last updated",humanDate(record.last_updated));sectionsHost.appendChild(section("Details",grid));const sectionWithEdit=(title,field)=>{const box=el("section","card-section");const heading=el("h3","card-section__title",title);const edit=el("button","card-edit-button","\u270e");edit.type="button";edit.dataset.edit=field;edit.title="Edit "+title;heading.appendChild(edit);const body=el("div","card-text");const slot=el("span","card-value");slot.appendChild(el("span","card-value__text",textOr(record[field])));body.appendChild(slot);edit.onclick=()=>beginEdit(field,record[field],slot);box.append(heading,body);return box};[["Description","description"],["Problem / Feature","problem_or_feature"],["Solution Needed","solution_needed"]].forEach(pair=>sectionsHost.appendChild(sectionWithEdit(pair[0],pair[1])));[["Key Details","key_details",record.key_details],["Deliverables","deliverables",record.deliverables],["Scope Included","scope_included",record.scope&&record.scope.included],["Scope Excluded","scope_excluded",record.scope&&record.scope.excluded],["Acceptance Criteria","acceptance_criteria",record.acceptance_criteria],["Test Steps","test_steps",record.test_steps],["BDD","bdd",record.bdd],["ATDD","atdd",record.atdd]].forEach(triple=>sectionsHost.appendChild(section(triple[0],editableList(triple[1],triple[2]))));{const box=el("div","card-checklist");const list=el("ul","card-list");(record.checklist||[]).forEach(entry=>{const row=el("li","card-list__row");row.dataset.checklist=entry.id;const text=el("span","card-list__text","["+(entry.status||"open")+"] "+(entry.item||dash));const editBtn=el("button","card-list__action","\u270e");editBtn.type="button";editBtn.dataset.checklistEdit=entry.id;editBtn.title="Edit checklist entry";editBtn.onclick=()=>{const itemInput=el("input","card-edit-input");itemInput.type="text";itemInput.value=entry.item||"";itemInput.dataset.checklistItem=entry.id;const statusInput=el("input","card-edit-input");statusInput.type="text";statusInput.value=entry.status||"";statusInput.dataset.checklistStatus=entry.id;const save=el("button","card-edit-save","Save");save.type="button";save.dataset.checklistSave=entry.id;save.onclick=()=>mutate("/checklist/update",{ref:dialog.dataset.ref,id:entry.id,item:itemInput.value,status:statusInput.value});const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const editor=el("span","card-edit");editor.append(itemInput,statusInput,save,cancel);row.replaceChildren(editor);statusInput.focus()};row.append(text,editBtn);list.appendChild(row)});box.appendChild(list);const form=el("form","card-checklist-form");const itemInput=el("input","");itemInput.name="item";itemInput.placeholder="New checklist item";const statusInput=el("input","");statusInput.name="status";statusInput.placeholder="Status";const submit=el("button","","Add entry");submit.type="submit";form.append(itemInput,statusInput,submit);form.onsubmit=event=>{event.preventDefault();if(!itemInput.value||!statusInput.value)return;mutate("/checklist/add",{ref:dialog.dataset.ref,item:itemInput.value,status:statusInput.value})};box.appendChild(form);sectionsHost.appendChild(section("Checklist",box))};maybeListSection("Subtasks",record.subtasks);if(record.linkage){const box=el("div","card-linkage");const linkedCache=new Map();const priorityRank=info=>info&&typeof info.priority==="number"?info.priority:-1;const linkedInfo=ref=>{if(linkedCache.has(ref))return linkedCache.get(ref);const seed=recordsByRef.get(ref);const promise=fetch("/record?type="+encodeURIComponent(dialog.dataset.type)+"&ref="+encodeURIComponent(ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("linked record failed");return response.json()}).catch(()=>seed||null);linkedCache.set(ref,promise);return promise};const sortLinkageTable=table=>{[...table.children].sort((a,b)=>(Number(b.dataset.priority??-1)-Number(a.dataset.priority??-1))||(a.getAttribute("data-linkage-row")||"").localeCompare(b.getAttribute("data-linkage-row")||"")).forEach(row=>table.appendChild(row))};const linkageRow=(ref,drop)=>{const row=el("div","card-linkage-table__row");row.setAttribute("data-linkage-row",ref);const titleCell=el("span","card-linkage__title","\u2026");const statusCell=el("span","card-linkage__status","");row.append(el("span","card-linkage__ref",ref),titleCell,statusCell);if(drop)row.appendChild(drop);linkedInfo(ref).then(info=>{titleCell.textContent=info&&info.title?info.title:dash;statusCell.textContent=info&&info.column?info.column:"";row.dataset.priority=priorityRank(info);if(row.parentElement&&row.parentElement.classList.contains("card-linkage-table"))sortLinkageTable(row.parentElement)});return row};const linkRoutes={hierarchy:{link:"/hierarchy/link",unlink:"/hierarchy/unlink"},subitem:{link:"/subitem/link",unlink:"/subitem/unlink"}};const linkageSpec={sow_ref:"hierarchy",epic_ref:"hierarchy",parent_sow_ref:"subitem",parent_epic_ref:"subitem",parent_ticket_ref:"subitem",epic_refs:"hierarchy",ticket_refs:"hierarchy",sub_sow_refs:"subitem",sub_epic_refs:"subitem",sub_ticket_refs:"subitem"};Object.keys(record.linkage).forEach(key=>{if(key==="links")return;const kind=linkageSpec[key];if(!kind)return;const value=record.linkage[key];const row=el("div","card-linkage__row");row.appendChild(el("span","card-linkage__label",key.replace(/_/g," ")));const holder=el("span","card-linkage__list");if(Array.isArray(value)){const table=el("div","card-linkage-table");value.forEach(ref=>{const drop=el("button","card-list__action card-list__action--danger","\u00d7");drop.type="button";drop.setAttribute("data-linkage-unlink",key+":"+ref);drop.title="Unlink";drop.onclick=()=>mutate(linkRoutes[kind].unlink,{parent:dialog.dataset.ref,child:ref});table.appendChild(linkageRow(ref,drop))});holder.appendChild(table);const input=el("input","card-edit-input");input.type="text";input.placeholder="REF";input.setAttribute("data-linkage-add",key);const add=el("button","card-edit-save","Link");add.type="button";add.setAttribute("data-linkage-add-save",key);add.onclick=()=>{if(input.value)mutate(linkRoutes[kind].link,{parent:dialog.dataset.ref,child:input.value})};holder.append(input,add)}else if(value){const table=el("div","card-linkage-table");const drop=el("button","card-list__action card-list__action--danger","Unlink");drop.type="button";drop.setAttribute("data-linkage-unlink",key+":"+String(value));drop.onclick=()=>mutate(linkRoutes[kind].unlink,{parent:String(value),child:dialog.dataset.ref});table.appendChild(linkageRow(String(value),drop));holder.appendChild(table)}else{const input=el("input","card-edit-input");input.type="text";input.placeholder="Parent REF";input.setAttribute("data-linkage-add",key);const add=el("button","card-edit-save","Link");add.type="button";add.setAttribute("data-linkage-add-save",key);add.onclick=()=>{if(input.value)mutate(linkRoutes[kind].link,{parent:input.value,child:dialog.dataset.ref})};holder.append(input,add)}row.appendChild(holder);box.appendChild(row)});const linksBox=el("div","card-linkage__links");const linkList=el("div","card-linkage-table");(record.linkage.links||[]).forEach(entry=>{const drop=el("button","card-list__action card-list__action--danger","\u00d7");drop.type="button";drop.setAttribute("data-link-remove",entry.type+":"+entry.ref);drop.title="Remove link";drop.onclick=()=>mutate("/link/remove",{from:dialog.dataset.ref,type:entry.type,to:entry.ref});const row=linkageRow(entry.ref,drop);row.classList.add("card-linkage-table__row--typed");row.insertBefore(el("span","card-linkage__type",entry.type),row.firstChild);linkList.appendChild(row)});linksBox.appendChild(linkList);const form=el("form","card-link-form");const select=el("select","");select.name="type";linkTypes.forEach(pair=>{[pair.outward,pair.inward].forEach(nameValue=>{if([...select.options].some(option=>option.value===nameValue))return;const option=el("option","",nameValue);option.value=nameValue;select.appendChild(option)})});const refInput=el("input","");refInput.name="to";refInput.placeholder="REF";const submit=el("button","","Add link");submit.type="submit";form.append(select,refInput,submit);form.onsubmit=event=>{event.preventDefault();if(!refInput.value)return;mutate("/link/add",{from:dialog.dataset.ref,type:select.value,to:refInput.value})};linksBox.appendChild(form);box.appendChild(linksBox);sectionsHost.appendChild(section("Linkage",box))}maybeListSection("Gate Passing Log",record.gate_passing_log);maybeListSection("Evidence",record.evidence);{const box=el("div","card-attachments");const strip=el("div","card-attachment-strip");sortByStamp(record.attachments,"added_at").forEach(reference=>strip.appendChild(attachChip(reference)));box.appendChild(strip);box.appendChild(attachInput());sectionsHost.appendChild(section("Attachments",box))};const comments=el("div","card-comments-box");const commentList=el("ul","card-comments");sortByStamp(record.comments,"created_at").forEach(comment=>{const item=el("li","card-comment");item.dataset.comment=comment.id;const head=el("div","card-comment__head");head.appendChild(el("strong","",peopleName(comment.author)));head.appendChild(el("span","card-comment__meta",comment.id+" \u00b7 "+humanDate(comment.created_at)+(comment.last_updated&&comment.last_updated!==comment.created_at?" \u00b7 edited "+humanDate(comment.last_updated):"")));const editButton=el("button","card-comment__action","Edit");editButton.type="button";editButton.dataset.commentEdit=comment.id;const removeButton=el("button","card-comment__action card-comment__action--danger","Delete");removeButton.type="button";removeButton.dataset.commentRemove=comment.id;head.append(editButton,removeButton);const body=comment.format==="text"?el("div","card-comment__body",comment.body):renderMarkdown(comment.body);item.append(head,body);const commentAttachments=el("div","card-comment__attachments");sortByStamp(comment.attachments,"added_at").forEach(reference=>commentAttachments.appendChild(attachChip(reference,comment.id)));commentAttachments.appendChild(attachInput(comment.id));item.appendChild(commentAttachments);editButton.onclick=()=>{const area=el("textarea","card-comment__editor");area.value=comment.body;const save=el("button","card-comment__action","Save");save.type="button";save.dataset.commentSave=comment.id;save.onclick=()=>mutate("/comment/update",{ref:dialog.dataset.ref,comment:comment.id,text:area.value});const cancel=el("button","card-comment__action","Cancel");cancel.type="button";cancel.onclick=()=>reloadCard();const editor=el("div","card-comment__edit");editor.append(area,save,cancel);body.replaceChildren(editor)};removeButton.onclick=()=>mutate("/comment/remove",{ref:dialog.dataset.ref,comment:comment.id});commentList.appendChild(item)});const composer=el("div","card-composer");const toggle=el("button","card-composer-toggle","\u002b Add a comment");toggle.type="button";const form=el("form","card-comment-form");form.hidden=true;const author=el("select","");author.name="author";people.forEach(person=>{const option=el("option","",person.name);option.value=person.id;author.appendChild(option)});const bar=el("div","card-md-bar");const text=el("textarea","");text.name="text";text.rows=4;text.placeholder="Write a comment - basic markdown supported";[["bold","B","**"],["italic","I","*"],["code","<>","`"],["list","\u2022","- "]].forEach(spec=>{const control=el("button","card-md-button",spec[1]);control.type="button";control.setAttribute("data-md",spec[0]);control.onclick=()=>{const start=text.selectionStart||0;const end=text.selectionEnd||0;const value=text.value;const selected=value.slice(start,end);if(spec[0]==="list"){const lines=(selected||"item").split("\n").map(line=>"- "+line).join("\n");text.value=value.slice(0,start)+lines+value.slice(end)}else{const mark=spec[2];text.value=value.slice(0,start)+mark+(selected||"text")+mark+value.slice(end)}text.focus()};bar.appendChild(control)});const submit=el("button","","Comment");submit.type="submit";form.append(author,bar,text,submit);toggle.onclick=()=>{toggle.hidden=true;form.hidden=false;text.focus()};form.onsubmit=event=>{event.preventDefault();if(!text.value)return;mutate("/comment/add",{ref:dialog.dataset.ref,author:author.value,text:text.value})};composer.append(toggle,form);comments.appendChild(composer);comments.appendChild(commentList);sectionsHost.appendChild(section("Comments",comments))};const showCard=record=>{if(!record)return;showError("");renderCard(record);if(!dialog.open)dialog.showModal()};const newCardField=(label,control)=>{const row=el("div","card-new__row");row.appendChild(el("label","card-new__label",label));row.appendChild(control);return row};const openNewCard=(type,column)=>{dialog.dataset.ref="";dialog.dataset.type=type;dialog.dataset.newColumn=column;lastDialogRecordJson="";showError("");const refLine=dialog.querySelector(".card-dialog__ref");refLine.replaceChildren(el("span","","New "+type+" \u00b7 "+column+" \u00b7 reference assigned on save"));dialog.querySelector("h2").replaceChildren(el("span","","New card"));const form=el("form","card-new");form.noValidate=true;const title=el("input","card-edit-input");title.type="text";title.required=true;title.name="title";title.placeholder="Title (required)";const description=el("textarea","card-edit-input");description.rows=4;description.name="description";const priority=el("select","card-edit-input");priority.name="priority";["","1","2","3","4","5"].forEach(value=>{const option=el("option","",value===""?dash:value+" "+priorityLabels[value]);option.value=value;priority.appendChild(option)});const assignee=el("select","card-edit-input");assignee.name="assignee";const noone=el("option","",dash);noone.value="";assignee.appendChild(noone);people.forEach(person=>{const option=el("option","",person.name);option.value=person.id;assignee.appendChild(option)});form.append(newCardField("Title",title),newCardField("Description",description),newCardField("Priority",priority),newCardField("Assignee",assignee));const submit=el("button","card-edit-save","Create card");submit.type="submit";submit.dataset.createCard=column;const cancel=el("button","card-edit-cancel","Cancel");cancel.type="button";cancel.onclick=()=>dialog.close();const actions=el("div","card-new__actions");actions.append(submit,cancel);form.appendChild(actions);form.onsubmit=event=>{event.preventDefault();if(!title.value.trim()){showError("A title is required");title.focus();return}fetch("/create",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:type,column:column,title:title.value,description:description.value,priority:priority.value,assignee:assignee.value})}).then(response=>response.json()).then(result=>{window.__tiraLastMutation="/create";window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;if(!result.ok){showError(result.error||"Unable to create the card");return}dialog.dataset.ref=result.record.ref;delete dialog.dataset.newColumn;showError("");renderCard(result.record);refreshDashboard()}).catch(()=>{window.__tiraMutationSeq=(window.__tiraMutationSeq||0)+1;showError("Unable to create the card")})};sectionsHost.replaceChildren(section("New card",form));if(!dialog.open)dialog.showModal();title.focus()};dialog.querySelector(".card-dialog__close").addEventListener("click",()=>dialog.close());const buildCard=record=>{const item=document.createElement("li");item.dataset.ref=record.ref;item.dataset.mtime=String(((record._mtime||0)*1000)||Date.parse(record.updated_at||record.last_updated||"")||0);const button=document.createElement("button");button.className="card";button.type="button";button.dataset.ref=record.ref;const ref=document.createElement("span");ref.className="card__ref";ref.textContent=record.ref;button.appendChild(ref);if(showTitles){const title=document.createElement("span");title.className="card__title";title.textContent=record.title||"";button.appendChild(title)}item.appendChild(button);return item};const updateBoards=data=>{recordsByRef.clear();document.querySelectorAll(".board").forEach(board=>{const type=board.dataset.type;(data._column_order?.[type]||[]).forEach(column=>{const list=[...board.querySelectorAll(".cards")].find(node=>node.dataset.column===column);if(!list)return;const records=data[type]?.[column]||[];records.forEach(record=>recordsByRef.set(record.ref,record));list.replaceChildren(...records.map(buildCard))});sortBoard(board,document.documentElement.dataset.sort)});bindBoards();updateColumnCounts();markSelection()};}
      : '';
    my $card_binding = $args{live}
      ? q{card.onclick=event=>{if(window.__tiraDragEndAt&&Date.now()-window.__tiraDragEndAt<50){window.__tiraDragEndAt=0;return}if(event.shiftKey){event.preventDefault();toggleSelection(card);return}if(selection.size)clearSelection();const ref=card.dataset.ref;const type=card.closest(".board").dataset.type;fetch("/record?type="+encodeURIComponent(type)+"&ref="+encodeURIComponent(ref),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("detail failed");return response.json()}).then(showCard).catch(()=>{});};}
      : q{card.onclick=()=>card.classList.toggle("is-selected");};
    my $dialog = $args{live}
      ? '<dialog class="card-dialog"><header><div><span class="card-dialog__ref">Card</span><h2 class="card-dialog__title">Details</h2></div><button class="card-dialog__close" type="button" aria-label="Close" autofocus>&times;</button></header><p class="card-dialog__error" hidden></p><div class="card-viewer" hidden><header><span class="card-viewer__name"></span><a class="card-viewer__download" target="_blank">Download</a><button class="card-viewer__close" type="button" aria-label="Close viewer">&times;</button></header><img hidden alt="attachment preview"><iframe hidden title="attachment preview"></iframe><pre class="card-viewer__text" hidden></pre><video class="card-viewer__video" hidden controls playsinline></video><audio class="card-viewer__audio" hidden controls></audio><div class="card-viewer__fallback" hidden><p>Preview is not supported for this file in this browser.</p><p>Use the Download button above to open it locally.</p></div></div><div class="card-dialog__sections"></div></dialog>'
      : '';
    my $with_title = $args{with_title} ? '1' : '0';
    my $initial_refresh = $args{live} ? 'refreshDashboard();' : '';
    my $drag_script = $args{live}
      ? q{const selection=new Set();const selectedCards=()=>[...document.querySelectorAll(".card.is-selected")];const markSelection=()=>{document.querySelectorAll(".card").forEach(card=>card.classList.toggle("is-selected",selection.has(card.dataset.ref)))};const clearSelection=()=>{selection.clear();markSelection()};const toggleSelection=card=>{const ref=card.dataset.ref;if(selection.has(ref))selection.delete(ref);else selection.add(ref);markSelection()};const dragState={card:null,ghost:null,started:false,startX:0,startY:0,lastX:0,lastY:0,timer:null,pointerId:null,fromTouch:false};const clearDrag=()=>{if(dragState.timer)clearTimeout(dragState.timer);if(dragState.ghost)dragState.ghost.remove();document.querySelectorAll(".cards.is-drop-target").forEach(node=>node.classList.remove("is-drop-target"));dragState.card=null;dragState.ghost=null;dragState.started=false;dragState.timer=null;dragState.pointerId=null};const positionGhost=(x,y)=>{if(dragState.ghost){dragState.ghost.style.left=x+"px";dragState.ghost.style.top=y+"px"}};const beginDrag=()=>{if(!dragState.card||dragState.started)return;dragState.started=true;const ghost=dragState.card.cloneNode(true);ghost.className="card card--ghost";ghost.style.width=dragState.card.offsetWidth+"px";const moving=dragState.refs.length;if(moving>1){const badge=document.createElement("span");badge.className="card__batch";badge.textContent=moving+" cards";ghost.appendChild(badge)}document.body.appendChild(ghost);dragState.ghost=ghost;positionGhost(dragState.lastX,dragState.lastY)};const columnAt=(x,y)=>{const board=dragState.card?dragState.card.closest(".board"):null;if(!board)return null;const hit=document.elementFromPoint(x,y);const direct=hit?hit.closest(".cards"):null;if(direct&&direct.closest(".board")===board)return direct;const boardRect=board.getBoundingClientRect();if(y<boardRect.top||y>boardRect.bottom)return null;let best=null;[...board.querySelectorAll(".cards")].forEach(list=>{const rect=list.getBoundingClientRect();if(x>=rect.left&&x<=rect.right)best=list});return best};document.addEventListener("pointerdown",event=>{const card=event.target.closest(".card");if(!card||event.button)return;if(event.shiftKey)return;dragState.card=card;dragState.refs=selection.has(card.dataset.ref)&&selection.size>1?selectedCards().map(node=>node.dataset.ref):[card.dataset.ref];dragState.startX=dragState.lastX=event.clientX;dragState.startY=dragState.lastY=event.clientY;dragState.pointerId=event.pointerId;dragState.fromTouch=event.pointerType==="touch";if(dragState.fromTouch){dragState.timer=setTimeout(beginDrag,250)}});document.addEventListener("pointermove",event=>{if(!dragState.card||event.pointerId!==dragState.pointerId)return;dragState.lastX=event.clientX;dragState.lastY=event.clientY;if(!dragState.started){const distance=Math.hypot(event.clientX-dragState.startX,event.clientY-dragState.startY);if(!dragState.fromTouch&&distance>6)beginDrag();else if(dragState.fromTouch&&distance>14&&dragState.timer){clearTimeout(dragState.timer);dragState.timer=null}}if(dragState.started){if(event.cancelable)event.preventDefault();positionGhost(event.clientX,event.clientY);const list=columnAt(event.clientX,event.clientY);document.querySelectorAll(".cards.is-drop-target").forEach(node=>{if(node!==list)node.classList.remove("is-drop-target")});if(list)list.classList.add("is-drop-target")}},{passive:false});document.addEventListener("pointerup",event=>{if(!dragState.card||event.pointerId!==dragState.pointerId)return;const wasStarted=dragState.started;const movingRefs=(dragState.refs&&dragState.refs.length?dragState.refs:[dragState.card.dataset.ref]).slice();const board=dragState.card.closest(".board");const list=wasStarted?columnAt(event.clientX,event.clientY):null;clearDrag();if(wasStarted){window.__tiraDragEndAt=Date.now();if(list&&board){Promise.all(movingRefs.map(ref=>fetch("/move",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({type:board.dataset.type,ref:ref,column:list.dataset.column})}).then(response=>{if(!response.ok)throw new Error("move failed");return response.json()}))).then(()=>{clearSelection();return refreshDashboard()}).catch(()=>{})}}});document.addEventListener("touchmove",event=>{if(dragState.started&&event.cancelable)event.preventDefault()},{passive:false});document.addEventListener("pointercancel",()=>clearDrag());}
      : '';
    return '<!doctype html><html lang="en" data-with-title="' . $with_title . '"><head><meta charset="utf-8">'
      . '<meta name="viewport" content="width=device-width,initial-scale=1"><title>'
      . $project_heading . ' :: '
      . ( @rendered_boards == 1 ? $rendered_boards[0] : 'Kanban' )
      . ' :: ' . $rendered_cards . '</title><style>'
      . <<'CSS'
:root{color-scheme:dark;--ink:#f8fafc;--muted:#9aa8bd;--panel:rgba(14,23,42,.76);--line:rgba(148,163,184,.16);font-family:Inter,ui-sans-serif,system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}*{box-sizing:border-box}body{margin:0;min-height:100vh;color:var(--ink);background:radial-gradient(circle at 12% 4%,rgba(99,102,241,.3),transparent 30rem),radial-gradient(circle at 88% 18%,rgba(14,165,233,.2),transparent 32rem),linear-gradient(145deg,#050816 0%,#0b1022 52%,#11182c 100%);background-attachment:fixed}body:before{content:"";position:fixed;inset:0;pointer-events:none;background-image:linear-gradient(rgba(255,255,255,.018) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.018) 1px,transparent 1px);background-size:32px 32px}.shell{position:relative;width:min(96rem,calc(100% - 2rem));margin:auto;padding:3.5rem 0 5rem}.hero{display:flex;align-items:end;justify-content:space-between;gap:2rem;margin:0 0 2.5rem;padding:0 .4rem}.hero__aside{display:grid;justify-items:end;gap:.7rem}.eyebrow,.board__kicker{color:#a5b4fc;font-size:.72rem;font-weight:800;letter-spacing:.18em;text-transform:uppercase}.hero h1{margin:.35rem 0 0;font-size:clamp(2.2rem,6vw,4.8rem);line-height:.9;letter-spacing:-.055em;background:linear-gradient(110deg,#fff 15%,#c4b5fd 52%,#67e8f9);-webkit-background-clip:text;color:transparent}.hero p{max-width:30rem;margin:0;color:var(--muted);line-height:1.6;text-align:right}.refresh-status{display:inline-flex;align-items:center;gap:.45rem;padding:.38rem .7rem;color:#a5f3fc;background:rgba(8,145,178,.13);border:1px solid rgba(103,232,249,.25);border-radius:999px;font:750 .72rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.04em}.refresh-status:before{content:"";width:.42rem;height:.42rem;border-radius:50%;background:#22d3ee;box-shadow:0 0 12px #22d3ee}.board{--accent:#818cf8;margin:0 0 2rem;padding:1.15rem;border:1px solid var(--line);border-radius:1.5rem;background:linear-gradient(145deg,rgba(255,255,255,.075),rgba(255,255,255,.025)),var(--panel);box-shadow:0 28px 70px rgba(0,0,0,.32),inset 0 1px rgba(255,255,255,.08);backdrop-filter:blur(20px)}.board--sow{--accent:#f59e0b}.board--epic{--accent:#a78bfa}.board--ticket{--accent:#22d3ee}.board__header{display:flex;align-items:center;gap:1rem;padding:.4rem .45rem 1.15rem}.board__header:before{content:"";width:.62rem;height:2.8rem;border-radius:1rem;background:var(--accent);box-shadow:0 0 28px var(--accent)}.board__header h2{margin:0;font-size:1.35rem;letter-spacing:-.025em}.board__kicker{margin-left:auto;color:var(--muted)}.sorter,.widther{display:flex;gap:.35rem;padding:.3rem;margin-left:.3rem;border:1px solid var(--line);border-radius:.8rem;background:rgba(2,6,23,.32)}.sorter button,.widther button{padding:.48rem .68rem;color:var(--muted);background:transparent;border:0;border-radius:.55rem;font-size:.72rem;font-weight:750;cursor:pointer}.sorter button:hover,.sorter button.is-active,.widther button:hover,.widther button.is-active{color:#07111f;background:var(--accent)}html[data-width="fit"] .shell{width:100%}html[data-width="fit"] .board{margin-left:0;margin-right:0;padding-left:0;padding-right:0}html[data-width="fit"] .board__header{padding-left:.5rem;padding-right:.5rem}html[data-width="fit"] .board__scroll{overflow-x:hidden}html[data-width="fit"] table{min-width:0}html[data-width="fit"] th,html[data-width="fit"] td{min-width:0;width:auto}html[data-width="fit"] th{padding:.75rem .6rem;font-size:.7rem;overflow-wrap:anywhere}html[data-width="fit"] .card{padding:.7rem}html[data-width="fit"] .card__title{margin-top:.45rem;font-size:.8rem;line-height:1.3;overflow-wrap:break-word;hyphens:auto}html[data-width="fit"] .card__ref{font-size:.68rem;overflow-wrap:anywhere}.board__scroll{overflow-x:auto;padding:0 0 .4rem;scrollbar-color:var(--accent) transparent}table{width:100%;min-width:max-content;border-spacing:.7rem 0;table-layout:fixed}th{position:sticky;top:0;z-index:2;width:17rem;min-width:17rem;padding:.9rem 1rem;text-align:left;color:#dbeafe;background:rgba(15,23,42,.94);border:1px solid var(--line);border-bottom:2px solid var(--accent);border-radius:.85rem .85rem .25rem .25rem;font-size:.78rem;letter-spacing:.08em;text-transform:uppercase}td{width:17rem;min-width:17rem;padding:.75rem .35rem;vertical-align:top;background:rgba(2,6,23,.28);border-radius:0 0 1rem 1rem}.cards{display:grid;gap:.7rem;margin:0;padding:0;list-style:none;min-width:0}.cards>li{min-width:0}.card{display:block;width:100%;min-width:0;padding:1rem;text-align:left;color:var(--ink);background:linear-gradient(145deg,rgba(255,255,255,.1),rgba(255,255,255,.045));border:1px solid rgba(255,255,255,.1);border-radius:1rem;box-shadow:0 10px 25px rgba(0,0,0,.18);cursor:pointer;transition:transform .18s ease,border-color .18s ease,box-shadow .18s ease}.card:hover{transform:translateY(-3px);border-color:var(--accent);box-shadow:0 14px 34px rgba(0,0,0,.28),0 0 0 1px var(--accent)}.card.is-selected{border-color:var(--accent);box-shadow:0 0 0 2px var(--accent),0 16px 40px rgba(0,0,0,.32)}.card__batch{display:block;margin-top:.5rem;padding:.2rem .45rem;color:#07111f;background:var(--accent);border-radius:.5rem;font:800 .7rem/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;text-align:center}.card__ref{display:block;color:var(--accent);font:800 .76rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.06em}.card__title{display:block;margin-top:.62rem;color:#eef2ff;font-size:.94rem;font-weight:650;line-height:1.35}.card{touch-action:pan-y;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}.card--ghost{position:fixed;z-index:60;opacity:.88;transform:translate(-50%,-30%) rotate(3deg);pointer-events:none;box-shadow:0 24px 60px rgba(0,0,0,.55),0 0 0 1px var(--accent)}.cards.is-drop-target{outline:2px dashed #67e8f9;outline-offset:4px;border-radius:.8rem;background:rgba(103,232,249,.07)}@media(max-width:720px){html[data-width="fit"] .board__scroll{overflow-x:auto}html[data-width="fit"] th,html[data-width="fit"] td{min-width:15rem;width:15rem}.shell{width:min(100% - 1rem,96rem);padding-top:2rem}.hero{display:block}.hero__aside{justify-items:start;margin-top:1rem}.hero p{margin:0;text-align:left}.board{padding:.7rem;border-radius:1rem}.board__header{flex-wrap:wrap}.board__kicker{margin-left:0}.sorter{width:100%;margin:0}th,td{min-width:15rem;width:15rem}}
.last-updated{color:#7dd3fc;font:650 .7rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace}
.cards{min-height:2rem}
.card-dialog{position:fixed;inset:0;margin:auto;width:min(54rem,calc(100% - 2rem));height:fit-content;max-height:86vh;padding:0;color:var(--ink);background:linear-gradient(145deg,#111a32,#080d1c);border:1px solid rgba(103,232,249,.3);border-radius:1.4rem;box-shadow:0 35px 100px rgba(0,0,0,.7)}.card-dialog::backdrop{background:rgba(2,6,23,.78);backdrop-filter:blur(8px)}.card-dialog header{display:flex;justify-content:space-between;align-items:start;padding:1.4rem 1.5rem;border-bottom:1px solid var(--line)}.card-dialog h2{margin:.35rem 0 0;font-size:1.3rem}.card-dialog__ref{display:inline-flex;align-items:center;gap:.4rem;color:#67e8f9;font:800 .76rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}.card-status{padding:.3rem .5rem;color:#67e8f9;background:rgba(8,145,178,.12);border:1px solid rgba(103,232,249,.3);border-radius:.5rem;font:750 .74rem/1 ui-monospace,SFMono-Regular,Menlo,monospace;cursor:pointer}.card-dialog__close{color:var(--ink);background:rgba(255,255,255,.08);border:1px solid var(--line);border-radius:.7rem;font-size:1.4rem;cursor:pointer}
.card-dialog__error{margin:0;padding:.75rem 1.5rem;color:#fecaca;background:rgba(153,27,27,.35);border-bottom:1px solid rgba(248,113,113,.4);font-size:.82rem}.card-dialog__sections{display:grid;gap:1.1rem;padding:1.3rem 1.5rem;overflow-y:auto;overflow-x:hidden;max-height:calc(86vh - 6.5rem)}
.card-section{padding:1rem 1.1rem;background:rgba(255,255,255,.035);border:1px solid var(--line);border-radius:1rem;overflow-wrap:anywhere;min-width:0}.card-section__title{margin:0 0 .7rem;color:#a5b4fc;font-size:.72rem;font-weight:800;letter-spacing:.16em;text-transform:uppercase}
.card-details{display:grid;grid-template-columns:auto 1fr auto 1fr;gap:.45rem 1rem;margin:0}.card-details dt{color:var(--muted);font-size:.74rem;font-weight:700;letter-spacing:.05em;text-transform:uppercase;align-self:center}.card-details dd{margin:0;font-size:.88rem;align-self:center}
.card-text{color:#dbeafe;font-size:.9rem;line-height:1.6;white-space:pre-wrap}
.card-list{margin:0;padding-left:1.2rem;display:grid;gap:.3rem;color:#dbeafe;font-size:.88rem;line-height:1.5}
.card-value{display:inline-flex;align-items:center;gap:.45rem}.card-edit-button{padding:.1rem .38rem;color:#67e8f9;background:transparent;border:1px solid rgba(103,232,249,.25);border-radius:.5rem;font-size:.82rem;cursor:pointer;opacity:.65;transition:opacity .15s ease}.card-value:hover .card-edit-button,.card-dialog h2 .card-edit-button,.card-edit-button:focus-visible{opacity:1}.card-edit-button:hover{border-color:rgba(103,232,249,.4);background:rgba(8,145,178,.15)}
.card-edit{display:inline-flex;align-items:center;gap:.45rem;flex-wrap:wrap}.card-edit-input{min-width:12rem;padding:.45rem .6rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid rgba(103,232,249,.35);border-radius:.6rem;font:inherit;font-size:.86rem}textarea.card-edit-input{width:100%;min-width:16rem}.card-edit-save,.card-edit-cancel,.card-comment__action{padding:.4rem .7rem;color:#07111f;background:#67e8f9;border:0;border-radius:.55rem;font-size:.74rem;font-weight:750;cursor:pointer}.card-edit-cancel,.card-comment__action{color:var(--ink);background:rgba(255,255,255,.1);border:1px solid var(--line)}.card-comment__action--danger:hover{color:#fecaca;border-color:rgba(248,113,113,.5);background:rgba(153,27,27,.3)}
.card-comments{margin:0;padding:0;list-style:none;display:grid;gap:.8rem}.card-comment{padding:.85rem 1rem;background:rgba(2,6,23,.4);border:1px solid var(--line);border-radius:.9rem}.card-comment__head{display:flex;align-items:center;gap:.7rem;margin-bottom:.45rem;flex-wrap:wrap}.card-comment__head strong{font-size:.86rem}.card-comment__meta{margin-right:auto;color:var(--muted);font:650 .68rem/1.2 ui-monospace,SFMono-Regular,Menlo,monospace}.card-comment__body{color:#dbeafe;font-size:.88rem;line-height:1.55;white-space:pre-wrap}.card-comment__edit{display:grid;gap:.5rem}.card-comment__editor{width:100%;min-height:4.5rem;padding:.55rem .7rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid rgba(103,232,249,.35);border-radius:.6rem;font:inherit;font-size:.86rem}
.card-comment-form[hidden]{display:none}.card-comment-form{display:grid;gap:.6rem;margin-top:.9rem;padding-top:.9rem;border-top:1px solid var(--line)}.card-comment-form select,.card-comment-form textarea{padding:.5rem .65rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid var(--line);border-radius:.6rem;font:inherit;font-size:.86rem}.card-comment-form button{justify-self:start;padding:.5rem 1rem;color:#07111f;background:linear-gradient(110deg,#67e8f9,#a5b4fc);border:0;border-radius:.6rem;font-size:.8rem;font-weight:800;cursor:pointer}
.card-attachment-strip{display:flex;flex-direction:column;gap:.45rem;margin-bottom:.8rem}.card-attachment{display:flex;width:100%;align-items:center;overflow:hidden;border:1px solid rgba(103,232,249,.3);border-radius:.7rem;background:rgba(8,145,178,.12)}.card-attachment__view{flex:1;display:flex;align-items:center;justify-content:space-between;gap:1rem;padding:.5rem .8rem;color:#a5f3fc;background:transparent;border:0;font-size:.8rem;font-weight:650;cursor:pointer;text-align:left;min-width:0}.card-attachment__view:hover{background:rgba(8,145,178,.25)}.card-attachment__delete{padding:.5rem .6rem;color:var(--muted);background:transparent;border:0;border-left:1px solid rgba(103,232,249,.2);font-size:.9rem;cursor:pointer}.card-attachment__delete:hover{color:#fecaca;background:rgba(153,27,27,.3)}
.card-attach-add{display:inline-flex;align-items:center;padding:.45rem .8rem;color:var(--muted);border:1px dashed var(--line);border-radius:.7rem;font-size:.76rem;font-weight:700;cursor:pointer}.card-attach-add:hover{color:#a5f3fc;border-color:rgba(103,232,249,.4)}.card-attach-add input{display:none}
.card-comment__attachments{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.6rem}
.card-attachment__date{margin-left:auto;flex-shrink:0;color:var(--muted);font:650 .68rem/1 ui-monospace,SFMono-Regular,Menlo,monospace}
.card-composer{margin-bottom:.9rem}.card-composer-toggle{width:100%;padding:.6rem .9rem;text-align:left;color:var(--muted);background:rgba(2,6,23,.4);border:1px dashed var(--line);border-radius:.8rem;font-size:.84rem;font-weight:650;cursor:pointer}.card-composer-toggle:hover{color:#a5f3fc;border-color:rgba(103,232,249,.4)}
.card-md-bar{display:flex;gap:.4rem}.card-md-button{min-width:2.1rem;padding:.35rem .5rem;color:#a5f3fc;background:rgba(8,145,178,.12);border:1px solid rgba(103,232,249,.3);border-radius:.5rem;font-size:.78rem;font-weight:800;cursor:pointer}.card-md-button:hover{background:rgba(8,145,178,.3)}
.card-md-p{margin:.2rem 0}.card-md-list{margin:.2rem 0;padding-left:1.2rem}.card-md-code{padding:.08rem .35rem;background:rgba(2,6,23,.65);border:1px solid var(--line);border-radius:.35rem;font:600 .82em ui-monospace,SFMono-Regular,Menlo,monospace;color:#a5f3fc}
.card-list__row{display:flex;align-items:center;gap:.5rem}.card-list__text{margin-right:auto}.card-list__action{padding:.1rem .4rem;color:#67e8f9;background:transparent;border:1px solid rgba(103,232,249,.25);border-radius:.5rem;font-size:.78rem;cursor:pointer;opacity:.65}.card-list__action:hover{opacity:1}.card-list__action--danger:hover{color:#fecaca;border-color:rgba(248,113,113,.5);background:rgba(153,27,27,.3)}
.card-list-wrap{display:grid;gap:.6rem}.card-list__adder{display:flex;gap:.5rem;align-items:center}.card-list__adder .card-edit-input{flex:1;min-width:8rem}
.card-checklist{display:grid;gap:.7rem}.card-checklist-form{display:flex;gap:.5rem;flex-wrap:wrap;padding-top:.6rem;border-top:1px solid var(--line)}.card-checklist-form input{flex:1;min-width:8rem;padding:.5rem .65rem;color:var(--ink);background:rgba(2,6,23,.6);border:1px solid var(--line);border-radius:.6rem;font:inherit;font-size:.86rem}.card-checklist-form button{padding:.5rem 1rem;color:#07111f;background:linear-gradient(110deg,#67e8f9,#a5b4fc);border:0;border-radius:.6rem;font-size:.78rem;font-weight:800;cursor:pointer}
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
      . '</style></head><body><main class="shell"><header class="hero"><div><span class="eyebrow">Tira Kanban &middot; Filesystem-native flow</span><h1>' . $project_heading . '</h1></div><div class="hero__aside"><p>Focused work, arranged by state. Select a card to keep your place.</p><span class="refresh-status" aria-live="polite">Refresh 60s</span><span class="last-updated">Last updated: pending</span></div></header>'
      . $boards
      . '</main>' . $dialog
      . q~<script>const pageSize=10;const pageState=new Map();const filterState=new Map();const columnKey=list=>list.closest(".board").dataset.type+"::"+list.dataset.column;
const renderColumns=()=>{document.querySelectorAll(".board").forEach(board=>{const matches=filterState.get(board.dataset.type);board.querySelectorAll(".cards").forEach(list=>{const key=columnKey(list);const limit=pageState.get(key)||pageSize;const items=[...list.children];const matched=items.filter(item=>!matches||matches.has(item.dataset.ref));items.forEach(item=>{item.hidden=true});matched.slice(0,limit).forEach(item=>{item.hidden=false});const cell=list.parentElement;let more=cell.querySelector(".column__more");if(!more){more=document.createElement("button");more.type="button";more.className="column__more";more.setAttribute("data-more-for",list.dataset.column);more.onclick=()=>{pageState.set(key,(pageState.get(key)||pageSize)+pageSize);renderColumns()};list.insertAdjacentElement("afterend",more)}const remaining=matched.length-Math.min(limit,matched.length);more.textContent="Show "+Math.min(remaining,pageSize)+" more of "+remaining;more.hidden=remaining<=0;const badge=board.querySelector('[data-count-for="'+list.dataset.column+'"]');if(badge){const total=matched.length;badge.textContent=total?String(total):"";badge.hidden=total===0}})})};
const applyFilter=(type,text)=>{const board=document.querySelector(".board--"+type);if(!board)return Promise.resolve();pageState.clear();if(!text){filterState.delete(type);renderColumns();return Promise.resolve()}return fetch("/search?type="+encodeURIComponent(type)+"&text="+encodeURIComponent(text),{cache:"no-store"}).then(response=>{if(!response.ok)throw new Error("filter failed");return response.json()}).then(refs=>{filterState.set(type,new Set(refs));window.__tiraFilterSeq=(window.__tiraFilterSeq||0)+1;renderColumns()}).catch(()=>{filterState.set(type,new Set());renderColumns()})};
const updateColumnCounts=()=>renderColumns();const sortBoard=(board,mode)=>{board.querySelectorAll(".cards").forEach(list=>{const cards=[...list.children];cards.sort((a,b)=>mode==="ref"?a.dataset.ref.localeCompare(b.dataset.ref):(Number(b.dataset.mtime)-Number(a.dataset.mtime)||a.dataset.ref.localeCompare(b.dataset.ref)));cards.forEach(card=>list.appendChild(card))});board.querySelectorAll("[data-sort]").forEach(button=>button.classList.toggle("is-active",button.dataset.sort===mode));document.documentElement.dataset.sort=mode};const widthStorageKey="tira-column-width";const readStoredWidth=()=>{try{return localStorage.getItem(widthStorageKey)}catch(error){return null}};const storeWidth=mode=>{try{localStorage.setItem(widthStorageKey,mode)}catch(error){}};const applyWidth=(mode,persist)=>{const chosen=mode==="fit"?"fit":"standard";document.documentElement.dataset.width=chosen;document.querySelectorAll("[data-width]").forEach(button=>button.classList.toggle("is-active",button.dataset.width===chosen));if(persist)storeWidth(chosen)};~ . $live_helpers
      . q~const bindBoards=()=>{document.querySelectorAll(".card").forEach(card=>{~ . $card_binding
      . q~});document.querySelectorAll(".board").forEach(board=>board.querySelectorAll("[data-sort]").forEach(button=>button.onclick=()=>sortBoard(board,button.dataset.sort)));document.querySelectorAll("[data-width]").forEach(button=>button.onclick=()=>applyWidth(button.dataset.width,true));document.querySelectorAll("[data-add-card]").forEach(button=>button.onclick=()=>openNewCard(button.closest(".board").dataset.type,button.dataset.addCard));document.querySelectorAll("[data-filter]").forEach(input=>{if(input.dataset.bound)return;input.dataset.bound="1";let timer=null;input.oninput=()=>{if(timer)clearTimeout(timer);timer=setTimeout(()=>applyFilter(input.dataset.filter,input.value.trim()),200)}})};const markUpdated=()=>{document.querySelector(".last-updated").textContent=`Last updated: ${new Date().toLocaleString()}`};document.documentElement.dataset.sort="mtime";bindBoards();updateColumnCounts();applyWidth(readStoredWidth(),false);document.documentElement.dataset.ready="true";markUpdated();const params=new URLSearchParams(location.search);const rawRefresh=params.get("refresh");const refreshSeconds=/^\d+$/.test(rawRefresh||"")?Math.max(1,Number(rawRefresh)):60;document.documentElement.dataset.refresh=String(refreshSeconds);document.querySelector(".refresh-status").textContent=`Refresh ${refreshSeconds}s`;const refreshDashboard=()=>~ . $refresh_action
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
    if ( ref($data) eq 'HASH' && exists $data->{ref} ) {
        my $description = $data->{description} ne '' ? $data->{description} : '_No description._';
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
        return "# $data->{ref}: $data->{title}\n\n$description\n\n"
          . "- Type: `$data->{type}`\n"
          . "- Assignee: $assignee\n"
          . "- Reporter: $reporter\n"
          . "- Priority: $priority\n"
          . "- Created: $data->{created_at}\n"
          . "- Last Updated: $data->{last_updated}\n"
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
    my $previous;
    if ( ref $data eq 'HASH' && defined $data->{ref} && $data->{ref} =~ /\A([A-Z][A-Z0-9-]{0,31}-\d{1,12})\z/ ) {
        my $ref = $1;
        $previous = -f $path ? eval { $self->_read_json($path) } : undef;
        my @entries = $self->_journal_changes( $previous // {}, $data );
        $self->_journal_record( ref => $ref, op => ( $previous ? 'update' : 'create' ), entries => \@entries )
          if @entries;
    }
    my $json = json_object()->canonical->pretty->utf8->encode($data);
    $self->_atomic_write( $path, $json );
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

sub _atomic_write {
    my ( $self, $path, $content ) = @_;
    my $dir = dirname($path);
    my ( $fh, $temporary ) = tempfile( '.tira-write-XXXXXX', DIR => $dir, UNLINK => 0 );
    $temporary = $self->_canonical_path( $temporary, "temporary file for '$path'" );
    binmode $fh, ':raw';
    print {$fh} $content or die "Cannot write temporary file for '$path': $!\n";
    close $fh or die "Cannot close temporary file for '$path': $!\n";
    rename $temporary, $path or do {
        my $error = $!;
        unlink $temporary;
        die "Cannot replace '$path': $error\n";
    };
    return 1;
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
